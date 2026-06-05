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
5. **Importer-compatible image** (`E2E_IMAGE`) containing `disk-block-diff`, nbdkit, VDDK, `nbd-client`.
6. **Kubernetes secret** with vCenter credentials for the repair pod.

## Setup

```bash
cp e2e/config.example.env e2e/config.env
# Edit e2e/config.env — never commit it

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

If `E2E_HELPER_SSH` is empty, `helper-hash` prints commands to run on the helper VM. Copy `e2e-work/source.jsonl` locally before continuing.

## What success looks like

1. `repair.jsonl` is non-empty when `E2E_CORRUPT_DEST=true` (or when dest genuinely differs).
2. Repair pod logs show `apply` copying only those blocks.
3. `verify` produces an **empty** `e2e-work/verify-repair.jsonl`.

## Files

| Path | Role |
|------|------|
| `config.example.env` | Template for secrets and sizing |
| `run-option-b.sh` | Orchestrator |
| `scripts/helper-hash.sh` | Source hash on VMware helper |
| `manifests/hash-dest-pod.yaml` | Dest hash (+ optional corruption) |
| `manifests/repair-pod.yaml` | `nbd-open` + `apply` only |
| `manifests/verify-dest-pod.yaml` | Post-repair dest hash |
