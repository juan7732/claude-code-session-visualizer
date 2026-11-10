package archive

// The raw copy and the rules that keep it from losing lines (ADR 0008):
//
//   - An append first checks that the copy is exactly as long as the index says,
//     cutting off anything after that length (a write that was torn by a crash
//     or a full disk), and that the source still starts with what was copied.
//   - Everything else is a rewrite: to a temp file, synced, then renamed over the
//     copy. A reader never sees half a file.
//   - A copy that holds more than its replacement, or that the source no longer
//     agrees with, or that no longer decodes, is renamed to <copy>.prev-<time>
//     and kept. skit never deletes it.

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/klauspost/compress/zstd"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/store"
)

// tailWindow is how many source bytes before the append offset are hashed to
// recognise the source on the next ingest.
const tailWindow = 64 << 10

// previousMark is the infix of a kept earlier copy: <copy>.prev-20261110T093000Z.
const previousMark = ".prev-"

// sourceFingerprint is the state of a located transcript, as the index records it.
func sourceFingerprint(l catalog.Located) string {
	return store.SourceFingerprint(l.File.Bytes, l.File.ModTime.UnixNano(), l.File.Subagents, l.File.SubagentBytes)
}

// lock takes the archive's cross-process lock: two skit processes (a manual
// `skit archive` beside `skit serve`) must not write the same copy at once.
func (a *Archive) lock() (unlock func(), err error) {
	f, err := os.OpenFile(filepath.Join(a.Home, "archive.lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		f.Close()
		return nil, err
	}
	return func() {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
	}, nil
}

// copyMain brings the raw copy of l up to date and returns what the index
// should record, plus the path of an earlier copy that was kept aside, if any.
func (a *Archive) copyMain(l catalog.Located, row *store.SessionRow, dst string, keep bool) (st store.ArchiveState, kept string, err error) {
	src := l.File.Path
	st = store.ArchiveState{Path: dst, KeepsRequests: keep}
	prior := row != nil && row.Archived() && row.ArchivePath == dst

	// Does the source still begin with what was copied? Unknown (rows from an
	// older schema) is treated as "cannot append", never as "diverged".
	diverged := false
	if prior && row.ArchiveTail != "" {
		if l.File.Bytes < row.ArchivedBytes {
			diverged = true
		} else if h, herr := tailHash(src, row.ArchivedBytes); herr != nil || h != row.ArchiveTail {
			diverged = true
		}
	}

	if prior && !diverged && row.KeepsRequests == keep && row.ArchiveTail != "" && row.ArchivedBytes > 0 &&
		prepareAppend(dst, row.ArchiveSize, row.ArchivedBytes, keep) {
		st.Bytes, st.Size, err = appendFrame(src, dst, row.ArchivedBytes, keep)
		if err != nil {
			return st, "", err
		}
	} else {
		var written int64
		var tmp string
		st.Bytes, written, tmp, err = compressTo(src, dst, keep)
		if err != nil {
			return st, "", err
		}
		// DECISION: --strip-requests on a lossless copy is the one case where a
		// smaller replacement is what the user asked for.
		allowSmaller := prior && row.KeepsRequests && !keep
		if kept, err = placeCopy(tmp, dst, written, allowSmaller, diverged); err != nil {
			return st, kept, err
		}
		fi, serr := os.Stat(dst)
		if serr != nil {
			return st, kept, serr
		}
		st.Size = fi.Size()
	}
	st.Tail, err = tailHash(src, st.Bytes)
	return st, kept, err
}

// tailHash hashes the source bytes in [end-tailWindow, end).
func tailHash(path string, end int64) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	start := max(end-tailWindow, 0)
	h := sha256.New()
	n, err := io.Copy(h, io.NewSectionReader(f, start, end-start))
	if err != nil {
		return "", err
	}
	if n != end-start {
		return "", fmt.Errorf("%s is shorter than %d bytes", path, end)
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// prepareAppend reports whether dst can take another frame. It can when it is
// exactly the size the index recorded. When it is longer, the extra bytes are
// a write the index never confirmed: if the first `size` bytes still decode to
// what was archived, the rest is cut off and the append may go ahead.
func prepareAppend(dst string, size, archivedBytes int64, lossless bool) bool {
	fi, err := os.Stat(dst)
	if err != nil || size <= 0 || fi.Size() < size {
		return false
	}
	if fi.Size() == size {
		return true
	}
	f, err := os.Open(dst)
	if err != nil {
		return false
	}
	n, _, err := decodedLen(io.LimitReader(f, size))
	f.Close()
	if err != nil || (lossless && n != archivedBytes) {
		return false
	}
	return os.Truncate(dst, size) == nil
}

// appendFrame appends the complete lines of src from offset start to dst as a
// new zstd frame and syncs it. It returns the source offset just past the last
// complete line and dst's new size.
func appendFrame(src, dst string, start int64, keep bool) (covered, size int64, err error) {
	in, err := os.Open(src)
	if err != nil {
		return 0, 0, err
	}
	defer in.Close()
	if _, err := in.Seek(start, io.SeekStart); err != nil {
		return 0, 0, err
	}
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return 0, 0, err
	}
	defer out.Close()
	zw := &frameWriter{out: out}
	covered, err = filterLines(bufio.NewReaderSize(in, 1<<20), zw, start, keep)
	if cerr := zw.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = out.Sync()
	}
	if err != nil {
		return covered, 0, err
	}
	fi, err := out.Stat()
	if err != nil {
		return covered, 0, err
	}
	return covered, fi.Size(), nil
}

