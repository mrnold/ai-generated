package main

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"strings"

	"github.com/vmware/govmomi"
	"github.com/vmware/govmomi/find"
	"github.com/vmware/govmomi/object"
	"github.com/vmware/govmomi/vim25/mo"
	"github.com/vmware/govmomi/vim25/types"
)

func boolPtr(value bool) *bool {
	return &value
}

type vddkConnectConfig struct {
	Server      string
	Username    string
	Password    string
	Thumbprint  string
	UUID        string
	Moref       string
	BackingFile string
	Snapshot    string
	DiskPath    string
}

func resolveVddkDiskPath(cfg vddkConnectConfig) (moref string, diskPath string, err error) {
	if cfg.DiskPath != "" {
		if cfg.Moref == "" && cfg.UUID == "" {
			return "", "", fmt.Errorf("disk is set; also provide -moref or -uuid for nbdkit")
		}
		if cfg.Moref != "" {
			return cfg.Moref, cfg.DiskPath, nil
		}
		moref, _, err = lookupVMMoref(cfg)
		if err != nil {
			return "", "", err
		}
		return moref, cfg.DiskPath, nil
	}

	if cfg.BackingFile == "" {
		return "", "", fmt.Errorf("provide -disk or -backing-file")
	}
	if cfg.Moref == "" && cfg.UUID == "" {
		return "", "", fmt.Errorf("provide -moref or -uuid")
	}

	ctx := context.Background()
	vmwURL, err := parseVCenterURL(cfg.Server, cfg.Username, cfg.Password)
	if err != nil {
		return "", "", err
	}

	client, err := govmomi.NewClient(ctx, vmwURL, true)
	if err != nil {
		return "", "", fmt.Errorf("connect vCenter: %w", err)
	}
	defer func() { _ = client.Logout(ctx) }()

	var vm *object.VirtualMachine
	if cfg.Moref != "" {
		moref = cfg.Moref
		vm = object.NewVirtualMachine(client.Client, types.ManagedObjectReference{Type: "VirtualMachine", Value: moref})
	} else {
		moref, vm, err = findVMByUUID(ctx, client, cfg.UUID)
		if err != nil {
			return "", "", err
		}
	}

	diskObjectID, err := findDiskObjectID(ctx, vm, cfg.BackingFile)
	if err != nil {
		return "", "", err
	}

	if cfg.Snapshot == "" {
		return moref, cfg.BackingFile, nil
	}

	snapshotRef, err := vm.FindSnapshot(ctx, cfg.Snapshot)
	if err != nil {
		return "", "", fmt.Errorf("find snapshot %q: %w", cfg.Snapshot, err)
	}
	if snapshotRef == nil {
		return "", "", fmt.Errorf("snapshot %q not found", cfg.Snapshot)
	}

	diskPath, err = findSnapshotDiskPath(ctx, vm, *snapshotRef, diskObjectID)
	if err != nil {
		return "", "", err
	}
	return moref, diskPath, nil
}

func lookupVMMoref(cfg vddkConnectConfig) (string, *object.VirtualMachine, error) {
	ctx := context.Background()
	vmwURL, err := parseVCenterURL(cfg.Server, cfg.Username, cfg.Password)
	if err != nil {
		return "", nil, err
	}
	client, err := govmomi.NewClient(ctx, vmwURL, true)
	if err != nil {
		return "", nil, fmt.Errorf("connect vCenter: %w", err)
	}
	defer func() { _ = client.Logout(ctx) }()
	return findVMByUUID(ctx, client, cfg.UUID)
}

func parseVCenterURL(server string, username string, password string) (*url.URL, error) {
	raw := strings.TrimSpace(server)
	if raw == "" {
		return nil, fmt.Errorf("vCenter server is required")
	}
	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}
	vmwURL, err := url.Parse(raw)
	if err != nil {
		return nil, fmt.Errorf("parse server URL: %w", err)
	}
	if username != "" {
		vmwURL.User = url.UserPassword(username, password)
	}
	vmwURL.Path = "/sdk"
	return vmwURL, nil
}

func findVMByUUID(ctx context.Context, client *govmomi.Client, uuid string) (string, *object.VirtualMachine, error) {
	finder := find.NewFinder(client.Client, true)
	datacenters, err := finder.DatacenterList(ctx, "*")
	if err != nil {
		return "", nil, fmt.Errorf("list datacenters: %w", err)
	}
	if len(datacenters) == 0 {
		return "", nil, fmt.Errorf("no datacenters found")
	}

	searcher := object.NewSearchIndex(client.Client)
	for _, instanceUUID := range []bool{true, false} {
		for _, dc := range datacenters {
			ref, err := searcher.FindByUuid(ctx, dc, uuid, true, boolPtr(instanceUUID))
			if err != nil {
				return "", nil, err
			}
			if ref != nil {
				moref := ref.Reference().Value
				return moref, object.NewVirtualMachine(client.Client, ref.Reference()), nil
			}
		}
	}
	return "", nil, fmt.Errorf("VM with UUID %q not found", uuid)
}

func findDiskObjectID(ctx context.Context, vm *object.VirtualMachine, backingFile string) (string, error) {
	var o mo.VirtualMachine
	if err := vm.Properties(ctx, vm.Reference(), []string{"config.hardware.device"}, &o); err != nil {
		return "", fmt.Errorf("read VM devices: %w", err)
	}
	for _, device := range o.Config.Hardware.Device {
		disk, ok := device.(*types.VirtualDisk)
		if !ok {
			continue
		}
		name := virtualDiskFileName(disk)
		if name == backingFile || strings.HasSuffix(name, backingFile) || strings.HasSuffix(backingFile, name) {
			return disk.DiskObjectId, nil
		}
	}
	return "", fmt.Errorf("disk %q not found on VM", backingFile)
}

func findSnapshotDiskPath(ctx context.Context, vm *object.VirtualMachine, snapshotRef types.ManagedObjectReference, diskObjectID string) (string, error) {
	var snapshot mo.VirtualMachineSnapshot
	if err := vm.Properties(ctx, snapshotRef, []string{"config.hardware.device"}, &snapshot); err != nil {
		return "", fmt.Errorf("read snapshot devices: %w", err)
	}
	for _, device := range snapshot.Config.Hardware.Device {
		disk, ok := device.(*types.VirtualDisk)
		if !ok {
			continue
		}
		if disk.DiskObjectId == diskObjectID {
			return virtualDiskFileName(disk), nil
		}
	}
	return "", fmt.Errorf("disk ID %q not found in snapshot %s", diskObjectID, snapshotRef.Value)
}

func virtualDiskFileName(disk *types.VirtualDisk) string {
	device := disk.GetVirtualDevice()
	backing := device.Backing.(types.BaseVirtualDeviceFileBackingInfo)
	info := backing.GetVirtualDeviceFileBackingInfo()
	return info.FileName
}

func vcenterHostForNbdkit(server string) string {
	raw := strings.TrimSpace(server)
	if raw == "" {
		return ""
	}
	if !strings.Contains(raw, "://") {
		return raw
	}
	vmwURL, err := url.Parse(raw)
	if err != nil {
		return raw
	}
	return vmwURL.Host
}

func envOrFlag(flagValue string, envKeys ...string) string {
	if strings.TrimSpace(flagValue) != "" {
		return flagValue
	}
	for _, key := range envKeys {
		if value := strings.TrimSpace(os.Getenv(key)); value != "" {
			return value
		}
	}
	return ""
}
