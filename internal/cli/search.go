package cli

import (
	"fmt"
	"strings"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/archive"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/search"
)

func newSearch() *cobra.Command {
	var opt search.Options
	cmd := &cobra.Command{
		Use:   "search <words...>",
		Short: "Find turns across archived sessions by keyword",
		Long: `search looks through every archived session (run 'skit archive' first) for the
words given: prompts, replies, thinking, tool calls and their results, injected
context and compaction summaries. Results are grouped by session and point at
the turn to open with 'skit show <id> --turn N'. A query made of ids or codes
("E1234", "toolu_01abc") weighs exact words more heavily.`,
		Example: "  skit search retention sweep\n  skit search ENOTFOUND --kind assistant\n  skit search zstd --project tools --json",
		Args:    cobra.MinimumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			a, err := archive.Open()
			if err != nil {
				return err
			}
			defer a.Close()
			hits, err := search.Run(a.Store, strings.Join(args, " "), opt)
			if err != nil {
				return err
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
				where := "prompt"
				if h.Turn >= 0 {
					where = fmt.Sprintf("turn %d", h.Turn)
				}
				if h.Agent != "" {
					where += " · agent " + h.Agent[:8]
				}
				kind := h.Kind
				if h.Tool != "" {
					kind += ":" + h.Tool
				}
				fmt.Fprintf(w, "  %-12s %-22s %s\n", where, truncate(kind, 22), truncate(h.Snippet, 100))
			}
			return nil
		},
	}
	cmd.Flags().IntVarP(&opt.Limit, "limit", "n", 20, "maximum hits")
	cmd.Flags().StringVarP(&opt.Project, "project", "p", "", "only projects whose slug contains this text")
	cmd.Flags().StringVar(&opt.Session, "session", "", "only this session id")
	cmd.Flags().StringVar(&opt.Kind, "kind", "", "only this kind: prompt, assistant, thinking, tool_use, tool_result, context, summary")
	cmd.Flags().BoolVar(&opt.PrefixLast, "prefix", false, "treat the last word as a prefix (while typing)")
	return cmd
}
