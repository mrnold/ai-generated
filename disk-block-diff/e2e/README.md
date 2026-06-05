# Option B E2E (two-site repair)

End-to-end test for the **production repair flow** with a **small configurable disk** (e.g. `1GiB`, not 35 TiB).

## Flow

```text
 VMware helper VM          Workstation              OpenShift cluster
 ----------------          -----------              -----------------
 hash source disk    ->    diff manifests    ->     hash dest PVC
 (once, full read)         repair.jsonl            nbd-open + apply ONLY
                           verify diff             re-hash dest PVC
```

The repair pod **never** runs `hash` on the NBD device. NBD is used only for block reads listed in `repair.jsonl`.

## Prerequisites

1. **Small test VM** on VMware with a disk of size `E2E_DISK_SIZE` (default `1GiB`).
2. **Snapshot** at a known point (`E2E_SNAPSHOT`) for `nbd-open` during repair.
3. **Helper VM** with that disk attached read-only (for source manifest only).
4. **Block-mode PVC** on OpenShift with the same logical content/size (e.g. from a prior import of the test VM).
5. **E2E image** built from your cluster's CDI importer base (see below).
6. **Kubernetes secret** with vCenter credentials for the repair pod.

## Build `E2E_IMAGE`

Importer pods are usually deleted after transfer, so build a thin image locally:

```bash
chmod +x e2e/build-image.sh e2e/discover-images.sh

# Discover CDI importer + VDDK from cluster (no importer pod needed):
./e2e/discover-images.sh

# Discover and build in one step:
./e2e/build-image.sh --discover

# Or set E2E_BASE_IMAGE / E2E_VDDK_IMAGE in e2e/config.env and build:
./e2e/build-image.sh
```

This compiles `disk-block-diff`, layers it onto the **CDI importer** image (nbdkit, `nbd-client`), and copies **VDDK libraries** from the Forklift VDDK init image (normally supplied via init container on real importer pods).

| Variable | Purpose |
|----------|---------|
| `E2E_BASE_IMAGE` | `cdi-importer` image (`IMPORTER_IMAGE` on `cdi-deployment` / `cdi-operator`) |
| `E2E_VDDK_IMAGE` | Your VDDK init image (auto-discovered from Forklift if unset) |
| `E2E_IMAGE` | Output tag used by E2E pods |

### VDDK image (not redistributable)

VMware VDDK **cannot be shipped** in public container images. Images like `quay.io/kubev2v/vddk`
are empty test shells (no `vmware-vix-disklib-distrib`); they exist only for CI layout checks.

For E2E and repair you need the **same private image** already configured for warm migrations:

- Forklift vSphere provider `spec.settings.vddkInitImage`, or
- `v2v-vmware` ConfigMap `vddk-init-image`, or
- a image you built locally from VMware's VDDK tarball (see [CDI `vddk/Dockerfile`](https://github.com/kubevirt/containerized-data-importer/blob/main/vddk/Dockerfile))

`discover-images.sh` / `build-image.sh` pull `E2E_VDDK_IMAGE` from those cluster sources — not from kubevirt quay.

**VDDK ConfigMaps** (separate from the init image):

| ConfigMap | Key | Purpose |
|-----------|-----|---------|
| `v2v-vmware` (CDI namespace) | `vddk-init-image` | Cluster-wide VDDK **image** URL |
| `<plan>-vddk-config-*` (Forklift) | `vddk-config-file` | nbdkit/VDDK **tuning** (mounted at `/etc/vddk-config`) |

`discover-images.sh` lists both types cluster-wide and suggests `E2E_VDDK_CONFIGMAP` from your target PVC (`E2E_PVC_NAME` / `E2E_NAMESPACE`) or any warm-migration PVC.

Optional:

```bash
./e2e/build-image.sh --push quay.io/yourorg/disk-block-diff-e2e:first   # full image ref
./e2e/build-image.sh --kind my-cluster                                   # load into kind after build
```

### OpenShift / `registry.redhat.io`

