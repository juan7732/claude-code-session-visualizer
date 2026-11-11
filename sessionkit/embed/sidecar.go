package embed

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// SidecarOptions say how to run llama-server.
type SidecarOptions struct {
	Binary string // path to llama-server (see FindBinary)
	Model  string // path to the GGUF file
	// RunDir, when set, gets one small file per running sidecar so a later
	// skit can stop one whose owner was killed before it could (see Reap).
	RunDir string
	// CPUOnly keeps every layer off the GPU: about a tenth of the speed.
	CPUOnly bool
	// StartTimeout bounds the wait for the model to load. Zero means a minute.
	StartTimeout time.Duration
}

// Sidecar is a running llama-server that this process started and owns.
type Sidecar struct {
	Client
	cmd     *exec.Cmd
	done    chan struct{} // closed when the process has exited
	log     *tail
	runFile string
}

// FindBinary locates llama-server: the explicit path when one is given, else
// the app bundle's Helpers directory beside this executable, else PATH, else
// where Homebrew installs it.
func FindBinary(explicit string) (string, error) {
	if explicit != "" {
		if fi, err := os.Stat(explicit); err != nil || fi.IsDir() {
			return "", fmt.Errorf("llama-server not found at %s", explicit)
		}
		return explicit, nil
	}
	if exe, err := os.Executable(); err == nil {
		for _, rel := range []string{"llama-server", "../Helpers/llama-server"} {
			p := filepath.Join(filepath.Dir(exe), rel)
			if fi, err := os.Stat(p); err == nil && !fi.IsDir() {
				return p, nil
			}
		}
	}
	if p, err := exec.LookPath("llama-server"); err == nil {
		return p, nil
	}
	// DECISION: Homebrew's directories are named outright. The background
	// agent runs under launchd, whose PATH is /usr/bin:/bin:/usr/sbin:/sbin, so
	// a `brew install llama.cpp` that every shell finds was invisible to
	// `skit serve` and meaning search failed only from the app.
	for _, p := range homebrewBinaries {
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() {
			return p, nil
		}
	}
	return "", errors.New("llama-server not found (install it with `brew install llama.cpp`, or point SKIT_LLAMA_SERVER at the binary)")
}

// homebrewBinaries is where `brew install llama.cpp` puts llama-server: Apple
// silicon first, then Intel. A variable so a test can point it elsewhere.
var homebrewBinaries = []string{"/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"}

// StartSidecar runs llama-server on a free loopback port with a random API key
// and returns once it answers /health. ctx bounds the start only.
//
// SPEC: docs/decisions/0005-embedding-worker.md gives the flags. Added here:
// the key travels in the environment so it is not in the process list,
// --offline so the server itself can never reach the network, and the web UI
// and slots routes are off because nothing uses them.
func StartSidecar(ctx context.Context, opt SidecarOptions) (*Sidecar, error) {
	if opt.Binary == "" || opt.Model == "" {
		return nil, errors.New("sidecar needs a llama-server binary and a model file")
	}
	if opt.StartTimeout <= 0 {
		opt.StartTimeout = time.Minute
	}
	if opt.RunDir != "" {
		Reap(opt.RunDir)
	}
	ctx, cancel := context.WithTimeout(ctx, opt.StartTimeout)
	defer cancel()
	var last error
	// The port is picked by binding and releasing it, so another process can
	// take it in between. That shows as an early exit; try again with a new one.
	for attempt := 0; attempt < 3; attempt++ {
		sc, err := startOnce(ctx, opt)
		if err == nil {
			return sc, nil
		}
		last = err
		if ctx.Err() != nil || !errors.Is(err, errExitedEarly) {
			break
		}
	}
	return nil, last
}

var errExitedEarly = errors.New("llama-server exited before it was ready")

