package archive

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/stats"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/transcript"
)

// ListRow is a session summary plus whether it survives only in the archive.
// It is what `skit list --json` prints and what GET /v0/sessions returns.
type ListRow struct {
	stats.Summary
	ArchivedOnly bool `json:"archived_only,omitempty"`
}

// List merges the sessions on disk with those that exist only in the archive,
// most recent activity first. With useIndex, summaries of unchanged sessions
// come from the index and new ones are indexed; without it every transcript
// is parsed and nothing is written.
func (a *Archive) List(rep *catalog.Report, project string, useIndex bool, limit int, warn func(error)) ([]ListRow, error) {
	match := func(slug string) bool {
		return project == "" || strings.Contains(strings.ToLower(slug), strings.ToLower(project))
	}
	var rows []ListRow
	onDisk := map[string]bool{}
	for _, l := range rep.Sessions() {
		if l.File.Kind != "main" || !match(l.Project.Slug) {
			continue
		}
		onDisk[l.File.ID] = true
		var sum stats.Summary
		var err error
		if useIndex {
			sum, _, err = a.Summary(l)
		} else {
			var s *transcript.Session
			if s, err = transcript.Load(l.File.Path); err == nil {
				sum = stats.Compute(s, l.Project.Slug, stats.Options{})
			}
		}
		if err != nil {
			if warn != nil {
				warn(fmt.Errorf("skipping %s: %w", l.File.Path, err))
			}
			continue
		}
		rows = append(rows, ListRow{Summary: sum})
	}
	archived, err := a.Store.Sessions()
	if err != nil {
		return nil, err
	}
	for _, r := range archived {
		if !r.Archived() || onDisk[r.ID] || !match(r.Project) {
			continue
		}
		var sum stats.Summary
		if json.Unmarshal(r.Summary, &sum) == nil {
			rows = append(rows, ListRow{Summary: sum, ArchivedOnly: true})
		}
	}
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].LastAt.After(rows[j].LastAt) })
	if limit > 0 && len(rows) > limit {
		rows = rows[:limit]
	}
	if rows == nil {
		rows = []ListRow{}
	}
	return rows, nil
}

// Resolved is a session found on disk or in the archive.
type Resolved struct {
	Session      *transcript.Session
	Project      string
	ArchivedOnly bool   // loaded from the archive because the source is gone
	Note         string // something the caller may want to surface
}

// NotFoundError says no session matched a query.
type NotFoundError struct{ Query string }

func (e *NotFoundError) Error() string {
	return fmt.Sprintf("no session matches %q on disk or in the archive", e.Query)
}

// Resolve finds a session by id, unique prefix or transcript path: Claude
// Code's directory first, then the archive.
func (a *Archive) Resolve(rep *catalog.Report, query string) (Resolved, error) {
	l, err := rep.Find(query)
	if err == nil {
		s, err := transcript.Load(l.File.Path)
		if err != nil {
			return Resolved{}, err
		}
		return Resolved{Session: s, Project: l.Project.Slug}, nil
	}
	if !strings.HasPrefix(err.Error(), "no session") {
		return Resolved{}, err // ambiguous prefix on disk
	}
	rows, err := a.Store.SessionsByPrefix(query)
	if err != nil {
		return Resolved{}, err
	}
	var ids []string
	for _, r := range rows {
		if r.Archived() {
			ids = append(ids, r.ID)
		}
	}
	switch len(ids) {
	case 0:
		return Resolved{}, &NotFoundError{Query: query}
	case 1:
		s, row, err := a.Load(ids[0])
		if err != nil {
			return Resolved{}, err
		}
		res := Resolved{Session: s, Project: row.Project, ArchivedOnly: true}
		if _, statErr := os.Stat(row.SourcePath); statErr == nil {
			res.Note = row.SourcePath + " exists on disk but was not found by catalog; showing the archived copy"
		}
		return res, nil
	}
	return Resolved{}, fmt.Errorf("%q matches %d archived sessions", query, len(ids))
}

// SessionDoc is the full session document: what `skit show --json` prints and
// what GET /v0/sessions/{id} returns. Image bytes are replaced by their size.
type SessionDoc struct {
	*transcript.Session
	Project      string        `json:"project"`
	ArchivedOnly bool          `json:"archived_only,omitempty"`
	Summary      stats.Summary `json:"summary"`
}

// Document builds the SessionDoc for a resolved session.
func Document(r Resolved) SessionDoc {
	r.Session.StripImages()
	return SessionDoc{Session: r.Session, Project: r.Project, ArchivedOnly: r.ArchivedOnly,
		Summary: stats.Compute(r.Session, r.Project, stats.Options{Context: true})}
}
