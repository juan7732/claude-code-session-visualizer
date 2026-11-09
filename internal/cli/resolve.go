package cli

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/archive"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
)

// resolve finds a session on disk or in the archive and surfaces any note.
func resolve(cmd *cobra.Command, query string) (archive.Resolved, error) {
	rep, err := catalog.Inspect()
	if err != nil {
		return archive.Resolved{}, err
	}
	a, err := archive.Open()
	if err != nil {
		return archive.Resolved{}, err
	}
	defer a.Close()
	r, err := a.Resolve(rep, query)
	if err != nil {
		var nf *archive.NotFoundError
		if ok := asNotFound(err, &nf); ok {
			return r, fmt.Errorf("%v (try `skit list`)", err)
		}
		return r, err
	}
	if r.Note != "" {
		fmt.Fprintln(cmd.ErrOrStderr(), "skit: note:", r.Note)
	}
	return r, nil
}

func asNotFound(err error, target **archive.NotFoundError) bool {
	nf, ok := err.(*archive.NotFoundError)
	if ok {
		*target = nf
	}
	return ok
}
