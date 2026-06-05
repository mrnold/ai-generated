package main

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	defaultNbdSocket   = "/tmp/disk-block-diff-nbd.sock"
	defaultNbdPidFile  = "/tmp/disk-block-diff-nbd.pid"
	defaultNbdDevice   = "/dev/nbd0"
	defaultNbdState    = "/var/run/disk-block-diff/nbd.state"
	defaultVddkLibDir  = "/opt/vmware-vix-disklib-distrib"
)

type nbdSessionState struct {
	Socket   string `json:"socket"`
	PidFile  string `json:"pid_file"`
	Device   string `json:"device"`
	DiskPath string `json:"disk_path"`
	Server   string `json:"server"`
	Snapshot string `json:"snapshot,omitempty"`
	Moref    string `json:"moref"`
}

func openNbdSession(cfg vddkNbdkitConfig, device string, statePath string, skipConnect bool) error {
	if device == "" {
		device = defaultNbdDevice
	}
	if statePath == "" {
		statePath = defaultNbdState
	}

	existing, err := readNbdSessionState(statePath)
	if err == nil && existing != nil {
		return fmt.Errorf("NBD session already open at %s (device %s); run nbd-close first", statePath, existing.Device)
	}

	nbdkit, err := startVddkNbdkit(cfg)
	if err != nil {
		return err
	}

	state := &nbdSessionState{
		Socket:   cfg.Socket,
		PidFile:  cfg.PidFile,
		Device:   device,
		DiskPath: cfg.DiskPath,
		Server:   cfg.Server,
		Snapshot: cfg.Snapshot,
		Moref:    cfg.Moref,
	}

	if !skipConnect {
		if err := ensureNbdKernelModule(); err != nil {
			log.Printf("nbd kernel module unavailable (%v); using libnbd socket mode", err)
			skipConnect = true
		} else if err := connectNbdClient(cfg.Socket, device); err != nil {
			log.Printf("nbd-client connect failed (%v); using libnbd socket mode", err)
			skipConnect = true
		} else {
			log.Printf("connected unix socket %s to %s", cfg.Socket, device)
		}
	}
	if skipConnect {
		state.Device = ""
		log.Printf("source via libnbd socket %s (apply -nbd-state)", cfg.Socket)
	}

	if err := writeNbdSessionState(statePath, state); err != nil {
		if state.Device != "" {
			_ = disconnectNbdClient(device)
		}
		_ = nbdkit.stop()
		return err
	}

	log.Printf("NBD session ready")
	log.Printf("  state file: %s", statePath)
	if skipConnect {
		log.Printf("  socket:     %s", cfg.Socket)
	} else {
		log.Printf("  source dev: %s", device)
		log.Printf("  example:    %s hash -device %s -output source.jsonl", os.Args[0], device)
		log.Printf("  example:    %s apply -source %s -dest /dev/cdi-block-volume -blocks repair.jsonl", os.Args[0], device)
	}
	return nil
}

func closeNbdSession(statePath string) error {
	if statePath == "" {
		statePath = defaultNbdState
	}
	state, err := readNbdSessionState(statePath)
	if err != nil {
		return err
	}
	if state == nil {
		return fmt.Errorf("no NBD session state at %s", statePath)
	}

	if state.Device != "" {
		if err := disconnectNbdClient(state.Device); err != nil {
			log.Printf("warning: disconnect %s: %v", state.Device, err)
		}
	} else if state.Socket != "" {
		log.Printf("libnbd socket session %s (no nbd-client device to disconnect)", state.Socket)
	}

	if state.PidFile != "" {
		if data, err := os.ReadFile(state.PidFile); err == nil {
			pid := strings.TrimSpace(string(data))
			if pid != "" {
				if n, convErr := strconv.Atoi(strings.TrimSpace(pid)); convErr == nil {
					if proc, err := os.FindProcess(n); err == nil && proc != nil {
						_ = proc.Signal(os.Interrupt)
					}
				}
			}
		}
		_ = os.Remove(state.PidFile)
	}
	if state.Socket != "" {
		_ = os.Remove(state.Socket)
	}
	_ = os.Remove(statePath)

	log.Printf("closed NBD session (was %s)", state.Device)
	return nil
}

func showNbdSession(statePath string) error {
	if statePath == "" {
		statePath = defaultNbdState
	}
	state, err := readNbdSessionState(statePath)
	if err != nil {
		return err
	}
	if state == nil {
		fmt.Printf("no active NBD session (%s not found)\n", statePath)
		return nil
	}
	fmt.Printf("state file: %s\n", statePath)
	fmt.Printf("device:     %s\n", state.Device)
	fmt.Printf("socket:     %s\n", state.Socket)
	fmt.Printf("disk:       %s\n", state.DiskPath)
	fmt.Printf("server:     %s\n", state.Server)
	fmt.Printf("moref:      %s\n", state.Moref)
	if state.Snapshot != "" {
		fmt.Printf("snapshot:   %s\n", state.Snapshot)
	}
	return nil
}

func sourceFromNbdState(statePath string) (string, error) {
	if statePath == "" {
		statePath = defaultNbdState
	}
	state, err := readNbdSessionState(statePath)
	if err != nil {
		return "", err
	}
	if state == nil || state.Device == "" {
		return "", fmt.Errorf("no connected NBD device in %s", statePath)
	}
	return state.Device, nil
}

func readNbdSessionState(path string) (*nbdSessionState, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var state nbdSessionState
	if err := json.Unmarshal(data, &state); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	return &state, nil
}

func writeNbdSessionState(path string, state *nbdSessionState) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

func modprobePath() string {
	for _, candidate := range []string{"/sbin/modprobe", "/usr/sbin/modprobe", "modprobe"} {
		if _, err := exec.LookPath(candidate); err == nil {
			return candidate
		}
	}
	return ""
}

func ensureNbdKernelModule() error {
	if _, err := os.Stat("/sys/module/nbd"); err == nil {
		return nil
	}
	if _, err := os.Stat("/dev/nbd0"); err == nil {
		return nil
	}
	path := modprobePath()
	if path == "" {
		return fmt.Errorf("modprobe not found and /dev/nbd0 missing")
	}
	cmd := exec.Command(path, "nbd")
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("load nbd kernel module (needs privileged pod): %w", err)
	}
	return nil
}

func connectNbdClient(socket string, device string) error {
	if _, err := exec.LookPath("nbd-client"); err != nil {
		return fmt.Errorf("nbd-client not found in PATH: %w", err)
	}
	cmd := exec.Command("nbd-client", "-u", socket, device, "-persist")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("nbd-client: %w (%s)", err, strings.TrimSpace(string(output)))
	}
	return nil
}

func disconnectNbdClient(device string) error {
	if _, err := exec.LookPath("nbd-client"); err != nil {
		return nil
	}
	cmd := exec.Command("nbd-client", "-d", device)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("nbd-client -d: %w (%s)", err, strings.TrimSpace(string(output)))
	}
	return nil
}
