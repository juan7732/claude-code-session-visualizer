package cli

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/archive"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/stats"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/transcript"
)

// listRow is a summary plus whether the session survives only in the archive.
type listRow struct {
	stats.Summary
	ArchivedOnly bool `json:"archived_only,omitempty"`
}

func newList() *cobra.Command {
	var project string
	var limit int
	cmd := &cobra.Command{
		Use:   "list",
		Short: "List sessions, most recent first, with their key numbers",
		Long: `list parses every session transcript Claude Code has on disk and prints one line
per session: id, last activity, duration, prompts, requests, tool calls, output
tokens, Claude Code's cost figure, and the title.`,
		Example: "  skit list\n  skit list --project tools -n 5\n  skit list --json | jq '.[] | {id, title, requests}'",
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			rep, err := catalog.Inspect()
			if err != nil {
				return err
			}
			var a *archive.Archive
			if cacheWanted(cmd) {
				if a, err = archive.Open(); err != nil {
					fmt.Fprintf(cmd.ErrOrStderr(), "skit: index unavailable: %v\n", err)
				} else {
					defer a.Close()
				}
			}
			var rows []listRow
			onDisk := map[string]bool{}
			for _, l := range rep.Sessions() {
				if l.File.Kind != "main" || (project != "" && !strings.Contains(strings.ToLower(l.Project.Slug), strings.ToLower(project))) {
					continue
				}
				onDisk[l.File.ID] = true
				var sum stats.Summary
				if a != nil {
					if sum, _, err = a.Summary(l); err != nil {
						fmt.Fprintf(cmd.ErrOrStderr(), "skit: skipping %s: %v\n", l.File.Path, err)
						continue
					}
				} else {
					s, err := transcript.Load(l.File.Path)
					if err != nil {
						fmt.Fprintf(cmd.ErrOrStderr(), "skit: skipping %s: %v\n", l.File.Path, err)
						continue
					}
					sum = stats.Compute(s, l.Project.Slug, stats.Options{})
				}
				rows = append(rows, listRow{Summary: sum})
			}
			// Sessions that only exist in the archive any more (Claude Code swept them).
			if a != nil {
				archived, err := a.Store.Sessions()
				if err == nil {
					for _, r := range archived {
						if !r.Archived() || onDisk[r.ID] || (project != "" && !strings.Contains(strings.ToLower(r.Project), strings.ToLower(project))) {
							continue
						}
						var sum stats.Summary
						if json.Unmarshal(r.Summary, &sum) == nil {
							rows = append(rows, listRow{Summary: sum, ArchivedOnly: true})
						}
					}
				}
			}
			sort.SliceStable(rows, func(i, j int) bool { return rows[i].LastAt.After(rows[j].LastAt) })
			if limit > 0 && len(rows) > limit {
				rows = rows[:limit]
			}
			if jsonWanted(cmd) {
				if rows == nil {
					rows = []listRow{}
				}
				return writeJSON(cmd.OutOrStdout(), rows)
			}
			w := cmd.OutOrStdout()
			fmt.Fprintf(w, "%-8s  %-16s %8s %7s %5s %5s %7s %7s  %s\n", "ID", "LAST ACTIVITY", "DURATION", "PROMPTS", "REQS", "TOOLS", "OUT TOK", "COST", "TITLE")
			for _, r := range rows {
				title := truncate(r.Title, 50)
				if r.ArchivedOnly {
					title += "  (archived; source gone)"
				}
				fmt.Fprintf(w, "%-8s  %-16s %8s %7d %5d %5d %7s %7s  %s\n", r.ID[:8], localTime(r.LastAt), r.Duration, r.Prompts, r.Requests, r.ToolCalls,
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
