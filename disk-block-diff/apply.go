package main

import (
	"fmt"
	"io"
	"log"
	"os"
	"sync"
	"sync/atomic"
	"syscall"
)

func applyBlocks(sourcePath string, destPath string, diffPath string, workers int, dryRun bool) error {
	records, err := readDiffManifest(diffPath)
	if err != nil {
		return err
	}
	if len(records) == 0 {
		log.Printf("diff list is empty, nothing to copy")
		return nil
	}

	source, err := os.Open(sourcePath)
	if err != nil {
		return fmt.Errorf("open source %s: %w", sourcePath, err)
	}
	defer source.Close()

	dest, err := os.OpenFile(destPath, os.O_WRONLY, 0)
	if err != nil {
		return fmt.Errorf("open destination %s: %w", destPath, err)
	}
	defer dest.Close()

	if dryRun {
		for _, rec := range records {
			log.Printf("dry-run: would copy block %d offset=%d size=%d reason=%s", rec.Index, rec.Offset, rec.Size, rec.Reason)
		}
		return nil
	}

	jobs := make(chan DiffRecord, workers*2)
	var wg sync.WaitGroup
	var copied atomic.Uint64
	var failed atomic.Uint64

	for range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			buf := make([]byte, 4<<20)
			for rec := range jobs {
				if err := copyBlock(source, dest, rec.Offset, rec.Size, buf); err != nil {
					failed.Add(1)
					log.Printf("copy block %d at offset %d failed: %v", rec.Index, rec.Offset, err)
					continue
				}
				done := copied.Add(1)
				if done%50 == 0 || done == uint64(len(records)) {
					log.Printf("copied %d/%d blocks (%.1f%%)", done, len(records), percent(done, uint64(len(records))))
				}
			}
		}()
	}

	for _, rec := range records {
		if rec.Reason == "missing_on_source" {
			log.Printf("skip block %d: present on dest manifest only", rec.Index)
			continue
		}
		jobs <- rec
	}
	close(jobs)
	wg.Wait()

	if err := dest.Sync(); err != nil {
		return fmt.Errorf("sync destination: %w", err)
	}
	if failed.Load() > 0 {
		return fmt.Errorf("apply finished with %d block failures", failed.Load())
	}
	log.Printf("applied %d blocks from %s to %s", copied.Load(), sourcePath, destPath)
	return nil
}

func copyBlock(source *os.File, dest *os.File, offset int64, size int64, buf []byte) error {
	remaining := size
	current := offset

	for remaining > 0 {
		toRead := int64(len(buf))
		if remaining < toRead {
			toRead = remaining
		}

		n, err := source.ReadAt(buf[:toRead], current)
		if err != nil && err != io.EOF {
			return err
		}
		if n == 0 {
			return fmt.Errorf("short read at offset %d", current)
		}

		written, err := syscall.Pwrite(int(dest.Fd()), buf[:n], current)
		if err != nil {
			return err
		}
		if written != n {
			return fmt.Errorf("short write at offset %d: wrote %d of %d", current, written, n)
		}

		current += int64(n)
		remaining -= int64(n)
	}
	return nil
}
