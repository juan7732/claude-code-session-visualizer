package service

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fake is a launchd whose launchctl is a function: it records the calls and
// answers `print` as launchd would for a loaded, running agent.
func fake(t *testing.T) (*launchd, *[]string) {
	t.Helper()
	var calls []string
	loaded := false
	l := &launchd{agentsDir: filepath.Join(t.TempDir(), "LaunchAgents"), domain: "gui/501"}
	l.run = func(args ...string) ([]byte, error) {
		calls = append(calls, strings.Join(args, " "))
		switch args[0] {
		case "bootstrap":
			loaded = true
		case "bootout":
			if !loaded {
				return []byte("Boot-out failed: 3: No such process"), errors.New("exit status 3")
			}
			loaded = false
		case "print":
			if !loaded {
				return []byte("Could not find service"), errors.New("exit status 113")
			}
			return []byte("gui/501/dev.sessionkit.skit = {\n\tstate = running\n\tprogram = /x/skit\n\tpid = 4242\n}\n"), nil
		}
		return nil, nil
	}
	return l, &calls
}

func TestInstallStatusUninstall(t *testing.T) {
	l, calls := fake(t)
	home := filepath.Join(t.TempDir(), "skit home & more")
	bin := filepath.Join(t.TempDir(), "skit")
	os.WriteFile(bin, []byte("#!/bin/sh\n"), 0o755)

	if st := l.inspect(); st.Installed || st.Running || !strings.Contains(st.Detail, "not installed") {
		t.Fatalf("before install: %+v", st)
	}
	st, err := l.install(Config{Binary: bin, SkitHome: home, SetSkitHome: true})
	if err != nil {
		t.Fatal(err)
	}
	if !st.Installed || !st.Running || st.PID != 4242 || st.Binary != bin || !st.BinaryExists || st.Log != filepath.Join(home, "serve.log") {
		t.Fatalf("after install: %+v", st)
	}
	plist, _ := os.ReadFile(st.Plist)
	for _, want := range []string{"<string>serve</string>", "<string>--quiet</string>", "<key>KeepAlive</key>", "<key>RunAtLoad</key>", "<key>SKIT_HOME</key>", "skit home &amp; more"} {
		if !strings.Contains(string(plist), want) {
			t.Fatalf("plist lacks %q:\n%s", want, plist)
		}
	}
	if got := strings.Join(*calls, " | "); !strings.Contains(got, "bootout gui/501/"+Label+" | bootstrap gui/501 "+st.Plist) {
		t.Fatalf("install must unload any previous agent, then load the new plist: %s", got)
	}

	// Installing again replaces the agent (after a rebuild or a move).
	if st, err := l.install(Config{Binary: bin, SkitHome: home}); err != nil || !st.Running {
		t.Fatalf("second install: %+v %v", st, err)
	}
	if b, _ := os.ReadFile(st.Plist); strings.Contains(string(b), "EnvironmentVariables") {
		t.Fatal("a default home needs no environment in the plist")
	}

	// The binary disappears: status says so.
	os.Remove(bin)
	if st := l.inspect(); st.BinaryExists || !strings.Contains(st.Detail, "no longer exists") {
		t.Fatalf("missing binary: %+v", st)
	}

	st, err = l.uninstall()
	if err != nil || st.Installed || st.Running {
		t.Fatalf("after uninstall: %+v %v", st, err)
	}
	if _, err := os.Stat(st.Plist); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("the plist should be gone")
	}
	if _, err := l.uninstall(); err != nil {
		t.Fatalf("uninstalling twice is fine: %v", err)
	}
}

// TestInstallWaitsForTheProcess: launchd loads the agent, then starts it. A
// status read in between must not be what install reports.
func TestInstallWaitsForTheProcess(t *testing.T) {
	l, _ := fake(t)
	inner, prints, waits := l.run, 0, 0
	l.run = func(args ...string) ([]byte, error) {
		if args[0] == "print" {
			if prints++; prints <= 2 {
				return []byte("gui/501/dev.sessionkit.skit = {\n\tstate = spawn scheduled\n}\n"), nil
			}
		}
		return inner(args...)
	}
	l.wait = func() { waits++ }
	bin := filepath.Join(t.TempDir(), "skit")
	os.WriteFile(bin, []byte("#!/bin/sh\n"), 0o755)
	st, err := l.install(Config{Binary: bin, SkitHome: t.TempDir()})
	if err != nil || !st.Running || st.PID != 4242 || waits != 2 {
		t.Fatalf("install should wait until the process is up: %+v err=%v waits=%d", st, err, waits)
	}
}

// TestReinstallWaitsForTheOldAgentToGo: launchd answers bootout at once and
// tears the agent down afterwards. A bootstrap sent in between fails with
// "5: Input/output error" and leaves nothing running, which is what a second
// `skit service install` did on a real Mac.
func TestReinstallWaitsForTheOldAgentToGo(t *testing.T) {
	l, calls := fake(t)
	bin := filepath.Join(t.TempDir(), "skit")
	os.WriteFile(bin, []byte("#!/bin/sh\n"), 0o755)
	l.wait = func() {}
	if _, err := l.install(Config{Binary: bin, SkitHome: t.TempDir()}); err != nil {
		t.Fatal(err)
	}

	// From here launchd is slow: after a bootout the agent lingers for two
	// status checks, and the first bootstrap after that is refused.
	inner, lingering, refused := l.run, 0, 0
	l.run = func(args ...string) ([]byte, error) {
		switch args[0] {
		case "bootout":
			lingering = 2
		case "print":
			if lingering > 0 {
				lingering--
				return []byte("state = running\n\tpid = 4242\n"), nil
			}
		case "bootstrap":
			if lingering > 0 {
				t.Fatal("bootstrap was sent while the old agent was still being torn down")
			}
			if refused == 0 {
				refused++
				return []byte("Bootstrap failed: 5: Input/output error"), errors.New("exit status 5")
			}
		}
		return inner(args...)
	}
	*calls = nil
	st, err := l.install(Config{Binary: bin, SkitHome: t.TempDir()})
	if err != nil || !st.Running {
		t.Fatalf("a second install must leave the agent running: %+v err=%v\ncalls: %s", st, err, strings.Join(*calls, " | "))
	}
	if refused != 1 {
		t.Fatalf("the refused bootstrap should have been retried once, was refused %d times", refused)
	}
}

func TestInstallRefusesABadBinary(t *testing.T) {
	l, calls := fake(t)
	if _, err := l.install(Config{Binary: "skit", SkitHome: t.TempDir()}); err == nil {
		t.Fatal("a relative path must be refused: launchd has no working directory to resolve it")
	}
	if _, err := l.install(Config{Binary: filepath.Join(t.TempDir(), "gone"), SkitHome: t.TempDir()}); err == nil {
		t.Fatal("a missing binary must be refused")
	}
	if len(*calls) != 0 {
		t.Fatalf("nothing should reach launchctl: %v", *calls)
	}
}