// compressTo writes every complete line of src into <dst>.tmp as one zstd
// frame, synced. It returns the source offset covered, the bytes written
// before compression, and the temp file's path. The caller places it.
func compressTo(src, dst string, keep bool) (covered, written int64, tmp string, err error) {
	in, err := os.Open(src)
	if err != nil {
		return 0, 0, "", err
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(dst), 0o700); err != nil {
		return 0, 0, "", err
	}
	tmp = dst + ".tmp"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return 0, 0, "", err
	}
	zw := &frameWriter{out: out, always: true}
	covered, err = filterLines(bufio.NewReaderSize(in, 1<<20), zw, 0, keep)
	if cerr := zw.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = out.Sync()
	}
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		os.Remove(tmp)
		return covered, zw.n, "", err
	}
	return covered, zw.n, tmp, nil
}

// placeCopy moves a finished temp file to dst. An existing dst is kept aside
// under a .prev- name when the source diverged from it (forceKeep), when it no
// longer decodes, or when it holds more than the new copy and a smaller copy
// was not asked for. An existing dst of the same decoded length is left alone.
func placeCopy(tmp, dst string, newLen int64, allowSmaller, forceKeep bool) (kept string, err error) {
	if _, serr := os.Stat(dst); serr == nil {
		oldLen, derr := decodedFileLen(dst)
		switch {
		case forceKeep, derr != nil, oldLen > newLen && !allowSmaller:
			kept = previousName(dst)
			if err := os.Rename(dst, kept); err != nil {
				os.Remove(tmp)
				return "", err
			}
		case oldLen == newLen:
			return "", os.Remove(tmp)
		}
	}
	if err := os.Rename(tmp, dst); err != nil {
		return kept, err
	}
	syncDir(filepath.Dir(dst))
	return kept, nil
}

// previousName picks a free <dst>.prev-<UTC time> name.
func previousName(dst string) string {
	base := dst + previousMark + time.Now().UTC().Format("20060102T150405Z")
	name := base
	for i := 2; ; i++ {
		if _, err := os.Stat(name); errors.Is(err, fs.ErrNotExist) {
			return name
		}
		name = fmt.Sprintf("%s-%d", base, i)
	}
}

// Previous lists the earlier copies kept beside a raw copy, oldest first.
func Previous(copyPath string) []string {
	m, _ := filepath.Glob(copyPath + previousMark + "*")
	return m
}

func syncDir(dir string) {
	if d, err := os.Open(dir); err == nil {
		_ = d.Sync()
		d.Close()
	}
}

// frameWriter is a zstd encoder that starts its frame on the first write, so an
// append with nothing new adds no bytes. With always set, Close writes an empty
// frame when nothing was written, so the file is still valid zstd.
type frameWriter struct {
	out    io.Writer
	always bool
	enc    *zstd.Encoder
	n      int64 // bytes written before compression
}

func (w *frameWriter) open() (err error) {
	if w.enc == nil {
		w.enc, err = zstd.NewWriter(w.out, zstd.WithEncoderLevel(zstd.SpeedDefault))
	}
	return err
}

func (w *frameWriter) Write(p []byte) (int, error) {
	if err := w.open(); err != nil {
		return 0, err
	}
	n, err := w.enc.Write(p)
	w.n += int64(n)
	return n, err
}

func (w *frameWriter) Close() error {
	if w.enc == nil && w.always {
		if err := w.open(); err != nil {
			return err
		}
	}
	if w.enc == nil {
		return nil
	}
	return w.enc.Close()
}

// lineCounter counts bytes and newlines.
type lineCounter struct {
	bytes int64
	lines int
}

func (c *lineCounter) Write(p []byte) (int, error) {
	c.bytes += int64(len(p))
	c.lines += bytes.Count(p, []byte{'\n'})
	return len(p), nil
}

// decodedLen decompresses r to nowhere and returns how many bytes and lines it
// held. On an error the counts say how much was readable before it.
func decodedLen(r io.Reader) (n int64, lines int, err error) {
	dec, err := zstd.NewReader(r)
	if err != nil {
		return 0, 0, err
	}
	defer dec.Close()
	var c lineCounter
	_, err = io.Copy(&c, dec)
	return c.bytes, c.lines, err
}

func decodedFileLen(path string) (int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	n, _, err := decodedLen(f)
	return n, err
}

