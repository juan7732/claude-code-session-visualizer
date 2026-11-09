// Package cli holds the Cobra command tree for skit. Commands parse flags,
// call sessionkit, and print. No logic lives here.
package cli

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"slices"

	"github.com/spf13/cobra"
)

// Main runs the CLI and returns the process exit code. With --json, an error
// is printed to stderr as a JSON object so agents never have to parse prose.
func Main(args []string, version string) int {
	root := NewRoot(version)
	root.SetArgs(args)
	if err := root.Execute(); err != nil {
		if slices.Contains(args, "--json") {
			_ = writeJSON(os.Stderr, map[string]string{"error": err.Error()})
		} else {
			fmt.Fprintln(os.Stderr, "skit:", err)
		}
		return 1
	}
	return 0
}

// NewRoot builds the command tree. Exported so describe and tests can walk it.
func NewRoot(version string) *cobra.Command {
	root := &cobra.Command{
		Use:   "skit",
		Short: "Browse, archive and search Claude Code sessions",
		Long: `skit reads the transcripts Claude Code writes under ~/.claude and makes them
browsable, durable and searchable. Every read command accepts --json for agents.`,
		Version:       version,
		SilenceUsage:  true,
		SilenceErrors: true,
	}
	root.PersistentFlags().Bool("json", false, "machine-readable output (one JSON document on stdout)")
	root.PersistentFlags().Bool("no-cache", false, "ignore and do not write the summary cache under ~/.sessionkit/cache")
	root.AddCommand(newDoctor(), newDescribe(), newProjects(), newList(), newShow(), newStats())
	return root
}

func cacheWanted(cmd *cobra.Command) bool {
	v, _ := cmd.Flags().GetBool("no-cache")
	return !v
}

func jsonWanted(cmd *cobra.Command) bool {
	v, _ := cmd.Flags().GetBool("json")
	return v
}

func writeJSON(w io.Writer, v any) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}
