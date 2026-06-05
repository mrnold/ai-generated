//go:build linux

package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReadBlockSectorSize(t *testing.T) {
	dir := t.TempDir()
	sizePath := filepath.Join(dir, "size")
	if err := os.WriteFile(sizePath, []byte("2048\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := readBlockSectorSize(sizePath)
	if err != nil {
		t.Fatal(err)
	}
	want := int64(2048 * linuxSectorSize)
	if got != want {
		t.Fatalf("got %d want %d", got, want)
	}
}
