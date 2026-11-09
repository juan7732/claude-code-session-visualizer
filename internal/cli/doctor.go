package cli

import (
	"fmt"
	"io"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/cache"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
)

func newDoctor() *cobra.Command {
	return &cobra.Command{
		Use:   "doctor",
		Short: "Report where Claude Code keeps sessions and what skit can see",
		Long: `doctor inspects the Claude Code data directory ($CLAUDE_CONFIG_DIR or ~/.claude):
projects, session files, subagents, live sessions, disk use, and the retention
setting that decides when Claude Code deletes transcripts.`,
		Example: "  skit doctor\n  skit doctor --json | jq .retention",
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			rep, err := catalog.Inspect()
			if err != nil {
				return err
			}
			if jsonWanted(cmd) {
				return writeJSON(cmd.OutOrStdout(), rep)
			}
			printDoctor(cmd.OutOrStdout(), rep)
			return nil
		},
	}
}

func printDoctor(w io.Writer, r *catalog.Report) {
	fmt.Fprintf(w, "Claude Code data   %s", r.ClaudeDir)
	if !r.Exists {
		fmt.Fprintln(w, "  (not found)")
		for _, warn := range r.Warnings {
			fmt.Fprintln(w, "warning:", warn)
		}
		return
	}
	fmt.Fprintln(w)
	fmt.Fprintf(w, "Retention          cleanupPeriodDays = %d (%s): transcripts older than this are deleted when Claude Code starts\n",
		r.Retention.CleanupPeriodDays, r.Retention.Source)
	fmt.Fprintf(w, "Sessions           %d in %d projects (%d orphaned, %d superseded), %d subagent transcripts, %s on disk\n",
		r.Totals.Sessions, len(r.Projects), r.Totals.Orphaned, r.Totals.Superseded, r.Totals.Subagents, humanBytes(r.Totals.Bytes))
	fmt.Fprintf(w, "Live sessions      %d\n", len(r.Live))
	for _, l := range r.Live {
		fmt.Fprintf(w, "  pid %-6d %-5s %-24s %s  (Claude Code %s)\n", l.PID, l.Status, l.Name, l.Cwd, l.Version)
	}
	if dir, err := cache.Dir(); err == nil {
		files, bytes := cache.SizeAt(dir)
		fmt.Fprintf(w, "skit home          %s   (summary cache: %d entries, %s)\n", dir, files, humanBytes(bytes))
	}
	if len(r.Projects) > 0 {
		fmt.Fprintln(w, "Projects")
		for _, p := range r.Projects {
			fmt.Fprintf(w, "  %-52s %3d sessions  %8s\n", p.Slug, len(p.Sessions), humanBytes(p.Bytes()))
		}
	}
	for _, warn := range r.Warnings {
		fmt.Fprintln(w, "warning:", warn)
	}
}

func humanBytes(n int64) string {
	const unit = 1000
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for n/div >= unit && exp < 3 {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(n)/float64(div), "kMGT"[exp])
}
