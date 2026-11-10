package cli

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/archive"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/home"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/serve"
)

func newServe() *cobra.Command {
	var socket string
	var noWatch, quiet bool
	var settle time.Duration
	cmd := &cobra.Command{
		Use:   "serve",
		Short: "Serve the engine over HTTP on a Unix socket",
		Long: `serve exposes every read operation and archiving over HTTP on a Unix domain
socket, with the same JSON shapes as the CLI's --json. Routes are under /v0/
(GET /v0 lists them). Unless --no-watch is given it also watches Claude Code's
projects directory and archives a session a few seconds after it stops changing,
so the archive and search stay current while it runs. On start, and every hour
after, it also archives whatever changed while no skit was running.

/v0/search?mode=meaning starts a local llama-server with the first such query
and stops it after ten minutes without one ('skit embed' prepares the index).

'skit service install' keeps it running from login on, so nothing depends on
remembering to start it.

Try it:  curl --unix-socket ~/.sessionkit/skit.sock http://skit/v0/status`,
		Example: "  skit serve\n  skit serve --socket /tmp/skit.sock --no-watch",
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if socket == "" {
				dir, err := home.Dir()
				if err != nil {
					return err
				}
				socket = filepath.Join(dir, "skit.sock")
			}
			a, err := archive.Open()
			if err != nil {
				return err
			}
			defer a.Close()
			logger := log.New(cmd.ErrOrStderr(), "skit serve: ", log.LstdFlags)
			s := serve.New(cmd.Root().Version, a)
			s.Logf = logger.Printf
			s.LogRequests = !quiet
			// Meaning search on demand: the sidecar starts with the first
			// meaning query and is stopped after ten quiet minutes, so the
			// model is in memory only while someone is searching.
			e := newEmbedder(a.Home, false)
			e.IdleStop = 10 * time.Minute
			defer e.Close()
			s.Embedder = e
			ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
			defer stop()
			// Bind first: when another skit already serves this socket, this one
			// leaves without watching or archiving beside it.
			ln, err := serve.Listen(socket)
			if err != nil {
				return err
			}
			if !noWatch {
				if dir, err := catalog.Dir(); err == nil {
					go func() {
						if err := s.Watch(ctx, filepath.Join(dir, "projects"), settle); err != nil {
							logger.Printf("watch stopped: %v", err)
						}
					}()
					go s.SweepEvery(ctx, time.Hour)
				}
			}
			fmt.Fprintf(cmd.ErrOrStderr(), "skit serve: listening on %s (watch=%v)\n", socket, !noWatch)
			return s.Serve(ctx, ln, socket)
		},
	}
	cmd.Flags().StringVar(&socket, "socket", "", "Unix socket path (default $SKIT_HOME/skit.sock)")
	cmd.Flags().BoolVar(&noWatch, "no-watch", false, "do not watch ~/.claude/projects for changes")
	cmd.Flags().BoolVar(&quiet, "quiet", false, "do not log each request (archiving and errors are still logged)")
	cmd.Flags().DurationVar(&settle, "settle", 3*time.Second, "how long a transcript must be quiet before it is archived")
	return cmd
}
