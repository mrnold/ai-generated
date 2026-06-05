// disk-block-diff hashes block devices in fixed-size chunks, compares manifests
// from two sites, and applies only differing blocks to a destination device.
//
// Typical warm-migration verification / repair flow:
//   1. VMware-side VM: attach source disk (or snapshot) and hash it.
//   2. OpenShift importer pod: hash the imported block PV.
//   3. Workstation: diff the two JSONL manifests.
//   4. VMware-side (or any host with both disks): apply diff onto destination.
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"
)

func main() {
	log.SetFlags(log.LstdFlags)

	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	switch os.Args[1] {
	case "hash":
		runHash(os.Args[2:])
	case "diff":
		runDiff(os.Args[2:])
	case "apply":
		runApply(os.Args[2:])
	case "info":
		runInfo(os.Args[2:])
	case "nbd-open":
		runNbdOpen(os.Args[2:])
	case "nbd-close":
		runNbdClose(os.Args[2:])
	case "nbd-status":
		runNbdStatus(os.Args[2:])
	case "help", "-h", "--help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n\n", os.Args[1])
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, `disk-block-diff — compare and sync block devices by fixed-size MD5 chunks

Usage:
  %s hash   -device PATH -output MANIFEST.jsonl [options]
  %s diff   -a SOURCE.jsonl -b DEST.jsonl -output TO-COPY.jsonl
  %s apply  -source PATH -dest PATH -blocks TO-COPY.jsonl [options]
  %s info   -device PATH [options]
  %s nbd-open  [vCenter/VDDK options]
  %s nbd-close [-state-file PATH]
  %s nbd-status [-state-file PATH]

Options for hash/info:
  -block-size SIZE   Chunk size (default 1GiB). Examples: 1GiB, 1G, 1073741824
  -workers N         Parallel hash workers (default 4)
  -start-index N     Resume hashing at block index N (default 0)

Options for apply:
  -workers N         Parallel copy workers (default 2)
  -dry-run           Print blocks that would be copied
  -nbd-state PATH    Read source device from nbd-open state file

Options for nbd-open:
  -server URL        vCenter host/URL (env: DISK_BLOCK_DIFF_VCENTER_SERVER)
  -username USER     vCenter user
  -password PASS     vCenter password
  -thumbprint SHA1   vCenter thumbprint
  -uuid UUID         VM UUID (instance, then BIOS fallback)
  -moref vm-NNN      VM managed object ID (alternative to -uuid)
  -backing-file PATH Backing file from DataVolume spec.source.vddk.backingFile
  -snapshot ID       Snapshot/checkpoint for source view
  -disk PATH         VMware disk path; skips backing-file lookup
  -device PATH       Local NBD device (default /dev/nbd0)
  -state-file PATH   Session state file (default /var/run/disk-block-diff/nbd.state)
  -skip-connect      Start nbdkit only; use libnbd against the unix socket

Manifest format (JSONL, one block per line):
  {"index":0,"offset":0,"size":1073741824,"md5":"..."}

Workflow:
  1. On VMware helper VM (source disk attached read-only):
       disk-block-diff hash -device /dev/sdb -output source.jsonl
  2. On OpenShift pod (imported PV attached):
       disk-block-diff hash -device /dev/cdi-block-volume -output dest.jsonl
  3. Copy manifests off-cluster and diff:
       disk-block-diff diff -a source.jsonl -b dest.jsonl -output repair.jsonl
  4. Copy differing blocks onto destination (source must be readable):
       disk-block-diff apply -source /dev/sdb -dest /dev/cdi-block-volume -blocks repair.jsonl

OpenShift pod with VDDK (no local VMware disk required):
  1. nbd-open -server vcenter.example -uuid <vm-uuid> -backing-file '[ds] vm/disk.vmdk' -snapshot <id>
  2. hash -device /dev/nbd0 -output source.jsonl
     OR apply -nbd-state /var/run/disk-block-diff/nbd.state -dest /dev/cdi-block-volume -blocks repair.jsonl
  3. nbd-close

Notes:
  - Devices must be the same logical size for a meaningful diff.
  - The last block may be shorter than -block-size.
  - MD5 is for diffing only, not cryptography.
  - Run hash/apply against raw block devices, not mounted filesystems.

`, os.Args[0], os.Args[0], os.Args[0], os.Args[0], os.Args[0], os.Args[0], os.Args[0])
}

