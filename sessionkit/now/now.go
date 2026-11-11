// Package now says what each session at work is doing at this moment: the
// model working, a tool running, waiting for the person, and how long its
// prompt cache will last. It reads the files Claude Code keeps about its
// running processes and the last records of each transcript, never the whole
// of one, so it can be asked every few seconds. It is read-only.
//
// SPEC: docs/now.md (what was measured, and what cannot be told).
package now

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
)

// DefaultWindow is how far back a session must have done something to be listed.
const DefaultWindow = 60 * time.Minute

// States a session can be in.
const (
	// StateModel: the model is being asked or is answering.
	StateModel = "model"
	// StateTool: one or more tool calls are running (a subagent is a tool call).
	StateTool = "tool"
	// StateBlocked: Claude Code says it waits for the person inside a turn: a
	// permission, a question, an open dialog. WaitingFor says which, in its words.
	StateBlocked = "blocked"
	// StateBackground: the agent stopped, and subagents it started still run.
	StateBackground = "background"
	// StateYou: the turn is over; it waits for the next prompt.
	StateYou = "you"
	// StateClosed: no process runs it. It can be resumed; its cache may still be warm.
	StateClosed = "closed"
)

// Report is what `skit now` prints and GET /v0/now returns.
type Report struct {
	At            time.Time `json:"at"`
	WindowMinutes int       `json:"window_minutes"`
	// Sessions are the ones that did something in the window, the latest first.
	Sessions []Session `json:"sessions"`
	// RunningOutside counts sessions whose process runs and that did nothing in the window.
	RunningOutside int `json:"running_outside_window"`
}

// Session is one session at work, or lately at work.
type Session struct {
	ID      string `json:"id"`
	Project string `json:"project"` // the slug Claude Code files it under
	// Cwd is the directory the session started in, when the process or the
	// index says; WorkDir is where its last record was written from.
	Cwd     string `json:"cwd,omitempty"`
	WorkDir string `json:"work_dir,omitempty"`
	Title   string `json:"title,omitempty"`
	// Running is true when a Claude Code process has the session open. Name,
	// Entrypoint, PID and Process are that process's: its own name for the
	// session ("tools-77"), where it runs ("claude-vscode", "cli"), and its
	// status in its own word (busy, idle, waiting).
	Running    bool   `json:"running"`
	Name       string `json:"name,omitempty"`
	Entrypoint string `json:"entrypoint,omitempty"`
	PID        int    `json:"pid,omitempty"`
	Process    string `json:"process_status,omitempty"`
	// State is what it is doing: model, tool, blocked, background, you, closed.
	// Since is when it began.
	State string    `json:"state"`
	Since time.Time `json:"since"`
	// WaitingFor is Claude Code's word for what a blocked session waits for.
	WaitingFor string `json:"waiting_for,omitempty"`
	// Tools are the calls running now, oldest first.
	Tools []Tool `json:"tools,omitempty"`
	// Subagents is how many subagents of the session have not finished.
	Subagents int `json:"subagents_running,omitempty"`
	// Said is the first line of what the agent last said when it stopped;
	// LastPrompt the last thing the person asked.
	Said       string `json:"said,omitempty"`
	LastPrompt string `json:"last_prompt,omitempty"`
	// LastAt is the session's last activity: its transcript's last record, or
	// the file's time when the tail held none.
	LastAt time.Time `json:"last_at"`
	Model  string    `json:"model,omitempty"`
	Cache  *Cache    `json:"cache,omitempty"`
	// Host is the editor window or the terminal a running session is in, when it could be found.
	Host *Host `json:"host,omitempty"`
	// Bytes is the transcript's size.
	Bytes int64 `json:"bytes"`
}

// Tool is a tool call that has not come back.
type Tool struct {
	ID      string    `json:"id"`
	Name    string    `json:"name"`
	Summary string    `json:"summary,omitempty"`
	Since   time.Time `json:"since"`
	done    bool
}

// Cache is the prompt cache as the session's last request left it.
type Cache struct {
	// Of the last request's input: read from the cache, written to it, and
	// neither. HitRatio is the part that was read.
	ReadTokens    int     `json:"read_tokens"`
	WrittenTokens int     `json:"written_tokens"`
	InputTokens   int     `json:"uncached_tokens"`
	HitRatio      float64 `json:"hit_ratio"`
	// ContextTokens is the size of what the next prompt would have to pay for
	// in full once the cache is gone.
	ContextTokens int `json:"context_tokens"`
	// TTLSeconds is the lifetime of the last write (300 or 3600), 0 when the
	// tail showed no write. LastRequestAt is when the cache was last used;
	// ExpiresAt is that plus the lifetime.
	TTLSeconds    int        `json:"ttl_seconds"`
	LastRequestAt time.Time  `json:"last_request_at"`
	ExpiresAt     *time.Time `json:"expires_at,omitempty"`
	// SecondsLeft is ExpiresAt from Report.At; 0 when it has passed.
	SecondsLeft int `json:"seconds_left"`
}

