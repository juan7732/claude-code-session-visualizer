package cli

import (
	"fmt"
	"io"
	"os"
	"slices"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/archive"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/primitives"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/stats"
)

func newPrimitives() *cobra.Command {
	var days int
	var unused bool
	var roots []string
	cmd := &cobra.Command{
		Use:   "primitives [kind [name]]",
		Short: "Skills, agents, commands, connectors, hooks, plugins, memory: what is installed where, and how much it is used",
		Long: `primitives lists what Claude Code is extended with on this machine and how
much each is used.

Installed: every definition found for the user (~/.claude), from the claude.ai
account, in an installed plugin, and in each project a session started in or
Claude Code remembers (their .claude folders, .mcp.json and CLAUDE.md, and the
folders up to two levels below them). A name defined in more than one place
lists its definitions in the order Claude Code prefers them.

Used: counted from the archived sessions (skit archive), not from Claude
Code's own counter, which is shown beside it for skills. A skill counts when
the model called it and when you typed it as a slash command; an agent by the
type that was spawned; a connector by calls to its tools; a memory file when
it was loaded. Sessions also record what they had on offer, so something that
was there and never used can be told from something that was never there.

kind is one of skill, agent, command, connector, hook, plugin, instructions,
memory. With a name too, one item is printed with the sessions that used it.
--days counts only the last N days. --unused keeps what was installed or on
offer and not used. A connector's arguments, environment and headers are never
read out; memory files are listed, never printed.`,
		Example: "  skit primitives\n  skit primitives skill --days 30\n  skit primitives skill cruise\n  skit primitives --unused --json | jq -r '.items[] | \"\\(.kind) \\(.name)\"'",
		Args:    cobra.MaximumNArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			opt := primitives.Options{Unused: unused}
			if len(args) > 0 {
				opt.Kind = strings.TrimSuffix(strings.ToLower(args[0]), "s")
				if opt.Kind == "instruction" {
					opt.Kind = "instructions"
				}
				if !slices.Contains(primitives.Kinds, opt.Kind) {
					return fmt.Errorf("unknown kind %q: one of %s", args[0], strings.Join(primitives.Kinds, ", "))
				}
			}
			if len(args) > 1 {
				opt.Name = args[1]
			}
			if days > 0 {
				opt.Since = time.Now().AddDate(0, 0, -days)
			}
			dir, err := catalog.Dir()
			if err != nil {
				return err
			}
			a, err := archive.Open()
			if err != nil {
				return err
			}
			defer a.Close()
			rep, err := primitives.Read(a.Store, primitives.Places{ClaudeDir: dir, Managed: primitives.ManagedDir, Dirs: roots}, opt)
			if err != nil {
				return err
			}
			if opt.Name != "" && len(rep.Items) == 0 {
				return fmt.Errorf("no %s named %q is installed, on offer or used in an archived session", opt.Kind, opt.Name)
			}
			if jsonWanted(cmd) {
				return writeJSON(cmd.OutOrStdout(), rep)
			}
			if opt.Name != "" {
				printPrimitive(cmd.OutOrStdout(), rep.Items[0])
				return nil
			}
			printPrimitives(cmd.OutOrStdout(), rep, days)
			return nil
		},
	}
	cmd.Flags().IntVar(&days, "days", 0, "count only uses in the last N days (0: every session kept)")
	cmd.Flags().BoolVar(&unused, "unused", false, "only what is installed or on offer and was not used")
	cmd.Flags().StringArrayVar(&roots, "root", nil, "also look in this project directory (repeatable)")
	return cmd
}

func printPrimitives(w io.Writer, rep *primitives.Report, days int) {
	window := "every session kept"
	if days > 0 {
		window = fmt.Sprintf("the last %d day%s", days, plural(days))
	}
	fmt.Fprintf(w, "Primitives  %d session%s, %s\n\n", rep.Sessions, plural(rep.Sessions), window)
	fmt.Fprintf(w, "  %-13s %6s %10s %6s %7s\n", "kind", "known", "installed", "used", "unused")
	for _, k := range rep.Kinds {
		un := fmt.Sprint(k.Unused)
		if k.Kind == "hook" || k.Kind == primitives.KindPlugin {
			un = "-"
		}
		fmt.Fprintf(w, "  %-13s %6d %10d %6d %7s\n", k.Kind, k.Items, k.Installed, k.Used, un)
	}
	kind := ""
	for _, it := range rep.Items {
		if it.Kind != kind {
			kind = it.Kind
			fmt.Fprintf(w, "\n%s\n", strings.ToUpper(kind[:1])+kind[1:])
		}
		name := it.Name
		if it.Title != "" {
			name = it.Title
		}
		if it.Kind == "instructions" || it.Kind == "memory" {
			// A path is told apart by its end.
			if r := []rune(tildePath(name)); len(r) > 34 {
				name = "…" + string(r[len(r)-33:])
			} else {
				name = string(r)
			}
		}
		fmt.Fprintf(w, "  %-34s %-26s %s\n", truncate(name, 34), truncate(placeOf(it), 26), useLine(it))
	}
}

// placeOf says where an item is defined, in a few words.
func placeOf(it primitives.Item) string {
	switch {
	case len(it.Definitions) == 0 && it.BuiltIn:
		return "built in"
	case len(it.Definitions) == 0:
		return "not on disk"
	}
	d := it.Definitions[0]
	place := d.Scope
	if d.Where != "" {
		place += " " + shortWhere(d.Where)
	}
	if n := len(it.Definitions); n > 1 {
		place += fmt.Sprintf(" +%d", n-1)
	}
	return place
}

