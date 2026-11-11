package cli

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/archive"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/search"
)

func newSearch() *cobra.Command {
	var opt search.Options
	cmd := &cobra.Command{
		Use:   "search <words...>",
		Short: "Find turns across archived sessions, by their words or by meaning",
		Long: `search looks through every archived session (run 'skit archive' first) for the
words given: prompts, replies, thinking, tool calls and their results, injected
context and compaction summaries. Results are grouped by session and point at
the agent turn and action to open with 'skit show <id> --turn N' or '--action N'. A query made of ids or codes
("E1234", "toolu_01abc") weighs exact words more heavily.

A version, a date or a numbered name ("0.5.1", "2026-11-10", "issue-3") is
searched whole. Common words ("how", "did", "the") are ignored, so a question
can be typed as it comes.

--mode meaning finds text that says what the query says, whether or not it uses
the same words: write the query as you would ask it. It covers prompts, replies,
thinking and compaction summaries (run 'skit embed' first), starts a local
llama-server for the query, and sends nothing off the machine. Each hit shows
the cosine similarity of its closest passage and z, how far that stands above
everything else for this query. A passage is a match when its cosine reaches a
threshold; when none does, the answer is that nothing was found, not the
nearest passages. A query that is only an id or a version matches a passage
only if the passage contains it. --all shows the nearest passages anyway;
--min-cosine moves the threshold, and --min-z lets a passage through on z too.

--mode hybrid gives both: first the passages close in meaning, nearest first,
then the keyword hits that are not among them. A hit says which it is
(meaning, both, or keyword). When nothing is close in meaning, what is left is
keyword hits only.

Narrowing works the same in every mode: --session (an id or a unique prefix),
--project, --kind (one or several, comma-separated) and --no-tools, which
leaves out tool calls and their results.`,
		Example: "  skit search retention sweep\n  skit search ENOTFOUND --kind assistant\n  skit search zstd --project tools --no-tools --json\n  skit search --mode meaning why does my history disappear after a month\n  skit search --mode meaning --session 36086585 --kind prompt,assistant how sessions are stored",
		Args:    cobra.MinimumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			a, err := archive.Open()
			if err != nil {
				return err
			}
			defer a.Close()
			if opt.Session != "" {
				// Like every other command, a unique prefix of the id is enough.
				rows, err := a.Store.SessionsByPrefix(opt.Session)
				if err != nil {
					return err
				}
				switch len(rows) {
				case 0:
					return fmt.Errorf("no archived session starts with %q", opt.Session)
				case 1:
					opt.Session = rows[0].ID
				default:
					return fmt.Errorf("%d archived sessions start with %q; use more of the id", len(rows), opt.Session)
				}
			}
			e := newEmbedder(a.Home, false) // starts nothing unless the mode needs it
			defer e.Close()
			// Interruptible, so a sidecar started for the query is stopped on the way out.
			ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
			defer stop()
			hits, err := search.Search(ctx, a.Store, e, strings.Join(args, " "), opt)
			if err != nil {
				return meaningAdvice(err)
			}
			if jsonWanted(cmd) {
				if hits == nil {
					hits = []search.Hit{}
				}
				return writeJSON(cmd.OutOrStdout(), hits)
			}
			w := cmd.OutOrStdout()
			if len(hits) == 0 && opt.Mode == search.ModeMeaning && !opt.NoGate {
				fmt.Fprintln(w, "nothing in the archive is close to this (--all shows the nearest passages anyway)")
				return nil
			}
			if len(hits) == 0 {
				fmt.Fprintln(w, "no matches (is the session archived? see `skit archive`)")
				return nil
			}
			last := ""
			for _, h := range hits {
				if h.Session != last {
					fmt.Fprintf(w, "\n%s  %s  (%s)\n", h.Session[:8], truncate(h.Title, 60), truncate(h.Project, 40))
					last = h.Session
				}
				where := "session"
				if h.Turn >= 0 {
					where = fmt.Sprintf("turn %d", h.Turn)
				}
				if h.Action >= 0 {
					where += fmt.Sprintf(" · action %d", h.Action)
				}
				if h.Agent != "" {
					where += " · agent " + h.Agent[:8]
				}
				kind := h.Kind
				if h.Tool != "" {
					kind += ":" + h.Tool
				}
				if h.Match == search.ModeMeaning || h.Match == search.MatchBoth {
					fmt.Fprintf(w, "  %-20s %-12s cos %.2f  z %4.1f  %s\n", where, truncate(kind, 12), h.Cosine, h.Z, truncate(h.Snippet, 100))
					continue
				}
				fmt.Fprintf(w, "  %-20s %-22s %s\n", where, truncate(kind, 22), truncate(h.Snippet, 100))
			}
			return nil
		},
	}
	cmd.Flags().StringVar(&opt.Mode, "mode", search.ModeKeyword, "keyword (the words), meaning (what it says; needs `skit embed`) or hybrid (meaning first, then the words)")
	cmd.Flags().IntVarP(&opt.Limit, "limit", "n", 20, "maximum hits")
	cmd.Flags().StringVarP(&opt.Project, "project", "p", "", "only projects whose slug contains this text")
	cmd.Flags().StringVar(&opt.Session, "session", "", "only this session (id or unique prefix)")
	cmd.Flags().StringSliceVar(&opt.Kinds, "kind", nil, "only these kinds, comma-separated: "+strings.Join(search.Kinds, ", "))
	cmd.Flags().BoolVar(&opt.NoTools, "no-tools", false, "leave out tool calls and their results")
	cmd.Flags().BoolVar(&opt.NoGate, "all", false, "meaning mode: return the nearest passages even when none is close enough to be a match")
	cmd.Flags().Float64Var(&opt.MinCosine, "min-cosine", 0, fmt.Sprintf("meaning mode: a passage matches at this cosine (default %.2f)", search.DefaultMinCosine))
	cmd.Flags().Float64Var(&opt.MinZ, "min-z", 0, "meaning mode: also let a passage through at this z (off by default)")
	cmd.Flags().BoolVar(&opt.PrefixLast, "prefix", false, "treat the last word as a prefix (while typing)")
	return cmd
}
