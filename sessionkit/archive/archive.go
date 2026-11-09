// Package archive keeps a durable copy of every session: the raw JSONL lines,
// zstd-compressed and appended as the session grows, beside the index that
// summarises and searches them. Claude Code deletes transcripts after
// cleanupPeriodDays; this is where they live on.
//
//	<home>/skit.sqlite                                    the index (package store)
//	<home>/archive/<project>/<session>.jsonl.zst          raw lines, every record (api-request* too unless --strip-requests)
//	<home>/archive/<project>/<session>/subagents/*.jsonl.zst, *.meta.json
//	<home>/archive/<project>/<session>/tool-results/*     spilled tool outputs, as-is
//
// The files are readable without skit: `zstd -dc <file>` gives the transcript back.
package archive

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/klauspost/compress/zstd"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/home"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/stats"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/store"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/transcript"
)

// Archive is an open skit home.
type Archive struct {
	Home  string
	Store *store.Store
}

// Open opens the archive under home.Dir().
func Open() (*Archive, error) {
	dir, err := home.Dir()
	if err != nil {
		return nil, err
	}
	return OpenAt(dir)
}

// OpenAt opens the archive under an explicit home directory.
func OpenAt(dir string) (*Archive, error) {
	st, err := store.Open(home.DBPath(dir))
	if err != nil {
		return nil, err
	}
	return &Archive{Home: dir, Store: st}, nil
}

// Close releases the index.
func (a *Archive) Close() error { return a.Store.Close() }

// Path is where a session's raw copy lives.
func (a *Archive) Path(project, id string) string {
	return filepath.Join(home.ArchiveDir(a.Home), project, id+".jsonl.zst")
}

// Options for Ingest.
type Options struct {
	// StripRequests drops api-request* records (system prompt, tool
	// definitions, message bodies and parameters of every request) from the raw
	// copy. Off by default: the archive is lossless, and `skit context` needs
	// these records to explain what the model received (ADR 0007).
	StripRequests bool
}

// Result says what Ingest did.
type Result struct {
	ID      string `json:"id"`
	Project string `json:"project"`
	Action  string `json:"action"` // archived | updated | unchanged
	Records int    `json:"records"`
	Bytes   int64  `json:"bytes"` // source bytes covered by the raw copy
	Path    string `json:"path"`
}

// Summary returns the indexed summary for a session on disk when the index is
// fresh for it, else parses the transcript, indexes the summary and returns
// it. fresh is true when no parsing was needed. This is list's cache.
func (a *Archive) Summary(l catalog.Located) (sum stats.Summary, fresh bool, err error) {
	row, err := a.Store.Session(l.File.ID)
	if err != nil {
		return sum, false, err
	}
	if row != nil && row.Schema == store.SchemaVersion && a.sourceMatches(row, l) {
		if json.Unmarshal(row.Summary, &sum) == nil {
			return sum, true, nil
		}
	}
	s, err := transcript.Load(l.File.Path)
	if err != nil {
		return sum, false, err
	}
	sum = stats.Compute(s, l.Project.Slug, stats.Options{})
	return sum, false, a.Store.UpsertSummary(rowFor(l, s, sum))
}

func (a *Archive) sourceMatches(row *store.SessionRow, l catalog.Located) bool {
	return row.SourceSize == l.File.Bytes && row.SourceMtime == l.File.ModTime.UnixNano() &&
		row.SourceSub == store.Fingerprint(l.File.Subagents, l.File.SubagentBytes)
}

func rowFor(l catalog.Located, s *transcript.Session, sum stats.Summary) store.SessionRow {
	b, _ := json.Marshal(sum)
	return store.SessionRow{
		ID: l.File.ID, Project: l.Project.Slug, SourcePath: l.File.Path, SourceSize: l.File.Bytes, SourceMtime: l.File.ModTime.UnixNano(),
		SourceSub: store.Fingerprint(l.File.Subagents, l.File.SubagentBytes), Records: s.Totals.Records, FirstAt: s.FirstAt, LastAt: s.LastAt,
		Title: sum.Title, OwnerAccount: s.OwnerAccount, OwnerOrg: s.OwnerOrg, Summary: b,
	}
}

