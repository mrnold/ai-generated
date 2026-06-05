//go:build !cgo || !linux

package main

import (
	"fmt"
	"io"
)

func openLibnbdSocket(socket string) (io.ReaderAt, func() error, error) {
	return nil, nil, fmt.Errorf("libnbd support not built (need CGO_ENABLED=1 on linux for socket %s)", socket)
}
