//go:build integration

// Package harness runs the real skit binary in a hermetic sandbox: a temp HOME
// with a seeded ~/.claude, a minimal environment, captured stdout/stderr.
// Modelled on ergo's integration harness.
package harness

import (
	"bytes"
	"context"
	"errors"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
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

// SeedFixture copies a fixture directory from internal/testdata/sessions into
// a project under the sandbox's ~/.claude/projects and returns the session id.
func (h *Harness) SeedFixture(fixture, slug string) string {
	h.t.Helper()
	src := filepath.Join("..", "..", "internal", "testdata", "sessions", fixture)
	dst := filepath.Join(h.ClaudeDir, "projects", slug)
	if err := os.MkdirAll(dst, 0o755); err != nil {
		h.t.Fatal(err)
	}
	id := ""
	err := filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		if rel == "." || filepath.Base(rel) == "expected.json" {
			return nil
		}
		target := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		if strings.HasSuffix(rel, ".jsonl") && !strings.Contains(rel, string(filepath.Separator)) {
			id = strings.TrimSuffix(rel, ".jsonl")
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		return os.WriteFile(target, b, 0o644)
	})
	if err != nil {
		h.t.Fatal(err)
	}
	if id == "" {
		h.t.Fatalf("fixture %s has no transcript", fixture)
	}
	return id
}

// Shim puts an executable named name, with the given shell script as its body,
// at the front of the sandbox's PATH: the way to stand in for an external tool
// (launchctl) without touching the real one.
func (h *Harness) Shim(name, script string) {
	h.t.Helper()
	dir := filepath.Join(h.Home, "shims")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		h.t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\n"+script+"\n"), 0o755); err != nil {
		h.t.Fatal(err)
	}
	for i, e := range h.Env {
		if strings.HasPrefix(e, "PATH=") && !strings.HasPrefix(e, "PATH="+dir+":") {
			h.Env[i] = "PATH=" + dir + ":" + strings.TrimPrefix(e, "PATH=")
		}
	}
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

// Proc is a skit process started in the background (serve).
type Proc struct {
	cmd *exec.Cmd
	out *bytes.Buffer
}

// Start launches skit with args and returns immediately. Stop kills it.
func (h *Harness) Start(args ...string) *Proc {
	h.t.Helper()
	cmd := exec.Command(Binary(), args...)
	cmd.Dir = h.Home
	cmd.Env = h.Env
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Start(); err != nil {
		h.t.Fatalf("start %s: %v", Binary(), err)
	}
	p := &Proc{cmd: cmd, out: &out}
	h.t.Cleanup(p.Stop)
	return p
}

// Stop terminates the process.
func (p *Proc) Stop() {
	if p.cmd.Process != nil {
		_ = p.cmd.Process.Signal(os.Interrupt)
		done := make(chan struct{})
		go func() { p.cmd.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(3 * time.Second):
			_ = p.cmd.Process.Kill()
		}
	}
}

// Output is what the process has written so far.
func (p *Proc) Output() string { return p.out.String() }

// WaitForFile polls until path exists or the timeout passes.
func (h *Harness) WaitForFile(path string, timeout time.Duration) bool {
	h.t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return true
		}
		time.Sleep(25 * time.Millisecond)
	}
	return false
}

func (r Result) AssertOK(t *testing.T) {
	t.Helper()
	if r.ExitCode != 0 {
		t.Fatalf("exit %d\nstdout:\n%s\nstderr:\n%s", r.ExitCode, r.Stdout, r.Stderr)
	}
}
