package now

import (
	"context"
	"encoding/json"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Host is where a running session's process lives: an editor's window, or a
// terminal. It is what "take me back to it" needs: which application, and what
// to open with it so the right window comes to the front.
type Host struct {
	// Kind is "editor" when the session runs in an editor's window (the
	// extension, or `claude` in the editor's own terminal), "terminal" when
	// its process descends from another application.
	Kind string `json:"kind"`
	// App is the application's name ("Visual Studio Code", "Terminal"), and
	// AppPath its bundle, when the process tree shows one.
	App     string `json:"app"`
	AppPath string `json:"app_path,omitempty"`
	// Open is what to open with the application to bring that window forward:
	// the workspace file of a window on several folders, or its one folder.
	// Empty when the window cannot be named: opening the application is then
	// all that can be done.
	Open string `json:"open,omitempty"`
	// Folders are the window's workspace folders, as the editor told Claude Code.
	Folders []string `json:"folders,omitempty"`
	// Sure is true when the window was found from the session's own process,
	// false when it was chosen because it has the session's folder open (two
	// windows can).
	Sure bool `json:"sure"`
}

// Processes is what finding a session's window asks of the system.
type Processes interface {
	// Parent is the process's parent and its own executable's path.
	Parent(pid int) (ppid int, exe string, ok bool)
	// Env is the value of one variable of the process's environment, "" when unset or unreadable.
	Env(pid int, key string) string
	// Listening lists the TCP ports the process listens on.
	Listening(pid int) []int
}

// hostFor is how long what was found of a process's window is kept. The
// window does not change; what the editor recorded about it can.
const hostFor = 30 * time.Second

type hostEntry struct {
	started int64
	at      time.Time
	host    *Host
}

// lock is one of the files an editor's Claude Code extension writes per
// window, <claude>/ide/<port>.lock.
type lock struct {
	port    int
	PID     int      `json:"pid"`
	Folders []string `json:"workspaceFolders"`
	IDE     string   `json:"ideName"`
}

// hostOf finds the window or terminal a running session's process is in.
//
// How a window is found, as measured on a Mac with two VS Code windows
// (2026-11-11): each window's extension listens on a port and writes
// ide/<port>.lock with the window's folders; the session's process is a child
// of that window's extension host, and the extension host is the process that
// listens on that port. `claude` run in the editor's own terminal is told the
// port in CLAUDE_CODE_SSE_PORT instead. When neither says (lsof is missing, a
// lock is stale), the window that has the session's folder open is taken, and
// Sure says it was a choice.
func (r *Reader) hostOf(claudeDir string, pid int, started int64, cwd string, now time.Time) *Host {
	r.mu.Lock()
	if e, ok := r.hosts[pid]; ok && e.started == started && now.Sub(e.at) < hostFor && now.Sub(e.at) >= 0 {
		r.mu.Unlock()
		return e.host
	}
	r.mu.Unlock()

	procs := r.Processes
	if procs == nil {
		procs = system{}
	}
	h := findHost(procs, claudeDir, pid, cwd, r.aliveFunc())
	r.mu.Lock()
	if r.hosts == nil {
		r.hosts = map[int]hostEntry{}
	}
	r.hosts[pid] = hostEntry{started: started, at: now, host: h}
	r.mu.Unlock()
	return h
}

func findHost(procs Processes, claudeDir string, pid int, cwd string, alive func(int) bool) *Host {
	// The application: the nearest ancestor that runs from inside a bundle.
	var app, appPath string
	ppid, _, ok := procs.Parent(pid)
	parent := ppid
	for at, depth := ppid, 0; ok && at > 1 && depth < 12; depth++ {
		next, exe, found := procs.Parent(at)
		if !found {
			break
		}
		if i := strings.Index(exe, ".app/"); i >= 0 {
			appPath = exe[:i+4]
			app = strings.TrimSuffix(filepath.Base(appPath), ".app")
			break
		}
		at = next
	}

	locks := readLocks(filepath.Join(claudeDir, "ide"), alive)
	byPort := map[int]*lock{}
	for i := range locks {
		byPort[locks[i].port] = &locks[i]
	}
	var window *lock
	sure := false
	// `claude` in the editor's terminal is told its window's port.
	if port, err := strconv.Atoi(procs.Env(pid, "CLAUDE_CODE_SSE_PORT")); err == nil && byPort[port] != nil {
		window, sure = byPort[port], true
	}
	// The extension's session is a child of the process that listens on its window's port.
	if window == nil && ok && parent > 1 && len(locks) > 0 {
		for _, port := range procs.Listening(parent) {
			if byPort[port] != nil {
				window, sure = byPort[port], true
				break
			}
		}
	}
	// Else the window that has the session's folder open; the deepest folder wins.
	if window == nil && cwd != "" && (app == "" || isEditor(app)) {
		best := -1
		for i := range locks {
			for _, f := range locks[i].Folders {
				if (cwd == f || strings.HasPrefix(cwd, strings.TrimSuffix(f, "/")+"/")) && len(f) > best {
					best, window = len(f), &locks[i]
				}
			}
		}
	}

	switch {
	case app != "" && !isEditor(app):
		// A terminal of its own, even one connected to an editor: the session is in the terminal.
		return &Host{Kind: "terminal", App: app, AppPath: appPath, Sure: true}
	case window != nil:
		h := &Host{Kind: "editor", App: window.IDE, AppPath: appPath, Folders: window.Folders, Sure: sure}
		if h.App == "" {
			h.App = app
		}
		h.Open = opensWith(filepath.Dir(claudeDir), h.App, window.Folders)
		return h
	case app != "" && isEditor(app):
		return &Host{Kind: "editor", App: app, AppPath: appPath}
	}
	return nil
}

// editors maps an editor's name, as its extension gives it, to the folder its
// state is kept in under ~/Library/Application Support.
//
// REVIEW: only Visual Studio Code was on the machine this was built on; the
// others are VS Code's kin and keep the same file in a folder of their own name.
var editors = map[string]string{
	"Visual Studio Code":            "Code",
	"Visual Studio Code - Insiders": "Code - Insiders",
	"Cursor":                        "Cursor",
	"Windsurf":                      "Windsurf",
	"VSCodium":                      "VSCodium",
}

func isEditor(app string) bool {
	_, ok := editors[app]
	return ok || strings.HasPrefix(app, "Code")
}

func readLocks(dir string, alive func(int) bool) []lock {
	files, _ := filepath.Glob(filepath.Join(dir, "*.lock"))
	sort.Strings(files)
	var out []lock
	for _, p := range files {
		port, err := strconv.Atoi(strings.TrimSuffix(filepath.Base(p), ".lock"))
		if err != nil {
			continue
		}
		b, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		// Only the window's folders and the editor's name are read: the file also holds a token.
		l := lock{port: port}
		if json.Unmarshal(b, &l) != nil || (l.PID > 0 && !alive(l.PID)) {
			continue
		}
		for i, f := range l.Folders {
			l.Folders[i] = filepath.Clean(f)
		}
		out = append(out, l)
	}
	return out
}

// opensWith says what to open so the editor brings the window with these
// folders forward: the workspace file the editor has that window open on, the
// one folder of a window on one, or "" when that cannot be told.
//
// DECISION: for a window on several folders the workspace file is needed.
// Opening one of its folders would make a new window on that folder alone.
// The editor records its open windows in globalStorage/storage.json; the one
// whose workspace lists exactly these folders is the window.
func opensWith(home, ide string, folders []string) string {
	if len(folders) == 0 {
		return ""
	}
	want := folderSet(folders)
	dir := editors[ide]
	if dir == "" {
		dir = "Code"
	}
	var state struct {
		Windows struct {
			Last   *editorWindow  `json:"lastActiveWindow"`
			Opened []editorWindow `json:"openedWindows"`
		} `json:"windowsState"`
	}
	if b, err := os.ReadFile(filepath.Join(home, "Library", "Application Support", dir, "User", "globalStorage", "storage.json")); err == nil {
		_ = json.Unmarshal(b, &state)
	}
	windows := state.Windows.Opened
	if state.Windows.Last != nil {
		windows = append(windows, *state.Windows.Last)
	}
	for _, w := range windows {
		if file := filePath(w.Workspace.Config); file != "" {
			if sameSet(workspaceFolders(file), want) {
				return file
			}
			continue
		}
		if f := filePath(w.Folder); f != "" && len(folders) == 1 && filepath.Clean(f) == folders[0] {
			return folders[0]
		}
	}
	if len(folders) == 1 {
		return folders[0]
	}
	// Not in the editor's record (it writes it late): a workspace file beside the folders that lists them.
	seen := map[string]bool{}
	for _, f := range folders {
		for _, d := range []string{f, filepath.Dir(f)} {
			if seen[d] {
				continue
			}
			seen[d] = true
			files, _ := filepath.Glob(filepath.Join(d, "*.code-workspace"))
			for _, file := range files {
				if sameSet(workspaceFolders(file), want) {
					return file
				}
			}
		}
	}
	return ""
}

type editorWindow struct {
	Folder    string `json:"folder"`
	Workspace struct {
		Config string `json:"configURIPath"`
	} `json:"workspaceIdentifier"`
}

// filePath is the path of a file:// URI, "" for anything else (a remote window).
func filePath(uri string) string {
	u, err := url.Parse(uri)
	if err != nil || u.Scheme != "file" {
		return ""
	}
	return u.Path
}

var (
	lineComment   = regexp.MustCompile(`(?m)^\s*//.*$`)
	trailingComma = regexp.MustCompile(`,(\s*[\]}])`)
)

// workspaceFolders reads the folders of a .code-workspace file, as absolute paths.
func workspaceFolders(file string) map[string]bool {
	b, err := os.ReadFile(file)
	if err != nil {
		return nil
	}
	var ws struct {
		Folders []struct {
			Path string `json:"path"`
		} `json:"folders"`
	}
	if json.Unmarshal(b, &ws) != nil {
		// The file may carry comments and trailing commas; whole-line comments and the commas are all that is forgiven.
		clean := trailingComma.ReplaceAll(lineComment.ReplaceAll(b, nil), []byte("$1"))
		if json.Unmarshal(clean, &ws) != nil {
			return nil
		}
	}
	var paths []string
	for _, f := range ws.Folders {
		if f.Path == "" {
			continue
		}
		p := f.Path
		if !filepath.IsAbs(p) {
			p = filepath.Join(filepath.Dir(file), p)
		}
		paths = append(paths, p)
	}
	return folderSet(paths)
}

func folderSet(paths []string) map[string]bool {
	set := map[string]bool{}
	for _, p := range paths {
		set[filepath.Clean(p)] = true
	}
	return set
}

func sameSet(a, b map[string]bool) bool {
	if len(a) == 0 || len(a) != len(b) {
		return false
	}
	for k := range a {
		if !b[k] {
			return false
		}
	}
	return true
}

// system asks ps and lsof.
//
// DECISION: two tools every Mac has, run once per session process and kept
// for half a minute, in place of the system calls behind them: those need
// cgo, and skit is built without it so one binary runs anywhere.
type system struct{}

func run(name string, args ...string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, name, args...).Output()
	if err != nil {
		return ""
	}
	return string(out)
}

