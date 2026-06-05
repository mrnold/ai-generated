#!/usr/bin/env bash
# Discover E2E_BASE_IMAGE, E2E_VDDK_IMAGE, and VDDK ConfigMaps from the cluster.
#
# Usage:
#   ./e2e/discover-images.sh              # print suggested config.env lines
#   eval "$(./e2e/discover-images.sh --export)"
#   ./e2e/build-image.sh --discover       # discover then build
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${E2E_CONFIG:-${SCRIPT_DIR}/config.env}"
if [[ -f "${CONFIG}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG}"
fi

EXPORT=0
SCOPE="all"
CDI_NS="${E2E_CDI_NAMESPACE:-cdi}"
E2E_TARGET_NS="${E2E_NAMESPACE:-}"
E2E_TARGET_PVC="${E2E_PVC_NAME:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --export)
      EXPORT=1
      shift
      ;;
    --vddk-only)
      SCOPE="vddk"
      shift
      ;;
    --base-only)
      SCOPE="base"
      shift
      ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [options]

Print image references for e2e/config.env by querying CDI and Forklift on the
current kubectl context. Importer pods are not used.

Options:
  --export      Emit shell assignments (E2E_BASE_IMAGE, E2E_VDDK_IMAGE, E2E_VDDK_CONFIGMAP)
  --vddk-only   Discover/export VDDK image and ConfigMaps only
  --base-only   Discover/export CDI importer base only

Reads e2e/config.env when present (E2E_NAMESPACE / E2E_PVC_NAME steer ConfigMap pick).
EOF
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found in PATH" >&2
  exit 1
fi

say() {
  if [[ "${EXPORT}" -eq 0 ]]; then
    echo "$@"
  fi
}

emit() {
  if [[ "${EXPORT}" -eq 1 ]]; then
    echo "$@"
  fi
}

importer_from_deployments_json() {
  local json
  json="$(kubectl get deployment -A -o json 2>/dev/null || true)"
  [[ -z "${json}" ]] && return 1
  echo "${json}" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(1)
preferred = (
    ("openshift-cnv", "cdi-deployment"),
    ("openshift-cnv", "cdi-operator"),
    ("cdi", "cdi-deployment"),
    ("cdi", "cdi-operator"),
    ("kubevirt-hyperconverged", "cdi-deployment"),
    ("kubevirt-hyperconverged", "cdi-operator"),
)
by_key = {}
for item in data.get("items", []):
    meta = item.get("metadata", {})
    key = (meta.get("namespace"), meta.get("name"))
    by_key[key] = item
for key in preferred:
    item = by_key.get(key)
    if not item:
        continue
    for c in item.get("spec", {}).get("template", {}).get("spec", {}).get("containers", []):
        for e in c.get("env", []):
            if e.get("name") == "IMPORTER_IMAGE" and e.get("value"):
                print(e["value"])
                sys.exit(0)
for item in data.get("items", []):
    name = item.get("metadata", {}).get("name") or ""
    if "cdi" not in name:
        continue
    for c in item.get("spec", {}).get("template", {}).get("spec", {}).get("containers", []):
        for e in c.get("env", []):
            if e.get("name") == "IMPORTER_IMAGE" and e.get("value"):
                print(e["value"])
                sys.exit(0)
sys.exit(1)
' 2>/dev/null || true
}

importer_from_csv() {
  local json
  json="$(kubectl get clusterserviceversions.operators.coreos.com -A -o json 2>/dev/null || true)"
  [[ -z "${json}" ]] && return 1
  echo "${json}" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(1)
for item in data.get("items", []):
    name = item.get("metadata", {}).get("name") or ""
    if "cdi" not in name.lower() and "hyperconverged" not in name.lower():
        continue
    for rel in item.get("spec", {}).get("relatedImages", []) or []:
        img = rel.get("image") or ""
        if "cdi-importer" in img:
            print(img)
            sys.exit(0)
sys.exit(1)
' 2>/dev/null || true
}

discover_cdi_importer() {
  local img
  if img="$(importer_from_deployments_json)"; then
    [[ -n "${img}" ]] && echo "${img}" && return 0
  fi
  if img="$(importer_from_csv)"; then
    [[ -n "${img}" ]] && echo "${img}" && return 0
  fi
  return 1
}

