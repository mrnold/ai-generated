#!/usr/bin/env bash
# Build E2E_IMAGE by layering disk-block-diff onto a CDI importer base image.
#
# Usage:
#   ./e2e/build-image.sh
#   E2E_BASE_IMAGE=quay.io/kubevirt/cdi-importer:v1.62.0 ./e2e/build-image.sh
#   ./e2e/build-image.sh --push quay.io/you/disk-block-diff-e2e:test
#   ./e2e/build-image.sh --kind kind
#
# Reads e2e/config.env when present (E2E_BASE_IMAGE, E2E_IMAGE).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
E2E_DIR="${ROOT}/e2e"
CONFIG="${E2E_CONFIG:-${E2E_DIR}/config.env}"

if [[ -f "${CONFIG}" ]]; then
  # shellcheck source=/dev/null
  source "${CONFIG}"
fi

BASE_IMAGE="${E2E_BASE_IMAGE:-}"
BUILDER_IMAGE="${E2E_BUILDER_IMAGE:-quay.io/centos/centos:stream9}"
VDDK_IMAGE="${E2E_VDDK_IMAGE:-}"
OUTPUT_IMAGE="${E2E_IMAGE:-disk-block-diff-e2e:local}"
KIND_CLUSTER=""
PUSH_TARGET=""
CONTAINER_CMD=""
DISCOVER=0
VDDK_EXPLICIT=0
# Public kubevirt/kubev2v VDDK images are empty CI shells (VDDK is not redistributable).
VDDK_PLACEHOLDER="quay.io/kubev2v/vddk:latest"

if [[ -n "${E2E_VDDK_IMAGE:-}" && "${E2E_VDDK_IMAGE}" != "${VDDK_PLACEHOLDER}" ]]; then
  VDDK_EXPLICIT=1
fi

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Build a local E2E image with disk-block-diff on top of a CDI importer image.

Environment / config.env:
  E2E_BASE_IMAGE   CDI importer image from your cluster's CDI version (required)
  E2E_VDDK_IMAGE   VDDK init image (discovered from cluster if unset)
  E2E_BUILDER_IMAGE  EL9 image with dnf for libnbd-devel build (default: centos:stream9)
  E2E_IMAGE        Output tag (default: disk-block-diff-e2e:local)

Options:
  --discover       Query cluster for E2E_BASE_IMAGE / E2E_VDDK_IMAGE (no importer pod)
  --base IMAGE     Importer base image (overrides E2E_BASE_IMAGE)
  --vddk IMAGE     VDDK image to copy libs from (overrides E2E_VDDK_IMAGE)
  --tag IMAGE      Output image tag (overrides E2E_IMAGE)
  --push IMAGE     Push built image (full ref like quay.io/you/img:tag, or registry prefix)
  --kind NAME      Load image into kind cluster after build
  -h, --help       Show this help

Discover images without a running importer pod:
  ./e2e/discover-images.sh
  ./e2e/build-image.sh --discover

Example:
  E2E_BASE_IMAGE=quay.io/kubevirt/cdi-importer:v1.62.0 ./e2e/build-image.sh
  # VDDK is auto-discovered from Forklift provider / v2v-vmware configmap when unset
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --discover)
      DISCOVER=1
      shift
      ;;
    --base)
      BASE_IMAGE=$2
      shift 2
      ;;
    --vddk)
      VDDK_IMAGE=$2
      VDDK_EXPLICIT=1
      shift 2
      ;;
    --builder)
      BUILDER_IMAGE=$2
      shift 2
      ;;
    --tag)
      OUTPUT_IMAGE=$2
      shift 2
      ;;
    --push)
      PUSH_TARGET=$2
      shift 2
      ;;
    --kind)
      KIND_CLUSTER=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -x "${E2E_DIR}/discover-images.sh" ]]; then
  if [[ "${DISCOVER}" -eq 1 ]] || [[ -z "${BASE_IMAGE}" ]]; then
    echo "discovering CDI importer image from cluster"
    # shellcheck source=/dev/null
    eval "$("${E2E_DIR}/discover-images.sh" --export --base-only)" || true
    BASE_IMAGE="${E2E_BASE_IMAGE:-${BASE_IMAGE}}"
  fi
  if [[ "${VDDK_EXPLICIT}" -eq 0 ]]; then
    echo "discovering VDDK image from cluster"
    # shellcheck source=/dev/null
    eval "$("${E2E_DIR}/discover-images.sh" --export --vddk-only)" || true
    VDDK_IMAGE="${E2E_VDDK_IMAGE:-${VDDK_IMAGE}}"
  fi
