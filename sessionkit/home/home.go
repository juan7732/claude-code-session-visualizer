// Package home locates skit's own data directory: $SKIT_HOME, else
// ~/.sessionkit. Never under ~/Library, never under ~/.claude.
package home

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Dir returns skit's home directory.
func Dir() (string, error) {
	if d := os.Getenv("SKIT_HOME"); d != "" {
		return d, nil
	}
	h, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("cannot find home directory: %w", err)
	}
	return filepath.Join(h, ".sessionkit"), nil
}

// DBPath is the index database inside a skit home.
func DBPath(dir string) string { return filepath.Join(dir, "skit.sqlite") }

// ArchiveDir is where raw transcripts are kept inside a skit home.
func ArchiveDir(dir string) string { return filepath.Join(dir, "archive") }

// RunDir holds small files about processes skit started (the embedding
// sidecar), so a later skit can clean up after one that was killed.
func RunDir(dir string) string { return filepath.Join(dir, "run") }

// LocalZone is the machine's time zone under its own name ("America/Chicago").
// time.Local calls itself "Local", which tells a reader on another clock
// nothing; the name comes from TZ or from where /etc/localtime points. When
// neither says, it is time.Local as it is.
func LocalZone() *time.Location {
	name := os.Getenv("TZ")
	if name == "" {
		if target, err := os.Readlink("/etc/localtime"); err == nil {
			if i := strings.Index(target, "zoneinfo/"); i >= 0 {
				name = target[i+len("zoneinfo/"):]
			}
		}
	}
	if name != "" {
		if loc, err := time.LoadLocation(name); err == nil {
			return loc
		}
	}
	return time.Local
}
