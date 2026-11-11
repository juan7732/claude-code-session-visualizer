package now

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeProcs is a process table: pid → parent, executable, environment, listening ports.
type fakeProcs map[int]struct {
	parent int
	exe    string
	env    map[string]string
	ports  []int
}

func (f fakeProcs) Parent(pid int) (int, string, bool) {
	p, ok := f[pid]
	return p.parent, p.exe, ok
}
func (f fakeProcs) Env(pid int, key string) string { return f[pid].env[key] }
func (f fakeProcs) Listening(pid int) []int        { return f[pid].ports }

const (
	codeHost = "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
	terminal = "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
)

// TestWhichWindow: two editor windows, sessions of the extension in each, one
// started in the editor's terminal, one in a terminal of its own.
func TestWhichWindow(t *testing.T) {
	home := t.TempDir()
	claude := filepath.Join(home, ".claude")
	alpha, beta := filepath.Join(home, "ws", "alpha"), filepath.Join(home, "ws", "beta")
	shared := filepath.Join(home, "ws", "shared")
	for _, d := range []string{alpha, beta, shared, filepath.Join(claude, "ide")} {
		os.MkdirAll(d, 0o755)
	}
	writeJSON := func(path string, v any) {
		b, _ := json.Marshal(v)
		os.MkdirAll(filepath.Dir(path), 0o755)
		if err := os.WriteFile(path, b, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// Window one is on a workspace of two folders, window two on one folder; both have "shared" open... only one does.
	workspace := filepath.Join(home, "ws", "pair.code-workspace")
	os.WriteFile(workspace, []byte("{\n  // the pair\n  \"folders\": [{\"path\": \"alpha\"}, {\"path\": \""+shared+"\"},],\n}\n"), 0o644)
	writeJSON(filepath.Join(claude, "ide", "4001.lock"), map[string]any{"pid": 100, "workspaceFolders": []string{alpha, shared}, "ideName": "Visual Studio Code", "authToken": "SECRET"})
	writeJSON(filepath.Join(claude, "ide", "4002.lock"), map[string]any{"pid": 100, "workspaceFolders": []string{beta + "/"}, "ideName": "Visual Studio Code", "authToken": "SECRET"})
	writeJSON(filepath.Join(claude, "ide", "4003.lock"), map[string]any{"pid": 999, "workspaceFolders": []string{beta}, "ideName": "Visual Studio Code"}) // its editor is gone
	writeJSON(filepath.Join(home, "Library", "Application Support", "Code", "User", "globalStorage", "storage.json"), map[string]any{"windowsState": map[string]any{
		"lastActiveWindow": map[string]any{"workspaceIdentifier": map[string]any{"id": "x", "configURIPath": "file://" + workspace}},
		"openedWindows":    []any{map[string]any{"folder": "file://" + beta}, map[string]any{"folder": "vscode-remote://ssh/elsewhere"}},
	}})

	procs := fakeProcs{
		100: {parent: 1, exe: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"},
		201: {parent: 100, exe: codeHost, ports: []int{50001, 4001}},                                                                   // window one's extension host
		202: {parent: 100, exe: codeHost, ports: []int{4002}},                                                                          // window two's
		203: {parent: 100, exe: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"}, // the terminals' host, shared by all windows
		301: {parent: 201, exe: "/Users/me/.vscode/extensions/anthropic.claude-code/resources/native-binary/claude"},
		302: {parent: 202, exe: "/Users/me/.vscode/extensions/anthropic.claude-code/resources/native-binary/claude", env: map[string]string{"CLAUDE_CODE_SSE_PORT": "59999"}}, // a port no window has: left over
		401: {parent: 203, exe: "/bin/zsh"},
		402: {parent: 401, exe: "/usr/local/bin/claude", env: map[string]string{"CLAUDE_CODE_SSE_PORT": "4002"}},
		500: {parent: 1, exe: terminal},
		501: {parent: 500, exe: "/usr/bin/login"},
		502: {parent: 501, exe: "/bin/zsh"},
		503: {parent: 502, exe: "/usr/local/bin/claude", env: map[string]string{"CLAUDE_CODE_SSE_PORT": "4001"}},
		601: {parent: 1, exe: "/usr/local/bin/claude"},
	}
	alive := func(pid int) bool { return pid != 999 }
	find := func(pid int, cwd string) *Host { return findHost(procs, claude, pid, cwd, alive) }

	// The extension's session: its parent listens on its window's port. Whatever folder it works in.
	h := find(301, beta)
	if h == nil || h.Kind != "editor" || h.App != "Visual Studio Code" || h.AppPath != "/Applications/Visual Studio Code.app" || !h.Sure ||
		h.Open != workspace || len(h.Folders) != 2 {
		t.Fatalf("window one, by its port: %+v", h)
	}
	// Window two is on one folder: that folder is what brings it forward.
	if h := find(302, alpha); h == nil || !h.Sure || h.Open != beta || len(h.Folders) != 1 || h.Folders[0] != beta {
		t.Fatalf("window two: %+v", h)
	}
	// `claude` in the editor's own terminal: the terminals' host is shared, the port it was told is not.
	if h := find(402, alpha); h == nil || h.Kind != "editor" || !h.Sure || h.Open != beta {
		t.Fatalf("in the editor's terminal: %+v", h)
	}
	// A terminal of its own, even one connected to an editor's window.
	if h := find(503, alpha); h == nil || h.Kind != "terminal" || h.App != "Terminal" || h.AppPath != "/System/Applications/Utilities/Terminal.app" || h.Open != "" {
		t.Fatalf("a terminal: %+v", h)
	}
	// Nothing the process tree says (a multiplexer, a daemon), but an editor has its folder open: that window, as a choice.
	if h := find(601, filepath.Join(shared, "sub")); h == nil || h.Kind != "editor" || h.Sure || h.Open != workspace {
		t.Fatalf("by its folder: %+v", h)
	}
	if h := find(601, "/somewhere/else"); h != nil {
		t.Fatalf("nothing to go by: %+v", h)
	}
	// A process that is gone.
	if h := find(777, "/somewhere/else"); h != nil {
		t.Fatalf("no such process: %+v", h)
	}

	// The editor has not recorded the window yet: a workspace file beside the folders that lists exactly them is found.
	os.Remove(filepath.Join(home, "Library", "Application Support", "Code", "User", "globalStorage", "storage.json"))
	if h := find(301, alpha); h.Open != workspace {
		t.Fatalf("without the editor's record: %+v", h)
	}
	// No such file either: the window on several folders cannot be named, and opening one folder would make a new window.
	os.Remove(workspace)
	if h := find(301, alpha); h.Open != "" || !h.Sure || h.App != "Visual Studio Code" {
		t.Fatalf("a window that cannot be named: %+v", h)
	}
	b, _ := json.Marshal(find(301, alpha))
	if string(b) == "" || strings.Contains(string(b), "SECRET") {
		t.Fatalf("the lock's token must stay where it is: %s", b)
	}
}

// TestHostIsInTheReportAndKept: a running session carries its host; the
// process table is asked once, not at every look.
func TestHostIsInTheReportAndKept(t *testing.T) {
	h := newHome(t)
	asked := 0
	procs := countingProcs{fakeProcs{
		1:   {parent: 500, exe: "/usr/local/bin/claude"},
		500: {parent: 1, exe: terminal},
	}, &asked}
	r := &Reader{Alive: func(int) bool { return true }, Processes: procs}
	h.session("tool", 62, prompt("u1", 0, "Fix the build"), request(1), answer("a1", 60, "tool_use", bash("t1"), hour))
	h.process(1, "tool", "busy", "", 0)
	h.session("closed", 90, prompt("u1", 0, "x"), answer("a1", 80, "end_turn", `{"type":"text","text":"Done."}`, hour))

	by := h.read(r, 100, Options{})
	if host := by["tool"].Host; host == nil || host.Kind != "terminal" || host.App != "Terminal" {
		t.Fatalf("a running session's host: %+v", host)
	}
	if by["closed"].Host != nil {
		t.Fatalf("a closed session is nowhere: %+v", by["closed"].Host)
	}
	first := asked
	h.read(r, 103, Options{})
	h.read(r, 106, Options{})
	if asked != first {
		t.Errorf("the process table was asked again within %v: %d then %d", hostFor, first, asked)
	}
	h.read(r, 100+int(hostFor/time.Second)+1, Options{})
	if asked == first {
		t.Error("what was found is kept for ever")
	}
	// The process ends: what was found of it is dropped.
	os.Remove(filepath.Join(h.claude, "sessions", fmt.Sprintf("%d.json", 1)))
	h.read(r, 200, Options{})
	if len(r.hosts) != 0 {
		t.Errorf("hosts kept for processes that are gone: %d", len(r.hosts))
	}
}

type countingProcs struct {
	fakeProcs
	asked *int
}

func (c countingProcs) Parent(pid int) (int, string, bool) {
	*c.asked++
	return c.fakeProcs.Parent(pid)
}