fi

if [[ -z "${BASE_IMAGE}" ]]; then
  echo "E2E_BASE_IMAGE is required (CDI importer image for this cluster)." >&2
  echo "Run ./e2e/discover-images.sh, set e2e/config.env, or pass --base IMAGE." >&2
  usage >&2
  exit 1
fi

if [[ -z "${VDDK_IMAGE}" ]]; then
  echo "E2E_VDDK_IMAGE is required — a private image containing vmware-vix-disklib-distrib." >&2
  echo "VDDK is not redistributable; public kubevirt/kubev2v images are empty test shells." >&2
  echo "Use your Forklift provider vddkInitImage: ./e2e/discover-images.sh --vddk-only" >&2
  usage >&2
  exit 1
fi

if command -v podman >/dev/null 2>&1; then
  CONTAINER_CMD=podman
elif command -v docker >/dev/null 2>&1; then
  CONTAINER_CMD=docker
else
  echo "need podman or docker in PATH" >&2
  exit 1
fi

base_image_available() {
  ${CONTAINER_CMD} image exists "${BASE_IMAGE}" 2>/dev/null
}

if [[ "${BASE_IMAGE}" == registry.redhat.io/* ]] && ! base_image_available; then
  cat >&2 <<EOF
E2E_BASE_IMAGE is on registry.redhat.io and is not present locally.
OpenShift can pull it, but your workstation needs credentials or a mirror.

  Option A — Red Hat registry login on this machine:
    podman login registry.redhat.io
    # Customer Portal credentials: https://access.redhat.com/RegistryAuthentication

  Option B — Mirror via cluster (recommended on OpenShift):
    E2E_MIRROR_DEST=quay.io/you/e2e-cdi-importer:local ./e2e/mirror-base-image.sh
    # then set E2E_BASE_IMAGE to the quay copy in e2e/config.env

EOF
  exit 1
fi

echo "building image ${OUTPUT_IMAGE}"
echo "  importer base: ${BASE_IMAGE}"
echo "  builder:       ${BUILDER_IMAGE}"
echo "  vddk libs:     ${VDDK_IMAGE}"
${CONTAINER_CMD} build \
  -f "${E2E_DIR}/Containerfile" \
  --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
  --build-arg "BUILDER_IMAGE=${BUILDER_IMAGE}" \
  --build-arg "VDDK_IMAGE=${VDDK_IMAGE}" \
  -t "${OUTPUT_IMAGE}" \
  "${ROOT}"

echo "verifying nbdkit and binary in image"
${CONTAINER_CMD} run --rm --entrypoint /bin/bash "${OUTPUT_IMAGE}" -ec \
  'disk-block-diff parse-size -size 1GiB && nbdkit --version && ldd /usr/local/bin/disk-block-diff | grep -q libnbd && ls -l /opt/vmware-vix-disklib-distrib | head -3'

if [[ -n "${KIND_CLUSTER}" ]]; then
  if ! command -v kind >/dev/null 2>&1; then
    echo "kind not found" >&2
    exit 1
  fi
  echo "loading ${OUTPUT_IMAGE} into kind cluster ${KIND_CLUSTER}"
  kind load docker-image "${OUTPUT_IMAGE}" --name "${KIND_CLUSTER}"
fi

if [[ -n "${PUSH_TARGET}" ]]; then
  if [[ "${PUSH_TARGET}" == */*:* ]]; then
    remote="${PUSH_TARGET}"
  elif [[ "${PUSH_TARGET}" == */* ]]; then
    remote="${PUSH_TARGET}:$(date +%Y%m%d)"
  else
    remote="${PUSH_TARGET}/disk-block-diff-e2e:$(date +%Y%m%d)"
  fi
  echo "tagging and pushing ${remote}"
  ${CONTAINER_CMD} tag "${OUTPUT_IMAGE}" "${remote}"
  ${CONTAINER_CMD} push "${remote}"
  echo "pushed ${remote}"
  echo "set E2E_IMAGE=${remote} in e2e/config.env"
fi

echo ""
echo "E2E image ready: ${OUTPUT_IMAGE}"
echo "Add to e2e/config.env:"
echo "  E2E_BASE_IMAGE=${BASE_IMAGE}"
echo "  E2E_VDDK_IMAGE=${VDDK_IMAGE}"
echo "  E2E_IMAGE=${OUTPUT_IMAGE}"
