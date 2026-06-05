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

# shellcheck source=/dev/null
source "${CONFIG}"

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
export E2E_VDDK_CONFIGMAP="${E2E_VDDK_CONFIGMAP:-disk-block-diff-e2e-unused-vddk-config}"

kubectl_cmd() {
  kubectl --kubeconfig "${KUBECONFIG}" -n "${E2E_NAMESPACE}" "$@"
}

render_manifest() {
  local template=$1
  envsubst < "${template}"
}

wait_pod() {
  local name=$1
  local timeout=${2:-600}
  echo "waiting for pod ${name} (timeout ${timeout}s)"
  local end=$((SECONDS + timeout))
  while (( SECONDS < end )); do
    local phase
    phase="$(kubectl_cmd get pod "${name}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "${phase}" in
      Succeeded)
        return 0
        ;;
      Failed)
        pod_logs "${name}" >&2 || true
        echo "pod ${name} failed" >&2
        return 1
        ;;
    esac
    sleep 5
  done
  echo "timeout waiting for pod ${name}" >&2
  return 1
}

pod_logs() {
  kubectl_cmd logs "pod/${1}"
}

copy_from_pod() {
  local pod=$1
  local remote=$2
  local local_path=$3
  kubectl_cmd cp "${E2E_NAMESPACE}/${pod}:${remote}" "${local_path}"
}

phase_helper_hash() {
  echo "=== phase 1: VMware helper — source manifest (full read of test disk) ==="
  export E2E_OUTPUT_PATH="/tmp/source-${RUN_ID}.jsonl"

  if [[ -n "${E2E_HELPER_SSH:-}" ]]; then
    ssh "${E2E_HELPER_SSH}" \
      E2E_HELPER_DEVICE="${E2E_HELPER_DEVICE}" \
      E2E_BLOCK_SIZE="${E2E_BLOCK_SIZE}" \
      E2E_HASH_WORKERS="${E2E_HASH_WORKERS}" \
      E2E_PROGRESS_INTERVAL="${E2E_PROGRESS_INTERVAL}" \
      E2E_DISK_SIZE="${E2E_DISK_SIZE:-}" \
      E2E_HELPER_BINARY="${E2E_HELPER_BINARY}" \
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
  export E2E_CORRUPT_DEST="${E2E_CORRUPT_DEST:-false}"
  export E2E_CORRUPT_BLOCK_INDEX="${E2E_CORRUPT_BLOCK_INDEX:-1}"

  render_manifest "${E2E_DIR}/manifests/hash-dest-pod.yaml" | kubectl_cmd apply -f -
  wait_pod "${E2E_POD_NAME}" "${E2E_POD_TIMEOUT:-900}"
  pod_logs "${E2E_POD_NAME}"
  copy_from_pod "${E2E_POD_NAME}" /var/tmp/dest.jsonl "${DEST_MANIFEST}"
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

  kubectl_cmd create configmap "${E2E_REPAIR_CONFIGMAP}" \
    --from-file=repair.jsonl="${REPAIR_MANIFEST}" \
    --dry-run=client -o yaml | kubectl_cmd apply -f -

  export E2E_POD_NAME="${E2E_POD_PREFIX}-repair-${RUN_ID}"
  render_manifest "${E2E_DIR}/manifests/repair-pod.yaml" | kubectl_cmd apply -f -
  wait_pod "${E2E_POD_NAME}" "${E2E_POD_TIMEOUT:-3600}"
  pod_logs "${E2E_POD_NAME}"
}

phase_verify() {
  echo "=== phase 5: OpenShift — re-hash dest (local only) ==="
  export E2E_POD_NAME="${E2E_POD_PREFIX}-verify-${RUN_ID}"
  render_manifest "${E2E_DIR}/manifests/verify-dest-pod.yaml" | kubectl_cmd apply -f -
  wait_pod "${E2E_POD_NAME}" "${E2E_POD_TIMEOUT:-900}"
  pod_logs "${E2E_POD_NAME}"
  copy_from_pod "${E2E_POD_NAME}" /var/tmp/dest-after.jsonl "${DEST_AFTER_MANIFEST}"

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
