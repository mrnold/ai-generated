#!/usr/bin/env bash
# Option B E2E: two-site repair flow with configurable small disk size.
#
#   1. VMware helper VM  -> hash source once -> source.jsonl
#   2. OpenShift pod     -> hash dest PVC    -> dest.jsonl
#   3. This workstation  -> diff             -> repair.jsonl
#   4. OpenShift pod     -> nbd-open + apply only (no NBD hash)
#   5. OpenShift pod     -> hash dest again  -> dest-after.jsonl
#   6. This workstation  -> diff source vs dest-after (expect empty)
#
# Usage:
#   cp e2e/config.example.env e2e/config.env   # edit
#   ./e2e/run-option-b.sh all
#   ./e2e/run-option-b.sh helper-hash|dest-hash|diff|repair|verify|cleanup
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
E2E_DIR="${ROOT}/e2e"
CONFIG="${E2E_CONFIG:-${E2E_DIR}/config.env}"

if [[ ! -f "${CONFIG}" ]]; then
  echo "missing ${CONFIG} — copy from e2e/config.example.env" >&2
  exit 1
fi

# Export config vars for envsubst when rendering pod manifests.
set -a
# shellcheck source=/dev/null
source "${CONFIG}"
set +a

BINARY="${E2E_BINARY:-${ROOT}/disk-block-diff}"
WORK_DIR="${E2E_WORK_DIR:-${ROOT}/e2e-work}"
mkdir -p "${WORK_DIR}"

SOURCE_MANIFEST="${WORK_DIR}/source.jsonl"
DEST_MANIFEST="${WORK_DIR}/dest.jsonl"
REPAIR_MANIFEST="${WORK_DIR}/repair.jsonl"
DEST_AFTER_MANIFEST="${WORK_DIR}/dest-after.jsonl"
VERIFY_DIFF="${WORK_DIR}/verify-repair.jsonl"

RUN_ID="${E2E_RUN_ID:-$(date +%Y%m%d%H%M%S)}"
export E2E_POD_NAME="${E2E_POD_PREFIX}-${RUN_ID}"
export E2E_REPAIR_CONFIGMAP="${E2E_POD_PREFIX}-repair-${RUN_ID}"

if [[ ! -x "${BINARY}" ]]; then
  echo "building ${BINARY}" >&2
  (cd "${ROOT}" && go build -o disk-block-diff .)
fi

export E2E_BLOCK_SIZE_BYTES
E2E_BLOCK_SIZE_BYTES="$("${BINARY}" parse-size -size "${E2E_BLOCK_SIZE}")"
export E2E_VDDK_CONFIGMAP="${E2E_VDDK_CONFIGMAP:-}"
export E2E_DEST_DEVICE="${E2E_DEST_DEVICE:-/dev/cdi-block-volume}"
export E2E_POD_BINARY="${E2E_POD_BINARY:-/usr/local/bin/disk-block-diff}"
export E2E_CORRUPT_DEST="${E2E_CORRUPT_DEST:-false}"
export E2E_CORRUPT_BLOCK_INDEX="${E2E_CORRUPT_BLOCK_INDEX:-1}"
export E2E_ARTIFACT_HOLD_SECONDS="${E2E_ARTIFACT_HOLD_SECONDS:-120}"

kubectl_cmd() {
  kubectl --kubeconfig "${KUBECONFIG}" -n "${E2E_NAMESPACE}" "$@"
}

