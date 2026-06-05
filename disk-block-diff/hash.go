package main

import (
	"crypto/md5"
	"encoding/hex"
	"fmt"
	"io"
	"log"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

type readerAt interface {
	io.ReaderAt
}

func hashDevice(devicePath string, outputPath string, blockSize int64, workers int, startIndex uint64, progressInterval time.Duration) error {
	f, err := os.Open(devicePath)
	if err != nil {
		return fmt.Errorf("open device %s: %w", devicePath, err)
	}
	defer f.Close()

	size, err := deviceSize(f, devicePath)
	if err != nil {
		return fmt.Errorf("size of device %s: %w", devicePath, err)
	}
	if size <= 0 {
		return fmt.Errorf("device %s has size 0 (wrong path or empty disk?)", devicePath)
	}
	deviceSize := size
	totalBlocks := blockCount(deviceSize, blockSize)
	if startIndex >= totalBlocks {
		return fmt.Errorf("start-index %d is beyond block count %d", startIndex, totalBlocks)
	}

	out, err := os.Create(outputPath)
	if err != nil {
		return fmt.Errorf("create manifest %s: %w", outputPath, err)
	}
	defer out.Close()

	writer := &sync.Mutex{}
	write := func(rec BlockRecord) error {
		writer.Lock()
		defer writer.Unlock()
		return writeBlockRecord(out, rec)
	}

	remainingBlocks := totalBlocks - startIndex
	var totalBytes int64
	for index := startIndex; index < totalBlocks; index++ {
		_, size := blockSpec(index, deviceSize, blockSize)
		totalBytes += size
	}

	progress := newProgressReporter("hashed", remainingBlocks, totalBytes, progressInterval)
	progress.start()
	defer progress.stop()

	jobs := make(chan uint64, workers*2)
	var wg sync.WaitGroup
	var failed atomic.Uint64

	for range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for index := range jobs {
				offset, size := blockSpec(index, deviceSize, blockSize)
				if size == 0 {
					continue
				}
				sum, err := hashRange(f, offset, size)
				if err != nil {
					failed.Add(1)
					log.Printf("hash block %d at offset %d failed: %v", index, offset, err)
					continue
				}
				rec := BlockRecord{
					Index:  index,
					Offset: offset,
					Size:   size,
					MD5:    sum,
				}
				if err := write(rec); err != nil {
					failed.Add(1)
					log.Printf("write manifest block %d failed: %v", index, err)
					continue
				}
				progress.add(size)
			}
		}()
	}

	for index := startIndex; index < totalBlocks; index++ {
		jobs <- index
	}
	close(jobs)
	wg.Wait()

	if failed.Load() > 0 {
		return fmt.Errorf("hashing finished with %d block failures", failed.Load())
	}
	log.Printf("wrote manifest %s (%d blocks, %s total)", outputPath, remainingBlocks, formatBytes(totalBytes))
	return nil
}

func hashRange(r readerAt, offset int64, size int64) (string, error) {
	const chunkSize = 4 << 20 // 4 MiB read buffer inside each block

	h := md5.New()
	buf := make([]byte, chunkSize)
	remaining := size
	current := offset

	for remaining > 0 {
		toRead := int64(len(buf))
		if remaining < toRead {
			toRead = remaining
		}
		n, err := r.ReadAt(buf[:toRead], current)
		if err != nil && err != io.EOF {
			return "", err
		}
		if n == 0 {
			break
		}
		if _, err := h.Write(buf[:n]); err != nil {
			return "", err
		}
		current += int64(n)
		remaining -= int64(n)
	}

	return hex.EncodeToString(h.Sum(nil)), nil
}

func percent(done uint64, total uint64) float64 {
	if total == 0 {
		return 100
	}
	return 100 * float64(done) / float64(total)
}