func shortWhere(where string) string {
	parts := strings.Split(strings.TrimRight(where, "/"), "/")
	if len(parts) > 2 {
		parts = parts[len(parts)-2:]
	}
	return strings.Join(parts, "/")
}

func tildePath(p string) string {
	if h, err := os.UserHomeDir(); err == nil && strings.HasPrefix(p, h+"/") {
		return "~" + p[len(h):]
	}
	return p
}

func useLine(it primitives.Item) string {
	u := it.Usage
	var parts []string
	switch {
	case u.Calls > 0:
		s := fmt.Sprintf("%d use%s in %d session%s", u.Calls, plural(u.Calls), u.Sessions, plural(u.Sessions))
		if u.ByUser > 0 {
			s += fmt.Sprintf(" (%d typed)", u.ByUser)
		}
		parts = append(parts, s)
		if u.Errors > 0 {
			parts = append(parts, fmt.Sprintf("%d failed", u.Errors))
		}
		if u.LastAt != nil {
			parts = append(parts, "last "+localTime(*u.LastAt))
		}
	case it.LastUsedAt != nil:
		parts = append(parts, "not used in this window, last "+localTime(*it.LastUsedAt))
	case it.Kind == "hook" || it.Kind == primitives.KindPlugin:
	default:
		parts = append(parts, "never used")
	}
	if u.OfferedSessions > 0 && u.Calls == 0 {
		parts = append(parts, fmt.Sprintf("on offer in %d session%s", u.OfferedSessions, plural(u.OfferedSessions)))
	}
	if c := it.Counter; c != nil && c.Uses > 0 {
		parts = append(parts, fmt.Sprintf("Claude Code counts %d", c.Uses))
	}
	return strings.Join(parts, " · ")
}

func printPrimitive(w io.Writer, it primitives.Item) {
	name := it.Name
	if it.Title != "" {
		name = it.Title + " (" + it.Name + ")"
	}
	fmt.Fprintf(w, "%s  %s\n", strings.ToUpper(it.Kind[:1])+it.Kind[1:], name)
	if it.Description != "" {
		fmt.Fprintf(w, "  %s\n", truncate(it.Description, 200))
	}
	fmt.Fprintln(w)
	switch {
	case len(it.Definitions) == 0 && it.BuiltIn:
		fmt.Fprintln(w, "Defined   nowhere on disk: built into Claude Code")
	case len(it.Definitions) == 0:
		fmt.Fprintln(w, "Defined   nowhere on disk: it comes with Claude Code, or it was there once and is gone")
	default:
		orderWords := map[string]string{"user-first": "where two apply, the first listed wins (managed, user, project)",
			"project-first": "where two apply, the first listed wins (managed, project, user, plugin)",
			"local-first":   "where two apply, the first listed wins (local, project, user, plugin, account)",
			"merged":        "all of them apply"}
		fmt.Fprintf(w, "Defined   in %d place%s", len(it.Definitions), plural(len(it.Definitions)))
		if len(it.Definitions) > 1 {
			fmt.Fprintf(w, "; %s", orderWords[it.Order])
		}
		fmt.Fprintln(w)
		for _, d := range it.Definitions {
			line := fmt.Sprintf("  %-8s %s", d.Scope, tildePath(d.Path))
			if d.Path == "" {
				line = fmt.Sprintf("  %-8s %s", d.Scope, d.Where)
			}
			if d.Lines > 0 {
				// A file of its own: how much it adds to what the model reads.
				line += fmt.Sprintf("  %s, %d line%s", humanBytes(d.Bytes), d.Lines, plural(d.Lines))
			}
			if d.Calls > 0 {
				line += fmt.Sprintf("  (%d use%s of this one)", d.Calls, plural(d.Calls))
			}
			fmt.Fprintln(w, line)
			for _, k := range []string{"event", "matcher", "command", "transport", "host", "program", "version", "enabled"} {
				if v := d.Detail[k]; v != "" {
					fmt.Fprintf(w, "           %s: %s\n", k, truncate(v, 100))
				}
			}
		}
	}
	u := it.Usage
	fmt.Fprintf(w, "\nUsed      %s\n", useLine(it))
	if u.OfferedSessions > 0 {
		fmt.Fprintf(w, "On offer  in %d session%s\n", u.OfferedSessions, plural(u.OfferedSessions))
	}
	if u.Seconds > 0 {
		fmt.Fprintf(w, "Time      %s", stats.FormatDuration(time.Duration(u.Seconds*float64(time.Second))))
		if u.OutputTokens > 0 {
			fmt.Fprintf(w, " · output %s", stats.FormatTokens(u.OutputTokens))
		}
		fmt.Fprintln(w)
	}
	if len(u.Projects) > 0 {
		fmt.Fprintln(w, "\nBy project")
		for _, p := range u.Projects {
			fmt.Fprintf(w, "  %-44s %3d session%s %5d use%s\n", truncate(p.Project, 44), p.Sessions, plural(p.Sessions), p.Calls, plural(p.Calls))
		}
	}
	if len(it.Sessions) > 0 {
		fmt.Fprintf(w, "\nSessions (%d), latest first\n", len(it.Sessions))
		for _, s := range it.Sessions {
			at := ""
			if s.Turn >= 0 {
				at = fmt.Sprintf("turn %d", s.Turn)
			}
			fmt.Fprintf(w, "  %s  %-16s %4d use%s %-9s %s\n", s.Session[:min(8, len(s.Session))], localTime(s.LastAt), s.Calls, plural(s.Calls), at, truncate(s.Title, 56))
		}
	}
}
