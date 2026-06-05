package main

import (
	"fmt"
	"log"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type progressReporter struct {
	action     string
	totalItems uint64
	totalBytes int64
	interval   time.Duration

	doneItems atomic.Uint64
	doneBytes atomic.Int64

	startTime time.Time
	stopCh    chan struct{}
	wg        sync.WaitGroup
}

func newProgressReporter(action string, totalItems uint64, totalBytes int64, interval time.Duration) *progressReporter {
	return &progressReporter{
		action:     action,
		totalItems: totalItems,
		totalBytes: totalBytes,
		interval:   interval,
		stopCh:     make(chan struct{}),
	}
}

func (p *progressReporter) start() {
	if p == nil || p.interval <= 0 {
		return
	}
	p.startTime = time.Now()
	p.logProgress()
	p.wg.Add(1)
	go func() {
		defer p.wg.Done()
		ticker := time.NewTicker(p.interval)
		defer ticker.Stop()
		for {
			select {
			case <-p.stopCh:
				return
			case <-ticker.C:
				p.logProgress()
			}
		}
	}()
}

func (p *progressReporter) stop() {
	if p == nil || p.interval <= 0 {
		return
	}
	close(p.stopCh)
	p.wg.Wait()
	p.logProgress()
}

func (p *progressReporter) add(bytes int64) {
	if p == nil {
		return
	}
	p.doneItems.Add(1)
	p.doneBytes.Add(bytes)
}

func (p *progressReporter) logProgress() {
	doneItems := p.doneItems.Load()
	doneBytes := p.doneBytes.Load()
	elapsed := time.Since(p.startTime)

	var rateBytesPerSec float64
	if elapsed > 0 {
		rateBytesPerSec = float64(doneBytes) / elapsed.Seconds()
	}

	eta := formatETA(doneBytes, p.totalBytes, rateBytesPerSec)
	log.Printf(
		"progress: %s %d/%d blocks (%.1f%%), %s / %s, rate %s/s, elapsed %s, ETA %s",
		p.action,
		doneItems,
		p.totalItems,
		percent(doneItems, p.totalItems),
		formatBytes(doneBytes),
		formatBytes(p.totalBytes),
		formatBytes(int64(rateBytesPerSec)),
		formatDuration(elapsed),
		eta,
	)
}

func formatETA(doneBytes int64, totalBytes int64, rateBytesPerSec float64) string {
	remaining := totalBytes - doneBytes
	if remaining <= 0 {
		return "0s"
	}
	if rateBytesPerSec <= 0 {
		return "unknown"
	}
	seconds := float64(remaining) / rateBytesPerSec
	return formatDuration(time.Duration(seconds * float64(time.Second)))
}

func formatBytes(bytes int64) string {
	if bytes < 0 {
		bytes = 0
	}
	const unit = 1024
	if bytes < unit {
		return fmt.Sprintf("%d B", bytes)
	}
	value := float64(bytes)
	div := float64(unit)
	suffixes := []string{"KiB", "MiB", "GiB", "TiB", "PiB"}
	for _, suffix := range suffixes {
		if value < div*unit {
			return fmt.Sprintf("%.1f %s", value/div, suffix)
		}
		div *= unit
	}
	return fmt.Sprintf("%.1f EiB", value/div)
}

func formatDuration(d time.Duration) string {
	if d < 0 {
		d = 0
	}
	seconds := int64(d.Round(time.Second) / time.Second)
	if seconds < 60 {
		return fmt.Sprintf("%ds", seconds)
	}
	minutes := seconds / 60
	seconds %= 60
	if minutes < 60 {
		return fmt.Sprintf("%dm%02ds", minutes, seconds)
	}
	hours := minutes / 60
	minutes %= 60
	if hours < 24 {
		return fmt.Sprintf("%dh%02dm", hours, minutes)
	}
	days := hours / 24
	hours %= 24
	return fmt.Sprintf("%dd%02dh", days, hours)
}

func parseProgressInterval(raw string) (time.Duration, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" || raw == "0" {
		return 0, nil
	}

	lower := strings.ToLower(raw)
	for _, suffix := range []struct {
		suffix string
		unit   time.Duration
	}{
		{"ms", time.Millisecond},
		{"s", time.Second},
		{"m", time.Minute},
		{"h", time.Hour},
	} {
		if strings.HasSuffix(lower, suffix.suffix) {
			num := strings.TrimSpace(lower[:len(lower)-len(suffix.suffix)])
			value, err := strconv.ParseFloat(num, 64)
			if err != nil {
				return 0, fmt.Errorf("parse progress interval %q: %w", raw, err)
			}
			if value <= 0 {
				return 0, nil
			}
			return time.Duration(value * float64(suffix.unit)), nil
		}
	}

	seconds, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		return 0, fmt.Errorf("parse progress interval %q: %w", raw, err)
	}
	if seconds <= 0 {
		return 0, nil
	}
	return time.Duration(seconds * float64(time.Second)), nil
}
