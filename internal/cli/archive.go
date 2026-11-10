package cli

import (
	"fmt"
	"strings"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/archive"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
)

func newArchive() *cobra.Command {
	var strip, verify bool
	var project string
	cmd := &cobra.Command{
		Use:   "archive [session...]",
		Short: "Copy sessions into the durable archive and index them for search",
		Long: `archive keeps your own copy of every session under ~/.sessionkit (or $SKIT_HOME):
the raw JSONL lines, zstd-compressed and appended as a session grows, plus its
subagent transcripts and spilled tool outputs, and an index of every content
block for search. Claude Code deletes transcripts after cleanupPeriodDays; the
archive does not. Safe to run any time; unchanged sessions are skipped.

The copy is lossless: it keeps the api-request* records too (system prompt, tool
definitions, message bodies, parameters), which is what 'skit context' explains.
--strip-requests drops them for a smaller copy.

The archive never ends up holding less than it did. A source that shrank or was
replaced leaves the earlier copy beside the new one as <copy>.prev-<time>, and a
write cut short by a crash is cut off before the next one. --verify decodes
every copy (or the named sessions) and compares it with the index; it changes
nothing and exits non-zero when a copy is missing, corrupt or the wrong length.`,
		Example: "  skit archive\n  skit archive --project tools\n  skit archive 36086585 --strip-requests\n  skit archive --verify",
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
			if verify {
				return runVerify(cmd, a, args)
			}
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
				res, err := a.Ingest(l, archive.Options{StripRequests: strip})
				if err != nil {
					fmt.Fprintf(cmd.ErrOrStderr(), "skit: %s: %v\n", l.File.ID[:8], err)
					res.Action = "failed"
				}
				counts[res.Action]++
				results = append(results, res)
				if !jsonWanted(cmd) {
					fmt.Fprintf(cmd.OutOrStdout(), "  %-9s %s  %-40s %5d records  %s\n", res.Action, res.ID[:8], truncate(l.Project.Slug, 40), res.Records, humanBytes(res.Bytes))
					for _, k := range res.Kept {
						fmt.Fprintf(cmd.OutOrStdout(), "            kept the earlier copy, which held more: %s\n", k)
					}
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
	cmd.Flags().BoolVar(&strip, "strip-requests", false, "drop api-request* records from the raw copy (smaller; skit context then cannot explain archived actions)")
	cmd.Flags().StringVarP(&project, "project", "p", "", "only projects whose slug contains this text")
	cmd.Flags().BoolVar(&verify, "verify", false, "check every archived copy against the index instead of archiving; changes nothing")
	return cmd
}

// runVerify prints the state of the archived copies and fails when any is not ok.
func runVerify(cmd *cobra.Command, a *archive.Archive, ids []string) error {
	checks, err := a.Verify(ids)
	if err != nil {
		return err
	}
	bad := 0
	for _, c := range checks {
		if c.Status != "ok" {
			bad++
		}
	}
	if jsonWanted(cmd) {
		if err := writeJSON(cmd.OutOrStdout(), checks); err != nil {
			return err
		}
	} else {
		for _, c := range checks {
			fmt.Fprintf(cmd.OutOrStdout(), "  %-9s %s  %-40s %5d records  %s\n", c.Status, c.ID[:min(8, len(c.ID))], truncate(c.Project, 40), c.Records, humanBytes(c.Bytes))
			if c.Detail != "" {
				fmt.Fprintf(cmd.OutOrStdout(), "            %s\n", c.Detail)
			}
			for _, p := range c.Previous {
				fmt.Fprintf(cmd.OutOrStdout(), "            earlier copy kept: %s\n", p)
			}
		}
		fmt.Fprintf(cmd.OutOrStdout(), "\n%d copies checked, %d ok, %d with problems\n", len(checks), len(checks)-bad, bad)
	}
	if bad > 0 {
		return fmt.Errorf("%d of %d archived copies have problems", bad, len(checks))
	}
	return nil
}
