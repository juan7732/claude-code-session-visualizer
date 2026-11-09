package catalog

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Located is a session file with its project.
type Located struct {
	Project Project
	File    SessionFile
}

// Sessions flattens the report into one list, most recent first.
func (r *Report) Sessions() []Located {
	var out []Located
	for _, p := range r.Projects {
		for _, s := range p.Sessions {
			out = append(out, Located{Project: p, File: s})
		}
	}
	sortByModTime(out)
	return out
}

func sortByModTime(list []Located) {
	for i := 1; i < len(list); i++ {
		for j := i; j > 0 && list[j].File.ModTime.After(list[j-1].File.ModTime); j-- {
			list[j], list[j-1] = list[j-1], list[j]
		}
	}
}

// Find resolves a query to one session: a path to a .jsonl file, a full
// session id, or a unique id prefix. Orphaned and superseded files are only
// matched when the query is a path.
func (r *Report) Find(query string) (Located, error) {
	if strings.HasSuffix(query, ".jsonl") {
		if st, err := os.Stat(query); err == nil && !st.IsDir() {
			abs, _ := filepath.Abs(query)
			return Located{Project: Project{Slug: filepath.Base(filepath.Dir(abs)), Dir: filepath.Dir(abs)},
				File: SessionFile{ID: strings.TrimSuffix(filepath.Base(abs), ".jsonl"), Path: abs, Kind: "main", Bytes: st.Size(), ModTime: st.ModTime()}}, nil
		}
	}
	q := strings.ToLower(query)
	var matches []Located
	for _, l := range r.Sessions() {
		if l.File.Kind != "main" {
			continue
		}
		if l.File.ID == q {
			return l, nil
		}
		if strings.HasPrefix(l.File.ID, q) {
			matches = append(matches, l)
		}
	}
	switch len(matches) {
	case 0:
		return Located{}, fmt.Errorf("no session matches %q (try `skit list`)", query)
	case 1:
		return matches[0], nil
	}
	ids := make([]string, 0, len(matches))
	for _, m := range matches {
		ids = append(ids, m.File.ID[:12])
	}
	return Located{}, fmt.Errorf("%q matches %d sessions: %s", query, len(matches), strings.Join(ids, ", "))
}
