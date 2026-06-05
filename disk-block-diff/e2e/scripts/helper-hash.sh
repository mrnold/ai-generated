#!/usr/bin/env bash
# Run on the VMware helper VM (or via: ssh helper 'bash -s' < helper-hash.sh).
# Hashes the attached source disk once. This is the only full read of the source.
set -euo pipefail

: "${E2E_HELPER_DEVICE:?E2E_HELPER_DEVICE required}"
: "${E2E_BLOCK_SIZE:?E2E_BLOCK_SIZE required}"
: "${E2E_HASH_WORKERS:?E2E_HASH_WORKERS required}"
: "${E2E_OUTPUT_PATH:=/tmp/source.jsonl}"

BINARY="${E2E_HELPER_BINARY:-./disk-block-diff}"
PROGRESS="${E2E_PROGRESS_INTERVAL:-10s}"

SUDO=()
case "${E2E_HELPER_SUDO:-auto}" in
  always|true|1|yes)
    SUDO=(sudo)
    ;;
  never|false|0|no)
    ;;
  auto)
    if [[ ! -r "${E2E_HELPER_DEVICE}" ]]; then
      echo "device ${E2E_HELPER_DEVICE} not readable; using sudo" >&2
      SUDO=(sudo)
    fi
    ;;
  *)
    echo "unknown E2E_HELPER_SUDO=${E2E_HELPER_SUDO} (use auto, always, or never)" >&2
    exit 2
    ;;
esac

"${SUDO[@]}" "${BINARY}" info -device "${E2E_HELPER_DEVICE}" -block-size "${E2E_BLOCK_SIZE}"

if [[ -n "${E2E_DISK_SIZE:-}" ]]; then
  echo "expected disk size (from config): ${E2E_DISK_SIZE}"
fi

"${SUDO[@]}" "${BINARY}" hash \
  -device "${E2E_HELPER_DEVICE}" \
  -output "${E2E_OUTPUT_PATH}" \
  -block-size "${E2E_BLOCK_SIZE}" \
  -workers "${E2E_HASH_WORKERS}" \
  -progress-interval "${PROGRESS}"

if ((${#SUDO[@]} > 0)); then
  "${SUDO[@]}" chmod a+r "${E2E_OUTPUT_PATH}"
fi

ls -lh "${E2E_OUTPUT_PATH}"
echo "source manifest: ${E2E_OUTPUT_PATH}"
