package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"runtime"
	"syscall"
	"time"

	"github.com/spf13/cobra"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/archive"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/embed"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/home"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/search"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/store"
)

// meaningReport says whether meaning search can run and how much of the index
// it covers: `skit embed --status` and a section of `skit doctor`.
type meaningReport struct {
	// Ready: the binary and the model are there and every text has a vector.
	Ready        bool               `json:"ready"`
	LlamaServer  string             `json:"llama_server"` // path, "" when not found
	ServerDetail string             `json:"llama_server_detail,omitempty"`
	Accelerated  bool               `json:"accelerated"` // Metal; false means CPU, about a tenth of the speed
	Model        string             `json:"model"`
	ModelFile    embed.ModelState   `json:"model_file"`
	Source       string             `json:"vector_source"` // what this skit would make vectors with
	Vectors      store.VectorCounts `json:"vectors"`
	// Stale: the index holds vectors made by another source; `skit embed` replaces them.
	Stale bool `json:"stale"`
}

// llamaServerPath resolves the sidecar binary. The environment is read here,
// in the CLI; the engine takes a path.
func llamaServerPath() (string, error) {
	return embed.FindBinary(os.Getenv("SKIT_LLAMA_SERVER"))
}

// inspectMeaning gathers the report without changing anything but the model's
// checksum marker. It does not create an index.
func inspectMeaning(dir string) meaningReport {
	m := embed.TextModel
	rep := meaningReport{Model: m.Name, ModelFile: m.Check(dir), Source: m.Source(), Accelerated: runtime.GOOS == "darwin" && runtime.GOARCH == "arm64"}
	bin, err := llamaServerPath()
	if err != nil {
		rep.ServerDetail = err.Error()
	}
	rep.LlamaServer = bin
	if _, err := os.Stat(home.DBPath(dir)); err == nil {
		if st, err := store.Open(home.DBPath(dir)); err == nil {
			if c, err := st.VectorCounts(); err == nil {
				rep.Vectors = c
			}
			st.Close()
		}
	}
	rep.Stale = rep.Vectors.Source != "" && rep.Vectors.Source != rep.Source
	rep.Ready = bin != "" && rep.ModelFile.Present && !rep.Stale && rep.Vectors.Texts > 0 && rep.Vectors.Vectors == rep.Vectors.Texts
	return rep
}

func printMeaning(w io.Writer, rep meaningReport) {
	state := "ready"
	switch {
	case rep.LlamaServer == "":
		state = "not available"
	case !rep.ModelFile.Present:
		state = "not set up"
	case rep.Stale:
		state = "vectors are from another model"
	case rep.Vectors.Texts == 0 && rep.Vectors.Source == "":
		state = "not indexed yet"
	case rep.Vectors.Vectors < rep.Vectors.Texts:
		state = "behind"
	}
	fmt.Fprintf(w, "Meaning search     %s · %d of %d texts have vectors (%s)\n", state, rep.Vectors.Vectors, rep.Vectors.Texts, humanBytes(rep.Vectors.Bytes))
	pad := "                   "
	if rep.LlamaServer == "" {
		fmt.Fprintf(w, "%s%s\n", pad, rep.ServerDetail)
	} else {
		fmt.Fprintf(w, "%sllama-server %s\n", pad, rep.LlamaServer)
	}
	if rep.ModelFile.Present {
		fmt.Fprintf(w, "%smodel %s\n", pad, rep.ModelFile.Path)
	} else {
		fmt.Fprintf(w, "%smodel %s: %s. `skit embed` downloads it once (%s, from huggingface.co, checksum verified)\n", pad, rep.Model, rep.ModelFile.Detail, humanBytes(rep.ModelFile.Want))
	}
	if !rep.Accelerated {
		fmt.Fprintf(w, "%sno Metal on this machine: embedding runs on the CPU, at about a tenth of the speed\n", pad)
	}
	switch {
	case rep.Stale:
		fmt.Fprintf(w, "%sthe index holds vectors from %q; run `skit embed` to replace them\n", pad, rep.Vectors.Source)
	case rep.LlamaServer != "" && rep.ModelFile.Present && rep.Vectors.Vectors < rep.Vectors.Texts:
		fmt.Fprintf(w, "%srun `skit embed` to cover the rest\n", pad)
	case rep.LlamaServer != "" && rep.ModelFile.Present && rep.Vectors.Texts == 0:
		fmt.Fprintf(w, "%srun `skit embed` (after `skit archive`) to index for meaning\n", pad)
	}
}

// meaningAdvice turns the engine's reasons meaning search cannot answer into
// what to do about it.
func meaningAdvice(err error) error {
	switch {
	case errors.Is(err, search.ErrNoVectors):
		return fmt.Errorf("%w: run `skit embed` first", err)
	case errors.Is(err, search.ErrStaleVectors):
		return fmt.Errorf("%w: run `skit embed` to replace them", err)
	}
	return err
}

// newEmbedder builds the embedder for a skit home. Nothing is checked or
// started until it is first used, and it never downloads: a missing binary or
// model is then an error that says what to do.
func newEmbedder(dir string, cpuOnly bool) *embed.Embedder {
	m := embed.TextModel
	return embed.NewEmbedderFunc(func() (embed.SidecarOptions, error) {
		bin, err := llamaServerPath()
		if err != nil {
			return embed.SidecarOptions{}, err
		}
		if st := m.Check(dir); !st.Present {
			return embed.SidecarOptions{}, fmt.Errorf("the embedding model is not in %s (%s): run `skit embed` to download it", embed.ModelsDir(dir), st.Detail)
		}
		return embed.SidecarOptions{Binary: bin, Model: m.Path(dir), RunDir: home.RunDir(dir), CPUOnly: cpuOnly}, nil
	}, m.Source())
}

