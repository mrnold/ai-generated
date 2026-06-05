# disk-block-diff

Compare two copies of the same disk (for example VMware source vs OpenShift imported block PV) by hashing fixed-size chunks, diffing the manifests, and copying only mismatched blocks onto the destination.

## Why this exists

After a failed warm-migration delta you may want to verify whether the destination matches a known-good source view, or repair specific regions without re-copying an entire multi-TiB disk. This tool implements the **hash → diff → apply** workflow you described.

## Existing tools (and why they are awkward here)

| Tool | Limitation for this use case |
|------|------------------------------|
| `cmp` / `md5sum` on whole device | No block-level resume; must re-read entire disk for any change |
| `rsync --checksum` | Not designed for raw block devices; poor sparse handling |
| `guestfish` / `virt-copy-out` | Good for files inside a disk, not raw block-by-block parity |
| `dd` + `md5sum` per chunk | Works but manual; no parallel diff/apply pipeline |
| VMware `QueryChangedDiskAreas` | Requires live CBT + snapshots; not for post-failure forensics |

`disk-block-diff` is deliberately boring: parallel MD5 over 1 GiB chunks, JSONL manifests you can move between sites, then targeted `Pwrite` repair.

## Build

```bash
cd disk-block-diff
go build -o disk-block-diff .
```

Static binary; no cgo. Copy the same binary to the VMware helper VM and the OpenShift importer pod.

`nbd-open` additionally requires **nbdkit with the VDDK plugin**, the **VDDK libraries**, and **nbd-client** plus the **nbd kernel module** (privileged pod). Use a CDI/Forklift importer-compatible image or equivalent.

**VDDK is not redistributable.** Public `quay.io/kubev2v/vddk` images are empty CI shells without VMware libraries. Use the same private VDDK init image configured on your Forklift vSphere provider (or build one from VMware's VDDK tarball).

## Commands

```bash
# Show device size and block count
./disk-block-diff info -device /dev/sdb

# Hash (run on BOTH sides with the same -block-size)
./disk-block-diff hash -device /dev/sdb -output source.jsonl -workers 8

# Diff manifests (run anywhere; only needs the two JSONL files)
./disk-block-diff diff -a source.jsonl -b dest.jsonl -output repair.jsonl

# Copy mismatched blocks from source onto destination
./disk-block-diff apply -source /dev/sdb -dest /dev/cdi-block-volume -blocks repair.jsonl -workers 4

# OpenShift: expose VMware source as local NBD device via nbdkit/VDDK
./disk-block-diff nbd-open \
  -server vcenter.example \
  -uuid <vm-uuid> \
  -backing-file '[datastore] vm/disk.vmdk' \
  -snapshot <snapshot-id>
./disk-block-diff apply -nbd-state /var/run/disk-block-diff/nbd.state \
  -dest /dev/cdi-block-volume -blocks repair.jsonl
./disk-block-diff nbd-close
```

Resume a long hash with `-start-index N` (manifest will contain only blocks from N onward; merge manifests externally or re-hash from scratch for simplicity).

`hash` and `apply` log progress every **10 seconds** by default (plus once at start and end), including throughput and ETA:

```
progress: hashed 120/35000 blocks (0.3%), 120.0 GiB / 34.8 TiB, rate 412.3 MiB/s, elapsed 5m0s, ETA 23h15m
```

Use `-progress-interval 30s` to change the interval, or `-progress-interval 0` to disable.

## Suggested deployment

### VMware side (helper VM)

1. Attach the source disk read-only (snapshot-backed virtual disk or RDM).
2. Identify device path (`lsblk`).
3. Hash:

```bash
./disk-block-diff hash -device /dev/sdX -output /tmp/source.jsonl -workers 8
```

4. Copy `source.jsonl` off the VM (`scp`, S3, etc.).

### OpenShift side (privileged importer-style pod)

Hash destination only: [examples/hash-pod.yaml](examples/hash-pod.yaml)

Repair from vCenter without a VMware helper VM: [examples/nbd-apply-pod.yaml](examples/nbd-apply-pod.yaml)

`nbd-open` starts nbdkit with the VDDK plugin, connects `nbd-client` to expose `/dev/nbd0`, and records session state. `apply -nbd-state` reads source blocks from that device.

```bash
./disk-block-diff hash -device /dev/cdi-block-volume -output /tmp/dest.jsonl -workers 8
kubectl cp <namespace>/<pod>:/tmp/dest.jsonl ./dest.jsonl
```

### Diff and repair

```bash
./disk-block-diff diff -a source.jsonl -b dest.jsonl -output repair.jsonl
```

`repair.jsonl` lists every block where MD5 differs. For a 35 TiB disk with 1 GiB blocks, the manifest is at most ~35k lines per side (~few MB).

**Apply** requires a host that can read the **source** disk and write the **destination** disk. Typical patterns:

- Run apply from the VMware helper VM if the OpenShift PV is not directly reachable (export repair list + re-import via a one-off copy job).
- Run apply inside an OpenShift pod that has **both** source (NFS/iSCSI staging) and destination PVC attached.
- Use apply only to **verify direction**: hash source vs dest, diff, then re-hash dest after a normal CDI/Forklift delta retry if blocks match expectations.

## Manifest formats

**Block manifest** (`hash` output), one JSON object per line:

```json
{"index":0,"offset":0,"size":1073741824,"md5":"d41d8cd98f00b204e9800998ecf8427e"}
```

**Diff list** (`diff` output):

```json
{"index":5,"offset":5368709120,"size":1073741824,"reason":"hash_mismatch","source_md5":"...","dest_md5":"..."}
```

## Performance notes

- Default block size is **1 GiB** (~35k hashes for a 35 TiB disk). Smaller blocks (e.g. `-block-size 64MiB`) give finer repair granularity but larger manifests and more syscall overhead.
- Hashing is read-only on the source side.
- `apply` uses `Pwrite` and does not truncate the destination; it only overwrites listed ranges.
- MD5 is used for change detection only, not security.

## End-to-end test (Option B)

See [e2e/README.md](e2e/README.md) for a two-site repair E2E with **configurable disk size** (default `1GiB`):

- VMware **helper VM**: hash source once
- OpenShift: hash dest PVC, then **repair** (`nbd-open` + `apply` only)
- Workstation: `diff` / verify

```bash
cp e2e/config.example.env e2e/config.env   # edit, do not commit
./e2e/build-image.sh --discover              # discover importer/VDDK from cluster, then build
./e2e/run-option-b.sh all
```

## Caveats

- Both disks must represent the **same logical content** (same size, same snapshot point). Diffing a live VM disk against a stale import will show many mismatches.
- Do not hash mounted filesystems; use the raw block device.
- Sparse / punched holes read as zeroes; both sides must agree on how holes are represented.
- If the failed delta may have torn a block, include adjacent blocks in repair by re-running `diff` with a smaller `-block-size`.