// Options for Read.
type Options struct {
	// Window is how far back a session must have done something; 0 is DefaultWindow.
	Window time.Duration
	// Now is the moment asked about; zero is the clock's.
	Now time.Time
	// Known says what the index holds of a session: its title, for a
	// transcript whose tail has none, and the directory it started in.
	Known func(id string) (title, cwd string)
}

// Reader answers what is going on now. It keeps what it read of each
// transcript's tail and reads it again only when the file has changed, so one
// Reader should live as long as its owner is asked.
type Reader struct {
	// Alive reports whether a process runs; nil asks the system.
	Alive func(pid int) bool
	// Processes answers what finding a session's window needs; nil asks ps and lsof.
	Processes Processes

	mu    sync.Mutex
	tails map[string]cached
	hosts map[int]hostEntry
}

func (r *Reader) aliveFunc() func(int) bool {
	if r.Alive != nil {
		return r.Alive
	}
	return processRuns
}

type cached struct {
	size  int64
	mtime time.Time
	tail  *tail
}

// Read builds the report from a fresh look at Claude Code's data directory.
func (r *Reader) Read(rep *catalog.Report, opt Options) (*Report, error) {
	now := opt.Now
	if now.IsZero() {
		now = time.Now()
	}
	window := opt.Window
	if window <= 0 {
		window = DefaultWindow
	}
	out := &Report{At: now.UTC(), WindowMinutes: int(window / time.Minute), Sessions: []Session{}}

	alive := r.aliveFunc()
	// One process per session: when two files name the same session (a process
	// that died without clearing its file), the one that runs and moved last wins.
	live := map[string]catalog.LiveSession{}
	for _, l := range rep.Live {
		if !alive(l.PID) {
			continue
		}
		if old, ok := live[l.SessionID]; !ok || l.UpdatedAt > old.UpdatedAt {
			live[l.SessionID] = l
		}
	}

	cutoff := now.Add(-window)
	seen := map[string]bool{}
	keep := map[string]bool{}
	for _, l := range rep.Sessions() {
		if l.File.Kind != "main" {
			continue
		}
		seen[l.File.ID] = true
		proc, running := live[l.File.ID]
		if l.File.ModTime.Before(cutoff) {
			if running {
				out.RunningOutside++
			}
			continue
		}
		keep[l.File.Path] = true
		t, err := r.tailOf(l.File.Path, l.File.Bytes, l.File.ModTime)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				continue // gone between the listing and the read
			}
			return nil, err
		}
		s := Session{ID: l.File.ID, Project: l.Project.Slug, WorkDir: t.cwd, Title: t.title, LastPrompt: head(t.lastPrompt, 280),
			LastAt: t.lastAt, Model: t.model, Bytes: l.File.Bytes, Running: running}
		if s.LastAt.IsZero() {
			s.LastAt = l.File.ModTime
		}
		if opt.Known != nil {
			title, cwd := opt.Known(s.ID)
			s.Cwd = cwd
			if s.Title == "" {
				s.Title = title
			}
		}
		if running {
			s.Name, s.Entrypoint, s.PID, s.Process = proc.Name, proc.Entrypoint, proc.PID, proc.Status
			if proc.Cwd != "" {
				s.Cwd = proc.Cwd
			}
			s.Subagents = unfinishedSubagents(strings.TrimSuffix(l.File.Path, ".jsonl"), now)
			s.Host = r.hostOf(rep.ClaudeDir, proc.PID, proc.StartedAt, proc.Cwd, now)
		}
		if s.Cwd == "" {
			s.Cwd = s.WorkDir
		}
		decide(&s, t, proc, running)
		s.Cache = cacheOf(t, now)
		out.Sessions = append(out.Sessions, s)
	}
	// A process whose session has no transcript yet (just opened) is at work too.
	for id, proc := range live {
		if seen[id] {
			continue
		}
		if millis(proc.UpdatedAt).Before(cutoff) {
			out.RunningOutside++
			continue
		}
		at := millis(proc.StatusUpdatedAt)
		out.Sessions = append(out.Sessions, Session{ID: id, Cwd: proc.Cwd, Running: true, Name: proc.Name, Entrypoint: proc.Entrypoint,
			PID: proc.PID, Process: proc.Status, State: processState(proc.Status), WaitingFor: proc.WaitingFor, Since: at, LastAt: at,
			Host: r.hostOf(rep.ClaudeDir, proc.PID, proc.StartedAt, proc.Cwd, now)})
	}
	sort.SliceStable(out.Sessions, func(i, j int) bool {
		a, b := out.Sessions[i], out.Sessions[j]
		if !a.LastAt.Equal(b.LastAt) {
			return a.LastAt.After(b.LastAt)
		}
		return a.ID < b.ID
	})
	r.forget(keep, live)
	return out, nil
}

