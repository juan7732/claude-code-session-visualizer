package cli

import (
	"fmt"
	"strings"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/archive"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
)

func newArchive() *cobra.Command {
	var debug bool
	var project string
	cmd := &cobra.Command{
		Use:   "archive [session...]",
		Short: "Copy sessions into the durable archive and index them for search",
		Long: `archive keeps your own copy of every session under ~/.sessionkit (or $SKIT_HOME):
the raw JSONL lines, zstd-compressed and appended as a session grows, plus its
subagent transcripts and spilled tool outputs, and an index of every content
block for search. Claude Code deletes transcripts after cleanupPeriodDays; the
archive does not. Safe to run any time; unchanged sessions are skipped.

Request bodies (api-request* records) are dropped unless --debug is given, which
roughly doubles the size of a session's copy.`,
		Example: "  skit archive\n  skit archive --project tools\n  skit archive 36086585 --debug",
		RunE: func(cmd *cobra.Command, args []string) error {
			rep, err := catalog.Inspect()
			if err != nil {
				return err
			}
			a, err := archive.Open()
			if err != nil {
				return err
			}
			defer a.Close()
			var targets []catalog.Located
			if len(args) > 0 {
				for _, q := range args {
					l, err := rep.Find(q)
					if err != nil {
						return err
					}
					targets = append(targets, l)
				}
			} else {
				for _, l := range rep.Sessions() {
					if l.File.Kind != "main" || (project != "" && !strings.Contains(strings.ToLower(l.Project.Slug), strings.ToLower(project))) {
						continue
					}
					targets = append(targets, l)
				}
			}
			var results []archive.Result
			counts := map[string]int{}
			for _, l := range targets {
				res, err := a.Ingest(l, archive.Options{Debug: debug})
				if err != nil {
					fmt.Fprintf(cmd.ErrOrStderr(), "skit: %s: %v\n", l.File.ID[:8], err)
					res.Action = "failed"
				}
				counts[res.Action]++
				results = append(results, res)
				if !jsonWanted(cmd) {
					fmt.Fprintf(cmd.OutOrStdout(), "  %-9s %s  %-40s %5d records  %s\n", res.Action, res.ID[:8], truncate(l.Project.Slug, 40), res.Records, humanBytes(res.Bytes))
				}
			}
			if jsonWanted(cmd) {
				if results == nil {
					results = []archive.Result{}
				}
				return writeJSON(cmd.OutOrStdout(), results)
			}
			c, _ := a.Store.Counts()
			fmt.Fprintf(cmd.OutOrStdout(), "\n%d archived, %d updated, %d unchanged, %d failed · index: %d sessions, %d segments, %s\n",
				counts["archived"], counts["updated"], counts["unchanged"], counts["failed"], c.Sessions, c.Segments, humanBytes(c.Bytes))
			return nil
		},
	}
	cmd.Flags().BoolVar(&debug, "debug", false, "keep api-request* records (full request bodies) in the raw copy")
	cmd.Flags().StringVarP(&project, "project", "p", "", "only projects whose slug contains this text")
	return cmd
}
