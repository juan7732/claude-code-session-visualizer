package cli

import (
	"fmt"
	"io"
	"time"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/archive"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/home"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/stats"
)

func newOverview() *cobra.Command {
	var project string
	var days int
	cmd := &cobra.Command{
		Use:   "overview",
		Short: "Every session added up: totals, by project, by day, tools, models, where the time went",
		Long: `overview adds up what each session's summary holds: turns, actions, tool calls
and failures, output tokens and Claude Code's cost figure; the same per project;
what happened on each day (in this machine's time zone, with the sessions that
were active); tool calls and failures by tool; actions by model; the prompt
cache; and where the wall time went (as in skit time). It reads the index, not
the transcripts: a session is parsed only when it has changed since it was
last listed. --project narrows everything to the projects whose slug contains
the text.`,
		Example: "  skit overview\n  skit overview -p tools --days 30\n  skit overview --json | jq '.days[-7:] | map({day, actions})'",
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
			rows, err := a.List(rep, project, cacheWanted(cmd), 0, func(err error) { fmt.Fprintln(cmd.ErrOrStderr(), "skit:", err) })
			if err != nil {
				return err
			}
			o := stats.Overall(summaries(rows), home.LocalZone())
			if jsonWanted(cmd) {
				return writeJSON(cmd.OutOrStdout(), o)
			}
			printOverview(cmd.OutOrStdout(), o, days)
			return nil
		},
	}
	cmd.Flags().StringVarP(&project, "project", "p", "", "only projects whose slug contains this text")
	cmd.Flags().IntVar(&days, "days", 14, "how many of the latest active days to print (--json has them all)")
	return cmd
}

func summaries(rows []archive.ListRow) []stats.Summary {
	out := make([]stats.Summary, len(rows))
	for i, r := range rows {
		out[i] = r.Summary
	}
	return out
}

func printOverview(w io.Writer, o stats.Overview, days int) {
	dur := func(s float64) string { return stats.FormatDuration(time.Duration(s * float64(time.Second))) }
	t := o.Totals
	fmt.Fprintf(w, "Sessions  %d in %d project%s\n", o.Sessions, len(o.Projects), plural(len(o.Projects)))
	fmt.Fprintf(w, "Totals    turns %d (+%d system-started) · actions %d · tool calls %d (%d failed) · output %s · cost %s over %d session%s\n",
		t.Turns, t.SystemTurns, t.Actions, t.ToolCalls, t.ToolErrors, stats.FormatTokens(t.OutputTokens), money(&t.CostUSD), t.CostSessions, plural(t.CostSessions))
	fmt.Fprintf(w, "Also      subagents %d · compactions %d · images %d · api errors %d · cache hit %.0f%% (%s read)\n",
		t.Subagents, t.Compactions, t.Images, t.APIErrors, o.CacheHitRatio*100, stats.FormatTokens(o.CacheRead))

	fmt.Fprintln(w, "\nBy project")
	for _, p := range o.Projects {
		fmt.Fprintf(w, "  %-34s %3d sessions %6d actions %6d tool calls %4d failed  out %7s  last %s\n",
			truncate(p.Project, 34), p.Sessions, p.Actions, p.ToolCalls, p.ToolErrors, stats.FormatTokens(p.OutputTokens), localTime(p.LastAt))
	}

	shown := o.Days
	if days > 0 && len(shown) > days {
		shown = shown[len(shown)-days:]
	}
	fmt.Fprintf(w, "\nBy day (%s), %d of %d active day%s\n", o.Timezone, len(shown), len(o.Days), plural(len(o.Days)))
	for _, d := range shown {
		fmt.Fprintf(w, "  %s %6d actions %6d tool calls %4d failed  out %7s  %d session%s\n",
			d.Day, d.Actions, d.ToolCalls, d.ToolErrors, stats.FormatTokens(d.OutputTokens), len(d.Sessions), plural(len(d.Sessions)))
	}
	if o.WithoutActivity > 0 {
		fmt.Fprintf(w, "  (%d session%s indexed before activity was kept, and gone from disk: counted above, on no day)\n", o.WithoutActivity, plural(o.WithoutActivity))
	}

	fmt.Fprintln(w, "\nTools")
	for i, tc := range o.Tools {
		if i == 10 {
			fmt.Fprintf(w, "  … %d more (use --json)\n", len(o.Tools)-10)
			break
		}
		fmt.Fprintf(w, "  %-34s %6d calls %4d failed\n", truncate(tc.Name, 34), tc.Calls, tc.Errors)
	}
	fmt.Fprintln(w, "\nModels")
	for _, m := range o.Models {
		fmt.Fprintf(w, "  %-34s %6d actions\n", m.Name, m.Count)
	}

	tm := o.Time
	if tm.Wall > 0 {
		fmt.Fprintf(w, "\nTime      wall %s · waiting for you %s · for background work %s · in turns %s\n", dur(tm.Wall), dur(tm.ForYou), dur(tm.ForBackground), dur(tm.Seconds))
		fmt.Fprintf(w, "          in turns: the model %s · tools %s · subagents %s · waiting for a hand-back %s\n", dur(tm.Model), dur(tm.Tools), dur(tm.Subagents), dur(tm.Waiting))
	}
}

func plural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}
