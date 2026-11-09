//go:build integration

// Package harness runs the real skit binary in a hermetic sandbox: a temp HOME
// with a seeded ~/.claude, a minimal environment, captured stdout/stderr.
// Modelled on ergo's integration harness.
package harness

import (
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

const defaultBinary = "/usr/local/bin/skit"

// Binary is the skit executable under test. $SKIT_TEST_BINARY overrides the
// container default, for running the suite outside Docker.
func Binary() string {
	if v := os.Getenv("SKIT_TEST_BINARY"); v != "" {
		return v
	}
	return defaultBinary
}

type Harness struct {
	t         *testing.T
	Home      string
	ClaudeDir string
	Env       []string
}

// New makes a sandbox with an empty ~/.claude.
func New(t *testing.T) *Harness {
	t.Helper()
	home := t.TempDir()
	claude := filepath.Join(home, ".claude")
	if err := os.MkdirAll(claude, 0o700); err != nil {
		t.Fatal(err)
	}
	return &Harness{t: t, Home: home, ClaudeDir: claude, Env: []string{"HOME=" + home, "PATH=" + os.Getenv("PATH"), "NO_COLOR=1", "TERM=dumb"}}
}

// SeedSession writes a transcript with the given lines under a project slug and returns its path.
func (h *Harness) SeedSession(slug, id string, lines ...string) string {
	h.t.Helper()
	dir := filepath.Join(h.ClaudeDir, "projects", slug)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		h.t.Fatal(err)
	}
	var b bytes.Buffer
	for _, l := range lines {
		b.WriteString(l)
		b.WriteByte('\n')
	}
	p := filepath.Join(dir, id+".jsonl")
	if err := os.WriteFile(p, b.Bytes(), 0o644); err != nil {
		h.t.Fatal(err)
	}
	return p
}

// WriteFile writes a file relative to ~/.claude.
func (h *Harness) WriteFile(rel, content string) {
	h.t.Helper()
	p := filepath.Join(h.ClaudeDir, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		h.t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		h.t.Fatal(err)
	}
}

type Result struct {
	Stdout, Stderr string
	ExitCode       int
}

// Run executes skit with args in the sandbox.
func (h *Harness) Run(args ...string) Result {
	h.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, Binary(), args...)
	cmd.Dir = h.Home
	cmd.Env = h.Env
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	err := cmd.Run()
	res := Result{Stdout: out.String(), Stderr: errb.String()}
	var exit *exec.ExitError
	switch {
	case err == nil:
	case errors.As(err, &exit):
		res.ExitCode = exit.ExitCode()
	default:
		h.t.Fatalf("exec %s: %v", Binary(), err)
	}
	return res
}

func (r Result) AssertOK(t *testing.T) {
	t.Helper()
	if r.ExitCode != 0 {
		t.Fatalf("exit %d\nstdout:\n%s\nstderr:\n%s", r.ExitCode, r.Stdout, r.Stderr)
	}
}
