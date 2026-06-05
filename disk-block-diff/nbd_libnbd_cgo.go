//go:build cgo && linux

package main

import (
	"fmt"
	"io"

	libnbd "libguestfs.org/libnbd"
)

// vCenter NBD reads are limited; chunk large apply reads like CDI importer.
const libnbdMaxPreadBytes = 2 << 20

type libnbdReader struct {
	handle *libnbd.Libnbd
}

func (r *libnbdReader) ReadAt(p []byte, off int64) (int, error) {
	if off < 0 {
		return 0, fmt.Errorf("negative offset %d", off)
	}
	total := 0
	for total < len(p) {
		chunk := len(p) - total
		if chunk > libnbdMaxPreadBytes {
			chunk = libnbdMaxPreadBytes
		}
		if err := r.handle.Pread(p[total:total+chunk], uint64(off)+uint64(total), nil); err != nil {
			if total > 0 {
				return total, err
			}
			return 0, err
		}
		total += chunk
	}
	return total, nil
}

func openLibnbdSocket(socket string) (io.ReaderAt, func() error, error) {
	handle, err := libnbd.Create()
	if err != nil {
		return nil, nil, fmt.Errorf("create libnbd handle: %w", err)
	}
	if err := handle.ConnectUri("nbd+unix://?socket=" + socket); err != nil {
		_ = handle.Close()
		return nil, nil, fmt.Errorf("libnbd connect %s: %w", socket, err)
	}
	reader := &libnbdReader{handle: handle}
	closeFn := func() error {
		if err := handle.Close(); err != nil {
			return err
		}
		return nil
	}
	return reader, closeFn, nil
}
