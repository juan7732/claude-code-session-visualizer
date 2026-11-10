package archive

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"sync"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/stats"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/store"
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

// Pending counts the sessions on disk the archive does not fully hold.
type Pending struct {
	Missing int `json:"missing"` // never archived
	Behind  int `json:"behind"`  // changed since their copy was made
}

// Pending compares the sessions on disk with the index. It reads nothing but
// the index: a session counts as behind when its fingerprint is not the one
// its copy was made from.
func (a *Archive) Pending(rep *catalog.Report) (Pending, error) {
	rows, err := a.Store.Sessions()
	if err != nil {
		return Pending{}, err
	}
	byID := make(map[string]store.SessionRow, len(rows))
	for _, r := range rows {
		byID[r.ID] = r
	}
	var p Pending
	for _, l := range rep.Sessions() {
		if l.File.Kind != "main" {
			continue
		}
		switch r, ok := byID[l.File.ID]; {
		case !ok || !r.Archived():
			p.Missing++
		case r.ArchivedFP != sourceFingerprint(l):
			p.Behind++
		}
	}
	return p, nil
}

// Resolved is a session found on disk or in the archive.
type Resolved struct {
	Session      *transcript.Session
	Project      string
	ArchivedOnly bool   // loaded from the archive because the source is gone
	Note         string // something the caller may want to surface

	// memo holds what is worth computing once per parsed session. It is set
	// for sessions that live in the cache; a one-shot Resolved computes directly.
	memo *memo
}

// memo is the work a long-lived process does once per parsed session and then
// serves from memory: the relations (a pass over every tool input and result)
// and the encoded session document (megabytes of JSON). Measured on a 166 MB
// transcript, 2026-11-10: /relations 490 ms → 1 ms, the document 190 ms → 6 ms.
type memo struct {
	relOnce sync.Once
	rel     *transcript.Relations
	docOnce sync.Once
	doc     []byte
	docErr  error
}

// Relations is the session's relations, derived once per parsed session.
// Callers must not change what they get back.
func (r Resolved) Relations() *transcript.Relations {
	if r.memo == nil {
		return r.Session.Relations()
	}
	r.memo.relOnce.Do(func() { r.memo.rel = r.Session.Relations() })
	return r.memo.rel
}

// DocumentJSON is the session document (Document) as compact JSON, encoded
// once per parsed session.
func (r Resolved) DocumentJSON() ([]byte, error) {
	if r.memo == nil {
		return json.Marshal(Document(r))
	}
	r.memo.docOnce.Do(func() { r.memo.doc, r.memo.docErr = json.Marshal(Document(r)) })
	return r.memo.doc, r.memo.docErr
}

// warm does the memoised work now, off the request path: called when an
// ingest has just re-parsed a session a reader has open, so the reader's next
// request finds the answers ready.
func (r Resolved) warm() {
	if r.memo == nil {
		return
	}
	r.Relations()
	_, _ = r.DocumentJSON()
}

// NotFoundError says no session matched a query.
type NotFoundError struct{ Query string }

func (e *NotFoundError) Error() string {
	return fmt.Sprintf("no session matches %q on disk or in the archive", e.Query)
}

// loadSource parses a transcript on disk, through the cache when there is one.
// With onlyIfHeld the cache is used only for a session it already holds: an
// ingest refreshes what a reader has open, and does not fill the cache with
// every session it archives.
func (a *Archive) loadSource(l catalog.Located, onlyIfHeld bool) (Resolved, error) {
	load := func() (Resolved, error) {
		s, err := transcript.Load(l.File.Path)
		if err != nil {
			return Resolved{}, err
		}
		return Resolved{Session: s, Project: l.Project.Slug}, nil
	}
	if a.cache == nil || (onlyIfHeld && !a.cache.holds(l.File.Path)) {
		return load()
	}
	return a.cache.get(l.File.Path, sourceFingerprint(l), l.File.Bytes+l.File.SubagentBytes, load)
}

// Resolve finds a session by id, unique prefix or transcript path: Claude
// Code's directory first, then the archive. With EnableCache the session may
// be one that other callers hold too: treat it as read-only.
func (a *Archive) Resolve(rep *catalog.Report, query string) (Resolved, error) {
	l, err := rep.Find(query)
	if err == nil {
		return a.loadSource(l, false)
	}
	if !strings.HasPrefix(err.Error(), "no session") {
		return Resolved{}, err // ambiguous prefix on disk
	}
	rows, err := a.Store.SessionsByPrefix(query)
	if err != nil {
		return Resolved{}, err
	}
	var archived []store.SessionRow
	for _, r := range rows {
		if r.Archived() {
			archived = append(archived, r)
		}
	}
	switch len(archived) {
	case 0:
		return Resolved{}, &NotFoundError{Query: query}
	case 1:
		found := archived[0]
		load := func() (Resolved, error) {
			s, row, err := a.Load(found.ID)
			if err != nil {
				return Resolved{}, err
			}
			res := Resolved{Session: s, Project: row.Project, ArchivedOnly: true}
			if _, statErr := os.Stat(row.SourcePath); statErr == nil {
				res.Note = row.SourcePath + " exists on disk but was not found by catalog; showing the archived copy"
			}
			return res, nil
		}
		if a.cache == nil {
			return load()
		}
		stamp := fmt.Sprintf("%d:%d", found.ArchiveSize, found.ArchivedAt.UnixNano())
		return a.cache.get(found.ArchivePath, stamp, found.ArchivedBytes, load)
	}
	return Resolved{}, fmt.Errorf("%q matches %d archived sessions", query, len(archived))
}

// SessionDoc is the full session document: what `skit show --json` prints and
// what GET /v0/sessions/{id} returns. Images appear with their size, never
// their bytes (transcript.ImageSource leaves the payload out of JSON).
type SessionDoc struct {
	*transcript.Session
	Project      string        `json:"project"`
	ArchivedOnly bool          `json:"archived_only,omitempty"`
	Summary      stats.Summary `json:"summary"`
}

// Document builds the SessionDoc for a resolved session.
func Document(r Resolved) SessionDoc {
	return SessionDoc{Session: r.Session, Project: r.Project, ArchivedOnly: r.ArchivedOnly,
		Summary: stats.Compute(r.Session, r.Project, stats.Options{Context: true})}
}
