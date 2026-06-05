package main

import (
	"bufio"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const (
	nbdPasswordFD     = 3
	nbdkitStartupWait = 15 * time.Second
)

type nbdkitProcess struct {
	cmd        *exec.Cmd
	pidFile    string
	socket     string
	passwordFD *os.File
}

type vddkNbdkitConfig struct {
	Server     string
	Username   string
	Password   string
	Thumbprint string
	Moref      string
	Snapshot   string
	DiskPath   string
	LibDir     string
	ConfigPath string
	Socket     string
	PidFile    string
}

func startVddkNbdkit(cfg vddkNbdkitConfig) (*nbdkitProcess, error) {
	if cfg.DiskPath == "" {
		return nil, fmt.Errorf("disk path is required")
	}
	if cfg.Server == "" {
		return nil, fmt.Errorf("vCenter server is required")
	}
	if cfg.Moref == "" {
		return nil, fmt.Errorf("VM moref is required")
	}
	if cfg.Socket == "" {
		cfg.Socket = defaultNbdSocket
	}
	if cfg.PidFile == "" {
		cfg.PidFile = defaultNbdPidFile
	}
	if cfg.LibDir == "" {
		cfg.LibDir = defaultVddkLibDir
	}

	_ = os.Remove(cfg.Socket)
	_ = os.Remove(cfg.PidFile)

	pluginArgs := []string{"libdir=" + cfg.LibDir}
	pluginArgs = append(pluginArgs, "server="+cfg.Server)
	if cfg.Username != "" {
		pluginArgs = append(pluginArgs, "user="+cfg.Username)
	}

	var passwordFD *os.File
	if cfg.Password != "" {
		fd, err := createPasswordPipe(cfg.Password)
		if err != nil {
			return nil, err
		}
		passwordFD = fd
		pluginArgs = append(pluginArgs, fmt.Sprintf("password=-%d", nbdPasswordFD))
	}
	if cfg.Thumbprint != "" {
		pluginArgs = append(pluginArgs, "thumbprint="+cfg.Thumbprint)
	}
	pluginArgs = append(pluginArgs, "vm=moref="+cfg.Moref)
	if cfg.Snapshot != "" {
		pluginArgs = append(pluginArgs, "snapshot="+cfg.Snapshot)
		pluginArgs = append(pluginArgs, "transports=file:nbdssl:nbd")
	}
	pluginArgs = append(pluginArgs, "--verbose")
	pluginArgs = append(pluginArgs, "-D", "nbdkit.backend.datapath=0")
	pluginArgs = append(pluginArgs, "-D", "vddk.datapath=0")
	if cfg.ConfigPath != "" {
		pluginArgs = append(pluginArgs, "config="+cfg.ConfigPath)
	}

	args := []string{
		"--foreground",
		"--readonly",
		"-U", cfg.Socket,
		"--pidfile", cfg.PidFile,
		"--filter=retry",
		"--filter=cacheextents",
		"vddk",
	}
	args = append(args, pluginArgs...)
	args = append(args, "file="+cfg.DiskPath)

	cmd := exec.Command("nbdkit", args...)
	if passwordFD != nil {
		cmd.ExtraFiles = []*os.File{passwordFD}
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		if passwordFD != nil {
			_ = passwordFD.Close()
		}
		return nil, fmt.Errorf("nbdkit stdout pipe: %w", err)
	}
	cmd.Stderr = cmd.Stdout
	go watchNbdkitLog(stdout)

	if err := cmd.Start(); err != nil {
		if passwordFD != nil {
			_ = passwordFD.Close()
		}
		return nil, fmt.Errorf("start nbdkit: %w", err)
	}
	if passwordFD != nil {
		_ = passwordFD.Close()
	}

	if err := waitForNbdkitPID(cfg.PidFile, nbdkitStartupWait); err != nil {
		_ = cmd.Process.Kill()
		return nil, err
	}

	log.Printf("nbdkit ready on socket %s", cfg.Socket)
	return &nbdkitProcess{
		cmd:     cmd,
		pidFile: cfg.PidFile,
		socket:  cfg.Socket,
	}, nil
}

func (p *nbdkitProcess) stop() error {
	if p == nil || p.cmd == nil || p.cmd.Process == nil {
		return nil
	}
	err := p.cmd.Process.Signal(os.Interrupt)
	if err != nil {
		err = p.cmd.Process.Kill()
	}
	_ = os.Remove(p.pidFile)
	_ = os.Remove(p.socket)
	return err
}

func createPasswordPipe(password string) (*os.File, error) {
	r, w, err := os.Pipe()
	if err != nil {
		return nil, fmt.Errorf("password pipe: %w", err)
	}
	if _, err := w.WriteString(password); err != nil {
		_ = r.Close()
		_ = w.Close()
		return nil, fmt.Errorf("write password pipe: %w", err)
	}
	if err := w.Close(); err != nil {
		_ = r.Close()
		return nil, fmt.Errorf("close password pipe writer: %w", err)
	}
	return r, nil
}

func waitForNbdkitPID(pidFile string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(pidFile); err == nil {
			return nil
		}
		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("timed out waiting for nbdkit pid file %s", pidFile)
}

func watchNbdkitLog(output io.Reader) {
	scanner := bufio.NewScanner(output)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.Contains(line, "password=") {
			continue
		}
		log.Printf("nbdkit: %s", line)
	}
}

func defaultVddkConfigPath() string {
	path := filepath.Join("/etc/vddk-config", "vddk-config-file")
	if _, err := os.Stat(path); err == nil {
		return path
	}
	return ""
}
