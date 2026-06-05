package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestHashDiffApplyRoundTrip(t *testing.T) {
	dir := t.TempDir()
	blockSize := int64(1 << 20) // 1 MiB for fast test

	sourcePath := filepath.Join(dir, "source.img")
	destPath := filepath.Join(dir, "dest.img")
	for _, path := range []string{sourcePath, destPath} {
		f, err := os.Create(path)
		if err != nil {
			t.Fatal(err)
		}
		if err := f.Truncate(3 * blockSize); err != nil {
			t.Fatal(err)
		}
		_ = f.Close()
	}

	source, err := os.OpenFile(sourcePath, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := source.WriteAt([]byte("source-block-1-data"), blockSize); err != nil {
		t.Fatal(err)
	}
	_ = source.Close()

	dest, err := os.OpenFile(destPath, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := dest.WriteAt([]byte("dest-block-1-data"), blockSize); err != nil {
		t.Fatal(err)
	}
	_ = dest.Close()

	sourceManifest := filepath.Join(dir, "source.jsonl")
	destManifest := filepath.Join(dir, "dest.jsonl")
	diffList := filepath.Join(dir, "repair.jsonl")

	if err := hashDevice(sourcePath, sourceManifest, blockSize, 2, 0, 0); err != nil {
		t.Fatal(err)
	}
	if err := hashDevice(destPath, destManifest, blockSize, 2, 0, 0); err != nil {
		t.Fatal(err)
	}
	if err := diffManifests(sourceManifest, destManifest, diffList); err != nil {
		t.Fatal(err)
	}

	records, err := readDiffManifest(diffList)
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 1 {
		t.Fatalf("expected 1 differing block, got %d", len(records))
	}
	if records[0].Index != 1 {
		t.Fatalf("expected block index 1, got %d", records[0].Index)
	}

	if err := applyBlocks(sourcePath, destPath, diffList, 1, false, 0); err != nil {
		t.Fatal(err)
	}

	destManifestAfter := filepath.Join(dir, "dest-after.jsonl")
	if err := hashDevice(destPath, destManifestAfter, blockSize, 2, 0, 0); err != nil {
		t.Fatal(err)
	}
	if err := diffManifests(sourceManifest, destManifestAfter, filepath.Join(dir, "after-repair.jsonl")); err != nil {
		t.Fatal(err)
	}
	after, err := readDiffManifest(filepath.Join(dir, "after-repair.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if len(after) != 0 {
		t.Fatalf("expected no differences after repair, got %d", len(after))
	}
}

func TestParseSize(t *testing.T) {
	cases := map[string]int64{
		"1GiB":       1 << 30,
		"1G":         1 << 30,
		"64MiB":      64 << 20,
		"1073741824": 1073741824,
	}
	for raw, want := range cases {
		got, err := parseSize(raw)
		if err != nil {
			t.Fatalf("%s: %v", raw, err)
		}
		if got != want {
			t.Fatalf("%s: got %d want %d", raw, got, want)
		}
	}
}
