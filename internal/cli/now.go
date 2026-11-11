package cli

import (
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/archive"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/now"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/stats"
)

func newNow() *cobra.Command {
	var minutes int
	cmd := &cobra.Command{
		Use:   "now",
		Short: "Sessions at work: what each is doing at this moment, and how long its prompt cache will last",
		Long: `now lists every session that did something in the last hour (--minutes), the
latest first, and says what each is doing: the model working, a tool running
(which, and since when), blocked on you inside a turn (a permission, a
question), waiting for subagents, waiting for your next prompt (and what it
last said), or closed. It reads the files Claude Code keeps about its running
processes and the last records of each transcript, never a whole transcript.

The cache line says how much of the last request's input was read from the
prompt cache and when the cache expires: the time the last request was sent
plus the lifetime of what it wrote (five minutes or an hour). After that, the
next prompt pays for the whole context again.

A permission prompt that is waiting is not in a transcript: it shows only when
Claude Code marks the process as waiting. Otherwise it reads as a tool that
has been running for a while.`,
		Example: "  skit now\n  skit now --minutes 240\n  skit now --json | jq '.sessions[] | {title, state, left: .cache.seconds_left}'",
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			rep, err := catalog.Inspect()
			if err != nil {
				return err
			}
			opt := now.Options{Window: time.Duration(minutes) * time.Minute}
			// The index names sessions Claude Code has not titled in the tail; it is not needed otherwise.
			if a, err := archive.Open(); err == nil {
				defer a.Close()
				opt.Known = func(id string) (string, string) { return a.Known(id) }
			}
			out, err := (&now.Reader{}).Read(rep, opt)
			if err != nil {
				return err
			}
			if jsonWanted(cmd) {
				return writeJSON(cmd.OutOrStdout(), out)
			}
			printNow(cmd.OutOrStdout(), out)
			return nil
		},
	}
	cmd.Flags().IntVar(&minutes, "minutes", int(now.DefaultWindow/time.Minute), "how far back a session must have done something")
	return cmd
}

func printNow(w io.Writer, rep *now.Report) {
	fmt.Fprintf(w, "Now  %d session%s at work in the last %d minutes", len(rep.Sessions), plural(len(rep.Sessions)), rep.WindowMinutes)
	if rep.RunningOutside > 0 {
		fmt.Fprintf(w, " · %d more running, quiet for longer", rep.RunningOutside)
	}
	fmt.Fprintln(w)
	ago := func(t time.Time) string {
		if t.IsZero() {
			return "?"
		}
		return stats.FormatDuration(rep.At.Sub(t).Round(time.Second))
	}
	for _, s := range rep.Sessions {
		title := s.Title
		if title == "" {
			title = s.ID[:min(8, len(s.ID))]
		}
		fmt.Fprintf(w, "\n%s  %s\n", s.ID[:min(8, len(s.ID))], truncate(title, 70))
		var state string
		switch s.State {
		case now.StateModel:
			state = "the model is working, for " + ago(s.Since)
		case now.StateTool:
			names := make([]string, 0, len(s.Tools))
			for _, t := range s.Tools {
				names = append(names, strings.TrimSpace(t.Name+" "+truncate(t.Summary, 50)))
			}
			state = fmt.Sprintf("running %s, for %s", strings.Join(names, "; "), ago(s.Since))
		case now.StateBlocked:
			state = "waiting for you inside a turn"
			if s.WaitingFor != "" {
				state += " (" + s.WaitingFor + ")"
			}
			state += ", for " + ago(s.Since)
		case now.StateBackground:
			state = fmt.Sprintf("waiting for %d subagent%s, for %s", s.Subagents, plural(s.Subagents), ago(s.Since))
		case now.StateYou:
			state = "waiting for you, for " + ago(s.Since)
		default:
			state = "closed " + ago(s.Since) + " ago"
		}
		fmt.Fprintf(w, "  %s\n", state)
		where := []string{tildePath(s.Cwd)}
		if s.Running {
			where = append(where, strings.TrimPrefix(s.Entrypoint, "claude-"), fmt.Sprintf("pid %d", s.PID))
			if s.Name != "" {
				where = append(where, s.Name)
			}
		}
		fmt.Fprintf(w, "  %s\n", strings.Join(where, " · "))
		if c := s.Cache; c != nil {
			line := fmt.Sprintf("cache  %.0f%% of the last request read · context %s", c.HitRatio*100, stats.FormatTokens(c.ContextTokens))
			switch {
			case c.ExpiresAt == nil:
				line += " · lifetime not known"
			case c.SecondsLeft > 0:
				line += fmt.Sprintf(" · expires in %s (at %s)", stats.FormatDuration(time.Duration(c.SecondsLeft)*time.Second), c.ExpiresAt.Local().Format("15:04"))
			default:
				line += " · expired " + ago(*c.ExpiresAt) + " ago"
			}
			fmt.Fprintf(w, "  %s\n", line)
		}
		if s.Said != "" && (s.State == now.StateYou || s.State == now.StateClosed || s.State == now.StateBackground) {
			fmt.Fprintf(w, "  said   %s\n", truncate(s.Said, 100))
		}
		if s.LastPrompt != "" {
			fmt.Fprintf(w, "  asked  %s\n", truncate(s.LastPrompt, 100))
		}
	}
}
