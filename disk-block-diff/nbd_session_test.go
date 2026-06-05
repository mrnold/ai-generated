package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNbdSessionStateRoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "nbd.state")

	state := &nbdSessionState{
		Socket:   "/tmp/test.sock",
		PidFile:  "/tmp/test.pid",
		Device:   "/dev/nbd0",
		DiskPath: "[datastore] vm/disk.vmdk",
		Server:   "vcenter.example",
		Snapshot: "snapshot-123",
		Moref:    "vm-42",
	}
	if err := writeNbdSessionState(path, state); err != nil {
		t.Fatal(err)
	}

	read, err := readNbdSessionState(path)
	if err != nil {
		t.Fatal(err)
	}
	if read.Device != state.Device || read.DiskPath != state.DiskPath {
		t.Fatalf("unexpected state: %+v", read)
	}

	device, err := sourceFromNbdState(path)
	if err != nil {
		t.Fatal(err)
	}
	if device != "/dev/nbd0" {
		t.Fatalf("device = %q", device)
	}
}

func TestSourceFromMissingState(t *testing.T) {
	_, err := sourceFromNbdState(filepath.Join(t.TempDir(), "missing.state"))
	if err == nil {
		t.Fatal("expected error for missing state")
	}
}

func TestVcenterHostForNbdkit(t *testing.T) {
	if got := vcenterHostForNbdkit("https://vcenter.example.com/sdk"); got != "vcenter.example.com" {
		t.Fatalf("got %q", got)
	}
	if got := vcenterHostForNbdkit("vcenter.example.com"); got != "vcenter.example.com" {
		t.Fatalf("got %q", got)
	}
}

func TestWriteNbdSessionCreatesParentDir(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "nested", "nbd.state")
	if err := writeNbdSessionState(path, &nbdSessionState{Device: "/dev/nbd0"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatal(err)
	}
}
