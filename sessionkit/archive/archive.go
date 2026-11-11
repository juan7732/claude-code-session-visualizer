// Package archive keeps a durable copy of every session: the raw JSONL lines,
// zstd-compressed and appended as the session grows, beside the index that
// summarises and searches them. Claude Code deletes transcripts after
// cleanupPeriodDays; this is where they live on.
//
//	<home>/skit.sqlite                                    the index (package store)
//	<home>/archive/<project>/<session>.jsonl.zst          raw lines, every record (api-request* too unless --strip-requests)
//	<home>/archive/<project>/<session>/subagents/*.jsonl.zst, *.meta.json
//	<home>/archive/<project>/<session>/tool-results/*     spilled tool outputs, as-is
//	<home>/archive/**/<copy>.prev-<time>                  an earlier copy that held more than the source does now
//
// The files are readable without skit: `zstd -dc <file>` gives the transcript back.
package archive

import (
	"encoding/json"
	"errors"
	"fmt"
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

	cache *cache // parsed sessions, when EnableCache was called
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
	// Kept lists earlier copies that were renamed and kept because they held
	// lines the source no longer has (it shrank, or was replaced).
	Kept []string `json:"kept,omitempty"`
}

// Summary returns the indexed summary for a session on disk when the index is
// fresh for it, else parses the transcript, indexes the summary and returns
// it. fresh is true when no parsing was needed. This is list's cache.
func (a *Archive) Summary(l catalog.Located) (sum stats.Summary, fresh bool, err error) {
	row, err := a.Store.Session(l.File.ID)
	if err != nil {
		return sum, false, err
	}
	if row != nil && row.Schema == store.IndexedVersion && a.sourceMatches(row, l) {
		if json.Unmarshal(row.Summary, &sum) == nil {
			return sum, true, nil
		}
	}
	s, err := transcript.Load(l.File.Path)
	if err != nil {
		return sum, false, err
	}
	sum = stats.Compute(s, l.Project.Slug, stats.Options{})
	r := rowFor(l, s, sum)
	// DECISION: an archived row from an earlier schema keeps its number. This
	// writes the summary only; the segments, files and uses the index holds for
	// an archived session are Ingest's to write, and it skips a row that says it
	// is current. Stamping it here left those tables empty after a schema step
	// whenever `list` ran before `archive` (found 2026-11-10).
	if row != nil && row.Archived() && row.Schema < store.IndexedVersion {
		r.Schema = row.Schema
	}
	return sum, false, a.Store.UpsertSummary(r)
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
// file only grew), companion files, segments for search, and the summary. It
// never makes the archive hold less than it did: see copy.go and ADR 0008.
func (a *Archive) Ingest(l catalog.Located, opt Options) (Result, error) {
	res := Result{ID: l.File.ID, Project: l.Project.Slug, Path: a.Path(l.Project.Slug, l.File.ID)}
	if err := os.MkdirAll(a.Home, 0o700); err != nil {
		return res, err
	}
	unlock, err := a.lock()
	if err != nil {
		return res, err
	}
	defer unlock()

	keep := !opt.StripRequests
	fp := sourceFingerprint(l)
	row, err := a.Store.Session(l.File.ID)
	if err != nil {
		return res, err
	}
	// Unchanged means the copy was made from exactly this source state and is
	// still the size we left it. The row's source_* columns cannot answer this:
	// list refreshes them without copying anything.
	if row != nil && row.Archived() && row.KeepsRequests == keep && row.Schema == store.IndexedVersion && row.ArchivedFP == fp && row.ArchivePath == res.Path {
		if fi, err := os.Stat(row.ArchivePath); err == nil && fi.Size() == row.ArchiveSize {
			res.Action, res.Records, res.Bytes = "unchanged", row.Records, row.ArchivedBytes
			return res, nil
		}
	}
	// Through the cache when a reader holds this session: in `skit serve` the
	// client often has it open, and a second parse of a large one costs as
	// much again.
	loaded, err := a.loadSource(l, true)
	if err != nil {
		return res, err
	}
	// A reader has this session open and it has just been parsed again:
	// have the answers it will ask for ready before it asks.
	go loaded.warm()
	s := loaded.Session
	rel := loaded.Relations()
	sum := stats.Compute(s, l.Project.Slug, stats.Options{Relations: rel})

	st, kept, err := a.copyMain(l, row, res.Path, keep)
	if kept != "" {
		res.Kept = append(res.Kept, kept)
	}
	if err != nil {
		return res, err
	}
	allowSmaller := row != nil && row.Archived() && row.KeepsRequests && !keep
	keptSub, err := a.copyCompanion(filepath.Join(filepath.Dir(l.File.Path), l.File.ID), filepath.Join(filepath.Dir(res.Path), l.File.ID), keep, allowSmaller)
	res.Kept = append(res.Kept, keptSub...)
	if err != nil {
		return res, err
	}

	if err := a.Store.UpsertSummary(rowFor(l, s, sum)); err != nil {
		return res, err
	}
	if err := a.Store.ReplaceSegments(l.File.ID, Segments(s)); err != nil {
		return res, err
	}
	if err := a.Store.ReplaceFiles(l.File.ID, fileRows(rel)); err != nil {
		return res, err
	}
	uses, offered := primitiveRows(transcript.PrimitivesOf(s))
	if err := a.Store.ReplacePrimitives(l.File.ID, uses, offered); err != nil {
		return res, err
	}
	st.Fingerprint = fp
	if err := a.Store.SetArchive(l.File.ID, st); err != nil {
		return res, err
	}
	res.Action = "archived"
	if row != nil && row.Archived() {
		res.Action = "updated"
	}
	res.Records, res.Bytes = s.Totals.Records, st.Bytes
	return res, nil
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
