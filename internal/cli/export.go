package cli

import (
	"bytes"
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/export"
)

func newExport() *cobra.Command {
	var turn int
	var thinking bool
	var format, out string
	cmd := &cobra.Command{
		Use:   "export <session>",
		Short: "Write a session, or one turn of it, as Markdown",
		Long: `export writes the conversation in a form that can leave the tool: each turn
with what was asked and what the agent said, and one line per tool call with
what it was for and how it went. Compactions are marked where they happened.
--turn N exports one turn. --thinking includes the model's thinking, quoted.
The text goes to stdout, or to --out. With --json the text is the "text" field
of an object that also names the session, the format and the turn.`,
		Example: "  skit export 36086585 --out session.md\n  skit export 36086585 --turn 4 | pbcopy",
		Args:    cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			if format != "markdown" {
				return fmt.Errorf("unknown format %q: markdown is the one there is", format)
			}
			r, err := resolve(cmd, args[0])
			if err != nil {
				return err
			}
			opt := export.Options{Thinking: thinking}
			if cmd.Flags().Changed("turn") {
				opt.Turn = &turn
			}
			var text bytes.Buffer
			if err := export.Markdown(&text, r.Session, opt); err != nil {
				return err
			}
			if jsonWanted(cmd) {
				return writeJSON(cmd.OutOrStdout(), ExportDoc{Session: r.Session.ID, Format: format, Turn: opt.Turn, Text: text.String()})
			}
			if out != "" {
				return os.WriteFile(out, text.Bytes(), 0o644)
			}
			_, err = cmd.OutOrStdout().Write(text.Bytes())
			return err
		},
	}
	cmd.Flags().IntVarP(&turn, "turn", "t", 0, "export only turn N")
	cmd.Flags().BoolVar(&thinking, "thinking", false, "include the model's thinking")
	cmd.Flags().StringVar(&format, "format", "markdown", "output format (markdown)")
	cmd.Flags().StringVarP(&out, "out", "o", "", "write to this file instead of stdout")
	return cmd
}

// ExportDoc is `skit export --json`.
type ExportDoc struct {
	Session string `json:"session"`
	Format  string `json:"format"`
	Turn    *int   `json:"turn,omitempty"`
	Text    string `json:"text"`
}
