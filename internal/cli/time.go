package cli

import (
	"fmt"
	"io"
	"sort"
	"time"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/stats"
)

func newTime() *cobra.Command {
	var top int
	cmd := &cobra.Command{
		Use:   "time <session>",
		Short: "Where a session's time went: waiting for you, the model, tools, subagents",
		Long: `time splits a session's wall time. Outside turns it waited: for you, or for
background work when the next turn was started by a notification. Inside turns
the model was working (waiting for a response, thinking, writing), tools were
running, a subagent was running, or the agent had spoken and waited for a
hand-back. A wait after speaking that no hand-back ended counts as waiting for
you: the transcript does not say what brought the agent back. The parts add up
to the whole. Then each turn's share, the slowest tool calls and the longest
waits; --top sets how many of those two.
A tool call that waited for your permission counts as tool time: a transcript
does not record that wait.`,
		Example: "  skit time 36086585\n  skit time 36086585 --top 3 --json | jq '.slowest_calls[] | {name, seconds, summary}'\n  skit time 36086585 --json | jq '.turns | max_by(.seconds)'",
		Args:    cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			r, err := resolve(cmd, args[0])
			if err != nil {
				return err
			}
			t := stats.TimeOf(r.Session, r.Relations(), top)
			if jsonWanted(cmd) {
				return writeJSON(cmd.OutOrStdout(), t)
			}
			printTime(cmd.OutOrStdout(), t)
			return nil
		},
	}
	cmd.Flags().IntVar(&top, "top", 10, "how many slowest calls and longest waits to list")
	return cmd
}

func printTime(w io.Writer, t stats.Time) {
	dur := func(s float64) string { return stats.FormatDuration(time.Duration(s * float64(time.Second))) }
	share := func(part, whole float64) string {
		if whole <= 0 {
			return "  0%"
		}
		return fmt.Sprintf("%3.0f%%", part/whole*100)
	}
	fmt.Fprintf(w, "Session   %s  %s\n", t.ID, t.Title)
	fmt.Fprintf(w, "Span      %s → %s  (%s)\n\n", localTime(t.FirstAt), localTime(t.LastAt), dur(t.Wall))

	fmt.Fprintln(w, "Wall")
	fmt.Fprintf(w, "  %-28s %10s  %s\n", "waiting for you", dur(t.ForYou), share(t.ForYou, t.Wall))
	if t.ForBackground > 0 {
		fmt.Fprintf(w, "  %-28s %10s  %s\n", "waiting for background work", dur(t.ForBackground), share(t.ForBackground, t.Wall))
	}
	fmt.Fprintf(w, "  %-28s %10s  %s\n\n", "in turns", dur(t.InTurns.Seconds), share(t.InTurns.Seconds, t.Wall))

	in := t.InTurns
	fmt.Fprintln(w, "In turns")
	fmt.Fprintf(w, "  %-28s %10s  %s\n", "the model", dur(in.Model), share(in.Model, in.Seconds))
	fmt.Fprintf(w, "  %-28s %10s  %s\n", "tools running", dur(in.Tools), share(in.Tools, in.Seconds))
	if in.Subagents > 0 {
		fmt.Fprintf(w, "  %-28s %10s  %s\n", "subagents running", dur(in.Subagents), share(in.Subagents, in.Seconds))
	}
	if in.Waiting > 0 {
		fmt.Fprintf(w, "  %-28s %10s  %s\n", "waiting for a hand-back", dur(in.Waiting), share(in.Waiting, in.Seconds))
	}

	fmt.Fprintf(w, "\nSlowest tool calls (%d)\n", len(t.SlowestCalls))
	for _, c := range t.SlowestCalls {
		note := ""
		if c.Subagent {
			note = "  (subagent)"
		}
		if c.IsError {
			note += "  (failed)"
		}
		fmt.Fprintf(w, "  %9s  turn %-3d action %-4d %-10s %s%s\n", dur(c.Seconds), c.Turn, c.Action, c.Name, truncate(c.Summary, 60), note)
	}
	fmt.Fprintf(w, "\nLongest waits (%d)\n", len(t.LongestWaits))
	for _, g := range t.LongestWaits {
		where := fmt.Sprintf("after turn %d", g.AfterTurn)
		if g.AfterTurn == g.BeforeTurn {
			where = fmt.Sprintf("inside turn %d, after the agent spoke", g.AfterTurn)
		}
		fmt.Fprintf(w, "  %9s  %s, for %s  (%s)\n", dur(g.Seconds), where, g.For, localTime(g.At))
	}
	fmt.Fprintf(w, "\nTurns (%d), longest first\n", len(t.Turns))
	turns := append([]stats.TurnTime(nil), t.Turns...)
	sort.SliceStable(turns, func(i, j int) bool { return turns[i].Seconds > turns[j].Seconds })
	for i, x := range turns {
		if i == 10 {
			fmt.Fprintf(w, "  … %d more (use --json)\n", len(turns)-10)
			break
		}
		fmt.Fprintf(w, "  %9s  turn %-3d %3d actions  model %s · tools %s", dur(x.Seconds), x.Turn, x.Actions, dur(x.Model), dur(x.Tools))
		if x.Subagents > 0 {
			fmt.Fprintf(w, " · subagents %s", dur(x.Subagents))
		}
		if x.Waiting > 0 {
			fmt.Fprintf(w, " · waiting %s", dur(x.Waiting))
		}
		fmt.Fprintln(w)
	}
}
