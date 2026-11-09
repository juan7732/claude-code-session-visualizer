package cli

import (
	"fmt"
	"io"
	"sort"
	"strings"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/stats"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/transcript"
)

func newContext() *cobra.Command {
	var action, compaction int
	var show string
	cmd := &cobra.Command{
		Use:   "context <session>",
		Short: "Explain what the model received for one action: system prompt, tools, messages, injected attachments",
		Long: `context breaks an action's context down into the pieces Claude Code sent: the
system prompt blocks, the tool definitions, the message bodies of the request
(including CLAUDE.md and other injected instructions, labelled), and the
attachments injected since the previous action, each with its size, next to the
token counts the API reported. Default is action 0: the seed context of the
session. --show prints one component in full.

--compaction N explains a compaction instead: the context before it, the summary
that replaced the history (with its sections), the messages kept verbatim, what
Claude Code re-injected afterwards, and the context of the first action after.

Works on live sessions and on archived copies (the archive keeps the api-request
records unless it was made with --strip-requests).`,
		Example: "  skit context f115114f\n  skit context f115114f --action 12\n  skit context f115114f --show instructions\n  skit context f115114f --compaction 0\n  skit context f115114f --compaction 0 --show summary",
		Args:    cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			r, err := resolve(cmd, args[0])
			if err != nil {
				return err
			}
			w := cmd.OutOrStdout()
			if cmd.Flags().Changed("compaction") {
				d, err := r.Session.CompactionOf(compaction, show != "" || jsonWanted(cmd))
				if err != nil {
					return err
				}
				if jsonWanted(cmd) {
					return writeJSON(w, d)
				}
				if show != "" {
					return printCompactionComponent(w, d, show)
				}
				printCompaction(w, r.Session, d)
				return nil
			}
			cb, err := r.Session.ContextOf(action, show != "" || jsonWanted(cmd))
			if err != nil {
				return err
			}
			if jsonWanted(cmd) {
				return writeJSON(w, cb)
			}
			if show != "" {
				return printComponent(w, cb, show)
			}
			printContext(w, r.Session, cb)
			return nil
		},
	}
	cmd.Flags().IntVarP(&action, "action", "a", 0, "which action (0 = the first request of the session)")
	cmd.Flags().IntVarP(&compaction, "compaction", "c", 0, "explain compaction N instead of an action (see the ✂ lines in skit show)")
	cmd.Flags().StringVar(&show, "show", "", "print one component in full: system, tools, messages, attachments, instructions (CLAUDE.md), an attachment type such as skill_listing; with --compaction: summary, preserved, reinjected")
	return cmd
}

