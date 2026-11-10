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

--mode meaning finds text that says what the query says, whether or not it uses
the same words: write the query as you would ask it. It covers prompts, replies,
thinking and compaction summaries (run 'skit embed' first), starts a local
llama-server for the query, and sends nothing off the machine. Each hit shows
the cosine similarity of its closest passage and z, how far that stands above
everything else for this query. In this mode the nearest passages are always
returned, even when nothing in the archive is about the query: a low z (under
about 3) is the sign of that.`,
		Example: "  skit search retention sweep\n  skit search ENOTFOUND --kind assistant\n  skit search zstd --project tools --json\n  skit search --mode meaning why does my history disappear after a month",
		Args:    cobra.MinimumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			a, err := archive.Open()
			if err != nil {
				return err
			}
			defer a.Close()
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
				if h.Match == search.ModeMeaning {
					fmt.Fprintf(w, "  %-20s %-12s cos %.2f  z %4.1f  %s\n", where, truncate(kind, 12), h.Cosine, h.Z, truncate(h.Snippet, 100))
					continue
				}
				fmt.Fprintf(w, "  %-20s %-22s %s\n", where, truncate(kind, 22), truncate(h.Snippet, 100))
			}
			return nil
		},
	}
	cmd.Flags().StringVar(&opt.Mode, "mode", search.ModeKeyword, "keyword (the words) or meaning (what it says; needs `skit embed`)")
	cmd.Flags().IntVarP(&opt.Limit, "limit", "n", 20, "maximum hits")
	cmd.Flags().StringVarP(&opt.Project, "project", "p", "", "only projects whose slug contains this text")
	cmd.Flags().StringVar(&opt.Session, "session", "", "only this session id")
	cmd.Flags().StringVar(&opt.Kind, "kind", "", "only this kind: prompt, assistant, thinking, tool_use, tool_result, context, summary")
	cmd.Flags().BoolVar(&opt.PrefixLast, "prefix", false, "treat the last word as a prefix (while typing)")
	return cmd
}
