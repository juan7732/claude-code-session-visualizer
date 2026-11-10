//go:build integration

package integration

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/juan7732/claude-code-session-visualizer/test/integration/harness"
)

// The background agent, with launchctl replaced by a PATH shim so the test
// never loads anything into the real launchd.
func TestService_InstallStatusUninstall(t *testing.T) {
	t.Parallel()
	h := harness.New(t)
	if runtime.GOOS != "darwin" {
		res := h.Run("service", "install", "--json")
		if res.ExitCode == 0 || !strings.Contains(res.Stderr, "macOS only") {
			t.Fatalf("off macOS, install should say it is not supported: exit %d\n%s", res.ExitCode, res.Stderr)
		}
		res = h.Run("service", "status", "--json")
		res.AssertOK(t)
		if !strings.Contains(res.Stdout, `"supported": false`) {
			t.Fatalf("status off macOS:\n%s", res.Stdout)
		}
		return
	}
	log := filepath.Join(h.Home, "launchctl.log")
	loaded := filepath.Join(h.Home, "loaded")
	h.Shim("launchctl", `echo "$@" >> "`+log+`"
case "$1" in
  bootstrap) touch "`+loaded+`" ;;
  bootout) [ -f "`+loaded+`" ] || exit 3; rm -f "`+loaded+`" ;;
  print) [ -f "`+loaded+`" ] || exit 113; printf 'state = running\n\tpid = 4242\n' ;;
esac`)

	type status struct {
		Installed bool   `json:"installed"`
		Running   bool   `json:"running"`
		PID       int    `json:"pid"`
		Plist     string `json:"plist"`
		Binary    string `json:"binary"`
		Log       string `json:"log"`
	}
	run := func(args ...string) status {
		res := h.Run(append(args, "--json")...)
		res.AssertOK(t)
		var st status
		if err := json.Unmarshal([]byte(res.Stdout), &st); err != nil {
			t.Fatalf("%v: not JSON: %v\n%s", args, err, res.Stdout)
		}
		return st
	}

	if st := run("service", "status"); st.Installed || st.Running {
		t.Fatalf("before install: %+v", st)
	}
	st := run("service", "install")
	if !st.Installed || !st.Running || st.PID != 4242 {
		t.Fatalf("after install: %+v", st)
	}
	if !strings.HasPrefix(st.Plist, filepath.Join(h.Home, "Library", "LaunchAgents")) || !strings.HasSuffix(st.Log, filepath.Join(".sessionkit", "serve.log")) {
		t.Fatalf("the agent and its log belong to the sandbox home: %+v", st)
	}
	if want, _ := filepath.EvalSymlinks(harness.Binary()); st.Binary != want {
		t.Fatalf("the agent should run this skit: %q, want %q", st.Binary, want)
	}
	calls, _ := os.ReadFile(log)
	if !strings.Contains(string(calls), "bootstrap gui/") {
		t.Fatalf("launchctl calls:\n%s", calls)
	}
	res := h.Run("doctor")
	res.AssertOK(t)
	if !strings.Contains(res.Stdout, "running (pid 4242)") {
		t.Fatalf("doctor should report the agent:\n%s", res.Stdout)
	}
	if st := run("service", "uninstall"); st.Installed || st.Running {
		t.Fatalf("after uninstall: %+v", st)
	}
}

// doctor says how many sessions the archive does not fully hold, and a
// starting `serve` archives them without waiting for a file to change.
func TestServe_SweepsAtStartAndDoctorCountsPending(t *testing.T) {
	t.Parallel()
	h := harness.New(t)
	id := h.SeedFixture("synthetic-basics", "-Users-me-work")
	src := filepath.Join(h.ClaudeDir, "projects", "-Users-me-work", id+".jsonl")
	pending := func() (missing, behind float64) {
		res := h.Run("doctor", "--json")
		res.AssertOK(t)
		var d struct {
			Archiver struct {
				Pending map[string]float64 `json:"pending"`
			} `json:"archiver"`
			Totals map[string]any `json:"totals"`
		}
		if err := json.Unmarshal([]byte(res.Stdout), &d); err != nil || d.Totals == nil {
			t.Fatalf("doctor --json keeps the catalog report and adds the archiver: %v\n%s", err, res.Stdout)
		}
		return d.Archiver.Pending["missing"], d.Archiver.Pending["behind"]
	}
	if m, b := pending(); m != 1 || b != 0 {
		t.Fatalf("before anything is archived: missing=%v behind=%v", m, b)
	}
	res := h.Run("doctor")
	if !strings.Contains(res.Stdout, "1 session(s) waiting: 1 never archived") {
		t.Fatalf("doctor:\n%s", res.Stdout)
	}

	// A relative socket path: the sandbox home is the working directory, and a
	// long test name would push an absolute one past the 103 bytes a Unix socket allows.
	p := h.Start("serve", "--socket", "s.sock", "--quiet")
	zst := filepath.Join(h.Home, ".sessionkit", "archive", "-Users-me-work", id+".jsonl.zst")
	if !h.WaitForFile(zst, 10*time.Second) {
		p.Stop()
		t.Fatalf("serve should archive what is on disk when it starts:\n%s", p.Output())
	}
	deadline := time.Now().Add(10 * time.Second)
	for {
		if m, b := pending(); m == 0 && b == 0 {
			break
		}
		if time.Now().After(deadline) {
			p.Stop()
			t.Fatalf("still pending after the sweep:\n%s", p.Output())
		}
		time.Sleep(100 * time.Millisecond)
	}
	p.Stop()

	// With nothing running, a change leaves the copy behind and doctor says so.
	f, _ := os.OpenFile(src, os.O_APPEND|os.O_WRONLY, 0o644)
	f.WriteString(`{"type":"user","uuid":"u9","parentUuid":"a8","turnOrigin":"human","sessionId":"` + id + `","timestamp":"2026-11-08T10:02:00.000Z","message":{"role":"user","content":"later"}}` + "\n")
	f.Close()
	if m, b := pending(); m != 0 || b != 1 {
		t.Fatalf("after the source grew: missing=%v behind=%v", m, b)
	}
}