# Scan cluster ConfigMaps/PVCs for VDDK-related objects. Sets globals used below.
scan_vddk_configmaps() {
  local json
  json="$(kubectl get configmap,persistentvolumeclaim -A -o json 2>/dev/null || true)"
  [[ -z "${json}" ]] && return 1

  local result
  result="$(E2E_TARGET_NS="${E2E_TARGET_NS}" E2E_TARGET_PVC="${E2E_TARGET_PVC}" python3 -c '
import json, os, sys

data = json.load(sys.stdin)
target_ns = os.environ.get("E2E_TARGET_NS", "")
target_pvc = os.environ.get("E2E_TARGET_PVC", "")

v2v = []
extra = []
pvc_extra = {}

for item in data.get("items", []):
    kind = item.get("kind")
    meta = item.get("metadata", {})
    ns = meta.get("namespace", "")
    name = meta.get("name", "")

    if kind == "ConfigMap":
        cm_data = item.get("data") or {}
        if name == "v2v-vmware" and cm_data.get("vddk-init-image"):
            v2v.append({"namespace": ns, "name": name, "image": cm_data["vddk-init-image"]})
        if "vddk-config-file" in cm_data:
            extra.append({"namespace": ns, "name": name, "keys": sorted(cm_data.keys())})
        labels = meta.get("labels") or {}
        if labels.get("resource") == "vddk-config" and "vddk-config-file" in cm_data:
            found = any(e["namespace"] == ns and e["name"] == name for e in extra)
            if not found:
                extra.append({"namespace": ns, "name": name, "keys": sorted(cm_data.keys())})

    if kind == "PersistentVolumeClaim":
        ann = meta.get("annotations") or {}
        cm_name = ann.get("cdi.kubevirt.io/storage.pod.vddk.extraargs")
        if cm_name:
            pvc_extra.setdefault(ns, []).append({
                "pvc": name,
                "configmap": cm_name,
                "source": ann.get("cdi.kubevirt.io/storage.import.source", ""),
            })

ns_priority = ["openshift-cnv", "cdi", "openshift-mtv", "kubevirt-hyperconverged"]
v2v_sorted = sorted(v2v, key=lambda x: (
    ns_priority.index(x["namespace"]) if x["namespace"] in ns_priority else len(ns_priority),
    x["namespace"],
))
v2v_image = v2v_sorted[0]["image"] if v2v_sorted else ""

suggested = None
if target_ns and target_pvc:
    for entry in pvc_extra.get(target_ns, []):
        if entry["pvc"] == target_pvc:
            suggested = {"namespace": target_ns, "name": entry["configmap"], "from": f"PVC {target_ns}/{target_pvc}"}
            break
if suggested is None and target_ns:
    in_ns = [e for e in extra if e["namespace"] == target_ns]
    if in_ns:
        suggested = {"namespace": target_ns, "name": in_ns[0]["name"], "from": f"ConfigMap in {target_ns}"}
if suggested is None:
    for ns, entries in pvc_extra.items():
        for entry in entries:
            if entry.get("source") == "vddk":
                suggested = {"namespace": ns, "name": entry["configmap"], "from": f"PVC {ns}/{entry['pvc']}"}
                break
        if suggested:
            break
if suggested is None and extra:
    suggested = {"namespace": extra[0]["namespace"], "name": extra[0]["name"], "from": "first vddk-config-file ConfigMap"}

print(json.dumps({
    "v2v_vmware": v2v_sorted,
    "extra_args": extra,
    "pvc_extra": pvc_extra,
    "v2v_image": v2v_image,
    "suggested_configmap": suggested,
}))
' <<<"${json}" 2>/dev/null || true)"

  [[ -z "${result}" ]] && return 1
  VDDK_SCAN_JSON="${result}"
  return 0
}

discover_vddk_from_configmap() {
  scan_vddk_configmaps || return 1
  VDDK_SCAN_JSON="${VDDK_SCAN_JSON}" python3 -c '
import json, os, sys
data = json.loads(os.environ["VDDK_SCAN_JSON"])
img = data.get("v2v_image") or ""
if img:
    print(img)
    sys.exit(0)
sys.exit(1)
' 2>/dev/null || return 1
}