// decide sets what the session is doing from what its process says and what
// its transcript's tail shows.
//
// DECISION: the process is believed for whether work is going on, the
// transcript for what the work is. They are written by different parts of
// Claude Code at different moments, so they can disagree for an instant, and
// for longer after a turn was interrupted (the transcript then ends on a call
// that will never come back).
func decide(s *Session, t *tail, proc catalog.LiveSession, running bool) {
	last := s.LastAt
	switch {
	case !running:
		s.State, s.Since = StateClosed, last
		s.Said = t.said
	case proc.Status == "waiting":
		s.State, s.Since, s.WaitingFor = StateBlocked, later(millis(proc.StatusUpdatedAt), last), proc.WaitingFor
		s.Tools = t.pending
	case proc.Status == "idle" || (proc.Status == "" && t.ended):
		// Idle with a turn that did not end in the transcript: it was stopped.
		s.State, s.Since = StateYou, last
		if t.ended {
			s.Since = t.endedAt
		} else if at := millis(proc.StatusUpdatedAt); at.After(last) {
			s.Since = at
		}
		s.Said = t.said
		if s.Subagents > 0 {
			s.State = StateBackground
		}
	case len(t.pending) > 0:
		s.State, s.Since, s.Tools = StateTool, t.pending[0].Since, t.pending
	default:
		// Busy with no call out: the model is being asked. When the transcript
		// says the turn ended, a new one has begun that is not written yet.
		s.State, s.Since = StateModel, last
		if t.ended {
			s.Since = later(millis(proc.StatusUpdatedAt), last)
		}
	}
}

func processState(status string) string {
	switch status {
	case "waiting":
		return StateBlocked
	case "idle":
		return StateYou
	}
	return StateModel
}

// cacheOf reads the prompt cache's state off the last request.
//
// DECISION: the cache is counted from when the last request was sent, with
// the lifetime of the last write the tail shows. Reading an entry refreshes
// it, so every request of the conversation pushes the end back; a request's
// usage says whether it wrote five-minute or one-hour entries
// (cache_creation.ephemeral_*). Only the main conversation counts: a
// subagent's requests keep their own cache warm, not this one.
func cacheOf(t *tail, now time.Time) *Cache {
	u := t.usage
	if u == nil {
		return nil
	}
	c := &Cache{ReadTokens: u.CacheReadInputTokens, WrittenTokens: u.CacheCreationInputTokens, InputTokens: u.InputTokens,
		ContextTokens: u.ContextTokens(), TTLSeconds: t.ttl, LastRequestAt: t.requestAt}
	if total := u.ContextTokens(); total > 0 {
		c.HitRatio = float64(u.CacheReadInputTokens) / float64(total)
	}
	if t.ttl > 0 && !t.requestAt.IsZero() {
		at := t.requestAt.Add(time.Duration(t.ttl) * time.Second)
		c.ExpiresAt = &at
		if left := at.Sub(now); left > 0 {
			c.SecondsLeft = int(left / time.Second)
		}
	}
	return c
}

func (r *Reader) tailOf(path string, size int64, mtime time.Time) (*tail, error) {
	r.mu.Lock()
	c, ok := r.tails[path]
	r.mu.Unlock()
	if ok && c.size == size && c.mtime.Equal(mtime) {
		return c.tail, nil
	}
	t, err := readTail(path, size)
	if err != nil {
		return nil, err
	}
	r.mu.Lock()
	if r.tails == nil {
		r.tails = map[string]cached{}
	}
	r.tails[path] = cached{size: size, mtime: mtime, tail: t}
	r.mu.Unlock()
	return t, nil
}

// forget drops the tails of transcripts that left the window, and what was
// found of processes that are gone.
func (r *Reader) forget(keep map[string]bool, live map[string]catalog.LiveSession) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for path := range r.tails {
		if !keep[path] {
			delete(r.tails, path)
		}
	}
	running := map[int]bool{}
	for _, l := range live {
		running[l.PID] = true
	}
	for pid := range r.hosts {
		if !running[pid] {
			delete(r.hosts, pid)
		}
	}
}

// subagentQuiet is how long a subagent may write nothing and still count as running.
const subagentQuiet = 30 * time.Minute

// unfinishedSubagents counts the subagents under a session's folder whose
// meta file does not say they finished.
//
// DECISION: one that wrote nothing for half an hour is not counted. A
// subagent that was interrupted never gets its "finished", and would hold its
// session in "background" for as long as the process lives.
func unfinishedSubagents(sessionDir string, now time.Time) int {
	metas, _ := filepath.Glob(filepath.Join(sessionDir, "subagents", "*.meta.json"))
	n := 0
	for _, p := range metas {
		if st, err := os.Stat(strings.TrimSuffix(p, ".meta.json") + ".jsonl"); err != nil || now.Sub(st.ModTime()) > subagentQuiet {
			continue
		}
		b, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		var m struct {
			Finished bool `json:"finished"`
		}
		if json.Unmarshal(b, &m) == nil && !m.Finished {
			n++
		}
	}
	return n
}

func millis(ms int64) time.Time {
	if ms <= 0 {
		return time.Time{}
	}
	return time.UnixMilli(ms).UTC()
}

// processRuns reports whether a process with this id exists. Signal 0 checks
// without sending anything; a process of another user answers EPERM and runs.
func processRuns(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}
