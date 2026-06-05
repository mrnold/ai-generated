package main

import (
	"testing"
	"time"
)

func TestParseProgressInterval(t *testing.T) {
	cases := map[string]time.Duration{
		"10s":  10 * time.Second,
		"30s":  30 * time.Second,
		"5m":   5 * time.Minute,
		"0":    0,
		"off":  0, // invalid - should error
	}
	for raw, want := range cases {
		if raw == "off" {
			if _, err := parseProgressInterval(raw); err == nil {
				t.Fatalf("expected error for %q", raw)
			}
			continue
		}
		got, err := parseProgressInterval(raw)
		if err != nil {
			t.Fatalf("%s: %v", raw, err)
		}
		if got != want {
			t.Fatalf("%s: got %v want %v", raw, got, want)
		}
	}
}

func TestFormatBytes(t *testing.T) {
	if got := formatBytes(1 << 30); got != "1.0 GiB" {
		t.Fatalf("got %q", got)
	}
	if got := formatBytes(512); got != "512 B" {
		t.Fatalf("got %q", got)
	}
}

func TestFormatETA(t *testing.T) {
	if got := formatETA(50, 100, 10); got == "unknown" || got == "" {
		t.Fatalf("got %q", got)
	}
	if got := formatETA(100, 100, 10); got != "0s" {
		t.Fatalf("got %q", got)
	}
	if got := formatETA(0, 100, 0); got != "unknown" {
		t.Fatalf("got %q", got)
	}
}

func TestFormatDuration(t *testing.T) {
	if got := formatDuration(90 * time.Second); got != "1m30s" {
		t.Fatalf("got %q", got)
	}
	if got := formatDuration(26*time.Hour + 15*time.Minute); got != "1d02h" {
		t.Fatalf("got %q", got)
	}
}
