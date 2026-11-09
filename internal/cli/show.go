package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/archive"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/stats"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/transcript"
)

func newShow() *cobra.Command {
	var turn int
	var width int
	var showContext bool
	cmd := &cobra.Command{
		Use:   "show <session>",
		Short: "Show one session as a timeline",
		Long: `show prints a session as a timeline: prompts, model turns, tool calls with their
durations, compactions, API errors and subagent launches, in time order. <session>
is a session id, a unique id prefix, or the path to a .jsonl transcript.

With --turn N the full content of request N is printed instead: its blocks (text,
thinking, tool inputs) and the results of its tool calls. With --json the whole
parsed session is emitted (image bytes replaced by their size).`,
		Example: "  skit show 36086585\n  skit show 36086585 --turn 12\n  skit show ~/.claude/projects/-Users-me-app/<id>.jsonl --json",
		Args:    cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			r, err := resolve(cmd, args[0])
			if err != nil {
				return err
			}
			s := r.Session
			w := cmd.OutOrStdout()
			if jsonWanted(cmd) {
				return writeJSON(w, archive.Document(r))
			}
			if cmd.Flags().Changed("turn") {
				return printTurn(w, s, turn, width)
			}
			if r.ArchivedOnly {
				fmt.Fprintln(w, "Source   gone from ~/.claude; showing the archived copy")
			}
			printTimeline(w, s, r.Project, width, showContext)
			return nil
		},
	}
	cmd.Flags().IntVarP(&turn, "turn", "t", 0, "print request N in full (0-based index from the timeline)")
	cmd.Flags().IntVar(&width, "width", 100, "column width for text snippets")
	cmd.Flags().BoolVar(&showContext, "context", false, "also show what shaped the context: blocks injected into prompts and every attachment Claude Code added")
	return cmd
}

type event struct {
	at   time.Time
	kind string
	text string
}

func printTimeline(w io.Writer, s *transcript.Session, project string, width int, showContext bool) {
	sum := stats.Compute(s, project, stats.Options{})
	fmt.Fprintf(w, "Session  %s  %s\n", s.ID, sum.Title)
	fmt.Fprintf(w, "Project  %s\n", project)
	for i, c := range s.Cwds {
		label := "Cwd     "
		if i > 0 {
			label = "        "
		}
		fmt.Fprintf(w, "%s %s\n", label, c)
	}
	fmt.Fprintf(w, "Span     %s → %s  (%s)   Claude Code %s · %s\n", localTime(s.FirstAt), localTime(s.LastAt), sum.Duration,
		strings.Join(s.Versions, ", "), strings.Join(s.Entrypoints, ", "))
	models := make([]string, 0, len(sum.Models))
	for _, m := range sum.Models {
		models = append(models, fmt.Sprintf("%s ×%d", m.Name, m.Count))
	}
	fmt.Fprintf(w, "Totals   prompts %d · requests %d · tool calls %d · compactions %d · subagents %d · api errors %d · synthetic %d · cost %s\n",
		sum.Prompts, sum.Requests, sum.ToolCalls, sum.Compactions, sum.Subagents, sum.APIErrors, sum.Synthetic, money(sum.ClaudeCodeCostUSD))
	fmt.Fprintf(w, "Context  %d injected blocks in prompts · %d attachments", sum.Injected, sum.Attachments)
	if !showContext {
		fmt.Fprint(w, "   (--context to show them)")
	}
	fmt.Fprintln(w)
	fmt.Fprintf(w, "Models   %s\n", strings.Join(models, ", "))
	if s.Partial {
		fmt.Fprintln(w, "Note     transcript ends mid-line: the session is still being written")
	}
	if s.Branches > 0 {
		fmt.Fprintf(w, "Note     %d branch point(s): the timeline shows every record, the main chain is %d records long\n", s.Branches, len(s.Chain))
	}
	fmt.Fprintln(w)

	var events []event
	for _, p := range s.Prompts {
		img := ""
		if p.Images > 0 {
			img = fmt.Sprintf(" [%d image(s)]", p.Images)
		}
		text := truncate(p.Text, width) + img
		if showContext {
			for _, b := range p.Context {
				text += fmt.Sprintf("\n%25s ctx %-16s %s", "", transcript.InjectedKind(b.Text), truncate(b.Text, width-20))
			}
		}
		events = append(events, event{p.At, "prompt", text})
	}
	if showContext {
		for _, r := range s.Records {
			if r.Type == "attachment" && r.Attachment != nil {
				size := 0
				var rendered struct {
					Rendered []struct {
						Content string `json:"content"`
					} `json:"rendered"`
				}
				if r.Decode(&rendered) == nil {
					for _, x := range rendered.Rendered {
						size += len(x.Content)
					}
				}
				events = append(events, event{r.Timestamp, "ctx", fmt.Sprintf("attachment %-24s %s chars → %s", r.Attachment.Type, stats.FormatTokens(size), r.RenderedRole)})
			}
		}
	}
	for _, t := range s.Turns {
		if t.Synthetic {
			kind := "· note"
			if t.SyntheticKind == "api_error" {
				kind = "! api_error"
			}
			events = append(events, event{t.At, kind, truncate(t.Text(), width) + "  (written by Claude Code, no request)"})
			continue
		}
		text := truncate(t.Text(), width-30)
		think := 0
		for _, b := range t.Blocks {
			if b.Type == "thinking" {
				think++
			}
		}
		meta := fmt.Sprintf("%s  out %s · ctx %s", shortModel(t.Model), stats.FormatTokens(t.Usage.OutputTokens), stats.FormatTokens(t.Usage.ContextTokens()))
		if think > 0 {
			meta += " · thinking"
		}
		if text != "" {
			meta += "  “" + text + "”"
		}
		events = append(events, event{t.At, fmt.Sprintf("turn %d", t.Index), meta})
	}
	for _, c := range s.ToolCalls {
		dur := ""
		if c.Paired {
			dur = shortDuration(c.EndedAt.Sub(c.At))
		} else {
			dur = "no result"
		}
		line := fmt.Sprintf("%-9s %s", dur, truncate(toolSummary(c.Name, c.Input), width-20))
		if c.IsError {
			line += "  ✗ error"
		}
		if c.Subagent != nil {
			sa := c.Subagent
			model := ""
			if sa.Meta != nil {
				model = sa.Meta.Model
			}
			line += fmt.Sprintf("  → subagent %s (%s, %d requests, %d tool calls)", sa.AgentID, model, sa.Session.Totals.Requests, sa.Session.Totals.ToolCalls)
		}
		events = append(events, event{c.At, "⚙ " + c.Name, line})
	}
	for _, c := range s.Compactions {
		text := "compaction"
		if c.Metadata != nil {
			text = fmt.Sprintf("compaction (%s): %s → %s tokens", c.Metadata.Trigger, stats.FormatTokens(c.Metadata.PreTokens), stats.FormatTokens(c.Metadata.PostTokens))
		}
		events = append(events, event{c.At, "✂", text})
	}
	for _, r := range s.Records {
		if r.Type == "system" && r.Subtype == "api_error" {
			var e struct {
				Retry int `json:"retryAttempt"`
				Max   int `json:"maxRetries"`
			}
			_ = r.Decode(&e)
			events = append(events, event{r.Timestamp, "! api_error", fmt.Sprintf("retry %d/%d", e.Retry, e.Max)})
		}
	}
	sort.SliceStable(events, func(i, j int) bool { return events[i].at.Before(events[j].at) })
	for _, e := range events {
		fmt.Fprintf(w, "%s  %-14s %s\n", offset(s.FirstAt, e.at), e.kind, e.text)
	}
}