discover_vddk_from_provider() {
  local json
  json="$(kubectl get providers.forklift.konveyor.io -A -o json 2>/dev/null || true)"
  [[ -z "${json}" ]] && return 1
  echo "${json}" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(1)
for item in data.get("items", []):
    spec = item.get("spec", {})
    if spec.get("type") != "vsphere":
        continue
    settings = spec.get("settings") or {}
    img = settings.get("vddkInitImage") or settings.get("vddkImage")
    if img:
        print(img)
        sys.exit(0)
sys.exit(1)
' 2>/dev/null || true
}

discover_vddk_from_pvc() {
  local json
  json="$(kubectl get pvc -A -o json 2>/dev/null || true)"
  [[ -z "${json}" ]] && return 1
  echo "${json}" | python3 -c '
import json, sys
ann = "cdi.kubevirt.io/storage.pod.vddk.initimageurl"
try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(1)
for item in data.get("items", []):
    img = (item.get("metadata", {}).get("annotations") or {}).get(ann)
    if img:
        print(img)
        sys.exit(0)
sys.exit(1)
' 2>/dev/null || true
}

discover_vddk() {
  local img source=""
  if img="$(discover_vddk_from_configmap)"; then
    source="configmap v2v-vmware"
  elif img="$(discover_vddk_from_provider)"; then
    source="vSphere provider"
  elif img="$(discover_vddk_from_controller)"; then
    source="forklift-controller VDDK_IMAGE"
  elif img="$(discover_vddk_from_pvc)"; then
    source="migration PVC annotation"
  else
    return 1
  fi
  DISCOVER_VDDK_SOURCE="${source}"
  echo "${img}"
}

discover_vddk_from_controller() {
  local json
  json="$(kubectl get deployment -A -o json 2>/dev/null || true)"
  [[ -z "${json}" ]] && return 1
  echo "${json}" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(1)
for item in data.get("items", []):
    meta = item.get("metadata", {})
    if "forklift" not in (meta.get("name") or ""):
        continue
    for c in item.get("spec", {}).get("template", {}).get("spec", {}).get("containers", []):
        for e in c.get("env", []):
            if e.get("name") == "VDDK_IMAGE" and e.get("value"):
                print(e["value"])
                sys.exit(0)
sys.exit(1)
' 2>/dev/null || true
}

BASE_IMAGE=""
VDDK_IMAGE=""
VDDK_CONFIGMAP=""
VDDK_CONFIGMAP_NS=""
DISCOVER_VDDK_SOURCE=""
DISCOVER_VDDK_CONFIGMAP_SOURCE=""
VDDK_SCAN_JSON=""
exit_code=0

report_vddk_configmaps() {
  scan_vddk_configmaps || return 0
  VDDK_SCAN_JSON="${VDDK_SCAN_JSON}" python3 -c '
import json, os, sys
data = json.loads(os.environ["VDDK_SCAN_JSON"])
v2v = data.get("v2v_vmware") or []
extra = data.get("extra_args") or []
if not v2v and not extra:
    sys.exit(0)
print("VDDK ConfigMaps:")
for cm in v2v:
    print(f"  {cm['"'"'namespace'"'"']}/{cm['"'"'name'"'"']}  vddk-init-image={cm['"'"'image'"'"']}")
for cm in extra:
    keys = ", ".join(cm.get("keys") or [])
    print(f"  {cm['"'"'namespace'"'"']}/{cm['"'"'name'"'"']}  keys={keys}")
' 2>/dev/null || true
}

pick_vddk_configmap() {
  scan_vddk_configmaps || return 1
  VDDK_SCAN_JSON="${VDDK_SCAN_JSON}" python3 -c '
import json, os, sys
data = json.loads(os.environ["VDDK_SCAN_JSON"])
s = data.get("suggested_configmap")
if not s:
    sys.exit(1)
print(s["namespace"])
print(s["name"])
print(s.get("from") or "")
' 2>/dev/null || return 1
}

