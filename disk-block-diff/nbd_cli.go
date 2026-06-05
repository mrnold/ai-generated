package main

import (
	"flag"
	"log"
	"strings"
)

func runNbdOpen(args []string) {
	fs := flag.NewFlagSet("nbd-open", flag.ExitOnError)
	server := fs.String("server", "", "vCenter host or URL")
	username := fs.String("username", "", "vCenter username (or DISK_BLOCK_DIFF_VCENTER_USER)")
	password := fs.String("password", "", "vCenter password (or DISK_BLOCK_DIFF_VCENTER_PASSWORD)")
	thumbprint := fs.String("thumbprint", "", "vCenter TLS thumbprint (or DISK_BLOCK_DIFF_VCENTER_THUMBPRINT)")
	uuid := fs.String("uuid", "", "VM instance or BIOS UUID")
	moref := fs.String("moref", "", "VM managed object reference (vm-123)")
	disk := fs.String("disk", "", "VMware disk path for nbdkit file= (skip lookup)")
	backingFile := fs.String("backing-file", "", "Backing file from DataVolume; resolved with -snapshot")
	snapshot := fs.String("snapshot", "", "Snapshot name or ID for source disk view")
	device := fs.String("device", defaultNbdDevice, "Local NBD device created by nbd-client")
	socket := fs.String("socket", defaultNbdSocket, "nbdkit unix socket path")
	pidFile := fs.String("pid-file", defaultNbdPidFile, "nbdkit pid file path")
	stateFile := fs.String("state-file", defaultNbdState, "Session state file path")
	vddkLib := fs.String("vddk-libdir", defaultVddkLibDir, "VDDK library directory")
	vddkConfig := fs.String("vddk-config", "", "Optional VDDK config file")
	skipConnect := fs.Bool("skip-connect", false, "Only start nbdkit; do not run nbd-client")
	_ = fs.Parse(args)

	connect := vddkConnectConfig{
		Server:      envOrFlag(*server, "DISK_BLOCK_DIFF_VCENTER_SERVER", "VDDK_ENDPOINT"),
		Username:    envOrFlag(*username, "DISK_BLOCK_DIFF_VCENTER_USER", "VDDK_USER", "IMPORTER_ACCESS_KEY_ID"),
		Password:    envOrFlag(*password, "DISK_BLOCK_DIFF_VCENTER_PASSWORD", "VDDK_PASSWORD", "IMPORTER_SECRET_KEY"),
		Thumbprint:  envOrFlag(*thumbprint, "DISK_BLOCK_DIFF_VCENTER_THUMBPRINT", "VDDK_THUMBPRINT"),
		UUID:        envOrFlag(*uuid, "DISK_BLOCK_DIFF_VM_UUID", "VDDK_UUID"),
		Moref:       strings.TrimSpace(*moref),
		BackingFile: strings.TrimSpace(*backingFile),
		Snapshot:    strings.TrimSpace(*snapshot),
		DiskPath:    strings.TrimSpace(*disk),
	}

	resolvedMoref, diskPath, err := resolveVddkDiskPath(connect)
	if err != nil {
		log.Fatalf("%v", err)
	}

	configPath := strings.TrimSpace(*vddkConfig)
	if configPath == "" {
		configPath = defaultVddkConfigPath()
	}

	nbdkitCfg := vddkNbdkitConfig{
		Server:     vcenterHostForNbdkit(connect.Server),
		Username:   connect.Username,
		Password:   connect.Password,
		Thumbprint: connect.Thumbprint,
		Moref:      resolvedMoref,
		Snapshot:   connect.Snapshot,
		DiskPath:   diskPath,
		LibDir:     *vddkLib,
		ConfigPath: configPath,
		Socket:     *socket,
		PidFile:    *pidFile,
	}

	log.Printf("opening VDDK disk %q (moref=%s snapshot=%q)", diskPath, resolvedMoref, connect.Snapshot)
	if err := openNbdSession(nbdkitCfg, *device, *stateFile, *skipConnect); err != nil {
		log.Fatalf("%v", err)
	}
}

func runNbdClose(args []string) {
	fs := flag.NewFlagSet("nbd-close", flag.ExitOnError)
	stateFile := fs.String("state-file", defaultNbdState, "Session state file path")
	_ = fs.Parse(args)

	if err := closeNbdSession(*stateFile); err != nil {
		log.Fatalf("%v", err)
	}
}

func runNbdStatus(args []string) {
	fs := flag.NewFlagSet("nbd-status", flag.ExitOnError)
	stateFile := fs.String("state-file", defaultNbdState, "Session state file path")
	_ = fs.Parse(args)

	if err := showNbdSession(*stateFile); err != nil {
		log.Fatalf("%v", err)
	}
}
