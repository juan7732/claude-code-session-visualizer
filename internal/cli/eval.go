package cli

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"slices"
	"strings"
	"syscall"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/archive"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/search"
)

func newEval() *cobra.Command {
	var modes []string
	var misses bool
	var knobs search.Options
	cmd := &cobra.Command{
		Use:   "eval <queries.json>",
		Short: "Measure search against queries whose answers are known",
		Long: `eval runs every query of a file through search and reports how often the turn
it should find comes first (R@1), in the first five (R@5) and in the first ten
(R@10), with the mean reciprocal rank (MRR), per mode and per tag. It is how a
change to search is judged: the same file before and after.

The file is JSON:

  {"queries": [
    {"q": "why does my history vanish after a month", "expect": ["36086585@12"], "tag": "paraphrase"},
    {"q": "ENOTFOUND", "expect": ["36086585@40-42", "9cb29ba2"], "tag": "lookup"},
    {"q": "a recipe for dinner", "expect": [], "tag": "nothing"}
  ]}

A target is a session id or a unique prefix of one, then @N for an agent turn
(as 'skit show <id> --turn N' numbers them) or @A-B for a range; without @, any
hit in that session counts. Reaching any one target is enough. Places are
counted in distinct turns, so several hits from one turn take one place. A
query with an empty "expect" should find nothing: eval reports how many of
those were answered anyway, per tag. Tag them "nothing" when the archive has
nothing on the subject and "near-miss" when it has something next to it, so
that related hits for a near miss are not counted against the gate.

Beside "queries" the file may hold "exclude": a list of session id prefixes
whose hits are dropped before anything is counted. Put the sessions in which
the queries were written there: they quote every query word for word. A query
may carry a "note" for whoever maintains the file; it is not scored.

Every target must be an archived session, or eval stops before running.
--misses lists the queries whose answer did not come first.

The remaining flags are search's own (--no-tools, --kind, --all, --min-cosine,
--min-z), applied to every query, so two settings can be compared by running
the same file twice.`,
		Example: "  skit eval queries.json\n  skit eval queries.json --mode keyword --misses\n  skit eval queries.json --mode meaning --min-cosine 0.75\n  skit eval queries.json --json | jq '.modes[] | {mode, overall}'",
		Args:    cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			for _, m := range modes {
				if !slices.Contains(search.Modes, m) {
					return fmt.Errorf("unknown mode %q (one of: %s)", m, strings.Join(search.Modes, ", "))
				}
			}
			data, err := os.ReadFile(args[0])
			if err != nil {
				return err
			}
			a, err := archive.Open()
			if err != nil {
				return err
			}
			defer a.Close()
			ev, err := search.LoadEval(a.Store, data)
			if err != nil {
				return err
			}
			e := newEmbedder(a.Home, false) // starts nothing unless a meaning query runs
			defer e.Close()
			ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
			defer stop()
			rep, err := ev.Run(ctx, modes, func(ctx context.Context, q string, opt search.Options) ([]search.Hit, error) {
				opt.NoTools, opt.Kinds = knobs.NoTools, knobs.Kinds
				opt.NoGate, opt.MinCosine, opt.MinZ = knobs.NoGate, knobs.MinCosine, knobs.MinZ
				hits, err := search.Search(ctx, a.Store, e, q, opt)
				return hits, meaningAdvice(err)
			})
			if err != nil {
				return err
			}
			if jsonWanted(cmd) {
				return writeJSON(cmd.OutOrStdout(), rep)
			}
			w := cmd.OutOrStdout()
			fmt.Fprintf(w, "%d queries, places counted in distinct turns down to %d\n\n", rep.Queries, rep.Depth)
			fmt.Fprintf(w, "%-9s %-16s %4s  %5s  %5s  %5s  %5s\n", "mode", "tag", "n", "R@1", "R@5", "R@10", "MRR")
			for _, m := range rep.Modes {
				for _, s := range append([]search.EvalScore{m.Overall}, m.Tags...) {
					fmt.Fprintf(w, "%-9s %-16s %4d  %5.2f  %5.2f  %5.2f  %5.2f\n", m.Mode, truncate(s.Tag, 16), s.N, s.R1, s.R5, s.R10, s.MRR)
				}
			}
			// Queries with no expected answer, by tag: "nothing" is the gate's
			// test; a "near-miss" that gets related hits is not its failure.
			for _, m := range rep.Modes {
				for _, n := range m.NothingTags {
					fmt.Fprintf(w, "\n%s: %d of %d %q queries (no answer expected) got one", m.Mode, n.Answered, n.N, n.Tag)
				}
			}
			if rep.Modes[0].Nothing.N > 0 {
				fmt.Fprintln(w)
			}
			if misses {
				for _, m := range rep.Modes {
					fmt.Fprintf(w, "\n%s, answer not first:\n", m.Mode)
					none := true
					for _, o := range m.Outcomes {
						if len(o.Expect) == 0 || o.Rank == 1 {
							continue
						}
						none = false
						place := fmt.Sprintf("not in top %d", rep.Depth)
						if o.Rank > 1 {
							place = fmt.Sprintf("place %d", o.Rank)
						}
						first := "no hits"
						if o.Top != "" {
							first = "first was " + o.Top
							if o.TopCosine != 0 {
								first += fmt.Sprintf(" (cos %.2f, z %.1f)", o.TopCosine, o.TopZ)
							}
						}
						fmt.Fprintf(w, "  %-16s %s\n  %-16s want %s · %s\n", place, truncate(o.Q, 90), "", strings.Join(o.Expect, ", "), first)
					}
					if none {
						fmt.Fprintln(w, "  none")
					}
				}
			}
			return nil
		},
	}
	cmd.Flags().StringSliceVar(&modes, "mode", search.Modes, "modes to measure, comma-separated: "+strings.Join(search.Modes, ", "))
	cmd.Flags().BoolVar(&misses, "misses", false, "list the queries whose expected turn did not come first, with what did")
	cmd.Flags().StringSliceVar(&knobs.Kinds, "kind", nil, "search only these kinds, comma-separated: "+strings.Join(search.Kinds, ", "))
	cmd.Flags().BoolVar(&knobs.NoTools, "no-tools", false, "search without tool calls and their results")
	cmd.Flags().BoolVar(&knobs.NoGate, "all", false, "meaning mode without its gate")
	cmd.Flags().Float64Var(&knobs.MinCosine, "min-cosine", 0, fmt.Sprintf("meaning mode: a passage matches at this cosine (default %.2f)", search.DefaultMinCosine))
	cmd.Flags().Float64Var(&knobs.MinZ, "min-z", 0, "meaning mode: also let a passage through at this z (off by default)")
	return cmd
}
