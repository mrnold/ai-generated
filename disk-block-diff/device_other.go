//go:build !linux

package main

import (
	"os"
)

func deviceSize(f *os.File, _ string) (int64, error) {
	info, err := f.Stat()
	if err != nil {
		return 0, err
	}
	return info.Size(), nil
}
