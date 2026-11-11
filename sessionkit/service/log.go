package service

import (
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"time"
)

// The agent's log is one file that launchd appends to for as long as the agent
// is installed. Nothing else ever shortens it, so `skit serve` does.
const (
	// LogName is the agent's log inside skit's home.
	LogName = "serve.log"
	// MaxLogBytes is the size past which the log is cut back.
	MaxLogBytes = 50 << 20
	// KeepLogBytes is how much of the newest log survives a cut: enough to
	// read back several weeks, far enough under the cap that cuts are rare.
	KeepLogBytes = 10 << 20
)

// LogPath is where the agent's log lives for a skit home.
func LogPath(skitHome string) string { return filepath.Join(skitHome, LogName) }

// CapLog cuts the log at path back to its newest keep bytes, starting at a line
// boundary, when it has grown past max. It reports whether it cut.
//
// The file is rewritten in place, never replaced: launchd holds it open in
// append mode, and a new file under the same name would leave the agent
// writing into the old, unlinked one.
func CapLog(path string, max, keep int64) (bool, error) {
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil || fi.Size() <= max {
		return false, err
	}
	tail := make([]byte, keep)
	n, err := f.ReadAt(tail, fi.Size()-keep)
	if err != nil && err != io.EOF {
		return false, err
	}
	tail = tail[:n]
	// Start at the first whole line.
	if i := bytes.IndexByte(tail, '\n'); i >= 0 {
		tail = tail[i+1:]
	}
	if err := f.Truncate(0); err != nil {
		return false, err
	}
	if _, err := f.WriteAt(tail, 0); err != nil {
		return false, err
	}
	return true, f.Sync()
}

// KeepLogCapped caps the agent's log now and then once an hour until ctx is done.
func KeepLogCapped(ctx context.Context, skitHome string, logf func(string, ...any)) {
	tick := time.NewTicker(time.Hour)
	defer tick.Stop()
	for {
		// launchd creates the log 0644. It names sessions, projects and paths: the owner's alone to read.
		if st, err := os.Stat(LogPath(skitHome)); err == nil && st.Mode().Perm()&0o077 != 0 {
			_ = os.Chmod(LogPath(skitHome), 0o600)
		}
		if cut, err := CapLog(LogPath(skitHome), MaxLogBytes, KeepLogBytes); err != nil {
			logf("log: %v", err)
		} else if cut {
			logf("log: %s passed %d MB and was cut back to its newest %d MB", LogName, MaxLogBytes>>20, KeepLogBytes>>20)
		}
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}
