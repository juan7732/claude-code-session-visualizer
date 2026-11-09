package cli

import (
	"fmt"
	"strings"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/cache"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/stats"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/transcript"
)

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
			var store *cache.Store
			if cacheWanted(cmd) {
				if store, err = cache.Open(); err != nil {
					fmt.Fprintf(cmd.ErrOrStderr(), "skit: cache unavailable: %v\n", err)
				}
			}
			var rows []stats.Summary
			for _, l := range rep.Sessions() {
				if l.File.Kind != "main" || (project != "" && !strings.Contains(strings.ToLower(l.Project.Slug), strings.ToLower(project))) {
					continue
				}
				key := cache.KeyFor(l.File.Path, l.File.Bytes, l.File.ModTime, l.File.Subagents, l.File.SubagentBytes)
				var sum stats.Summary
				if store == nil || !store.Get(l.File.ID, key, &sum) {
					s, err := transcript.Load(l.File.Path)
					if err != nil {
						fmt.Fprintf(cmd.ErrOrStderr(), "skit: skipping %s: %v\n", l.File.Path, err)
						continue
					}
					sum = stats.Compute(s, l.Project.Slug, stats.Options{})
					if store != nil {
						if err := store.Put(l.File.ID, key, sum); err != nil {
							fmt.Fprintf(cmd.ErrOrStderr(), "skit: cache write failed: %v\n", err)
						}
					}
				}
				rows = append(rows, sum)
				if limit > 0 && len(rows) >= limit {
					break
				}
			}
			if jsonWanted(cmd) {
				if rows == nil {
					rows = []stats.Summary{}
				}
				return writeJSON(cmd.OutOrStdout(), rows)
			}
			w := cmd.OutOrStdout()
			fmt.Fprintf(w, "%-8s  %-16s %8s %7s %5s %5s %7s %7s  %s\n", "ID", "LAST ACTIVITY", "DURATION", "PROMPTS", "REQS", "TOOLS", "OUT TOK", "COST", "TITLE")
			for _, r := range rows {
				fmt.Fprintf(w, "%-8s  %-16s %8s %7d %5d %5d %7s %7s  %s\n", r.ID[:8], localTime(r.LastAt), r.Duration, r.Prompts, r.Requests, r.ToolCalls,
					stats.FormatTokens(r.Usage.OutputTokens), money(r.ClaudeCodeCostUSD), truncate(r.Title, 50))
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
