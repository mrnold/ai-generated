package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
)

const defaultBlockSize = 1 << 30 // 1 GiB

// BlockRecord is one fixed-size chunk of a block device.
type BlockRecord struct {
	Index  uint64 `json:"index"`
	Offset int64  `json:"offset"`
	Size   int64  `json:"size"`
	MD5    string `json:"md5"`
}

// DiffRecord identifies a destination block that should be overwritten from source.
type DiffRecord struct {
	Index  uint64 `json:"index"`
	Offset int64  `json:"offset"`
	Size   int64  `json:"size"`
	Reason string `json:"reason"`
	Source string `json:"source_md5,omitempty"`
	Dest   string `json:"dest_md5,omitempty"`
}

func writeBlockRecord(w io.Writer, rec BlockRecord) error {
	data, err := json.Marshal(rec)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(w, "%s\n", data)
	return err
}

func readBlockManifest(path string) ([]BlockRecord, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var records []BlockRecord
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var rec BlockRecord
		if err := json.Unmarshal(line, &rec); err != nil {
			return nil, fmt.Errorf("parse manifest %s: %w", path, err)
		}
		records = append(records, rec)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return records, nil
}

func writeDiffRecord(w io.Writer, rec DiffRecord) error {
	data, err := json.Marshal(rec)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(w, "%s\n", data)
	return err
}

func readDiffManifest(path string) ([]DiffRecord, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var records []DiffRecord
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var rec DiffRecord
		if err := json.Unmarshal(line, &rec); err != nil {
			return nil, fmt.Errorf("parse diff list %s: %w", path, err)
		}
		records = append(records, rec)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return records, nil
}

func blockCount(deviceSize int64, blockSize int64) uint64 {
	if deviceSize <= 0 {
		return 0
	}
	n := uint64(deviceSize / blockSize)
	if deviceSize%blockSize != 0 {
		n++
	}
	return n
}

func blockSpec(index uint64, deviceSize int64, blockSize int64) (offset int64, size int64) {
	offset = int64(index) * blockSize
	remaining := deviceSize - offset
	if remaining <= 0 {
		return offset, 0
	}
	if remaining < blockSize {
		return offset, remaining
	}
	return offset, blockSize
}