func printContext(w io.Writer, s *transcript.Session, cb transcript.ContextBreakdown) {
	a := s.Actions[cb.Action]
	fmt.Fprintf(w, "Context of action %d (turn %d)  %s  %s\n", cb.Action, cb.Turn, localTime(a.At), a.Model)
	u := cb.Usage
	fmt.Fprintf(w, "Reported by the API   input %s · cache creation %s · cache read %s · total %s tokens\n",
		stats.FormatTokens(u.InputTokens), stats.FormatTokens(u.CacheCreationInputTokens), stats.FormatTokens(u.CacheReadInputTokens), stats.FormatTokens(cb.ReportedTokens))
	if !cb.Available {
		fmt.Fprintf(w, "Request records       unavailable: %s\n", cb.Reason)
	} else {
		fmt.Fprintf(w, "Estimated from text   ~%s tokens (chars ÷ 4; JSON schemas tokenize worse, so the estimate runs low)\n", stats.FormatTokens(cb.EstimatedTokens))
	}
	fmt.Fprintln(w)
	if cb.Available {
		sysChars := 0
		for _, p := range cb.System {
			sysChars += p.Chars
		}
		fmt.Fprintf(w, "System prompt         %d blocks · %s chars · ~%s tok\n", len(cb.System), commas(sysChars), stats.FormatTokens(transcript.EstimateTokens(sysChars)))
		for _, p := range cb.System {
			fmt.Fprintf(w, "  ~%-6s %s\n", stats.FormatTokens(transcript.EstimateTokens(p.Chars)), truncate(p.Head, 110))
		}
		names := make([]string, 0, len(cb.Tools))
		for _, t := range cb.Tools {
			names = append(names, t.Name)
		}
		fmt.Fprintf(w, "Tool definitions      %d tools · %s chars · ~%s tok\n  %s\n", len(cb.Tools), commas(cb.ToolsChars), stats.FormatTokens(transcript.EstimateTokens(cb.ToolsChars)), truncate(strings.Join(names, ", "), 120))
		fmt.Fprintf(w, "Messages in request   %d new · %d kept from the previous request\n", len(cb.Messages), cb.Keep)
		for _, m := range cb.Messages {
			fmt.Fprintf(w, "  %-9s %s chars · ~%s tok\n", m.Role, commas(m.Chars), stats.FormatTokens(transcript.EstimateTokens(m.Chars)))
			for _, b := range m.Blocks {
				label := b.Type
				if b.Label != "" {
					label += " · " + b.Label
				}
				fmt.Fprintf(w, "     %-38s %7s chars  %s\n", truncate(label, 38), commas(b.Chars), truncate(b.Head, 70))
			}
		}
		if len(cb.CacheBreaks) > 0 {
			fmt.Fprintf(w, "Cache breakpoints     %s\n", strings.Join(cb.CacheBreaks, " · "))
		}
	}
	attChars := 0
	for _, p := range cb.Attachments {
		attChars += p.Chars
	}
	fmt.Fprintf(w, "Injected this action  %d attachments · %s chars · ~%s tok\n", len(cb.Attachments), commas(attChars), stats.FormatTokens(transcript.EstimateTokens(attChars)))
	sorted := append([]transcript.AttachmentPart(nil), cb.Attachments...)
	sort.SliceStable(sorted, func(i, j int) bool { return sorted[i].Chars > sorted[j].Chars })
	for _, p := range sorted {
		note := ""
		if p.Type == "instructions" || p.Type == "nested_memory" {
			note = "  ← CLAUDE.md"
		}
		fmt.Fprintf(w, "  %-26s %7s chars → %s%s\n", p.Type, commas(p.Chars), p.Role, note)
	}
	fmt.Fprintln(w, "\nUse --show <component> to print one in full: system, tools, messages, attachments, instructions, or an attachment type.")
}

func printComponent(w io.Writer, cb transcript.ContextBreakdown, which string) error {
	switch which {
	case "system":
		for i, p := range cb.System {
			fmt.Fprintf(w, "══ system block %d (%s chars) ══\n%s\n\n", i, commas(p.Chars), p.Text)
		}
	case "tools":
		for _, t := range cb.Tools {
			fmt.Fprintf(w, "══ %s (%s chars) ══\n%s\n\n", t.Name, commas(t.Chars), t.Text)
		}
	case "messages":
		for i, m := range cb.Messages {
			fmt.Fprintf(w, "══ message %d · %s (%s chars) ══\n", i, m.Role, commas(m.Chars))
			for _, b := range m.Blocks {
				fmt.Fprintf(w, "── %s %s ──\n%s\n\n", b.Type, b.Label, b.Text)
			}
		}
	case "attachments":
		for _, p := range cb.Attachments {
			fmt.Fprintf(w, "══ %s → %s (%s chars) ══\n%s\n\n", p.Type, p.Role, commas(p.Chars), p.Text)
		}
	default:
		found := false
		for _, p := range cb.Attachments {
			if p.Type == which {
				found = true
				fmt.Fprintf(w, "══ %s → %s (%s chars) ══\n%s\n\n", p.Type, p.Role, commas(p.Chars), p.Text)
			}
		}
		if !found {
			for _, m := range cb.Messages {
				for _, b := range m.Blocks {
					if which == "instructions" && strings.HasPrefix(b.Label, "CLAUDE.md") {
						found = true
						fmt.Fprintf(w, "══ %s · %s ══\n%s\n\n", m.Role, b.Label, b.Text)
					}
				}
			}
		}
		if !found {
			return fmt.Errorf("no component %q; try system, tools, messages, attachments, instructions, or an attachment type", which)
		}
	}
	return nil
}

