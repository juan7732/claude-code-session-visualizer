package cli

import (
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/home"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/service"
)

func newService() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "service",
		Short: "Keep the archiver running: install, remove or inspect the background agent",
		Long: `service manages a launchd agent (macOS) that runs 'skit serve' from login on and
restarts it if it stops. With it installed, every Claude Code session is archived
a few seconds after it goes quiet, and whatever changed while the Mac was off is
caught at the next login, without anyone running a command.

  skit service install     write the agent and start it (safe to repeat, e.g. after moving skit)
  skit service status      installed? running? which skit does it run?
  skit service uninstall   stop it and remove the agent; the archive is untouched

The agent is one file, ~/Library/LaunchAgents/` + service.Label + `.plist. Its log is
serve.log in skit's home.`,
		Example: "  skit service install\n  skit service status --json",
	}
	cmd.AddCommand(
		&cobra.Command{
			Use:   "install",
			Short: "Install and start the background agent that keeps sessions archived",
			Args:  cobra.NoArgs,
			RunE: func(cmd *cobra.Command, _ []string) error {
				bin, err := os.Executable()
				if err != nil {
					return err
				}
				if resolved, err := filepath.EvalSymlinks(bin); err == nil {
					bin = resolved
				}
				dir, err := home.Dir()
				if err != nil {
					return err
				}
				st, err := service.Install(service.Config{Binary: bin, SkitHome: dir, SetSkitHome: os.Getenv("SKIT_HOME") != "", ClaudeDir: os.Getenv("CLAUDE_CONFIG_DIR")})
				if err != nil {
					return err
				}
				return printService(cmd, st)
			},
		},
		&cobra.Command{
			Use:   "uninstall",
			Short: "Stop and remove the background agent (the archive is untouched)",
			Args:  cobra.NoArgs,
			RunE: func(cmd *cobra.Command, _ []string) error {
				st, err := service.Uninstall()
				if err != nil {
					return err
				}
				return printService(cmd, st)
			},
		},
		&cobra.Command{
			Use:   "status",
			Short: "Report whether the background agent is installed and running",
			Args:  cobra.NoArgs,
			RunE: func(cmd *cobra.Command, _ []string) error {
				return printService(cmd, service.Inspect())
			},
		},
	)
	return cmd
}

func printService(cmd *cobra.Command, st service.Status) error {
	if jsonWanted(cmd) {
		return writeJSON(cmd.OutOrStdout(), st)
	}
	fmt.Fprintln(cmd.OutOrStdout(), serviceLine(st))
	writeServiceDetail(cmd.OutOrStdout(), st)
	return nil
}

// serviceLine is the one-line state, shared with doctor.
func serviceLine(st service.Status) string {
	switch {
	case !st.Supported:
		return "no background agent on this system (macOS only for now)"
	case !st.Installed:
		return "not installed"
	case st.Running:
		return fmt.Sprintf("launchd agent %s running (pid %d)", st.Label, st.PID)
	}
	return fmt.Sprintf("launchd agent %s installed, not running", st.Label)
}

func writeServiceDetail(w io.Writer, st service.Status) {
	if st.Binary != "" {
		fmt.Fprintf(w, "  runs   %s serve --quiet\n", st.Binary)
	}
	if st.Installed {
		fmt.Fprintf(w, "  agent  %s\n", st.Plist)
	}
	if st.Log != "" {
		fmt.Fprintf(w, "  log    %s\n", st.Log)
	}
	if st.Detail != "" {
		fmt.Fprintf(w, "  note   %s\n", st.Detail)
	}
}
