// Package home locates skit's own data directory: $SKIT_HOME, else
// ~/.sessionkit. Never under ~/Library, never under ~/.claude.
package home

import (
	"fmt"
	"os"
	"path/filepath"
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
