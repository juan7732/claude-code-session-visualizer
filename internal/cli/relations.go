package cli

import (
	"encoding/base64"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/annotate"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/claudeconfig"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/home"
)

func newRelations() *cobra.Command {
	return &cobra.Command{
		Use:   "relations <session>",
		Short: "What connects to what: background tasks, hand-backs, retries, files, outside services, errors",
		Long: `relations derives the links a transcript does not state: how long each action
wrote, ran tools and waited; which commands ran in the background and where
their output was read; where each subagent handed back; which failed calls were
retried; which files were read or written; which web hosts, skills and
connectors were reached; and the API errors along the way.`,
		Example: "  skit relations 36086585\n  skit relations 36086585 --json | jq '.tasks[] | {id, pickups: (.pickups | length)}'",
		Args:    cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			r, err := resolve(cmd, args[0])
			if err != nil {
				return err
			}
			rel := r.Session.Relations()
			if jsonWanted(cmd) {
				return writeJSON(cmd.OutOrStdout(), rel)
			}
			w := cmd.OutOrStdout()
			fmt.Fprintf(w, "Session   %s  %s\n\n", r.Session.ID, r.Session.Title)
			fmt.Fprintf(w, "Background tasks (%d)\n", len(rel.Tasks))
			for _, t := range rel.Tasks {
				read := "never read"
				if n := len(t.Pickups); n > 0 {
					read = fmt.Sprintf("read %d× (first in turn %d, action %d)", n, t.Pickups[0].Turn, t.Pickups[0].Action)
				}
				fmt.Fprintf(w, "  %-12s turn %d action %d  %s  · %s\n", t.ID, t.Launch.Turn, t.Launch.Action, t.Label, read)
			}
			fmt.Fprintf(w, "\nSubagent hand-backs (%d)\n", len(rel.Handbacks))
			for _, h := range rel.Handbacks {
				into := "no later action in the turn"
				if h.Action >= 0 {
					into = fmt.Sprintf("into action %d", h.Action)
				}
				fmt.Fprintf(w, "  %s  spawned in action %d, %s  %s\n", h.AgentID, h.Spawn.Action, into, truncate(h.Message, 70))
			}
			fmt.Fprintf(w, "\nRetries (%d)\n", len(rel.Retries))
			for _, x := range rel.Retries {
				fmt.Fprintf(w, "  action %d failed → retried in action %d\n", x.Failed.Action, x.Retry.Action)
			}
			fmt.Fprintf(w, "\nFiles (%d)\n", len(rel.Files))
			for i, f := range rel.Files {
				if i == 15 {
					fmt.Fprintf(w, "  … %d more (use --json)\n", len(rel.Files)-15)
					break
				}
				fmt.Fprintf(w, "  %2d touches  %d writes  %d turns  %s\n", len(f.Touches), f.Writes, f.Turns, f.Path)
			}
			fmt.Fprintf(w, "\nOutside (%d)\n", len(rel.Outside))
			for _, o := range rel.Outside {
				fmt.Fprintf(w, "  %-9s %-28s %d calls\n", o.Kind, o.Name, len(o.Calls))
			}
			fmt.Fprintf(w, "\nEvents (%d)\n", len(rel.Events))
			for _, e := range rel.Events {
				fmt.Fprintf(w, "  %s  turn %d  %-20s %s\n", localTime(e.At), e.Turn, e.Kind, e.Message)
			}
			return nil
		},
	}
}

func newImages() *cobra.Command {
	var extract int
	var out string
	cmd := &cobra.Command{
		Use:   "images <session>",
		Short: "List the images in a session, or extract one",
		Long: `images lists every image pasted into a prompt or returned by a tool, with its
turn, media type and size. --extract N writes image N to --out (or stdout).`,
		Example: "  skit images a93a7619\n  skit images a93a7619 --extract 0 --out first.png",
		Args:    cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			r, err := resolve(cmd, args[0])
			if err != nil {
				return err
			}
			if cmd.Flags().Changed("extract") {
				_, b64, err := r.Session.ImageData(extract)
				if err != nil {
					return err
				}
				raw, err := base64.StdEncoding.DecodeString(b64)
				if err != nil {
					return err
				}
				if out == "" {
					_, err = cmd.OutOrStdout().Write(raw)
					return err
				}
				return os.WriteFile(out, raw, 0o644)
			}
			imgs := r.Session.Images()
			if jsonWanted(cmd) {
				return writeJSON(cmd.OutOrStdout(), imgs)
			}
			w := cmd.OutOrStdout()
			for _, im := range imgs {
				fmt.Fprintf(w, "%3d  turn %-3d %-11s %-10s %7d bytes  %s\n", im.Index, im.Turn, im.Where, im.MediaType, im.Size, localTime(im.At))
			}
			if len(imgs) == 0 {
				fmt.Fprintln(w, "no images in this session")
			}
			return nil
		},
	}
	cmd.Flags().IntVar(&extract, "extract", 0, "write image N instead of listing")
	cmd.Flags().StringVar(&out, "out", "", "file to write the extracted image to (default stdout)")
	return cmd
}

