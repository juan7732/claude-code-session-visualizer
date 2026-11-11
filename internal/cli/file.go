package cli

import (
	"errors"
	"fmt"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/archive"
)

func newFile() *cobra.Command {
	var session string
	var text bool
	cmd := &cobra.Command{
		Use:   "file <path>",
		Short: "A file some session touched: whether it is still there, and every session that touched it",
		Long: `file says what a file is now (there or deleted, its size, when it changed)
and lists the archived sessions that read or wrote it, the latest first. The
path is where the file is on disk; with --session it may be the path as that
session wrote it (docs/plan.md): the archive found where that is when it
indexed the session. --text prints the content too (text files, up to 2 MB).
Only files an archived session touched are ever looked at.`,
		Example: "  skit file /Users/me/work/docs/plan.md\n  skit file docs/plan.md --session 36086585 --text\n  skit file /Users/me/work/docs/plan.md --json | jq '.sessions[] | {title, writes}'",
		Args:    cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			a, err := archive.Open()
			if err != nil {
				return err
			}
			defer a.Close()
			id := ""
			if session != "" {
				r, err := resolve(cmd, session)
				if err != nil {
					return err
				}
				id = r.Session.ID
			}
			v, err := a.FileNow(args[0], id, text || jsonWanted(cmd))
			if errors.Is(err, archive.ErrUntouched) {
				return fmt.Errorf("%s: %v (paths are as `skit relations` lists them; --session resolves a relative one)", args[0], err)
			}
			if err != nil {
				return err
			}
			if jsonWanted(cmd) {
				return writeJSON(cmd.OutOrStdout(), v)
			}
			w := cmd.OutOrStdout()
			state := "deleted or moved"
			switch {
			case v.Exists && v.Reason == "directory":
				state = "a directory"
			case v.Exists && v.Modified != nil:
				state = fmt.Sprintf("%d bytes, changed %s", v.Bytes, localTime(*v.Modified))
			case v.Exists:
				state = "there, not readable"
			}
			fmt.Fprintf(w, "File      %s\nNow       %s\n\nSessions (%d), latest first\n", v.Path, state, len(v.Sessions))
			for _, h := range v.Sessions {
				fmt.Fprintf(w, "  %s  %-16s %2d written %2d read  %s\n", short(h.Session), localTime(h.LastAt), h.Writes, h.Reads, truncate(h.Title, 60))
			}
			if text {
				switch {
				case v.Reason == "binary":
					fmt.Fprintln(w, "\n(not text)")
				case v.Text != "":
					fmt.Fprintf(w, "\n%s", v.Text)
					if v.Truncated {
						fmt.Fprintf(w, "\n… the first %d bytes of %d\n", archive.MaxFileText, v.Bytes)
					}
				}
			}
			return nil
		},
	}
	cmd.Flags().StringVar(&session, "session", "", "resolve the path as this session wrote it")
	cmd.Flags().BoolVar(&text, "text", false, "print the file's content too")
	return cmd
}