require_manifest_vars() {
  local missing=()
  local var
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("${var}")
    fi
  done
  if ((${#missing[@]} > 0)); then
    echo "missing required config for pod manifest: ${missing[*]}" >&2
    echo "set them in ${CONFIG}" >&2
    exit 1
  fi
}

ensure_vddk_secret() {
  require_manifest_vars E2E_VCENTER_USER E2E_VCENTER_PASSWORD E2E_VDDK_SECRET_NAME
  echo "ensuring Secret ${E2E_NAMESPACE}/${E2E_VDDK_SECRET_NAME} from ${CONFIG}"
  kubectl_cmd create secret generic "${E2E_VDDK_SECRET_NAME}" \
    --from-literal=user="${E2E_VCENTER_USER}" \
    --from-literal=password="${E2E_VCENTER_PASSWORD}" \
    --dry-run=client -o yaml | kubectl_cmd apply -f -
  kubectl_cmd label secret "${E2E_VDDK_SECRET_NAME}" app=disk-block-diff-e2e --overwrite &>/dev/null || true
}

is_example_vddk_config_value() {
  local value="${1:-}"
  [[ -z "${value}" ]] && return 0
  [[ "${value}" == *'e2e-vm/e2e-disk'* ]] && return 0
  [[ "${value}" == 'vcenter.example.com' ]] && return 0
  return 1
}

# Fill E2E_BACKING_FILE / E2E_VM_UUID / E2E_SNAPSHOT from migration PVC or DataVolume when unset or still example placeholders.
discover_repair_vddk_from_pvc() {
  local pvc="${E2E_PVC_NAME:-}"
  local ns="${E2E_NAMESPACE:-}"
  [[ -z "${pvc}" || -z "${ns}" ]] && return 0

  local pvc_json dv_json
  pvc_json="$(kubectl_cmd get pvc "${pvc}" -o json 2>/dev/null || true)"
  [[ -z "${pvc_json}" ]] && return 0
  dv_json="$(kubectl_cmd get datavolume "${pvc}" -o json 2>/dev/null || true)"

  local -a discovered
  mapfile -t discovered < <(PVC_JSON="${pvc_json}" DV_JSON="${dv_json}" python3 - <<'PY'
import json, os, sys

def load(name):
    raw = os.environ.get(name, "")
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {}

pvc = load("PVC_JSON")
dv = load("DV_JSON")
ann = (pvc.get("metadata") or {}).get("annotations") or {}

def pick(*keys):
    for key in keys:
        if ann.get(key):
            return ann[key]
    return ""

backing = pick(
    "cdi.kubevirt.io/storage.import.backingFile",
    "forklift.konveyor.io/disk-source",
)
uuid = pick("cdi.kubevirt.io/storage.import.uuid")
snapshot = pick("cdi.kubevirt.io/storage.checkpoint.current")

vddk = ((dv.get("spec") or {}).get("source") or {}).get("vddk") or {}
if not backing:
    backing = vddk.get("backingFile") or ""
if not uuid:
    uuid = vddk.get("uuid") or ""
if not snapshot:
    for cp in reversed((dv.get("status") or {}).get("checkpoints") or []):
        if cp.get("current"):
            snapshot = cp["current"]
            break

print(backing)
print(uuid)
print(snapshot)
PY
)

  local disc_backing="${discovered[0]:-}"
  local disc_uuid="${discovered[1]:-}"
  local disc_snapshot="${discovered[2]:-}"

  if [[ -n "${disc_backing}" ]] && is_example_vddk_config_value "${E2E_BACKING_FILE}"; then
    export E2E_BACKING_FILE="${disc_backing}"
    echo "discovered E2E_BACKING_FILE from PVC/DataVolume: ${E2E_BACKING_FILE}"
  fi
  if [[ -n "${disc_uuid}" ]] && is_example_vddk_config_value "${E2E_VM_UUID}"; then
    export E2E_VM_UUID="${disc_uuid}"
    echo "discovered E2E_VM_UUID from PVC/DataVolume: ${E2E_VM_UUID}"
  fi
  if [[ -n "${disc_snapshot}" ]] && [[ -z "${E2E_SNAPSHOT:-}" ]]; then
    export E2E_SNAPSHOT="${disc_snapshot}"
    echo "discovered E2E_SNAPSHOT from PVC/DataVolume: ${E2E_SNAPSHOT}"
  fi
}

# Only substitute E2E_* — pod scripts use ${BIN}, ${DEST}, etc. at runtime.
E2E_ENVSUBST_VARS='$E2E_APPLY_WORKERS $E2E_ARTIFACT_HOLD_SECONDS $E2E_BACKING_FILE $E2E_BLOCK_SIZE $E2E_BLOCK_SIZE_BYTES $E2E_CORRUPT_BLOCK_INDEX $E2E_CORRUPT_DEST $E2E_DEST_DEVICE $E2E_HASH_WORKERS $E2E_IMAGE $E2E_NAMESPACE $E2E_POD_BINARY $E2E_POD_NAME $E2E_PROGRESS_INTERVAL $E2E_PVC_NAME $E2E_REPAIR_CONFIGMAP $E2E_SNAPSHOT $E2E_VCENTER_SERVER $E2E_VCENTER_THUMBPRINT $E2E_VDDK_CONFIGMAP $E2E_VDDK_SECRET_NAME $E2E_VM_UUID'

render_manifest() {
  local template=$1
  envsubst "${E2E_ENVSUBST_VARS}" < "${template}"
}

render_repair_pod() {
  local rendered
  rendered="$(render_manifest "${E2E_DIR}/manifests/repair-pod.yaml")"
  if [[ -z "${E2E_VDDK_CONFIGMAP}" ]]; then
    awk '/^# @vddk-config-start$/{skip=1; next} /^# @vddk-config-end$/{skip=0; next} !skip{print}' <<< "${rendered}"
  else
    awk '/^# @vddk-config-(start|end)$/ {next} {print}' <<< "${rendered}"
  fi
}

# wait_pod NAME TIMEOUT [CONTAINER [REMOTE_ARTIFACT LOCAL_ARTIFACT]]
# kubectl cp only works while the container is Running; copy the artifact during the wait loop.
wait_pod() {
  local name=$1
  local timeout=${2:-600}
  local container=${3:-}
  local artifact_remote=${4:-}
  local artifact_local=${5:-}
  local poll=${E2E_POD_POLL_INTERVAL:-15}
  local start=${SECONDS}
  local log_follow_pid=""
  local artifact_copied=0
  local phase=""

  echo "waiting for pod ${name} to finish (namespace=${E2E_NAMESPACE}, timeout=${timeout}s)"

  stop_log_follow() {
    if [[ -n "${log_follow_pid}" ]]; then
      kill "${log_follow_pid}" 2>/dev/null || true
      wait "${log_follow_pid}" 2>/dev/null || true
      log_follow_pid=""
    fi
  }

  start_log_follow() {
    if [[ -n "${log_follow_pid}" ]]; then
      return 0
    fi
    local -a args=(logs -f "pod/${name}")
    if [[ -n "${container}" ]]; then
      args+=(-c "${container}")
    fi
    kubectl_cmd "${args[@]}" &
    log_follow_pid=$!
  }

  pod_remote_path_exists() {
    local remote_path=$1
    local -a args=(exec "pod/${name}")
    if [[ -n "${container}" ]]; then
      args+=(-c "${container}")
    fi
    args+=(-- test -f "${remote_path}")
    kubectl_cmd "${args[@]}" &>/dev/null
  }

  pod_artifact_ready() {
    # hash creates the output file at start; only copy after the pod marks completion.
    pod_remote_path_exists "${artifact_remote}.ready"
  }

  try_copy_artifact() {
    if [[ -z "${artifact_remote}" || -z "${artifact_local}" || "${artifact_copied}" -eq 1 ]]; then
      return 0
    fi
    if [[ "${phase}" != "Running" ]]; then
      return 1
    fi
    if ! pod_artifact_ready; then
      return 1
    fi
    if ! pod_remote_path_exists "${artifact_remote}"; then
      return 1
    fi
    echo "copying ${artifact_remote} from pod ${name} (container must still be Running)"
    local -a args=(cp "${E2E_NAMESPACE}/${name}:${artifact_remote}" "${artifact_local}")
    if [[ -n "${container}" ]]; then
      args+=(-c "${container}")
    fi
    if kubectl_cmd "${args[@]}"; then
      artifact_copied=1
      echo "saved ${artifact_local}"
      return 0
    fi
    return 1
  }

  while (( SECONDS - start < timeout )); do
    if ! kubectl_cmd get pod "${name}" &>/dev/null; then
      printf '  %s  pod not found yet (ns=%s)\n' "$(date +%H:%M:%S)" "${E2E_NAMESPACE}"
      sleep 2
      continue
    fi

    local ready waiting terminated exit_code
    phase="$(kubectl_cmd get pod "${name}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    ready="$(kubectl_cmd get pod "${name}" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)"
    waiting="$(kubectl_cmd get pod "${name}" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
    terminated="$(kubectl_cmd get pod "${name}" -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || true)"
    exit_code="$(kubectl_cmd get pod "${name}" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || true)"

    case "${phase}" in
      Succeeded)
        stop_log_follow
        if [[ -n "${artifact_remote}" && "${artifact_copied}" -eq 0 ]]; then
          echo "pod ${name} succeeded before artifact was copied (kubectl cp needs a Running container)" >&2
          return 1
        fi
        printf '  %s  pod Succeeded\n' "$(date +%H:%M:%S)"
        return 0
        ;;
      Failed)
        stop_log_follow
        printf '  %s  pod Failed (reason=%s exit=%s)\n' "$(date +%H:%M:%S)" "${terminated:-unknown}" "${exit_code:-?}"
        kubectl_cmd logs "pod/${name}" ${container:+-c "${container}"} --tail=50 >&2 || true
        echo "pod ${name} failed" >&2
        return 1
        ;;
    esac

    if [[ "${phase}" == "Running" ]]; then
      start_log_follow
      try_copy_artifact || true
      if [[ -n "${artifact_remote}" && "${artifact_copied}" -eq 1 ]]; then
        stop_log_follow
        printf '  %s  artifact saved; done (pod %s still in hold sleep)\n' "$(date +%H:%M:%S)" "${name}"
        return 0
      fi
    fi

    if [[ -z "${log_follow_pid}" ]]; then
      local status_line="phase=${phase:-?} ready=${ready:-?}"
      if [[ -n "${waiting}" ]]; then
        status_line+=" waiting=${waiting}"
      fi
      printf '  %s  %s (elapsed %ds)\n' "$(date +%H:%M:%S)" "${status_line}" "$((SECONDS - start))"
    fi

    if [[ -n "${artifact_remote}" && "${artifact_copied}" -eq 0 ]]; then
      sleep 2
    else
      sleep "${poll}"
    fi
  done

  stop_log_follow
  echo "timeout after ${timeout}s waiting for pod ${name} (last phase=${phase:-?})" >&2
  kubectl_cmd get pod "${name}" -o wide >&2 || true
  kubectl_cmd logs "pod/${name}" ${container:+-c "${container}"} --tail=30 >&2 || true
  return 1
}

pod_logs() {
  local name=$1
  local container=${2:-}
  kubectl_cmd logs "pod/${name}" ${container:+-c "${container}"}
}

sync_helper_binary() {
  local remote_bin="${E2E_HELPER_BINARY:-/tmp/disk-block-diff-e2e}"
  local tmp_remote="/tmp/disk-block-diff-sync-${RUN_ID}"
  echo "copying ${BINARY} to ${E2E_HELPER_SSH}:${remote_bin}"
  scp "${BINARY}" "${E2E_HELPER_SSH}:${tmp_remote}"
  ssh "${E2E_HELPER_SSH}" bash -s -- "${tmp_remote}" "${remote_bin}" <<'EOF'
set -euo pipefail
tmp=$1
dest=$2
if install -m 755 "${tmp}" "${dest}" 2>/dev/null; then
  :
elif sudo install -m 755 "${tmp}" "${dest}"; then
  :
else
  echo "failed to install ${dest} (tried install and sudo install)" >&2
  exit 1
fi
rm -f "${tmp}"
EOF
}

phase_helper_hash() {
  echo "=== phase 1: VMware helper — source manifest (full read of test disk) ==="
  export E2E_OUTPUT_PATH="/tmp/source-${RUN_ID}.jsonl"

  if [[ -n "${E2E_HELPER_SSH:-}" ]]; then
    sync_helper_binary
    ssh "${E2E_HELPER_SSH}" \
      E2E_HELPER_DEVICE="${E2E_HELPER_DEVICE}" \
      E2E_BLOCK_SIZE="${E2E_BLOCK_SIZE}" \
      E2E_HASH_WORKERS="${E2E_HASH_WORKERS}" \
      E2E_PROGRESS_INTERVAL="${E2E_PROGRESS_INTERVAL}" \
      E2E_DISK_SIZE="${E2E_DISK_SIZE:-}" \
      E2E_HELPER_BINARY="${E2E_HELPER_BINARY}" \
      E2E_HELPER_SUDO="${E2E_HELPER_SUDO:-auto}" \
      E2E_OUTPUT_PATH="${E2E_OUTPUT_PATH}" \
      bash -s < "${E2E_DIR}/scripts/helper-hash.sh"
    scp "${E2E_HELPER_SSH}:${E2E_OUTPUT_PATH}" "${SOURCE_MANIFEST}"
  else
    cat <<EOF
Run on the VMware helper VM (disk attached read-only at ${E2E_HELPER_DEVICE}):

  export E2E_HELPER_DEVICE='${E2E_HELPER_DEVICE}'
  export E2E_BLOCK_SIZE='${E2E_BLOCK_SIZE}'
  export E2E_HASH_WORKERS='${E2E_HASH_WORKERS}'
  export E2E_PROGRESS_INTERVAL='${E2E_PROGRESS_INTERVAL}'
  export E2E_DISK_SIZE='${E2E_DISK_SIZE:-}'
  export E2E_HELPER_BINARY='${E2E_HELPER_BINARY}'
  export E2E_OUTPUT_PATH='${E2E_OUTPUT_PATH}'
  bash helper-hash.sh

Then copy manifest to this machine:
  scp helper:${E2E_OUTPUT_PATH} ${SOURCE_MANIFEST}

Continue with:  ${0} dest-hash
Or set E2E_HELPER_SSH=user@helper and re-run:  ${0} helper-hash
EOF
    if [[ ! -f "${SOURCE_MANIFEST}" ]]; then
      echo "waiting for ${SOURCE_MANIFEST}" >&2
      exit 2
    fi
  fi
  wc -l "${SOURCE_MANIFEST}"
}

phase_dest_hash() {
  echo "=== phase 2: OpenShift — dest manifest (local PVC only) ==="
  echo "E2E_IMAGE=${E2E_IMAGE}"
  require_manifest_vars E2E_NAMESPACE E2E_PVC_NAME E2E_IMAGE E2E_DEST_DEVICE E2E_BLOCK_SIZE

  render_manifest "${E2E_DIR}/manifests/hash-dest-pod.yaml" | kubectl_cmd apply -f -
  wait_pod "${E2E_POD_NAME}" "${E2E_POD_TIMEOUT:-900}" hasher /var/tmp/dest.jsonl "${DEST_MANIFEST}"
  wc -l "${DEST_MANIFEST}"
}

phase_diff() {
  echo "=== phase 3: workstation — diff manifests ==="
  [[ -f "${SOURCE_MANIFEST}" ]] || { echo "missing ${SOURCE_MANIFEST}" >&2; exit 1; }
  [[ -f "${DEST_MANIFEST}" ]] || { echo "missing ${DEST_MANIFEST}" >&2; exit 1; }
  "${BINARY}" diff \
    -a "${SOURCE_MANIFEST}" \
    -b "${DEST_MANIFEST}" \
    -output "${REPAIR_MANIFEST}"
  wc -l "${REPAIR_MANIFEST}"
  if [[ ! -s "${REPAIR_MANIFEST}" ]] && [[ "${E2E_CORRUPT_DEST}" != "true" ]]; then
    echo "warning: repair list is empty; dest already matches source or corruption disabled" >&2
  fi
}

phase_repair() {
  echo "=== phase 4: OpenShift — repair (nbd-open + apply only) ==="
  [[ -f "${REPAIR_MANIFEST}" ]] || { echo "missing ${REPAIR_MANIFEST}" >&2; exit 1; }
  if [[ ! -s "${REPAIR_MANIFEST}" ]]; then
    echo "repair list empty; skipping repair pod"
    return 0
  fi

  discover_repair_vddk_from_pvc
  require_manifest_vars \
    E2E_VCENTER_SERVER E2E_VCENTER_USER E2E_VCENTER_PASSWORD \
    E2E_VCENTER_THUMBPRINT E2E_VM_UUID E2E_BACKING_FILE E2E_SNAPSHOT \
    E2E_VDDK_SECRET_NAME E2E_IMAGE E2E_DEST_DEVICE
  ensure_vddk_secret
  echo "repair target: vm=${E2E_VM_UUID} backing=${E2E_BACKING_FILE} snapshot=${E2E_SNAPSHOT}"

  kubectl_cmd create configmap "${E2E_REPAIR_CONFIGMAP}" \
    --from-file=repair.jsonl="${REPAIR_MANIFEST}" \
    --dry-run=client -o yaml | kubectl_cmd apply -f -

  export E2E_POD_NAME="${E2E_POD_PREFIX}-repair-${RUN_ID}"
  if [[ -z "${E2E_VDDK_CONFIGMAP}" ]]; then
    echo "E2E_VDDK_CONFIGMAP unset — repair pod runs without nbdkit extra-args ConfigMap"
  else
    echo "E2E_VDDK_CONFIGMAP=${E2E_VDDK_CONFIGMAP}"
  fi
  render_repair_pod | kubectl_cmd apply -f -
  wait_pod "${E2E_POD_NAME}" "${E2E_POD_TIMEOUT:-3600}" repair
}

phase_verify() {
  echo "=== phase 5: OpenShift — re-hash dest (local only) ==="
  export E2E_POD_NAME="${E2E_POD_PREFIX}-verify-${RUN_ID}"
  render_manifest "${E2E_DIR}/manifests/verify-dest-pod.yaml" | kubectl_cmd apply -f -
  wait_pod "${E2E_POD_NAME}" "${E2E_POD_TIMEOUT:-900}" verify /var/tmp/dest-after.jsonl "${DEST_AFTER_MANIFEST}"

  echo "=== phase 6: workstation — verify no remaining diffs ==="
  "${BINARY}" diff \
    -a "${SOURCE_MANIFEST}" \
    -b "${DEST_AFTER_MANIFEST}" \
    -output "${VERIFY_DIFF}"
  if [[ -s "${VERIFY_DIFF}" ]]; then
    echo "E2E FAILED: dest still differs from source after repair" >&2
    wc -l "${VERIFY_DIFF}" >&2
    exit 1
  fi
  echo "E2E PASSED: dest matches source manifest"
}

phase_cleanup() {
  echo "=== cleanup ==="
  kubectl_cmd delete pod -l "app=disk-block-diff-e2e" --ignore-not-found --wait=false
  kubectl_cmd delete configmap -l "app=disk-block-diff-e2e" --ignore-not-found 2>/dev/null || true
  kubectl_cmd delete configmap "${E2E_REPAIR_CONFIGMAP}" --ignore-not-found 2>/dev/null || true
}

usage() {
  cat <<EOF
Usage: $(basename "$0") <phase>

Phases:
  helper-hash   Source manifest on VMware helper (or manual; see output)
  dest-hash     Hash destination PVC on OpenShift
  diff          Build repair.jsonl on this machine
  repair        nbd-open + apply on OpenShift (no source hash)
  verify        Re-hash dest and assert empty diff vs source
  cleanup       Delete E2E pods/configmaps
  all           helper-hash, dest-hash, diff, repair, verify

Config: ${CONFIG}
Work dir: ${WORK_DIR}
Disk size (config): ${E2E_DISK_SIZE:-not set}
Block size: ${E2E_BLOCK_SIZE} (${E2E_BLOCK_SIZE_BYTES} bytes)
EOF
}

main() {
  local phase=${1:-}
  case "${phase}" in
    helper-hash) phase_helper_hash ;;
    dest-hash)   phase_dest_hash ;;
    diff)        phase_diff ;;
    repair)      phase_repair ;;
    verify)      phase_verify ;;
    cleanup)     phase_cleanup ;;
    all)
      phase_helper_hash
      phase_dest_hash
      phase_diff
      phase_repair
      phase_verify
      ;;
    -h|--help|help) usage ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "${@:-}"
