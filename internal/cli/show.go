package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/archive"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/stats"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/transcript"
)

func newShow() *cobra.Command {
	var turn, action int
	var width int
	var showContext, showThinking bool
	var agent string
	cmd := &cobra.Command{
		Use:   "show <session>",
		Short: "Show one session as a timeline",
		Long: `show prints a session as a timeline grouped by turn: each human prompt opens a
turn, and the agent's turn below it lists its actions (one per API request) with
their tool calls, durations, compactions, API errors and subagent launches.
<session> is a session id, a unique id prefix, or the path to a .jsonl transcript.

--turn N prints agent turn N in full: every action's thinking, text, tool inputs
and results. --action N prints one action; with --agent <id> it is action N of
that subagent's own transcript. --thinking adds thinking text to the timeline. --json emits the whole parsed session (image bytes replaced by size).`,
		Example: "  skit show 36086585\n  skit show 36086585 --turn 4\n  skit show 36086585 --action 12\n  skit show ~/.claude/projects/-Users-me-app/<id>.jsonl --json",
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
			if agent != "" {
				sub := s.SubagentSession(agent)
				if sub == nil {
					return fmt.Errorf("no subagent %q in session %s", agent, s.ID)
				}
				if !cmd.Flags().Changed("action") {
					return fmt.Errorf("--agent needs --action N: the step of the subagent to print")
				}
				return printAction(w, sub, action, width)
			}
			if cmd.Flags().Changed("action") {
				return printAction(w, s, action, width)
			}
			if cmd.Flags().Changed("turn") {
				return printTurn(w, s, turn, width)
			}
			if r.ArchivedOnly {
				fmt.Fprintln(w, "Source   gone from ~/.claude; showing the archived copy")
			}
			printTimeline(w, s, r.Project, width, showContext, showThinking)
			return nil
		},
	}
	cmd.Flags().IntVarP(&turn, "turn", "t", 0, "print agent turn N in full: all its actions and tool results")
	cmd.Flags().IntVarP(&action, "action", "a", 0, "print action N in full (one API request)")
	cmd.Flags().StringVar(&agent, "agent", "", "with --action: the subagent whose action N to print (its agent id)")
	cmd.Flags().BoolVar(&showThinking, "thinking", false, "include thinking text under each action in the timeline")
	cmd.Flags().IntVar(&width, "width", 100, "column width for text snippets")
	cmd.Flags().BoolVar(&showContext, "context", false, "also show what shaped the context: blocks injected into prompts and every attachment Claude Code added")
	return cmd
}

type event struct {
	at   time.Time
	kind string
	text string
}

