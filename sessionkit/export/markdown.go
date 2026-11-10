// Package export writes a session in formats meant to leave the tool: pasted
// into a note, attached to a pull request, read by someone without skit.
package export

import (
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/stats"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/transcript"
)

// Options narrow and shape an export.
type Options struct {
	// Turn exports one turn; nil exports the whole session under a title.
	Turn *int
	// Thinking includes the model's thinking, quoted, before what it said.
	Thinking bool
	// Location is the time zone times are written in; nil is the local one.
	Location *time.Location
}

// Markdown writes the session as Markdown: what was asked, what was said, and
// one line per tool call with how it went.
//
// DECISION: tool calls are one line each (name, what it was for, the first
// line of the result), not their full input and output. The export is the
// conversation someone else can read; the whole record stays in `skit show`.
func Markdown(w io.Writer, s *transcript.Session, opt Options) error {
	loc := opt.Location
	if loc == nil {
		loc = time.Local
	}
	stamp := func(t time.Time) string { return t.In(loc).Format("2006-01-02 15:04") }
	var b strings.Builder
	if opt.Turn != nil {
		if *opt.Turn < 0 || *opt.Turn >= len(s.Turns) {
			return fmt.Errorf("turn %d out of range (session has %d turns)", *opt.Turn, len(s.Turns))
		}
		writeTurn(&b, s.Turns[*opt.Turn], opt, stamp)
	} else {
		fmt.Fprintf(&b, "# %s\n\n", oneLine(s.DisplayTitle()))
		fmt.Fprintf(&b, "%s → %s · %s", stamp(s.FirstAt), stamp(s.LastAt), stats.FormatDuration(s.Duration()))
		if s.Cwd != "" {
			fmt.Fprintf(&b, " · `%s`", s.Cwd)
		}
		fmt.Fprintf(&b, "\n\nSession `%s`\n", s.ID)
		next := 0 // the next compaction to place
		for _, t := range s.Turns {
			for ; next < len(s.Compactions) && !s.Compactions[next].At.After(t.StartAt); next++ {
				writeCompaction(&b, s.Compactions[next])
			}
			b.WriteString("\n")
			writeTurn(&b, t, opt, stamp)
		}
		for ; next < len(s.Compactions); next++ {
			writeCompaction(&b, s.Compactions[next])
		}
	}
	_, err := io.WriteString(w, strings.TrimRight(b.String(), "\n")+"\n")
	return err
}

func writeCompaction(b *strings.Builder, c *transcript.Compaction) {
	b.WriteString("\n> Context compacted")
	if m := c.Metadata; m != nil {
		fmt.Fprintf(b, " (%s): %s → %s tokens", m.Trigger, stats.FormatTokens(m.PreTokens), stats.FormatTokens(m.PostTokens))
	}
	b.WriteString(". The model continued from a summary.\n")
}

func writeTurn(b *strings.Builder, t *transcript.Turn, opt Options, stamp func(time.Time) string) {
	fmt.Fprintf(b, "## Turn %d · %s\n\n", t.Index, stamp(t.StartAt))
	switch {
	case t.Prompt != nil:
		b.WriteString("**You**")
		if t.Rewound {
			b.WriteString(" (rewound: the conversation left this branch)")
		}
		fmt.Fprintf(b, "\n\n%s\n", strings.TrimSpace(t.Prompt.Text))
		if n := t.Prompt.Images; n > 0 {
			fmt.Fprintf(b, "\n_%d image%s attached_\n", n, plural(n))
		}
	default:
		fmt.Fprintf(b, "_Started by %s, not by a prompt_\n", strings.ReplaceAll(t.Origin, "_", " "))
	}
	// The tool calls of actions that said nothing in between read as one list.
	inList := false
	for _, a := range t.Actions {
		if a.Synthetic {
			if text := strings.TrimSpace(a.Text()); text != "" {
				fmt.Fprintf(b, "\n_Claude Code: %s_\n", oneLine(text))
				inList = false
			}
			continue
		}
		if opt.Thinking {
			if thinking := strings.TrimSpace(a.Thinking()); thinking != "" {
				b.WriteString("\n> **Thinking**\n>\n> " + strings.ReplaceAll(thinking, "\n", "\n> ") + "\n")
				inList = false
			}
		}
		if text := strings.TrimSpace(a.Text()); text != "" {
			fmt.Fprintf(b, "\n**Claude**\n\n%s\n", text)
			inList = false
		}
		if len(a.ToolCalls) > 0 && !inList {
			b.WriteString("\n")
			inList = true
		}
		for _, c := range a.ToolCalls {
			fmt.Fprintf(b, "- `%s`", c.Name)
			if what := oneLine(transcript.ToolSummary(c.Name, c.Input)); what != "" {
				b.WriteString(" " + clip(what, 160))
			}
			switch {
			case !c.Paired:
				b.WriteString(" (no result recorded)")
			case c.IsError:
				b.WriteString(" (failed)")
			}
			if c.ResultHead != "" {
				b.WriteString(" → " + clip(c.ResultHead, 120))
			}
			b.WriteString("\n")
		}
	}
}

// oneLine flattens text so it cannot break out of a list item or a heading.
func oneLine(s string) string { return strings.Join(strings.Fields(s), " ") }

func clip(s string, max int) string {
	if r := []rune(s); len(r) > max {
		return string(r[:max-1]) + "…"
	}
	return s
}

func plural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}