// Ingest archives one session: raw copy (appended from the last offset when the
// file only grew), companion files, segments for search, and the summary.
func (a *Archive) Ingest(l catalog.Located, opt Options) (Result, error) {
	res := Result{ID: l.File.ID, Project: l.Project.Slug, Path: a.Path(l.Project.Slug, l.File.ID)}
	row, err := a.Store.Session(l.File.ID)
	if err != nil {
		return res, err
	}
	if row != nil && row.Archived() && row.KeepsRequests == !opt.StripRequests && row.Schema == store.SchemaVersion && a.sourceMatches(row, l) {
		if _, err := os.Stat(row.ArchivePath); err == nil {
			res.Action, res.Records, res.Bytes = "unchanged", row.Records, row.ArchivedBytes
			return res, nil
		}
	}
	s, err := transcript.Load(l.File.Path)
	if err != nil {
		return res, err
	}
	sum := stats.Compute(s, l.Project.Slug, stats.Options{})

	// Raw copy: append when the source only grew, rewrite otherwise.
	start := int64(0)
	if row != nil && row.Archived() && row.KeepsRequests == !opt.StripRequests && row.ArchivedBytes <= l.File.Bytes && row.ArchivePath == res.Path {
		if _, err := os.Stat(res.Path); err == nil {
			start = row.ArchivedBytes
		}
	}
	covered, err := a.copyRaw(l.File.Path, res.Path, start, !opt.StripRequests)
	if err != nil {
		return res, err
	}
	if err := a.copyCompanion(filepath.Join(filepath.Dir(l.File.Path), l.File.ID), filepath.Join(filepath.Dir(res.Path), l.File.ID), !opt.StripRequests); err != nil {
		return res, err
	}

	if err := a.Store.UpsertSummary(rowFor(l, s, sum)); err != nil {
		return res, err
	}
	if err := a.Store.ReplaceSegments(l.File.ID, Segments(s)); err != nil {
		return res, err
	}
	if err := a.Store.SetArchive(l.File.ID, res.Path, covered, !opt.StripRequests); err != nil {
		return res, err
	}
	res.Action = "archived"
	if row != nil && row.Archived() {
		res.Action = "updated"
	}
	res.Records, res.Bytes = s.Totals.Records, covered
	return res, nil
}

// copyRaw appends the complete lines of src from offset start to dst as a new
// zstd frame (start == 0 truncates dst first). It returns the source offset
// just past the last complete line copied. keepRequests false drops api-request*.
func (a *Archive) copyRaw(src, dst string, start int64, keepRequests bool) (int64, error) {
	in, err := os.Open(src)
	if err != nil {
		return 0, err
	}
	defer in.Close()
	if start > 0 {
		if _, err := in.Seek(start, io.SeekStart); err != nil {
			return 0, err
		}
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o700); err != nil {
		return 0, err
	}
	flags := os.O_CREATE | os.O_WRONLY | os.O_APPEND
	if start == 0 {
		flags = os.O_CREATE | os.O_WRONLY | os.O_TRUNC
	}
	out, err := os.OpenFile(dst, flags, 0o600)
	if err != nil {
		return 0, err
	}
	defer out.Close()
	enc, err := zstd.NewWriter(out, zstd.WithEncoderLevel(zstd.SpeedDefault))
	if err != nil {
		return 0, err
	}
	covered, err := filterLines(bufio.NewReaderSize(in, 1<<20), enc, start, keepRequests)
	if cerr := enc.Close(); err == nil {
		err = cerr
	}
	return covered, err
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

// copyCompanion mirrors <session>/ (subagents, tool-results, …), compressing
// transcripts and copying everything else as-is.
func (a *Archive) copyCompanion(src, dst string, keepRequests bool) error {
	return filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
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
			_, err := a.copyRaw(p, target+".zst", 0, keepRequests)
			return err
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		return os.WriteFile(target, b, 0o600)
	})
}

// Load rebuilds a session from its archived copy.
func (a *Archive) Load(id string) (*transcript.Session, *store.SessionRow, error) {
	row, err := a.Store.Session(id)
	if err != nil {
		return nil, nil, err
	}
	if row == nil || !row.Archived() {
		return nil, row, fmt.Errorf("session %s is not archived", id)
	}
	s, err := parseZst(row.ArchivePath)
	if err != nil {
		return nil, row, err
	}
	s.ID = id
	s.Path = row.ArchivePath
	subdir := filepath.Join(filepath.Dir(row.ArchivePath), id, "subagents")
	entries, err := os.ReadDir(subdir)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return nil, row, err
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".jsonl.zst") {
			continue
		}
		p := filepath.Join(subdir, e.Name())
		sub, err := parseZst(p)
		if err != nil {
			return nil, row, fmt.Errorf("%s: %w", p, err)
		}
		sub.Path = p
		sa := &transcript.Subagent{Path: p, Session: sub, AgentID: strings.TrimSuffix(strings.TrimPrefix(e.Name(), "agent-"), ".jsonl.zst")}
		if len(sub.Records) > 0 && sub.Records[0].AgentID != "" {
			sa.AgentID = sub.Records[0].AgentID
		}
		if b, err := os.ReadFile(strings.TrimSuffix(p, ".jsonl.zst") + ".meta.json"); err == nil {
			var m transcript.SubagentMeta
			if json.Unmarshal(b, &m) == nil {
				sa.Meta = &m
				sa.ToolUseID = m.ToolUseID
			}
		}
		s.AttachSubagent(sa)
	}
	return s, row, nil
}

