// Package catalog finds Claude Code's data on disk: the data directory, its
// projects and session files, subagent transcripts, live sessions and the
// retention setting. It reads only; nothing here ever writes under ~/.claude.
//
// Layout (see docs/where-sessions-live.md):
//
//	<claude>/projects/<slug>/<session-uuid>.jsonl
//	<claude>/projects/<slug>/<session-uuid>/subagents/agent-<id>.jsonl
//	<claude>/sessions/<pid>.json          one per running Claude Code process
//	<claude>/settings.json                cleanupPeriodDays
package catalog

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// DefaultCleanupPeriodDays is Claude Code's retention default when settings.json does not set it.
const DefaultCleanupPeriodDays = 30

// Report is what Inspect found.
type Report struct {
	ClaudeDir string        `json:"claude_dir"`
	Exists    bool          `json:"exists"`
	Retention Retention     `json:"retention"`
	Projects  []Project     `json:"projects"`
	Live      []LiveSession `json:"live"`
	Totals    Totals        `json:"totals"`
	Warnings  []string      `json:"warnings,omitempty"`
}

// Retention is the sweep setting: transcripts older than CleanupPeriodDays are deleted at startup.
type Retention struct {
	CleanupPeriodDays int    `json:"cleanup_period_days"`
	Source            string `json:"source"` // "default" or the settings file that set it
}

// Project is one <claude>/projects/<slug> directory: the directory Claude Code was started in.
type Project struct {
	Slug     string        `json:"slug"`
	Dir      string        `json:"dir"`
	Sessions []SessionFile `json:"sessions"`
}

// Bytes is the size of all session files in the project, subagents included.
func (p Project) Bytes() int64 {
	var n int64
	for _, s := range p.Sessions {
		n += s.Bytes + s.SubagentBytes
	}
	return n
}

// SessionFile is one transcript on disk.
type SessionFile struct {
	ID            string    `json:"id"`
	Path          string    `json:"path"`
	Kind          string    `json:"kind"` // main | orphaned | superseded
	Bytes         int64     `json:"bytes"`
	ModTime       time.Time `json:"mod_time"`
	Subagents     int       `json:"subagents"`
	SubagentBytes int64     `json:"subagent_bytes"`
}

// LiveSession is a running Claude Code process, from <claude>/sessions/<pid>.json.
//
// Status is "busy", "idle" or "waiting"; WaitingFor says for what when Claude
// Code wrote it (a dialog, an answer it asked for). The times are Unix
// milliseconds, as Claude Code writes them.
type LiveSession struct {
	PID             int    `json:"pid"`
	SessionID       string `json:"sessionId"`
	Cwd             string `json:"cwd"`
	Name            string `json:"name"`
	Status          string `json:"status"`
	Version         string `json:"version"`
	WaitingFor      string `json:"waitingFor,omitempty"`
	Kind            string `json:"kind,omitempty"`       // interactive, or a background kind
	Entrypoint      string `json:"entrypoint,omitempty"` // claude-vscode, cli…
	StartedAt       int64  `json:"startedAt,omitempty"`
	UpdatedAt       int64  `json:"updatedAt,omitempty"`
	StatusUpdatedAt int64  `json:"statusUpdatedAt,omitempty"`
}

// Totals summarises the report.
type Totals struct {
	Sessions   int   `json:"sessions"`
	Orphaned   int   `json:"orphaned"`
	Superseded int   `json:"superseded"`
	Subagents  int   `json:"subagents"`
	Bytes      int64 `json:"bytes"`
}

var (
	mainFile       = regexp.MustCompile(`^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$`)
	orphanedFile   = regexp.MustCompile(`^([0-9a-f-]{36})\.orphaned-.*\.jsonl$`)
	supersededFile = regexp.MustCompile(`^([0-9a-f-]{36})\.jsonl\.superseded-.*$`)
)

// Dir returns the Claude Code data directory: $CLAUDE_CONFIG_DIR, else ~/.claude.
func Dir() (string, error) {
	if d := os.Getenv("CLAUDE_CONFIG_DIR"); d != "" {
		return d, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("cannot find home directory: %w", err)
	}
	return filepath.Join(home, ".claude"), nil
}