func startOnce(ctx context.Context, opt SidecarOptions) (*Sidecar, error) {
	port, err := freePort()
	if err != nil {
		return nil, err
	}
	keyBytes := make([]byte, 16)
	if _, err := rand.Read(keyBytes); err != nil {
		return nil, err
	}
	key := hex.EncodeToString(keyBytes)
	layers := "99"
	if opt.CPUOnly {
		layers = "0"
	}
	cmd := exec.Command(opt.Binary, "-m", opt.Model, "--embeddings", "--pooling", "mean",
		"-c", "2048", "-b", "2048", "-ub", "2048", "-ngl", layers,
		"--host", "127.0.0.1", "--port", strconv.Itoa(port), "--offline", "--no-webui", "--no-slots")
	cmd.Env = append(os.Environ(), "LLAMA_API_KEY="+key)
	logTail := &tail{max: 4096}
	cmd.Stdout, cmd.Stderr = logTail, logTail
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start %s: %w", opt.Binary, err)
	}
	sc := &Sidecar{
		Client: Client{BaseURL: fmt.Sprintf("http://127.0.0.1:%d", port), Key: key, HTTP: &http.Client{}},
		cmd:    cmd, done: make(chan struct{}), log: logTail,
	}
	go func() {
		_ = cmd.Wait()
		close(sc.done)
	}()
	if opt.RunDir != "" {
		sc.runFile = writeRunFile(opt.RunDir, runRecord{Owner: os.Getpid(), PID: cmd.Process.Pid, Binary: opt.Binary, Started: time.Now().UTC()})
	}
	tick := time.NewTicker(40 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-sc.done:
			sc.removeRunFile()
			return nil, fmt.Errorf("%w: %s", errExitedEarly, logTail.lastLines(4))
		case <-ctx.Done():
			_ = sc.Stop()
			return nil, fmt.Errorf("llama-server was not ready in time: %s", logTail.lastLines(2))
		case <-tick.C:
			if sc.healthy(ctx) {
				return sc, nil
			}
		}
	}
}

func (s *Sidecar) healthy(ctx context.Context) bool {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.BaseURL+"/health", nil)
	if err != nil {
		return false
	}
	resp, err := s.HTTP.Do(req)
	if err != nil {
		return false
	}
	resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

// PID is the server's process id.
func (s *Sidecar) PID() int { return s.cmd.Process.Pid }

// Exited reports whether the process is gone (stopped, or died on its own).
func (s *Sidecar) Exited() bool {
	select {
	case <-s.done:
		return true
	default:
		return false
	}
}

// Stop ends the server: a polite signal first, then a kill if it lingers.
func (s *Sidecar) Stop() error {
	defer s.removeRunFile()
	if s.Exited() {
		return nil
	}
	_ = s.cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-s.done:
		return nil
	case <-time.After(3 * time.Second):
	}
	_ = s.cmd.Process.Kill()
	select {
	case <-s.done:
		return nil
	case <-time.After(3 * time.Second):
		return fmt.Errorf("llama-server (pid %d) did not exit", s.PID())
	}
}

func (s *Sidecar) removeRunFile() {
	if s.runFile != "" {
		os.Remove(s.runFile)
	}
}

func freePort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}

// runRecord is what a run file holds.
type runRecord struct {
	Owner   int       `json:"owner"` // the skit process that started the server
	PID     int       `json:"pid"`
	Binary  string    `json:"binary"`
	Started time.Time `json:"started"`
}

func writeRunFile(dir string, r runRecord) string {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return ""
	}
	b, _ := json.Marshal(r)
	p := filepath.Join(dir, fmt.Sprintf("llama-server-%d.json", r.PID))
	if os.WriteFile(p, b, 0o600) != nil {
		return ""
	}
	return p
}

// Reap stops sidecars whose owner is gone: a skit that was killed outright
// cannot stop its server, and a 540 MB process should not outlive it for long.
// It returns how many it stopped. A server whose owner is alive is left alone.
func Reap(runDir string) int {
	files, _ := filepath.Glob(filepath.Join(runDir, "llama-server-*.json"))
	stopped := 0
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		var r runRecord
		if json.Unmarshal(b, &r) != nil || r.PID <= 0 {
			os.Remove(f)
			continue
		}
		if alive(r.Owner) {
			continue
		}
		// Process ids are reused: only signal a process that still looks like
		// the server we started.
		if alive(r.PID) && commandMatches(r.PID, r.Binary) {
			if syscall.Kill(r.PID, syscall.SIGTERM) == nil {
				stopped++
			}
		}
		os.Remove(f)
	}
	return stopped
}

func alive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

// commandMatches asks ps for the process's command name. Linux truncates it to
// 15 characters, so a prefix of the binary's name counts.
func commandMatches(pid int, binary string) bool {
	out, err := exec.Command("ps", "-o", "comm=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return false
	}
	got := filepath.Base(strings.TrimSpace(string(out)))
	want := filepath.Base(binary)
	return got != "" && (got == want || strings.HasPrefix(want, got))
}

// tail keeps the last bytes a process wrote, for error messages.
type tail struct {
	mu  sync.Mutex
	max int
	buf []byte
}

func (t *tail) Write(p []byte) (int, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.buf = append(t.buf, p...)
	if len(t.buf) > t.max {
		t.buf = t.buf[len(t.buf)-t.max:]
	}
	return len(p), nil
}

func (t *tail) lastLines(n int) string {
	t.mu.Lock()
	defer t.mu.Unlock()
	lines := strings.Split(strings.TrimSpace(string(t.buf)), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	if len(lines) == 1 && lines[0] == "" {
		return "(it printed nothing)"
	}
	return strings.Join(lines, " | ")
}