func newEmbed() *cobra.Command {
	var status, cpu bool
	cmd := &cobra.Command{
		Use:   "embed",
		Short: "Give archived text vectors, so search can find a turn by meaning",
		Long: `embed prepares the index for meaning search. It cuts prompts, replies, thinking
and compaction summaries into pieces of a paragraph or two and computes a vector
for each with EmbeddingGemma 2, running in a local llama-server that skit starts
for the duration and stops afterwards. Tool calls and their output are left to
keyword search.

The first run downloads the model once: one file of about 310 MB from
huggingface.co at a pinned revision, checked against a SHA-256 before it is
used, kept in ~/.sessionkit/models. That is the only time skit uses the
network. A download that was interrupted resumes.

Safe to run any time and to interrupt: a text is embedded once, and what was
done is kept. Run it after 'skit archive'. --status reports what is there and
changes nothing.

Needs llama-server (brew install llama.cpp), found on PATH or at the path in
$SKIT_LLAMA_SERVER.`,
		Example: "  skit embed\n  skit embed --status\n  skit embed --json",
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			dir, err := home.Dir()
			if err != nil {
				return err
			}
			if status {
				rep := inspectMeaning(dir)
				if jsonWanted(cmd) {
					return writeJSON(cmd.OutOrStdout(), rep)
				}
				printMeaning(cmd.OutOrStdout(), rep)
				return nil
			}
			// The binary first: without it the download would be for nothing.
			if _, err := llamaServerPath(); err != nil {
				return err
			}
			ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
			defer stop()
			quiet := jsonWanted(cmd)
			errw := cmd.ErrOrStderr()

			m := embed.TextModel
			if st := m.Check(dir); !st.Present {
				if !quiet {
					fmt.Fprintf(errw, "downloading %s (%s) from huggingface.co, once\n", m.Name, humanBytes(m.Bytes))
				}
				pr := newProgress(errw, quiet)
				err := m.Ensure(ctx, dir, func(done, total int64) {
					pr.show(fmt.Sprintf("  %s of %s", humanBytes(done), humanBytes(total)), done == total)
				})
				pr.end()
				if err != nil {
					return err
				}
			}

			a, err := archive.OpenAt(dir)
			if err != nil {
				return err
			}
			defer a.Close()
			e := newEmbedder(dir, cpu)
			defer e.Close()
			pr := newProgress(errw, quiet)
			res, err := a.Embed(ctx, e, func(done, total int) {
				pr.show(fmt.Sprintf("  embedded %d of %d texts", done, total), done == total)
			})
			pr.end()
			if err != nil {
				if errors.Is(err, context.Canceled) {
					return fmt.Errorf("stopped: %d texts embedded and kept, %d to go; run `skit embed` again to continue", res.Embedded, res.Texts-res.Vectors)
				}
				return err
			}
			if quiet {
				return writeJSON(cmd.OutOrStdout(), res)
			}
			w := cmd.OutOrStdout()
			if res.Dropped > 0 {
				fmt.Fprintf(w, "replaced %d vectors made by another model\n", res.Dropped)
			}
			switch {
			case res.Texts == 0:
				fmt.Fprintln(w, "nothing to embed: the index has no text yet (run `skit archive` first)")
			case res.Embedded == 0:
				fmt.Fprintf(w, "up to date: %d texts have vectors (%s)\n", res.Vectors, humanBytes(res.Bytes))
			default:
				fmt.Fprintf(w, "embedded %d texts in %.1fs (%.0f a second) · %d of %d texts have vectors (%s)\n",
					res.Embedded, res.Seconds, res.PerSec, res.Vectors, res.Texts, humanBytes(res.Bytes))
			}
			return nil
		},
	}
	cmd.Flags().BoolVar(&status, "status", false, "report the model, llama-server and how much of the index has vectors; changes nothing")
	cmd.Flags().BoolVar(&cpu, "cpu", false, "keep the model off the GPU (about a tenth of the speed)")
	return cmd
}

// progress prints one changing line on a terminal, and an occasional line
// anywhere else, so a log does not fill with thousands of updates.
type progress struct {
	w        io.Writer
	off, tty bool
	last     time.Time
	open     bool
}

func newProgress(w io.Writer, off bool) *progress {
	p := &progress{w: w, off: off}
	if f, ok := w.(*os.File); ok {
		if fi, err := f.Stat(); err == nil && fi.Mode()&os.ModeCharDevice != 0 {
			p.tty = true
		}
	}
	return p
}

func (p *progress) show(line string, final bool) {
	if p.off {
		return
	}
	every := 5 * time.Second
	if p.tty {
		every = 100 * time.Millisecond
	}
	if !final && time.Since(p.last) < every {
		return
	}
	p.last = time.Now()
	if p.tty {
		fmt.Fprintf(p.w, "\r\033[K%s", line)
		p.open = true
		return
	}
	fmt.Fprintln(p.w, line)
}

func (p *progress) end() {
	if p.open {
		fmt.Fprintln(p.w)
		p.open = false
	}
}
