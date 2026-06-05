#!/usr/bin/env bash
# Mirror E2E_BASE_IMAGE from a registry the cluster can reach (e.g. registry.redhat.io)
# to one your workstation can pull from when building locally (e.g. quay.io).
#
# Uses "oc image mirror", which runs with cluster credentials for the source registry.
#
# Usage:
#   ./e2e/mirror-base-image.sh
#   ./e2e/mirror-base-image.sh 'registry.redhat.io/.../virt-cdi-importer-rhel9@sha256:...' quay.io/you/cdi-importer-base:local
#   E2E_MIRROR_DEST=quay.io/you/cdi-importer-base:local ./e2e/mirror-base-image.sh
set -euo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${E2E_CONFIG:-${E2E_DIR}/config.env}"

if [[ -f "${CONFIG}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG}"
fi

SOURCE="${1:-${E2E_BASE_IMAGE:-}}"
DEST="${2:-${E2E_MIRROR_DEST:-}}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [SOURCE_IMAGE] [DEST_IMAGE]

Mirror the CDI importer base image to a registry you can pull from locally.

SOURCE defaults to E2E_BASE_IMAGE in e2e/config.env (or ./discover-images.sh --export).
DEST defaults to E2E_MIRROR_DEST or quay.io/<user>/e2e-cdi-importer:local

Requires: oc logged into a cluster that can pull SOURCE, and push access to DEST.

Example:
  ./e2e/discover-images.sh
  # copy E2E_BASE_IMAGE into e2e/config.env, then:
  E2E_MIRROR_DEST=quay.io/mrnold/e2e-cdi-importer:local ./e2e/mirror-base-image.sh
  # set E2E_BASE_IMAGE=quay.io/mrnold/e2e-cdi-importer:local and rebuild
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "${SOURCE}" ]]; then
  if [[ -x "${E2E_DIR}/discover-images.sh" ]]; then
    # shellcheck source=/dev/null
    eval "$("${E2E_DIR}/discover-images.sh" --export)" || true
    SOURCE="${E2E_BASE_IMAGE:-}"
  fi
fi

if [[ -z "${SOURCE}" ]]; then
  echo "SOURCE image is required (arg, E2E_BASE_IMAGE, or discover-images.sh)." >&2
  usage >&2
  exit 1
fi

if [[ -z "${DEST}" ]]; then
  user="$(oc whoami 2>/dev/null || true)"
  if [[ -z "${user}" ]]; then
    user="local"
  fi
  DEST="quay.io/${user}/e2e-cdi-importer:local"
fi

if ! command -v oc >/dev/null 2>&1; then
  echo "oc not found; install OpenShift CLI or pass images you can already pull." >&2
  exit 1
fi

echo "mirroring (cluster credentials for source):"
echo "  from: ${SOURCE}"
echo "  to:   ${DEST}"

oc image mirror "${SOURCE}" "${DEST}" --max-per-registry=3

echo ""
echo "Mirror complete. Update e2e/config.env:"
echo "  E2E_BASE_IMAGE=${DEST}"
echo ""
echo "Then build locally:"
echo "  ./e2e/build-image.sh"