func parseZst(path string) (*transcript.Session, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	dec, err := zstd.NewReader(f)
	if err != nil {
		return nil, err
	}
	defer dec.Close()
	return transcript.Parse(dec)
}

// Segments turns a session (and its subagents) into searchable pieces: one per
// content block with text, kinds prompt | context | assistant | thinking |
// tool_use | tool_result | summary. Tool results are capped so one giant
// output cannot dominate the index.
func Segments(s *transcript.Session) []store.Segment {
	var out []store.Segment
	add := func(sess *transcript.Session, agent string) {
		for _, p := range sess.Prompts {
			turn := turnOfPrompt(sess, p)
			if t := strings.TrimSpace(p.Text); t != "" {
				out = append(out, store.Segment{Session: s.ID, Agent: agent, Turn: turn, Action: -1, UUID: p.UUID, Kind: "prompt", At: p.At, Text: t})
			}
			for _, b := range p.Context {
				out = append(out, store.Segment{Session: s.ID, Agent: agent, Turn: turn, Action: -1, UUID: p.UUID, Kind: "context", Tool: transcript.InjectedKind(b.Text), At: p.At, Text: capText(b.Text)})
			}
		}
		for _, a := range sess.Actions {
			for _, b := range a.Blocks {
				switch b.Type {
				case "text":
					if txt := strings.TrimSpace(b.Text); txt != "" {
						out = append(out, store.Segment{Session: s.ID, Agent: agent, Turn: a.Turn, Action: a.Index, Kind: "assistant", At: a.At, Text: txt})
					}
				case "thinking":
					if txt := strings.TrimSpace(b.Thinking); txt != "" {
						out = append(out, store.Segment{Session: s.ID, Agent: agent, Turn: a.Turn, Action: a.Index, Kind: "thinking", At: a.At, Text: capText(txt)})
					}
				case "tool_use":
					out = append(out, store.Segment{Session: s.ID, Agent: agent, Turn: a.Turn, Action: a.Index, Kind: "tool_use", Tool: b.Name, At: a.At, Text: b.Name + " " + capText(string(b.Input))})
				}
			}
			for _, c := range a.ToolCalls {
				if !c.Paired {
					continue
				}
				if txt := strings.TrimSpace(c.ResultText()); txt != "" {
					out = append(out, store.Segment{Session: s.ID, Agent: agent, Turn: a.Turn, Action: a.Index, Kind: "tool_result", Tool: c.Name, At: c.EndedAt, Text: capText(txt)})
				}
			}
		}
		for _, c := range sess.Compactions {
			if c.SummaryTxt != "" {
				out = append(out, store.Segment{Session: s.ID, Agent: agent, Turn: -1, Action: -1, Kind: "summary", At: c.At, Text: capText(c.SummaryTxt)})
			}
		}
	}
	add(s, "")
	for _, sa := range s.Subagents {
		if sa.Session != nil {
			add(sa.Session, sa.AgentID)
		}
	}
	return out
}

func turnOfPrompt(s *transcript.Session, p *transcript.Prompt) int {
	for _, t := range s.Turns {
		if t.Prompt == p {
			return t.Index
		}
	}
	return -1
}

// maxSegmentText caps one segment's indexed text (runes).
const maxSegmentText = 100_000

func capText(t string) string {
	if len(t) <= maxSegmentText {
		return t
	}
	cut := maxSegmentText
	for cut > 0 && cut < len(t) && t[cut]&0xC0 == 0x80 {
		cut--
	}
	return t[:cut] + "\n… (truncated for the index)"
}

// Since reports how long ago a session was archived, for humans.
func Since(t time.Time) string {
	if t.IsZero() {
		return "never"
	}
	return stats.FormatDuration(time.Since(t)) + " ago"
}
