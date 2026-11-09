// Package annotate keeps what the human adds to sessions: pins, tags and notes
// on a session or on one of its turns, actions or tool calls. They live in
// <skit home>/annotations.json, apart from the archive, so a re-index or a
// re-archive never touches them.
//
// DECISION: a JSON file, not a table in the index. Annotations are tiny, are
// the one thing in skit's home the human wrote by hand, and must survive
// deleting skit.sqlite. Writes go through a temp file and a rename.
package annotate

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Annotation is everything attached to one session.
type Annotation struct {
	Pinned bool     `json:"pinned"`
	Tags   []string `json:"tags"`
	// Notes are keyed by what they are about: "session", "turn:3", "action:60",
	// "tool:<id>". The key is opaque to the engine.
	Notes     map[string]string `json:"notes"`
	UpdatedAt time.Time         `json:"updated_at,omitempty"`
}

// Patch changes an annotation. Nil and empty fields leave things as they are;
// a note set to "" is removed.
type Patch struct {
	Pinned     *bool             `json:"pinned,omitempty"`
	AddTags    []string          `json:"add_tags,omitempty"`
	RemoveTags []string          `json:"remove_tags,omitempty"`
	Notes      map[string]string `json:"notes,omitempty"`
}

// Path is the annotations file inside a skit home.
func Path(home string) string { return filepath.Join(home, "annotations.json") }

// All reads every annotation, keyed by session id. A missing file is empty.
func All(home string) (map[string]Annotation, error) {
	out := map[string]Annotation{}
	b, err := os.ReadFile(Path(home))
	if errors.Is(err, os.ErrNotExist) {
		return out, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(b, &out); err != nil {
		return nil, err
	}
	for id, a := range out {
		out[id] = normal(a)
	}
	return out, nil
}

// Get reads one session's annotation; the zero annotation when it has none.
func Get(home, id string) (Annotation, error) {
	all, err := All(home)
	if err != nil {
		return Annotation{}, err
	}
	return normal(all[id]), nil
}

// Apply patches one session's annotation and writes the file.
func Apply(home, id string, p Patch) (Annotation, error) {
	all, err := All(home)
	if err != nil {
		return Annotation{}, err
	}
	a := normal(all[id])
	if p.Pinned != nil {
		a.Pinned = *p.Pinned
	}
	tags := map[string]bool{}
	for _, t := range a.Tags {
		tags[t] = true
	}
	for _, t := range p.AddTags {
		if t = strings.ToLower(strings.TrimSpace(t)); t != "" {
			tags[t] = true
		}
	}
	for _, t := range p.RemoveTags {
		delete(tags, strings.ToLower(strings.TrimSpace(t)))
	}
	a.Tags = a.Tags[:0]
	for t := range tags {
		a.Tags = append(a.Tags, t)
	}
	sort.Strings(a.Tags)
	for k, v := range p.Notes {
		if strings.TrimSpace(v) == "" {
			delete(a.Notes, k)
		} else {
			a.Notes[k] = v
		}
	}
	a.UpdatedAt = time.Now().UTC().Truncate(time.Second)
	if !a.Pinned && len(a.Tags) == 0 && len(a.Notes) == 0 {
		delete(all, id)
	} else {
		all[id] = a
	}
	b, err := json.MarshalIndent(all, "", "  ")
	if err != nil {
		return Annotation{}, err
	}
	if err := os.MkdirAll(home, 0o700); err != nil {
		return Annotation{}, err
	}
	tmp := Path(home) + ".tmp"
	if err := os.WriteFile(tmp, append(b, '\n'), 0o600); err != nil {
		return Annotation{}, err
	}
	return a, os.Rename(tmp, Path(home))
}

func normal(a Annotation) Annotation {
	if a.Tags == nil {
		a.Tags = []string{}
	}
	if a.Notes == nil {
		a.Notes = map[string]string{}
	}
	return a
}