// Inspect reads the data directory and reports what is there. A missing
// directory is not an error: the report says so and carries a warning.
func Inspect() (*Report, error) {
	dir, err := Dir()
	if err != nil {
		return nil, err
	}
	return InspectDir(dir)
}

// InspectDir is Inspect for an explicit directory.
func InspectDir(dir string) (*Report, error) {
	r := &Report{ClaudeDir: dir, Retention: Retention{CleanupPeriodDays: DefaultCleanupPeriodDays, Source: "default"}}
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		r.Warnings = append(r.Warnings, "no Claude Code data directory at "+dir)
		return r, nil
	}
	r.Exists = true
	r.readRetention(filepath.Join(dir, "settings.json"))
	if err := r.readProjects(filepath.Join(dir, "projects")); err != nil {
		return nil, err
	}
	r.readLive(filepath.Join(dir, "sessions"))
	return r, nil
}

func (r *Report) readRetention(settings string) {
	b, err := os.ReadFile(settings)
	if err != nil {
		return
	}
	var s struct {
		CleanupPeriodDays *float64 `json:"cleanupPeriodDays"`
	}
	if err := json.Unmarshal(b, &s); err != nil {
		r.Warnings = append(r.Warnings, "settings.json is not valid JSON: "+err.Error())
		return
	}
	if s.CleanupPeriodDays != nil {
		r.Retention = Retention{CleanupPeriodDays: int(*s.CleanupPeriodDays), Source: settings}
	}
}

func (r *Report) readProjects(root string) error {
	entries, err := os.ReadDir(root)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("reading %s: %w", root, err)
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		p, err := readProject(filepath.Join(root, e.Name()))
		if err != nil {
			return err
		}
		if len(p.Sessions) == 0 {
			continue
		}
		r.Projects = append(r.Projects, p)
		for _, s := range p.Sessions {
			switch s.Kind {
			case "main":
				r.Totals.Sessions++
			case "orphaned":
				r.Totals.Orphaned++
			case "superseded":
				r.Totals.Superseded++
			}
			r.Totals.Subagents += s.Subagents
			r.Totals.Bytes += s.Bytes + s.SubagentBytes
		}
	}
	sort.Slice(r.Projects, func(i, j int) bool { return r.Projects[i].Slug < r.Projects[j].Slug })
	return nil
}

func readProject(dir string) (Project, error) {
	p := Project{Slug: filepath.Base(dir), Dir: dir}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return p, fmt.Errorf("reading %s: %w", dir, err)
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		var id, kind string
		switch {
		case mainFile.MatchString(name):
			id, kind = mainFile.FindStringSubmatch(name)[1], "main"
		case orphanedFile.MatchString(name):
			id, kind = orphanedFile.FindStringSubmatch(name)[1], "orphaned"
		case supersededFile.MatchString(name):
			id, kind = supersededFile.FindStringSubmatch(name)[1], "superseded"
		default:
			continue
		}
		info, err := e.Info()
		if errors.Is(err, fs.ErrNotExist) {
			continue // removed since the directory was read (Claude Code's cleanup, a rename)
		}
		if err != nil {
			return p, err
		}
		s := SessionFile{ID: id, Path: filepath.Join(dir, name), Kind: kind, Bytes: info.Size(), ModTime: info.ModTime()}
		if kind == "main" {
			s.Subagents, s.SubagentBytes = countSubagents(filepath.Join(dir, id, "subagents"))
		}
		p.Sessions = append(p.Sessions, s)
	}
	sort.Slice(p.Sessions, func(i, j int) bool { return p.Sessions[i].ModTime.After(p.Sessions[j].ModTime) })
	return p, nil
}

func countSubagents(dir string) (int, int64) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0, 0
	}
	var n int
	var bytes int64
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".jsonl") {
			continue
		}
		if info, err := e.Info(); err == nil {
			n++
			bytes += info.Size()
		}
	}
	return n, bytes
}

func (r *Report) readLive(dir string) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			continue
		}
		var l LiveSession
		if json.Unmarshal(b, &l) == nil && l.SessionID != "" {
			r.Live = append(r.Live, l)
		}
	}
	sort.Slice(r.Live, func(i, j int) bool { return r.Live[i].PID < r.Live[j].PID })
}