On OpenShift Virtualization, discovery often returns a **Red Hat registry** importer image
(`registry.redhat.io/container-native-virtualization/virt-cdi-importer-rhel9@sha256:...`).
The cluster can pull it; your laptop usually cannot without extra setup.

**Option A** — login on the build host:

```bash
podman login registry.redhat.io
# https://access.redhat.com/RegistryAuthentication
./e2e/build-image.sh --discover
```

**Option B** — mirror to quay using cluster pull credentials, then build from the copy:

```bash
./e2e/discover-images.sh
# put E2E_BASE_IMAGE in e2e/config.env, then:
E2E_MIRROR_DEST=quay.io/mrnold/e2e-cdi-importer:local ./e2e/mirror-base-image.sh
# update e2e/config.env: E2E_BASE_IMAGE=quay.io/mrnold/e2e-cdi-importer:local
./e2e/build-image.sh --push quay.io/mrnold/disk-block-diff-e2e:first
```

## Setup

```bash
cp e2e/config.example.env e2e/config.env
# Edit e2e/config.env — set E2E_BASE_IMAGE, build E2E_IMAGE, fill vCenter/PVC fields

# Create vCenter secret (example)
kubectl -n default create secret generic disk-block-diff-e2e-vddk \
  --from-literal=user='vcenter-user' \
  --from-literal=password='vcenter-pass'
```

### Configurable sizing

| Variable | Default | Purpose |
|----------|---------|---------|
| `E2E_DISK_SIZE` | `1GiB` | Documented expected capacity; validate with `info` |
| `E2E_BLOCK_SIZE` | `64MiB` | Hash chunk size (same on helper and OpenShift) |
| `E2E_CORRUPT_DEST` | `false` | If `true`, corrupt one block on dest before hash to force repair |

Use smaller disks and blocks for faster iteration, e.g.:

```bash
E2E_DISK_SIZE=256MiB
E2E_BLOCK_SIZE=16MiB
```

## Run

```bash
chmod +x e2e/run-option-b.sh e2e/scripts/helper-hash.sh

# Full run (helper via SSH if E2E_HELPER_SSH is set)
./e2e/run-option-b.sh all

# Or step by step
./e2e/run-option-b.sh helper-hash   # or manual on helper VM
./e2e/run-option-b.sh dest-hash
./e2e/run-option-b.sh diff
./e2e/run-option-b.sh repair
./e2e/run-option-b.sh verify
./e2e/run-option-b.sh cleanup
```

Override config path:

```bash
E2E_CONFIG=/path/to/config.env ./e2e/run-option-b.sh all
```

## Manual helper step

If `E2E_HELPER_SSH` is set, `helper-hash` uploads the locally built `disk-block-diff` to `/tmp` on the helper, then `install` (or `sudo install`) to `E2E_HELPER_BINARY` before hashing.

If `E2E_HELPER_SSH` is empty, `helper-hash` prints commands to run on the helper VM. Copy `e2e-work/source.jsonl` locally before continuing.

## What success looks like

1. `repair.jsonl` is non-empty when `E2E_CORRUPT_DEST=true` (or when dest genuinely differs).
2. Repair pod logs show `apply` copying only those blocks.
3. `verify` produces an **empty** `e2e-work/verify-repair.jsonl`.

## Files

| Path | Role |
|------|------|
| `config.example.env` | Template for secrets and sizing |
| `Containerfile` | Thin layer on CDI importer base |
| `discover-images.sh` | Find `E2E_BASE_IMAGE` / `E2E_VDDK_IMAGE` from CDI deployments and Forklift |
| `mirror-base-image.sh` | Mirror `registry.redhat.io` importer base to quay via `oc image mirror` |
| `build-image.sh` | Build `E2E_IMAGE` (thin layer on importer + VDDK libs) |
| `run-option-b.sh` | Orchestrator |
| `scripts/helper-hash.sh` | Source hash on VMware helper |
| `manifests/hash-dest-pod.yaml` | Dest hash (+ optional corruption) |
| `manifests/repair-pod.yaml` | `nbd-open` + `apply` only |
| `manifests/verify-dest-pod.yaml` | Post-repair dest hash |
