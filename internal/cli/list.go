package cli

import (
	"fmt"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/archive"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/stats"
)

func newList() *cobra.Command {
	var project string
	var limit int
	cmd := &cobra.Command{
		Use:   "list",
		Short: "List sessions, most recent first, with their key numbers",
		Long: `list parses every session transcript Claude Code has on disk and prints one line
per session: id, last activity, duration, turns, actions (API requests), tool
calls, output tokens, Claude Code's cost figure, and the title.`,
		Example: "  skit list\n  skit list --project tools -n 5\n  skit list --json | jq '.[] | {id, title, requests}'",
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			rep, err := catalog.Inspect()
			if err != nil {
				return err
			}
			a, err := archive.Open()
			if err != nil {
				return err
			}
			defer a.Close()
			rows, err := a.List(rep, project, cacheWanted(cmd), limit, func(err error) { fmt.Fprintln(cmd.ErrOrStderr(), "skit:", err) })
			if err != nil {
				return err
			}
			if jsonWanted(cmd) {
				return writeJSON(cmd.OutOrStdout(), rows)
			}
			w := cmd.OutOrStdout()
			fmt.Fprintf(w, "%-8s  %-16s %8s %5s %7s %5s %7s %7s  %s\n", "ID", "LAST ACTIVITY", "DURATION", "TURNS", "ACTIONS", "TOOLS", "OUT TOK", "COST", "TITLE")
			for _, r := range rows {
				title := truncate(r.Title, 50)
				if r.ArchivedOnly {
					title += "  (archived; source gone)"
				}
				fmt.Fprintf(w, "%-8s  %-16s %8s %5d %7d %5d %7s %7s  %s\n", r.ID[:8], localTime(r.LastAt), r.Duration, r.Turns+r.SystemTurns, r.Requests, r.ToolCalls,
					stats.FormatTokens(r.Usage.OutputTokens), money(r.ClaudeCodeCostUSD), title)
			}
			if len(rows) == 0 {
				fmt.Fprintln(w, "no sessions found (see `skit doctor`)")
			}
			return nil
		},
	}
	cmd.Flags().StringVarP(&project, "project", "p", "", "only projects whose slug contains this text")
	cmd.Flags().IntVarP(&limit, "limit", "n", 0, "stop after this many sessions (0 = all)")
	return cmd
}