// filterLines copies complete lines, dropping api-request* unless keepRequests,
// and returns the offset after the last complete line.
func filterLines(r *bufio.Reader, w io.Writer, start int64, keepRequests bool) (int64, error) {
	offset := start
	for {
		line, err := r.ReadBytes('\n')
		if err != nil && err != io.EOF {
			return offset, err
		}
		complete := err == nil
		if complete {
			if keepRequests || !isAPIRequest(line) {
				if _, werr := w.Write(line); werr != nil {
					return offset, werr
				}
			}
			offset += int64(len(line))
		}
		if err == io.EOF {
			return offset, nil // a partial last line is left for the next ingest
		}
	}
}

var apiRequestMarker = []byte(`"type":"api-request`)

func isAPIRequest(line []byte) bool {
	// Fast path on the usual serialisation, then the exact check.
	if !bytes.Contains(line, apiRequestMarker) && !bytes.Contains(line, []byte(`"type": "api-request`)) {
		return false
	}
	var t struct {
		Type string `json:"type"`
	}
	return json.Unmarshal(line, &t) == nil && strings.HasPrefix(t.Type, "api-request")
}

// copyCompanion mirrors <session>/ (subagents, tool-results, …). Transcripts
// are compressed and placed under the same rules as the main copy; everything
// else is copied as-is, atomically, and only when it differs.
func (a *Archive) copyCompanion(src, dst string, keepRequests, allowSmaller bool) (kept []string, err error) {
	err = filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		target := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o700)
		}
		if strings.HasSuffix(p, ".jsonl") {
			_, written, tmp, err := compressTo(p, target+".zst", keepRequests)
			if err != nil {
				return err
			}
			k, err := placeCopy(tmp, target+".zst", written, allowSmaller, false)
			if k != "" {
				kept = append(kept, k)
			}
			return err
		}
		return copyFile(p, target)
	})
	return kept, err
}

// copyFile writes src to dst through a temp file, unless dst already has the
// same bytes.
func copyFile(src, dst string) error {
	b, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	if old, err := os.ReadFile(dst); err == nil && bytes.Equal(old, b) {
		return nil
	}
	tmp := dst + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, dst)
}

// Check is the state of one archived copy, from Verify.
type Check struct {
	ID      string `json:"id"`
	Project string `json:"project"`
	Path    string `json:"path"`
	// Status is ok, missing (no file), corrupt (does not decode to the end) or
	// mismatch (decodes, but is not the length the index recorded).
	Status    string `json:"status"`
	Detail    string `json:"detail,omitempty"`
	Records   int    `json:"records"`   // lines readable in the copy
	Bytes     int64  `json:"bytes"`     // their size before compression
	Subagents int    `json:"subagents"` // subagent transcripts checked
	// Previous are earlier copies kept beside this one because they held
	// lines the current source no longer has.
	Previous []string `json:"previous,omitempty"`
}

// Verify decodes every archived copy (or those whose id starts with one of
// ids) and compares it with what the index recorded. It changes nothing.
func (a *Archive) Verify(ids []string) ([]Check, error) {
	rows, err := a.Store.Sessions()
	if err != nil {
		return nil, err
	}
	out := []Check{}
	for _, r := range rows {
		if !r.Archived() || !matchesAny(r.ID, ids) {
			continue
		}
		out = append(out, verifyRow(r))
	}
	return out, nil
}

func matchesAny(id string, prefixes []string) bool {
	for _, p := range prefixes {
		if strings.HasPrefix(id, strings.ToLower(p)) {
			return true
		}
	}
	return len(prefixes) == 0
}

func verifyRow(r store.SessionRow) Check {
	c := Check{ID: r.ID, Project: r.Project, Path: r.ArchivePath, Status: "ok", Previous: Previous(r.ArchivePath)}
	f, err := os.Open(r.ArchivePath)
	if err != nil {
		c.Status, c.Detail = "missing", err.Error()
		return c
	}
	fi, _ := f.Stat()
	n, lines, derr := decodedLen(f)
	f.Close()
	c.Bytes, c.Records = n, lines
	switch {
	case derr != nil:
		c.Status = "corrupt"
		c.Detail = fmt.Sprintf("%v; %d lines (%d bytes) are readable before the damage", derr, lines, n)
	case r.KeepsRequests && n != r.ArchivedBytes:
		c.Status = "mismatch"
		c.Detail = fmt.Sprintf("the copy holds %d bytes, the index recorded %d", n, r.ArchivedBytes)
	case r.ArchiveSize > 0 && fi != nil && fi.Size() != r.ArchiveSize:
		c.Status = "mismatch"
		c.Detail = fmt.Sprintf("the file is %d bytes on disk, the index recorded %d", fi.Size(), r.ArchiveSize)
	}
	subs, _ := filepath.Glob(filepath.Join(filepath.Dir(r.ArchivePath), r.ID, "subagents", "*.jsonl.zst"))
	for _, p := range subs {
		c.Subagents++
		if _, err := decodedFileLen(p); err != nil && c.Status == "ok" {
			c.Status, c.Detail = "corrupt", fmt.Sprintf("subagent %s: %v", filepath.Base(p), err)
		}
	}
	return c
}
