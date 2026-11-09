package cli

import (
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

// Manifest is the machine-readable description of the whole CLI: what an agent
// reads once to learn the tool. It is derived from the command tree, so it can
// never drift from the real flags.
type Manifest struct {
	Name     string            `json:"name"`
	Version  string            `json:"version"`
	Summary  string            `json:"summary"`
	Commands []ManifestCommand `json:"commands"`
}

type ManifestCommand struct {
	Path        string         `json:"path"`
	Summary     string         `json:"summary"`
	Description string         `json:"description,omitempty"`
	Usage       string         `json:"usage"`
	Example     string         `json:"example,omitempty"`
	Flags       []ManifestFlag `json:"flags,omitempty"`
}

type ManifestFlag struct {
	Name      string `json:"name"`
	Shorthand string `json:"shorthand,omitempty"`
	Type      string `json:"type"`
	Default   string `json:"default,omitempty"`
	Usage     string `json:"usage"`
	Global    bool   `json:"global,omitempty"`
}

func newDescribe() *cobra.Command {
	return &cobra.Command{
		Use:     "describe",
		Short:   "Print a machine-readable manifest of every command and flag",
		Long:    "describe emits the agent manifest: all commands, flags, defaults and examples as JSON. Output is always JSON.",
		Example: "  skit describe | jq '.commands[].path'",
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return writeJSON(cmd.OutOrStdout(), BuildManifest(cmd.Root()))
		},
	}
}

// BuildManifest walks a command tree into a Manifest.
func BuildManifest(root *cobra.Command) Manifest {
	m := Manifest{Name: root.Name(), Version: root.Version, Summary: root.Short}
	var walk func(c *cobra.Command)
	walk = func(c *cobra.Command) {
		for _, sub := range c.Commands() {
			if sub.Hidden || sub.Name() == "help" || sub.Name() == "completion" {
				continue
			}
			mc := ManifestCommand{Path: sub.CommandPath(), Summary: sub.Short, Description: sub.Long, Usage: sub.UseLine(), Example: sub.Example}
			sub.LocalFlags().VisitAll(func(f *pflag.Flag) { mc.Flags = append(mc.Flags, flagOf(f, false)) })
			sub.InheritedFlags().VisitAll(func(f *pflag.Flag) { mc.Flags = append(mc.Flags, flagOf(f, true)) })
			m.Commands = append(m.Commands, mc)
			walk(sub)
		}
	}
	walk(root)
	return m
}

func flagOf(f *pflag.Flag, global bool) ManifestFlag {
	return ManifestFlag{Name: f.Name, Shorthand: f.Shorthand, Type: f.Value.Type(), Default: f.DefValue, Usage: f.Usage, Global: global}
}
