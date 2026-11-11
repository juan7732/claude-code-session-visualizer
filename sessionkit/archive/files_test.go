package archive

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/store"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/transcript"
)

// TestFileNow: a touched file as it is on disk, and that nothing else is read.
func TestFileNow(t *testing.T) {
	dir := t.TempDir()
	a, err := OpenAt(filepath.Join(dir, "home"))
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	work := filepath.Join(dir, "work")
	os.MkdirAll(filepath.Join(work, "sub"), 0o755)
	text, gone, binary := filepath.Join(work, "a.go"), filepath.Join(work, "gone.md"), filepath.Join(work, "pic.bin")
	os.WriteFile(text, []byte("package a\n// héllo\n"), 0o644)
	os.WriteFile(binary, []byte{0x89, 'P', 'N', 'G', 0, 1, 2}, 0o644)
	secret := filepath.Join(dir, "secret.txt")
	os.WriteFile(secret, []byte("not for the socket"), 0o600)

	at := time.Date(2026, 11, 8, 10, 0, 0, 0, time.UTC)
	if err := a.Store.UpsertSummary(store.SessionRow{ID: "s1", Project: "p", SourcePath: "/x", Title: "the session", Summary: []byte("{}")}); err != nil {
		t.Fatal(err)
	}
	rows := []store.FileRow{}
	for _, p := range []string{text, gone, binary, filepath.Join(work, "sub")} {
		rows = append(rows, store.FileRow{Path: p, Raw: filepath.Base(p), Writes: 1, FirstAt: at, LastAt: at})
	}
	if err := a.Store.ReplaceFiles("s1", rows); err != nil {
		t.Fatal(err)
	}

	v, err := a.FileNow(text, "", true)
	if err != nil || !v.Exists || v.Text != "package a\n// héllo\n" || v.Bytes != 20 || v.Modified == nil || v.Truncated || v.Reason != "" {
		t.Fatalf("a text file: %+v %v", v, err)
	}
	if len(v.Sessions) != 1 || v.Sessions[0].Title != "the session" || v.Sessions[0].Writes != 1 || v.Sessions[0].Raw != "a.go" {
		t.Fatalf("its sessions: %+v", v.Sessions)
	}
	if v, _ := a.FileNow(text, "", false); v.Text != "" || !v.Exists {
		t.Fatalf("without text: %+v", v)
	}
	if v, err := a.FileNow(gone, "", true); err != nil || v.Exists || v.Reason != "deleted" || len(v.Sessions) != 1 {
		t.Fatalf("a file that is gone still has its history: %+v %v", v, err)
	}
	if v, _ := a.FileNow(binary, "", true); !v.Exists || v.Reason != "binary" || v.Text != "" {
		t.Fatalf("a binary file: %+v", v)
	}
	if v, _ := a.FileNow(filepath.Join(work, "sub"), "", true); v.Reason != "directory" || v.Text != "" {
		t.Fatalf("a directory: %+v", v)
	}
	// A file no session touched is not read, whoever asks.
	if v, err := a.FileNow(secret, "", true); !errors.Is(err, ErrUntouched) || v.Text != "" {
		t.Fatalf("an untouched file must not be read: %+v %v", v, err)
	}

	// With a session, a path as that session wrote it is found where the index put it.
	if v, err := a.FileNow("a.go", "s1", true); err != nil || v.Path != text || v.Asked != "a.go" || !strings.HasPrefix(v.Text, "package a") {
		t.Fatalf("a path as the session wrote it: %+v %v", v, err)
	}

	// Of the places a path may be, the index keeps the one that is on disk.
	rel := &transcript.Relations{Files: []transcript.FileTouched{
		{Path: "a.go", Places: []string{filepath.Join(dir, "elsewhere", "a.go"), text}, Writes: 1, Touches: []transcript.FileTouch{{Mode: "write"}}},
		{Path: "never.go", Places: []string{filepath.Join(work, "never.go"), filepath.Join(dir, "never.go")}, Touches: []transcript.FileTouch{{Mode: "read"}}},
		{Path: "nowhere.go", Touches: []transcript.FileTouch{{Mode: "read"}}},
	}}
	picked := fileRows(rel)
	if len(picked) != 2 || picked[0].Path != text || picked[0].Writes != 1 || picked[1].Path != filepath.Join(work, "never.go") || picked[1].Reads != 1 {
		t.Fatalf("places: %+v", picked)
	}

	// More than the limit comes back cut, and says so.
	big := filepath.Join(work, "big.txt")
	os.WriteFile(big, []byte(strings.Repeat("é", MaxFileText)), 0o644)
	a.Store.ReplaceFiles("s1", []store.FileRow{{Path: big, Raw: "big.txt", Reads: 1, FirstAt: at, LastAt: at}})
	if v, _ := a.FileNow(big, "", true); !v.Truncated || len(v.Text) != MaxFileText || v.Bytes != int64(2*MaxFileText) {
		t.Fatalf("a large file: truncated=%v len=%d bytes=%d reason=%q", v.Truncated, len(v.Text), v.Bytes, v.Reason)
	}
}