func commas(n int) string {
	s := fmt.Sprint(n)
	if len(s) <= 3 {
		return s
	}
	var out []byte
	for i, c := range []byte(s) {
		if i > 0 && (len(s)-i)%3 == 0 {
			out = append(out, ',')
		}
		out = append(out, c)
	}
	return string(out)
}

func printCompaction(w io.Writer, s *transcript.Session, d transcript.CompactionDetail) {
	fmt.Fprintf(w, "Compaction %d (turn %d)  %s  trigger %s  %d ms\n", d.Index, d.Turn, localTime(d.At), d.Trigger, d.DurationMs)
	before := "no action before"
	if d.LastActionBefore != nil {
		before = fmt.Sprintf("action %d reported %s tokens", *d.LastActionBefore, stats.FormatTokens(d.ContextBefore))
	}
	fmt.Fprintf(w, "Before    %s; Claude Code counted %s before compacting; %s dropped so far in this session\n", before, stats.FormatTokens(d.PreTokens), stats.FormatTokens(d.CumulativeDropped))
	fmt.Fprintf(w, "After     %s tokens remained: the summary (%s chars, ~%s tok, %d sections) + %d preserved messages; %d prompts folded into the summary\n",
		stats.FormatTokens(d.PostTokens), commas(d.Summary.Chars), stats.FormatTokens(transcript.EstimateTokens(d.Summary.Chars)), len(d.Summary.Sections), len(d.Preserved), d.SummarisedPrompts)
	if d.FirstActionAfter != nil {
		fmt.Fprintf(w, "Next      action %d reported %s tokens: summary + preserved + %s chars re-injected (~%s tok) + system prompt + tool definitions\n",
			*d.FirstActionAfter, stats.FormatTokens(d.ContextAfter), commas(d.ReinjectedChars), stats.FormatTokens(transcript.EstimateTokens(d.ReinjectedChars)))
	}
	if len(d.Summary.Sections) > 0 {
		fmt.Fprintln(w, "\nSummary sections")
		for _, sec := range d.Summary.Sections {
			fmt.Fprintf(w, "  %7s chars  %s\n", commas(sec.Chars), sec.Title)
		}
	}
	if len(d.Preserved) > 0 {
		fmt.Fprintln(w, "\nPreserved verbatim")
		for _, p := range d.Preserved {
			where := ""
			if p.Action >= 0 {
				where = fmt.Sprintf("action %d", p.Action)
			} else if p.Turn >= 0 {
				where = fmt.Sprintf("turn %d", p.Turn)
			}
			fmt.Fprintf(w, "  %-10s %-16s %-10s %7s chars  %s\n", p.Type, p.Kind, where, commas(p.Chars), truncate(p.Head, 70))
		}
	}
	if len(d.Reinjected) > 0 {
		fmt.Fprintln(w, "\nRe-injected after the boundary")
		for _, p := range d.Reinjected {
			note := ""
			if p.Type == "instructions" {
				note = "  ← CLAUDE.md"
			}
			fmt.Fprintf(w, "  %-26s %7s chars → %s%s\n", p.Type, commas(p.Chars), p.Role, note)
		}
	}
	if len(d.FileRefs) > 0 {
		fmt.Fprintf(w, "\nFiles re-read after compacting\n  %s\n", strings.Join(d.FileRefs, "\n  "))
	}
	fmt.Fprintln(w, "\nUse --show summary, --show preserved or --show reinjected to print the texts; --action N --show … for the action after.")
}

func printCompactionComponent(w io.Writer, d transcript.CompactionDetail, which string) error {
	switch which {
	case "summary":
		fmt.Fprintln(w, d.Summary.Text)
	case "preserved":
		for _, p := range d.Preserved {
			fmt.Fprintf(w, "══ %s %s (%s chars) ══\n%s\n\n", p.Type, p.Kind, commas(p.Chars), p.Text)
		}
	case "reinjected":
		for _, p := range d.Reinjected {
			fmt.Fprintf(w, "══ %s → %s (%s chars) ══\n%s\n\n", p.Type, p.Role, commas(p.Chars), p.Text)
		}
	default:
		return fmt.Errorf("no compaction component %q; try summary, preserved or reinjected", which)
	}
	return nil
}
