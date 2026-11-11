package archive

import (
	"errors"
	"os"
	"time"
	"unicode/utf8"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/store"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/transcript"
)

// MaxFileText is how much of a file FileNow returns as text.
const MaxFileText = 2 << 20

// FileView is a file some session touched, as it is on disk now, with the
// sessions that touched it. It is what `skit file` prints and GET /v0/file returns.
type FileView struct {
	// Path is where the file is on disk; Asked is the path as it was asked for.
	Path   string `json:"path"`
	Asked  string `json:"asked,omitempty"`
	Exists bool   `json:"exists"`
	// Reason says why there is no text: "deleted", "binary", "directory", "unreadable".
	Reason   string     `json:"reason,omitempty"`
	Bytes    int64      `json:"bytes,omitempty"`
	Modified *time.Time `json:"modified,omitempty"`
	// Text is the file's content, at most MaxFileText of it (Truncated says so).
	Text      string        `json:"text,omitempty"`
	Truncated bool          `json:"truncated,omitempty"`
	Sessions  []FileHistory `json:"sessions"`
}

// FileHistory is one session's dealings with a file.
type FileHistory struct {
	Session string `json:"session"`
	Title   string `json:"title"`
	Project string `json:"project"`
	// Raw is the path as that session wrote it: the key of the file in its relations.
	Raw     string    `json:"raw"`
	Reads   int       `json:"reads"`
	Writes  int       `json:"writes"`
	FirstAt time.Time `json:"first_at"`
	LastAt  time.Time `json:"last_at"`
}

// ErrUntouched is returned for a path no archived session touched.
var ErrUntouched = errors.New("no archived session touched this path")

// fileRows is what the index keeps of a session's files: one row per file,
// at the first of its likely places that is on disk now, or at the likeliest
// when none is (the file is gone, or was never where a command seemed to say).
func fileRows(rel *transcript.Relations) []store.FileRow {
	var rows []store.FileRow
	for _, f := range rel.Files {
		if len(f.Places) == 0 || len(f.Touches) == 0 {
			continue
		}
		where := f.Places[0]
		for _, p := range f.Places {
			if st, err := os.Stat(p); err == nil && !st.IsDir() {
				where = p
				break
			}
		}
		rows = append(rows, store.FileRow{Path: where, Raw: f.Path, Writes: f.Writes, Reads: len(f.Touches) - f.Writes,
			FirstAt: f.Touches[0].At, LastAt: f.Touches[len(f.Touches)-1].At})
	}
	return rows
}

// FileNow says what a file is now and which sessions touched it. path is
// where the file is on disk, or, with a session's id, the path as that session
// wrote it. withText includes the content.
//
// DECISION: only a file some archived session touched is ever read, so the
// engine does not become a way to read any file by asking the socket.
func (a *Archive) FileNow(path, session string, withText bool) (FileView, error) {
	view := FileView{Path: path, Asked: path, Sessions: []FileHistory{}}
	if session != "" {
		where, err := a.Store.FilePath(session, path)
		if err != nil {
			return view, err
		}
		if where != "" {
			view.Path = where
		}
	}
	touched, err := a.Store.FileSessions(view.Path)
	if err != nil {
		return view, err
	}
	if len(touched) == 0 {
		return view, ErrUntouched
	}
	for _, t := range touched {
		view.Sessions = append(view.Sessions, FileHistory{Session: t.Session, Title: t.Title, Project: t.Project, Raw: t.Raw,
			Reads: t.Reads, Writes: t.Writes, FirstAt: t.FirstAt, LastAt: t.LastAt})
	}
	st, err := os.Stat(view.Path)
	switch {
	case errors.Is(err, os.ErrNotExist):
		view.Reason = "deleted"
		return view, nil
	case err != nil:
		view.Reason = "unreadable"
		return view, nil
	case st.IsDir():
		view.Exists, view.Reason = true, "directory"
		return view, nil
	case !st.Mode().IsRegular():
		view.Exists, view.Reason = true, "unreadable"
		return view, nil
	}
	mod := st.ModTime()
	view.Exists, view.Bytes, view.Modified = true, st.Size(), &mod
	if !withText {
		return view, nil
	}
	f, err := os.Open(view.Path)
	if err != nil {
		view.Reason = "unreadable"
		return view, nil
	}
	defer f.Close()
	buf := make([]byte, MaxFileText+1)
	n, _ := readFull(f, buf)
	if n > MaxFileText {
		n, view.Truncated = MaxFileText, true
	}
	buf = buf[:n]
	if !isText(buf, view.Truncated) {
		view.Reason = "binary"
		return view, nil
	}
	view.Text = string(buf)
	return view, nil
}

func readFull(f *os.File, buf []byte) (int, error) {
	total := 0
	for total < len(buf) {
		n, err := f.Read(buf[total:])
		total += n
		if err != nil {
			return total, err
		}
	}
	return total, nil
}

// isText: no NUL, and valid UTF-8 (a cut in the middle of a rune at the end of a truncated read is allowed).
func isText(b []byte, truncated bool) bool {
	for _, c := range b {
		if c == 0 {
			return false
		}
	}
	if utf8.Valid(b) {
		return true
	}
	if truncated {
		for cut := 1; cut <= 3 && cut < len(b); cut++ {
			if utf8.Valid(b[:len(b)-cut]) {
				return true
			}
		}
	}
	return false
}
