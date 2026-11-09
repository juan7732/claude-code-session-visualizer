package cli

import (
	"fmt"
	"io"
	"strings"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/stats"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/transcript"
)

func newStats() *cobra.Command {
	var context bool
	cmd := &cobra.Command{
		Use:   "stats <session>",
		Short: "Token, cost, tool and compaction statistics for one session",
		Long: `stats sums usage once per request (subagents rolled in), lists models and tools,
compactions and API errors, and shows Claude Code's own cost figure when the
transcript has one. --context adds the context-window size at every request.`,
		Example: "  skit stats 36086585\n  skit stats 36086585 --context\n  skit stats 36086585 --json | jq .usage",
		Args:    cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			rep, err := catalog.Inspect()
			if err != nil {
				return err
			}
			l, err := rep.Find(args[0])
			if err != nil {
				return err
			}
			s, err := transcript.Load(l.File.Path)
			if err != nil {
				return err
			}
			sum := stats.Compute(s, l.Project.Slug, stats.Options{Context: context || jsonWanted(cmd)})
			if jsonWanted(cmd) {
				return writeJSON(cmd.OutOrStdout(), sum)
			}
			printStats(cmd.OutOrStdout(), sum, context)
			return nil
		},
	}
	cmd.Flags().BoolVar(&context, "context", false, "print the context-window size at every request")
	return cmd
}

func printStats(w io.Writer, sum stats.Summary, context bool) {
	fmt.Fprintf(w, "Session   %s  %s\n", sum.ID, sum.Title)
	fmt.Fprintf(w, "Project   %s\n", sum.Project)
	fmt.Fprintf(w, "Span      %s → %s  (%s)\n\n", localTime(sum.FirstAt), localTime(sum.LastAt), sum.Duration)

	u := sum.Usage
	fmt.Fprintln(w, "Tokens (once per request, subagents included)")
	fmt.Fprintf(w, "  input           %12d\n", u.InputTokens)
	fmt.Fprintf(w, "  cache creation  %12d   (5m %d · 1h %d)\n", u.CacheCreationInputTokens, u.Ephemeral5mInputTokens, u.Ephemeral1hInputTokens)
	fmt.Fprintf(w, "  cache read      %12d   hit ratio %.1f%%\n", u.CacheReadInputTokens, sum.CacheHitRatio*100)
	fmt.Fprintf(w, "  output          %12d   (thinking %d)\n", u.OutputTokens, u.ThinkingTokens)
	if u.WebSearchRequests+u.WebFetchRequests > 0 {
		fmt.Fprintf(w, "  server tools    %12d   (web search %d · web fetch %d)\n", u.WebSearchRequests+u.WebFetchRequests, u.WebSearchRequests, u.WebFetchRequests)
	}
	fmt.Fprintf(w, "\nCost      Claude Code's figure %s", money(sum.ClaudeCodeCostUSD))
	if sum.ClaudeCodeCostUSD == nil {
		fmt.Fprint(w, " (no cost-state record)")
	}
	if sum.LinesAdded+sum.LinesRemoved > 0 {
		fmt.Fprintf(w, "   lines +%d −%d", sum.LinesAdded, sum.LinesRemoved)
	}
	fmt.Fprintln(w)

	fmt.Fprintf(w, "\nCounts    prompts %d · requests %d · tool calls %d (errors %d, unpaired %d) · images %d · api errors %d · subagents %d · branches %d\n",
		sum.Prompts, sum.Requests, sum.ToolCalls, sum.ToolErrors, sum.Unpaired, sum.Images, sum.APIErrors, sum.Subagents, sum.Branches)

	fmt.Fprintln(w, "\nModels")
	for _, m := range sum.Models {
		fmt.Fprintf(w, "  %-32s %5d requests\n", m.Name, m.Count)
	}
	fmt.Fprintln(w, "\nTools")
	for _, t := range sum.Tools {
		errs := ""
		if t.Errors > 0 {
			errs = fmt.Sprintf("  (%d errors)", t.Errors)
		}
		fmt.Fprintf(w, "  %-32s %5d%s\n", t.Name, t.Calls, errs)
	}
	if len(sum.CompactionList) > 0 {
		fmt.Fprintln(w, "\nCompactions")
		for _, c := range sum.CompactionList {
			fmt.Fprintf(w, "  %s  %-6s %s → %s tokens\n", localClock(c.At), c.Trigger, stats.FormatTokens(c.PreTokens), stats.FormatTokens(c.PostTokens))
		}
	}
	if len(sum.PRLinks) > 0 {
		fmt.Fprintln(w, "\nPull requests")
		for _, p := range sum.PRLinks {
			fmt.Fprintf(w, "  %s\n", p.URL)
		}
	}
	if context && len(sum.Context) > 0 {
		fmt.Fprintln(w, "\nContext window per request")
		max := 0
		for _, p := range sum.Context {
			if p.Tokens > max {
				max = p.Tokens
			}
		}
		for _, p := range sum.Context {
			bar := ""
			if max > 0 {
				bar = strings.Repeat("▇", p.Tokens*40/max)
			}
			fmt.Fprintf(w, "  %4d  %s  %7s  %s\n", p.Index, localClock(p.At), stats.FormatTokens(p.Tokens), bar)
		}
	}
}