func newAnnotate() *cobra.Command {
	var pin, unpin bool
	var tags, untags, notes []string
	cmd := &cobra.Command{
		Use:   "annotate <session>",
		Short: "Pin, tag or note a session; with no flags, show its annotations",
		Long: `annotate keeps what you add to a session in ~/.sessionkit/annotations.json:
a pin, tags, and notes keyed by what they are about ("session", "turn:3",
"action:60", "tool:<id>"). A note set to an empty text is removed.`,
		Example: "  skit annotate 36086585 --pin --tag m6\n  skit annotate 36086585 --note action:60='the hand-back'\n  skit annotate 36086585 --json",
		Args:    cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			r, err := resolve(cmd, args[0])
			if err != nil {
				return err
			}
			dir, err := home.Dir()
			if err != nil {
				return err
			}
			p := annotate.Patch{AddTags: tags, RemoveTags: untags}
			if pin || unpin {
				v := pin
				p.Pinned = &v
			}
			for _, n := range notes {
				k, v, ok := strings.Cut(n, "=")
				if !ok {
					return fmt.Errorf("--note wants key=text, got %q", n)
				}
				if p.Notes == nil {
					p.Notes = map[string]string{}
				}
				p.Notes[k] = v
			}
			var a annotate.Annotation
			if p.Pinned != nil || len(tags)+len(untags)+len(notes) > 0 {
				a, err = annotate.Apply(dir, r.Session.ID, p)
			} else {
				a, err = annotate.Get(dir, r.Session.ID)
			}
			if err != nil {
				return err
			}
			if jsonWanted(cmd) {
				return writeJSON(cmd.OutOrStdout(), a)
			}
			w := cmd.OutOrStdout()
			fmt.Fprintf(w, "Session   %s  %s\nPinned    %v\nTags      %s\n", r.Session.ID, r.Session.Title, a.Pinned, strings.Join(a.Tags, ", "))
			keys := make([]string, 0, len(a.Notes))
			for k := range a.Notes {
				keys = append(keys, k)
			}
			sort.Strings(keys)
			for _, k := range keys {
				fmt.Fprintf(w, "Note      %-12s %s\n", k, a.Notes[k])
			}
			return nil
		},
	}
	cmd.Flags().BoolVar(&pin, "pin", false, "pin the session")
	cmd.Flags().BoolVar(&unpin, "unpin", false, "unpin the session")
	cmd.Flags().StringArrayVar(&tags, "tag", nil, "add a tag (repeatable)")
	cmd.Flags().StringArrayVar(&untags, "untag", nil, "remove a tag (repeatable)")
	cmd.Flags().StringArrayVar(&notes, "note", nil, "set a note as key=text; empty text removes it (repeatable)")
	return cmd
}

func newClaude() *cobra.Command {
	var roots []string
	var flags bool
	cmd := &cobra.Command{
		Use:   "claude",
		Short: "How Claude Code is configured here: settings in effect, experiments, flags",
		Long: `claude reads Claude Code's own configuration, read-only: each settings layer and
the value that wins, the experiments this install is assigned to (id, variation,
value), the cached feature flags, known projects, memory files and skills.
Identity and tokens are never printed; the output only says whether they are set.
--root adds a project directory whose .claude/settings*.json, CLAUDE.md and
skills are included.`,
		Example: "  skit claude\n  skit claude --root . --json | jq '.experiments[] | \"\\(.experiment_id)=\\(.variation_id)\"'\n  skit claude --flags | grep tengu_",
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			dir, err := catalog.Dir()
			if err != nil {
				return err
			}
			snap, err := claudeconfig.Read(dir, roots)
			if err != nil {
				return err
			}
			if jsonWanted(cmd) {
				return writeJSON(cmd.OutOrStdout(), snap)
			}
			w := cmd.OutOrStdout()
			fmt.Fprintf(w, "Experiments (%d)\n", len(snap.Experiments))
			for _, e := range snap.Experiments {
				v := "control"
				if e.VariationID != 0 {
					v = fmt.Sprintf("variation %d", e.VariationID)
				}
				fmt.Fprintf(w, "  %-38s %-12s drives %-32s = %s\n", e.ExperimentID, v, e.Flag, truncate(fmt.Sprint(e.Value), 50))
			}
			fmt.Fprintf(w, "\nSettings in effect (%d)\n", len(snap.Effective))
			for _, s := range snap.Effective {
				also := ""
				if len(s.Also) > 0 {
					also = "  (overrides " + strings.Join(s.Also, ", ") + ")"
				}
				fmt.Fprintf(w, "  %-34s %-40s from %s%s\n", s.Key, truncate(fmt.Sprint(s.Value), 40), s.From, also)
			}
			fmt.Fprintln(w, "\nLayers, lowest precedence first")
			for _, l := range snap.Layers {
				state := "absent"
				if l.Exists {
					state = "present"
				}
				fmt.Fprintf(w, "  %-8s %-24s %s\n", state, l.Name, l.Path)
			}
			at := "never"
			if snap.FlagsAt != nil {
				at = localTime(*snap.FlagsAt)
			}
			fmt.Fprintf(w, "\nFlags     %d cached at %s (--flags lists them)\n", len(snap.Flags), at)
			if flags {
				for _, f := range snap.Flags {
					fmt.Fprintf(w, "  %-44s %s\n", f.Key, truncate(fmt.Sprint(f.Value), 70))
				}
			}
			fmt.Fprintf(w, "Projects  %d   Connectors %d   Memory files %d   Skills %d\n", len(snap.Projects), len(snap.Connectors), len(snap.Memory), len(snap.Skills))
			fmt.Fprintf(w, "Identity  user id %s · machine id %s · account %s (values never shown)\n", snap.Identity["userID"], snap.Identity["machineID"], snap.Identity["oauthAccount"])
			return nil
		},
	}
	cmd.Flags().StringArrayVar(&roots, "root", nil, "project directory to include (repeatable)")
	cmd.Flags().BoolVar(&flags, "flags", false, "list every cached feature flag")
	return cmd
}
