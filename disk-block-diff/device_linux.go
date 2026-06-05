//go:build linux

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"unsafe"

	"golang.org/x/sys/unix"
)

const linuxSectorSize = 512

func deviceSize(f *os.File, devicePath string) (int64, error) {
	if size, err := linuxBlkGetSize64(f.Fd()); err == nil && size > 0 {
		return int64(size), nil
	}
	if size, err := blockSizeFromSysfs(devicePath); err == nil && size > 0 {
		return size, nil
	}
	if size, err := blockSizeFromFstat(int(f.Fd())); err == nil && size > 0 {
		return size, nil
	}
	info, err := f.Stat()
	if err != nil {
		return 0, err
	}
	if info.Mode()&os.ModeDevice != 0 && info.Size() == 0 {
		return 0, fmt.Errorf(
			"block device %s: ioctl and sysfs size lookups failed (check volumeDevices attachment and PVC volumeMode=Block)",
			devicePath,
		)
	}
	return info.Size(), nil
}

func blockSizeFromSysfs(devicePath string) (int64, error) {
	resolved, err := filepath.EvalSymlinks(devicePath)
	if err != nil {
		resolved = devicePath
	}
	name := blockSysfsName(resolved)
	if name == "" {
		return 0, fmt.Errorf("cannot resolve sysfs block name for %s", devicePath)
	}
	return readBlockSectorSize(filepath.Join("/sys/class/block", name, "size"))
}

func blockSizeFromFstat(fd int) (int64, error) {
	var st unix.Stat_t
	if err := unix.Fstat(fd, &st); err != nil {
		return 0, err
	}
	if st.Mode&unix.S_IFMT != unix.S_IFBLK {
		return 0, fmt.Errorf("fd is not a block device")
	}
	major := unix.Major(uint64(st.Rdev))
	minor := unix.Minor(uint64(st.Rdev))
	return readBlockSectorSize(fmt.Sprintf("/sys/dev/block/%d:%d/size", major, minor))
}

func readBlockSectorSize(sysfsSizePath string) (int64, error) {
	data, err := os.ReadFile(sysfsSizePath)
	if err != nil {
		return 0, err
	}
	sectors, err := strconv.ParseUint(strings.TrimSpace(string(data)), 10, 64)
	if err != nil {
		return 0, err
	}
	return int64(sectors) * linuxSectorSize, nil
}

func linuxBlkGetSize64(fd uintptr) (uint64, error) {
	var size uint64
	_, _, errno := unix.Syscall(unix.SYS_IOCTL, fd, unix.BLKGETSIZE64, uintptr(unsafe.Pointer(&size)))
	if errno != 0 {
		return 0, errno
	}
	return size, nil
}

func blockSysfsName(devicePath string) string {
	base := filepath.Base(devicePath)
	if base == "" || base == "." || base == "/" {
		return ""
	}
	return base
}