if [[ "${SCOPE}" == "all" || "${SCOPE}" == "base" ]]; then
  if BASE_IMAGE="$(discover_cdi_importer)"; then
    say "CDI importer (E2E_BASE_IMAGE): ${BASE_IMAGE}"
  else
    say "CDI importer: not found (set E2E_BASE_IMAGE manually)"
    say "  (looks for IMPORTER_IMAGE on cdi-deployment/cdi-operator in openshift-cnv or cdi)"
    exit_code=1
  fi
fi

if [[ "${SCOPE}" == "all" || "${SCOPE}" == "vddk" ]]; then
  report_vddk_configmaps

  if VDDK_IMAGE="$(discover_vddk)"; then
    say "VDDK image (${DISCOVER_VDDK_SOURCE}): ${VDDK_IMAGE}"
  else
    say "VDDK image: not found"
    say "  VDDK is not redistributable; public kubevirt images are empty shells."
    say "  Configure Forklift vSphere provider vddkInitImage, or set E2E_VDDK_IMAGE to your private image."
    say "  Discovery checks: v2v-vmware configmap, provider, controller env, PVC annotations"
    exit_code=1
  fi

  _vddk_cm=()
  mapfile -t _vddk_cm < <(pick_vddk_configmap 2>/dev/null || true)
  if ((${#_vddk_cm[@]} >= 2)) && [[ -n "${_vddk_cm[0]}" && -n "${_vddk_cm[1]}" ]]; then
    VDDK_CONFIGMAP_NS="${_vddk_cm[0]}"
    VDDK_CONFIGMAP="${_vddk_cm[1]}"
    DISCOVER_VDDK_CONFIGMAP_SOURCE="${_vddk_cm[2]:-}"
    if [[ -n "${E2E_TARGET_NS}" && "${VDDK_CONFIGMAP_NS}" == "${E2E_TARGET_NS}" ]]; then
      say "VDDK extra-args ConfigMap (E2E_VDDK_CONFIGMAP): ${VDDK_CONFIGMAP}  (${DISCOVER_VDDK_CONFIGMAP_SOURCE})"
    else
      say "VDDK extra-args ConfigMap: ${VDDK_CONFIGMAP_NS}/${VDDK_CONFIGMAP}  (${DISCOVER_VDDK_CONFIGMAP_SOURCE})"
      if [[ -n "${E2E_TARGET_NS}" && "${VDDK_CONFIGMAP_NS}" != "${E2E_TARGET_NS}" ]]; then
        say "  repair pod runs in ${E2E_TARGET_NS}; copy ConfigMap or set E2E_VDDK_CONFIGMAP manually"
      fi
    fi
  else
    say "VDDK extra-args ConfigMap: not found (optional; nbdkit uses defaults without vddk-config-file)"
  fi
fi

if [[ "${EXPORT}" -eq 1 ]]; then
  [[ -n "${BASE_IMAGE}" ]] && emit "export E2E_BASE_IMAGE='${BASE_IMAGE}'"
  [[ -n "${VDDK_IMAGE}" ]] && emit "export E2E_VDDK_IMAGE='${VDDK_IMAGE}'"
  if [[ -n "${VDDK_CONFIGMAP}" ]]; then
    if [[ -z "${E2E_TARGET_NS}" || "${VDDK_CONFIGMAP_NS}" == "${E2E_TARGET_NS}" ]]; then
      emit "export E2E_VDDK_CONFIGMAP='${VDDK_CONFIGMAP}'"
    fi
  fi
  exit 0
fi

say ""
say "Suggested e2e/config.env lines:"
[[ -n "${BASE_IMAGE}" ]] && say "E2E_BASE_IMAGE=${BASE_IMAGE}"
[[ -n "${VDDK_IMAGE}" ]] && say "E2E_VDDK_IMAGE=${VDDK_IMAGE}"
[[ -n "${VDDK_CONFIGMAP}" ]] && say "E2E_VDDK_CONFIGMAP=${VDDK_CONFIGMAP}"
say "E2E_IMAGE=disk-block-diff-e2e:local"
say ""
say "Then: ./e2e/build-image.sh"

exit "${exit_code}"
