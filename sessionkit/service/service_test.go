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