func runHash(args []string) {
	fs := flag.NewFlagSet("hash", flag.ExitOnError)
	device := fs.String("device", "", "Block device or image file to hash")
	output := fs.String("output", "", "Output manifest path (JSONL)")
	blockSizeRaw := fs.String("block-size", "1GiB", "Hash chunk size")
	workers := fs.Int("workers", 4, "Parallel workers")
	startIndex := fs.Uint64("start-index", 0, "Start at block index (resume)")
	_ = fs.Parse(args)

	if *device == "" || *output == "" {
		fs.Usage()
		os.Exit(2)
	}
	blockSize, err := parseSize(*blockSizeRaw)
	if err != nil {
		log.Fatalf("invalid block-size: %v", err)
	}
	if err := hashDevice(*device, *output, blockSize, *workers, *startIndex); err != nil {
		log.Fatalf("%v", err)
	}
}

func runDiff(args []string) {
	fs := flag.NewFlagSet("diff", flag.ExitOnError)
	sourceManifest := fs.String("a", "", "Manifest from source (e.g. VMware side)")
	destManifest := fs.String("b", "", "Manifest from destination (e.g. OpenShift side)")
	output := fs.String("output", "", "Output diff list (JSONL)")
	_ = fs.Parse(args)

	if *sourceManifest == "" || *destManifest == "" || *output == "" {
		fs.Usage()
		os.Exit(2)
	}
	if err := diffManifests(*sourceManifest, *destManifest, *output); err != nil {
		log.Fatalf("%v", err)
	}
}

func runApply(args []string) {
	fs := flag.NewFlagSet("apply", flag.ExitOnError)
	source := fs.String("source", "", "Source block device to read from")
	dest := fs.String("dest", "", "Destination block device to write to")
	blocks := fs.String("blocks", "", "Diff list from diff subcommand")
	nbdState := fs.String("nbd-state", "", "Use source device from nbd-open state file")
	workers := fs.Int("workers", 2, "Parallel copy workers")
	dryRun := fs.Bool("dry-run", false, "List blocks without copying")
	_ = fs.Parse(args)

	sourcePath := *source
	if sourcePath == "" && *nbdState != "" {
		device, err := sourceFromNbdState(*nbdState)
		if err != nil {
			log.Fatalf("%v", err)
		}
		sourcePath = device
	}
	if sourcePath == "" || *dest == "" || *blocks == "" {
		fs.Usage()
		os.Exit(2)
	}
	if err := applyBlocks(sourcePath, *dest, *blocks, *workers, *dryRun); err != nil {
		log.Fatalf("%v", err)
	}
}

func runInfo(args []string) {
	fs := flag.NewFlagSet("info", flag.ExitOnError)
	device := fs.String("device", "", "Block device or image file")
	blockSizeRaw := fs.String("block-size", "1GiB", "Hash chunk size")
	_ = fs.Parse(args)

	if *device == "" {
		fs.Usage()
		os.Exit(2)
	}
	blockSize, err := parseSize(*blockSizeRaw)
	if err != nil {
		log.Fatalf("invalid block-size: %v", err)
	}

	f, err := os.Open(*device)
	if err != nil {
		log.Fatalf("open device: %v", err)
	}
	defer f.Close()

	info, err := f.Stat()
	if err != nil {
		log.Fatalf("stat device: %v", err)
	}
	size := info.Size()
	blocks := blockCount(size, blockSize)
	fmt.Printf("device:      %s\n", *device)
	fmt.Printf("size_bytes:  %d\n", size)
	fmt.Printf("block_size:  %d\n", blockSize)
	fmt.Printf("block_count: %d\n", blocks)
	if blocks > 0 {
		_, lastSize := blockSpec(blocks-1, size, blockSize)
		fmt.Printf("last_block_size: %d\n", lastSize)
	}
}

func parseSize(raw string) (int64, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return 0, fmt.Errorf("empty size")
	}

	multipliers := []struct {
		suffix string
		value  int64
	}{
		{"gib", 1 << 30},
		{"gb", 1_000_000_000},
		{"g", 1 << 30},
		{"mib", 1 << 20},
		{"mb", 1_000_000},
		{"m", 1 << 20},
		{"kib", 1 << 10},
		{"kb", 1_000},
		{"k", 1 << 10},
	}

	lower := strings.ToLower(raw)
	for _, m := range multipliers {
		if strings.HasSuffix(lower, m.suffix) {
			num := strings.TrimSpace(lower[:len(lower)-len(m.suffix)])
			n, err := strconv.ParseInt(num, 10, 64)
			if err != nil {
				return 0, err
			}
			return n * m.value, nil
		}
	}

	n, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("parse size %q: %w", raw, err)
	}
	if n <= 0 {
		return 0, fmt.Errorf("size must be positive")
	}
	return n, nil
}
