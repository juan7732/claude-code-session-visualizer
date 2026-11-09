package cli

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/archive"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/transcript"
)

// resolved is a session found either on disk or in the archive.
type resolved struct {
	Session  *transcript.Session
	Project  string
	Archived bool // loaded from the archive because the source is gone
}

// resolve finds a session by id, prefix or path: Claude Code's directory
// first, then the archive. The archive is opened only when needed.
func resolve(cmd *cobra.Command, query string) (resolved, error) {
	rep, err := catalog.Inspect()
	if err != nil {
		return resolved{}, err
	}
	if l, err := rep.Find(query); err == nil {
		s, err := transcript.Load(l.File.Path)
		if err != nil {
			return resolved{}, err
		}
		return resolved{Session: s, Project: l.Project.Slug}, nil
	} else if !isNotFound(err) {
		return resolved{}, err
	}
	a, err := archive.Open()
	if err != nil {
		return resolved{}, err
	}
	defer a.Close()
	rows, err := a.Store.SessionsByPrefix(query)
	if err != nil {
		return resolved{}, err
	}
	var archived []string
	for _, r := range rows {
		if r.Archived() {
			archived = append(archived, r.ID)
		}
	}
	switch len(archived) {
	case 0:
		return resolved{}, fmt.Errorf("no session matches %q on disk or in the archive (try `skit list`)", query)
	case 1:
		s, row, err := a.Load(archived[0])
		if err != nil {
			return resolved{}, err
		}
		if _, statErr := os.Stat(row.SourcePath); statErr == nil {
			fmt.Fprintf(cmd.ErrOrStderr(), "skit: note: %s exists on disk but was not found by catalog; showing the archived copy\n", row.SourcePath)
		}
		return resolved{Session: s, Project: row.Project, Archived: true}, nil
	}
	return resolved{}, fmt.Errorf("%q matches %d archived sessions", query, len(archived))
}

func isNotFound(err error) bool {
	return err != nil && len(err.Error()) > 10 && err.Error()[:10] == "no session"
}
