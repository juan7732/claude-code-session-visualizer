package cli

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
)

type projectRow struct {
	Slug      string `json:"slug"`
	Dir       string `json:"dir"`
	Sessions  int    `json:"sessions"`
	Subagents int    `json:"subagents"`
	Bytes     int64  `json:"bytes"`
	LastAt    string `json:"last_at"`
}

func newProjects() *cobra.Command {
	return &cobra.Command{
		Use:     "projects",
		Short:   "List Claude Code projects (start directories) that have sessions",
		Example: "  skit projects\n  skit projects --json",
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			rep, err := catalog.Inspect()
			if err != nil {
				return err
			}
			var rows []projectRow
			for _, p := range rep.Projects {
				row := projectRow{Slug: p.Slug, Dir: p.Dir, Bytes: p.Bytes()}
				for _, s := range p.Sessions {
					if s.Kind == "main" {
						row.Sessions++
					}
					row.Subagents += s.Subagents
					if row.LastAt == "" || s.ModTime.Format("2006-01-02T15:04:05") > row.LastAt {
						row.LastAt = s.ModTime.Format("2006-01-02T15:04:05")
					}
				}
				rows = append(rows, row)
			}
			if jsonWanted(cmd) {
				return writeJSON(cmd.OutOrStdout(), rows)
			}
			w := cmd.OutOrStdout()
			fmt.Fprintf(w, "%-52s %8s %9s %9s  %s\n", "PROJECT", "SESSIONS", "SUBAGENTS", "SIZE", "LAST ACTIVITY")
			for _, r := range rows {
				fmt.Fprintf(w, "%-52s %8d %9d %9s  %s\n", truncate(r.Slug, 52), r.Sessions, r.Subagents, humanBytes(r.Bytes), r.LastAt)
			}
			return nil
		},
	}
}
