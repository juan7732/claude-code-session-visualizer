package cli

import (
	"fmt"
	"io"
	"os"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/archive"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/home"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/service"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/store"
)

// doctorReport is what `skit doctor --json` prints: the catalog report plus
// whether anything keeps the archive current.
type doctorReport struct {
	*catalog.Report
	Archiver archiverReport `json:"archiver"`
	// Meaning says whether search by meaning can run and what it covers.
	Meaning meaningReport `json:"meaning"`
}

type archiverReport struct {
	// Service is the background agent that archives without being asked.
	Service service.Status `json:"service"`
	// Pending counts sessions on disk the archive does not fully hold.
	Pending archive.Pending `json:"pending"`
}

// inspectArchiver reads the agent's state and compares the sessions on disk
// with the index. Without an index, every session is missing.
func inspectArchiver(rep *catalog.Report) archiverReport {
	ar := archiverReport{Service: service.Inspect()}
	for _, l := range rep.Sessions() {
		if l.File.Kind == "main" {
			ar.Pending.Missing++
		}
	}
	dir, err := home.Dir()
	if err != nil {
		return ar
	}
	if _, err := os.Stat(home.DBPath(dir)); err != nil {
		return ar
	}
	a, err := archive.OpenAt(dir)
	if err != nil {
		return ar
	}
	defer a.Close()
	if p, err := a.Pending(rep); err == nil {
		ar.Pending = p
	}
	return ar
}

func newDoctor() *cobra.Command {
	return &cobra.Command{
		Use:   "doctor",
		Short: "Report where Claude Code keeps sessions and what skit can see",
		Long: `doctor inspects the Claude Code data directory ($CLAUDE_CONFIG_DIR or ~/.claude):
projects, session files, subagents, live sessions, disk use, and the retention
setting that decides when Claude Code deletes transcripts. It also says whether
anything keeps the archive current: the background agent ('skit service') and how
many sessions on disk are not archived yet or changed since they were. And it
says whether search by meaning is set up: llama-server, the embedding model, and
how much of the indexed text has vectors ('skit embed').`,
		Example: "  skit doctor\n  skit doctor --json | jq .retention",
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			rep, err := catalog.Inspect()
			if err != nil {
				return err
			}
			ar := inspectArchiver(rep)
			var meaning meaningReport
			if dir, err := home.Dir(); err == nil {
				meaning = inspectMeaning(dir)
			}
			if jsonWanted(cmd) {
				return writeJSON(cmd.OutOrStdout(), doctorReport{Report: rep, Archiver: ar, Meaning: meaning})
			}
			printDoctor(cmd.OutOrStdout(), rep)
			if rep.Exists {
				printArchiver(cmd.OutOrStdout(), ar)
				printMeaning(cmd.OutOrStdout(), meaning)
			}
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
	if dir, err := home.Dir(); err == nil {
		line := fmt.Sprintf("skit home          %s", dir)
		if _, statErr := os.Stat(home.DBPath(dir)); statErr == nil {
			if st, err := store.Open(home.DBPath(dir)); err == nil {
				if c, err := st.Counts(); err == nil {
					line += fmt.Sprintf("   index: %d sessions (%d archived), %d segments, %s", c.Sessions, c.Archived, c.Segments, humanBytes(c.Bytes))
				}
				st.Close()
			}
		} else {
			line += "   (no index yet: run `skit archive`)"
		}
		fmt.Fprintln(w, line)
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

func printArchiver(w io.Writer, ar archiverReport) {
	waiting := "every session on disk is archived"
	if n := ar.Pending.Missing + ar.Pending.Behind; n > 0 {
		waiting = fmt.Sprintf("%d session(s) waiting: %d never archived, %d changed since", n, ar.Pending.Missing, ar.Pending.Behind)
	}
	fmt.Fprintf(w, "Archiver           %s · %s\n", serviceLine(ar.Service), waiting)
	switch {
	case ar.Service.Supported && !ar.Service.Installed:
		fmt.Fprintln(w, "                   run `skit service install` once and sessions are archived without being asked")
	case ar.Service.Installed && !ar.Service.Running && ar.Service.Detail != "":
		fmt.Fprintf(w, "                   %s\n", ar.Service.Detail)
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