func printTimeline(w io.Writer, s *transcript.Session, project string, width int, showContext, showThinking bool) {
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
	fmt.Fprintf(w, "Totals   turns %d · actions %d · tool calls %d · compactions %d · subagents %d · api errors %d · synthetic %d · cost %s\n",
		sum.Turns+sum.SystemTurns, sum.Requests, sum.ToolCalls, sum.Compactions, sum.Subagents, sum.APIErrors, sum.Synthetic, money(sum.ClaudeCodeCostUSD))
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
		fmt.Fprintf(w, "Note     %d branch point(s): the timeline shows every record; %d turn(s) and %d action(s) are on rewound branches, marked ↩ and included in the counts\n",
			s.Branches, s.Totals.RewoundTurns, s.Totals.RewoundActions)
	}
	fmt.Fprintln(w)

	var events []event
	turnOf := map[*transcript.Prompt]int{}
	for _, t := range s.Turns {
		if t.Prompt != nil {
			turnOf[t.Prompt] = t.Index
		} else {
			events = append(events, event{t.StartAt, fmt.Sprintf("turn %d", t.Index), fmt.Sprintf("started by %s (no human prompt)", t.Origin)})
		}
		if len(t.Actions) > 0 {
			events = append(events, event{t.EndAt, "  ↳ end", fmt.Sprintf("turn %d: %d actions · %d tool calls · %s · out %s", t.Index, len(t.Actions), t.ToolCalls, shortDuration(t.Duration()), stats.FormatTokens(t.Usage.OutputTokens))})
		}
	}
	for _, p := range s.Prompts {
		img := ""
		if p.Images > 0 {
			img = fmt.Sprintf(" [%d image(s)]", p.Images)
		}
		text := truncate(p.Text, width) + img
		if p.Rewound {
			text = "↩ rewound · " + text
		}
		if showContext {
			for _, b := range p.Context {
				text += fmt.Sprintf("\n%25s ctx %-16s %s", "", transcript.InjectedKind(b.Text), truncate(b.Text, width-20))
			}
		}
		events = append(events, event{p.At, fmt.Sprintf("turn %d", turnOf[p]), text})
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
	for _, a := range s.Actions {
		if a.Synthetic {
			kind := "  · note"
			if a.SyntheticKind == "api_error" {
				kind = "  ! api_error"
			}
			events = append(events, event{a.At, kind, truncate(a.Text(), width) + "  (written by Claude Code, no request)"})
			continue
		}
		text := truncate(a.Text(), width-30)
		thinking := a.Thinking()
		meta := fmt.Sprintf("%s  out %s · ctx %s", shortModel(a.Model), stats.FormatTokens(a.Usage.OutputTokens), stats.FormatTokens(a.Usage.ContextTokens()))
		if thinking != "" {
			meta += " · thinking"
		}
		if text != "" {
			meta += "  “" + text + "”"
		}
		if showThinking && thinking != "" {
			meta += fmt.Sprintf("\n%25s 💭 %s", "", truncate(thinking, width-10))
		}
		events = append(events, event{a.At, fmt.Sprintf("  action %d", a.Index), meta})
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
		events = append(events, event{c.At, "    ⚙ " + c.Name, line})
	}
	for i, c := range s.Compactions {
		text := fmt.Sprintf("compaction %d", i)
		if c.Metadata != nil {
			text = fmt.Sprintf("compaction %d (%s): %s → %s tokens  (skit context <id> --compaction %d)", i, c.Metadata.Trigger, stats.FormatTokens(c.Metadata.PreTokens), stats.FormatTokens(c.Metadata.PostTokens), i)
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
		fmt.Fprintf(w, "%s  %-16s %s\n", offset(s.FirstAt, e.at), e.kind, e.text)
	}
}

func printTurn(w io.Writer, s *transcript.Session, n, width int) error {
	if n < 0 || n >= len(s.Turns) {
		return fmt.Errorf("turn %d out of range (session has %d turns)", n, len(s.Turns))
	}
	t := s.Turns[n]
	fmt.Fprintf(w, "Turn %d  %s  origin %s  %d actions · %d tool calls · %s · out %s\n", t.Index, localClock(t.StartAt), t.Origin, len(t.Actions), t.ToolCalls, shortDuration(t.Duration()), stats.FormatTokens(t.Usage.OutputTokens))
	if t.Rewound {
		fmt.Fprintln(w, "↩ rewound: this turn is on a branch the conversation left")
	}
	if t.Prompt != nil {
		fmt.Fprintf(w, "\n══ human ══\n%s\n", t.Prompt.Text)
		for _, b := range t.Prompt.Context {
			fmt.Fprintf(w, "   [injected %s] %s\n", transcript.InjectedKind(b.Text), truncate(b.Text, width))
		}
	}
	for _, a := range t.Actions {
		fmt.Fprintln(w)
		if err := printAction(w, s, a.Index, width); err != nil {
			return err
		}
	}
	for _, c := range t.Compactions {
		if c.Metadata != nil {
			fmt.Fprintf(w, "\n✂ compaction (%s): %s → %s tokens\n", c.Metadata.Trigger, stats.FormatTokens(c.Metadata.PreTokens), stats.FormatTokens(c.Metadata.PostTokens))
		}
	}
	return nil
}

func printAction(w io.Writer, s *transcript.Session, n, width int) error {
	if n < 0 || n >= len(s.Actions) {
		return fmt.Errorf("action %d out of range (session has %d actions)", n, len(s.Actions))
	}
	a := s.Actions[n]
	fmt.Fprintf(w, "── action %d  (turn %d)  %s  %s  request %s\n", a.Index, a.Turn, localClock(a.At), a.Model, a.RequestID)
	fmt.Fprintf(w, "   in %d · cache write %d · cache read %d · out %d (thinking %d) · context %s · stop %s\n",
		a.Usage.InputTokens, a.Usage.CacheCreationInputTokens, a.Usage.CacheReadInputTokens, a.Usage.OutputTokens, a.Usage.ThinkingTokens,
		stats.FormatTokens(a.Usage.ContextTokens()), a.StopReason)
	for _, b := range a.Blocks {
		switch b.Type {
		case "thinking":
			fmt.Fprintf(w, "\n   💭 thinking\n%s\n", indent(b.Thinking, "   "))
		case "text":
			fmt.Fprintf(w, "\n   text\n%s\n", indent(b.Text, "   "))
		case "tool_use":
			var pretty bytes.Buffer
			if err := json.Indent(&pretty, b.Input, "", "  "); err != nil {
				pretty.Write(b.Input)
			}
			fmt.Fprintf(w, "\n   ⚙ tool_use %s (%s)\n%s\n", b.Name, b.ID, indent(pretty.String(), "   "))
			for _, c := range a.ToolCalls {
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
					// The transcript holds a preview; the full output was spilled to a file.
					if full, p, _, ok := s.SpilledText(c); ok {
						res = full
						label += " (full output from " + p + ")"
					} else if p != "" {
						label += " (full output in " + p + ", unreadable)"
					}
					fmt.Fprintf(w, "   %s after %s:\n%s\n", label, shortDuration(c.EndedAt.Sub(c.At)), indent(truncateLines(res, 40), "      "))
					if c.Subagent != nil {
						fmt.Fprintf(w, "   → subagent %s: %d actions, %d tool calls\n", c.Subagent.AgentID, c.Subagent.Session.Totals.Requests, c.Subagent.Session.Totals.ToolCalls)
					}
				}
			}
		default:
			fmt.Fprintf(w, "\n   [%s]\n", b.Type)
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
