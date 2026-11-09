// Command skit browses, archives and searches Claude Code sessions.
// It is a thin face over the sessionkit engine; see docs/architecture.md.
package main

import (
	"os"

	"github.com/juan7732/claude-code-session-visualizer/internal/cli"
)

// version is set by the linker: -X main.version=<tag>.
var version = "dev"

func main() {
	os.Exit(cli.Main(os.Args[1:], version))
}