func printTurn(w io.Writer, s *transcript.Session, n, width int) error {
	if n < 0 || n >= len(s.Turns) {
		return fmt.Errorf("turn %d out of range (session has %d requests)", n, len(s.Turns))
	}
	t := s.Turns[n]
	fmt.Fprintf(w, "Turn %d  %s  %s  request %s\n", t.Index, localClock(t.At), t.Model, t.RequestID)
	fmt.Fprintf(w, "Usage   in %d · cache write %d · cache read %d · out %d (thinking %d) · context %s · stop %s\n\n",
		t.Usage.InputTokens, t.Usage.CacheCreationInputTokens, t.Usage.CacheReadInputTokens, t.Usage.OutputTokens, t.Usage.ThinkingTokens,
		stats.FormatTokens(t.Usage.ContextTokens()), t.StopReason)
	for _, b := range t.Blocks {
		switch b.Type {
		case "thinking":
			fmt.Fprintf(w, "── thinking ──\n%s\n\n", b.Thinking)
		case "text":
			fmt.Fprintf(w, "── text ──\n%s\n\n", b.Text)
		case "tool_use":
			var pretty bytes.Buffer
			if err := json.Indent(&pretty, b.Input, "", "  "); err != nil {
				pretty.Write(b.Input)
			}
			fmt.Fprintf(w, "── tool_use %s (%s) ──\n%s\n", b.Name, b.ID, pretty.String())
			for _, c := range t.ToolCalls {
				if c.ID == b.ID {
					if !c.Paired {
						fmt.Fprintln(w, "   (no result recorded)")
						break
					}
					res := c.ResultText()
					label := "result"
					if c.IsError {
						label = "result (error)"
					}
					if p, ok := s.SpilledPath(c); ok {
						// The transcript holds a preview; the full output was spilled to a file.
						if full, err := os.ReadFile(p); err == nil {
							res = string(full)
							label += " (full output from " + p + ")"
						} else {
							label += " (full output in " + p + ", unreadable: " + err.Error() + ")"
						}
					}
					fmt.Fprintf(w, "   %s after %s:\n%s\n", label, shortDuration(c.EndedAt.Sub(c.At)), indent(truncateLines(res, 40), "   "))
				}
			}
			fmt.Fprintln(w)
		default:
			fmt.Fprintf(w, "── %s ──\n\n", b.Type)
		}
	}
	return nil
}

func shortModel(m string) string {
	return strings.TrimPrefix(m, "claude-")
}

func indent(s, prefix string) string {
	lines := strings.Split(s, "\n")
	for i := range lines {
		lines[i] = prefix + lines[i]
	}
	return strings.Join(lines, "\n")
}

func truncateLines(s string, max int) string {
	lines := strings.Split(s, "\n")
	if len(lines) <= max {
		return s
	}
	return strings.Join(lines[:max], "\n") + fmt.Sprintf("\n… (%d more lines)", len(lines)-max)
}