func (system) Parent(pid int) (int, string, bool) {
	fields := strings.SplitN(strings.TrimSpace(run("ps", "-o", "ppid=,comm=", "-p", strconv.Itoa(pid))), " ", 2)
	ppid, err := strconv.Atoi(fields[0])
	if err != nil {
		return 0, "", false
	}
	exe := ""
	if len(fields) > 1 {
		exe = strings.TrimSpace(fields[1])
	}
	return ppid, exe, true
}

func (system) Env(pid int, key string) string {
	// `ps e` prints the environment after the command, separated by spaces: enough for a value without any.
	out := run("ps", "eww", "-o", "command=", "-p", strconv.Itoa(pid))
	for _, word := range strings.Fields(out) {
		if v, ok := strings.CutPrefix(word, key+"="); ok {
			return v
		}
	}
	return ""
}

func (system) Listening(pid int) []int {
	var ports []int
	for _, line := range strings.Split(run("lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", strconv.Itoa(pid), "-Fn"), "\n") {
		if !strings.HasPrefix(line, "n") {
			continue
		}
		if i := strings.LastIndexByte(line, ':'); i >= 0 {
			if port, err := strconv.Atoi(line[i+1:]); err == nil {
				ports = append(ports, port)
			}
		}
	}
	return ports
}
