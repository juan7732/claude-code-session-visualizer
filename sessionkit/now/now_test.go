package now

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
)

var base = time.Date(2026, 11, 11, 10, 0, 0, 0, time.UTC)

func at(seconds int) string {
	return base.Add(time.Duration(seconds) * time.Second).Format(time.RFC3339Nano)
}

// Lines of a transcript, in the shapes Claude Code writes (cut down).
func prompt(uuid string, s int, text string) string {
	return fmt.Sprintf(`{"type":"user","uuid":%q,"cwd":"/w","turnOrigin":"human","timestamp":%q,"message":{"role":"user","content":%q}}`, uuid, at(s), text)
}

func request(s int) string {
	return fmt.Sprintf(`{"type":"api-request","id":"ar","timestamp":%q}`, at(s))
}

func answer(uuid string, s int, stop, blocks string, cache string) string {
	return fmt.Sprintf(`{"type":"assistant","uuid":%q,"requestId":"req_%s","timestamp":%q,"message":{"id":"m","model":"claude-fable-5-1","role":"assistant","stop_reason":%q,"content":[%s],"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":900,"cache_creation_input_tokens":90,"cache_creation":{%s}}}}`,
		uuid, uuid, at(s), stop, blocks, cache)
}

func result(uuid string, s int, id string) string {
	return fmt.Sprintf(`{"type":"user","uuid":%q,"timestamp":%q,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":%q,"content":"ok"}]}}`, uuid, at(s), id)
}

const (
	hour     = `"ephemeral_1h_input_tokens":90,"ephemeral_5m_input_tokens":0`
	five     = `"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":90`
	lastWord = `{"type":"last-prompt","lastPrompt":"Fix the build"}`
	title    = `{"type":"ai-title","aiTitle":"Fixing the build"}`
)

func bash(id string) string {
	return fmt.Sprintf(`{"type":"tool_use","id":%q,"name":"Bash","input":{"command":"go test ./...","description":"Run the tests"}}`, id)
}

// sid makes a session id out of a word, so the tests can name sessions by what they are.
func sid(name string) string {
	hex := fmt.Sprintf("%x", name)
	return (hex + strings.Repeat("0", 32))[:8] + "-0000-0000-0000-" + fmt.Sprintf("%012d", len(name))
}

type home struct {
	t      *testing.T
	claude string
}

func newHome(t *testing.T) *home {
	h := &home{t: t, claude: filepath.Join(t.TempDir(), ".claude")}
	os.MkdirAll(filepath.Join(h.claude, "projects", "-w"), 0o755)
	os.MkdirAll(filepath.Join(h.claude, "sessions"), 0o755)
	return h
}

// session writes a transcript last touched at `touched` seconds.
func (h *home) session(id string, touched int, lines ...string) string {
	p := filepath.Join(h.claude, "projects", "-w", sid(id)+".jsonl")
	if err := os.WriteFile(p, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		h.t.Fatal(err)
	}
	when := base.Add(time.Duration(touched) * time.Second)
	os.Chtimes(p, when, when)
	return p
}

// process writes the file Claude Code keeps for a running process.
func (h *home) process(pid int, id, status, waitingFor string, statusAt int) {
	ms := base.Add(time.Duration(statusAt) * time.Second).UnixMilli()
	body := fmt.Sprintf(`{"pid":%d,"sessionId":%q,"cwd":"/w","name":"w-1","status":%q,"waitingFor":%q,"entrypoint":"claude-vscode","kind":"interactive","updatedAt":%d,"statusUpdatedAt":%d}`,
		pid, sid(id), status, waitingFor, ms, ms)
	os.WriteFile(filepath.Join(h.claude, "sessions", fmt.Sprintf("%d.json", pid)), []byte(body), 0o644)
}

func (h *home) read(r *Reader, nowAt int, opt Options) map[string]Session {
	h.t.Helper()
	names := map[string]string{}
	for _, n := range []string{"tool", "model", "you", "background", "blocked", "stopped", "closed", "crashed", "quiet", "fresh", "again", "hour", "five", "nocopy", "empty", "big"} {
		names[sid(n)] = n
	}
	rep, err := catalog.InspectDir(h.claude)
	if err != nil {
		h.t.Fatal(err)
	}
	opt.Now = base.Add(time.Duration(nowAt) * time.Second)
	out, err := r.Read(rep, opt)
	if err != nil {
		h.t.Fatal(err)
	}
	by := map[string]Session{"": {Subagents: out.RunningOutside}}
	for i, s := range out.Sessions {
		s.Bytes = int64(i) // its place in the list
		by[names[s.ID]] = s
	}
	return by
}

func TestWhatEachSessionIsDoing(t *testing.T) {
	h := newHome(t)
	running := map[int]bool{1: true, 2: true, 3: true, 4: true, 5: true, 6: true, 8: true, 9: true}
	r := &Reader{Alive: func(pid int) bool { return running[pid] }}

	// 1: a tool is out. 2: its result came back, the model is being asked.
	h.session("tool", 62, title, prompt("u1", 0, "Fix the build"), lastWord, request(1), answer("a1", 60, "tool_use", bash("t1"), hour))
	h.process(1, "tool", "busy", "", 0)
	h.session("model", 70, prompt("u1", 0, "Fix the build"), request(1), answer("a1", 60, "tool_use", bash("t1"), hour), result("r1", 70, "t1"), request(71))
	h.process(2, "model", "busy", "", 0)
	// 3: the turn ended. 4: the same, with a subagent still running.
	h.session("you", 90, prompt("u1", 0, "Fix the build"), request(1), answer("a1", 80, "end_turn", `{"type":"text","text":"The build is fixed.\nDetails follow."}`, five))
	h.process(3, "you", "idle", "", 81)
	h.session("background", 90, prompt("u1", 0, "Fix the build"), request(1), answer("a1", 80, "end_turn", `{"type":"text","text":"Two reviewers are at it."}`, hour))
	h.process(4, "background", "idle", "", 81)
	sub := filepath.Join(h.claude, "projects", "-w", sid("background"), "subagents")
	os.MkdirAll(sub, 0o755)
	for name, meta := range map[string]string{"agent-a": `{"agentType":"Explore"}`, "agent-b": `{"agentType":"Explore","finished":true}`, "agent-old": `{"agentType":"Explore"}`} {
		os.WriteFile(filepath.Join(sub, name+".meta.json"), []byte(meta), 0o644)
		os.WriteFile(filepath.Join(sub, name+".jsonl"), []byte("{}\n"), 0o644)
		when := base.Add(85 * time.Second)
		if name == "agent-old" {
			when = base.Add(-2 * time.Hour) // interrupted long ago: never marked finished
		}
		os.Chtimes(filepath.Join(sub, name+".jsonl"), when, when)
	}
	// 5: Claude Code says it waits inside a turn. 6: stopped by the person, the call never came back.
	h.session("blocked", 62, prompt("u1", 0, "Fix the build"), request(1), answer("a1", 60, "tool_use", bash("t1"), hour))
	h.process(5, "blocked", "waiting", "approve Bash", 61)
	h.session("stopped", 62, prompt("u1", 0, "Fix the build"), request(1), answer("a1", 60, "tool_use", bash("t1"), hour))
	h.process(6, "stopped", "idle", "", 75)
	// No process: closed. A process that died without clearing its file: closed too.
	h.session("closed", 90, prompt("u1", 0, "Fix the build"), request(1), answer("a1", 80, "end_turn", `{"type":"text","text":"Done."}`, hour))
	h.session("crashed", 90, prompt("u1", 0, "Fix the build"), request(1), answer("a1", 80, "tool_use", bash("t1"), hour))
	h.process(7, "crashed", "busy", "", 0)
	// Running and quiet for longer than the window; a process with no transcript yet.
	h.session("quiet", -7200, prompt("u1", -7300, "Earlier"))
	h.process(8, "quiet", "idle", "", -7200)
	h.process(9, "fresh", "idle", "", 95)
	// Busy again after a turn that ended: the next one is not written yet.
	h.session("again", 90, prompt("u1", 0, "Fix the build"), request(1), answer("a1", 80, "end_turn", `{"type":"text","text":"Done."}`, hour))
	running[10] = true
	h.process(10, "again", "busy", "", 99)

	by := h.read(r, 100, Options{Known: func(id string) (string, string) { return "from the index: " + id[:8], "/started/here" }})
	if len(by) != 10+1 || by[""].Subagents != 1 {
		t.Fatalf("sessions listed: %d (want 10), running outside the window: %d (want 1)", len(by)-1, by[""].Subagents)
	}

	s := by["tool"]
	if s.State != StateTool || !s.Since.Equal(base.Add(60*time.Second)) || len(s.Tools) != 1 || s.Tools[0].Name != "Bash" || s.Tools[0].Summary != "Run the tests" {
		t.Errorf("tool: %+v", s)
	}
	if s.Title != "Fixing the build" || s.LastPrompt != "Fix the build" || s.Cwd != "/w" || s.WorkDir != "/w" || !s.Running || s.PID != 1 || s.Name != "w-1" || s.Entrypoint != "claude-vscode" || s.Process != "busy" || s.Model != "claude-fable-5-1" {
		t.Errorf("tool, who it is: %+v", s)
	}
	if s := by["model"]; s.State != StateModel || !s.Since.Equal(base.Add(70*time.Second)) || len(s.Tools) != 0 || s.Title != "from the index: "+sid("model")[:8] {
		t.Errorf("model: %+v", s)
	}
	if s := by["you"]; s.State != StateYou || !s.Since.Equal(base.Add(80*time.Second)) || s.Said != "The build is fixed." {
		t.Errorf("you: %+v", s)
	}
	if s := by["background"]; s.State != StateBackground || s.Subagents != 1 || s.Said != "Two reviewers are at it." {
		t.Errorf("background: %+v", s)
	}
	if s := by["blocked"]; s.State != StateBlocked || s.WaitingFor != "approve Bash" || !s.Since.Equal(base.Add(61*time.Second)) || len(s.Tools) != 1 {
		t.Errorf("blocked: %+v", s)
	}
	if s := by["stopped"]; s.State != StateYou || !s.Since.Equal(base.Add(75*time.Second)) || len(s.Tools) != 0 {
		t.Errorf("stopped: %+v", s)
	}
	if s := by["closed"]; s.State != StateClosed || s.Running || s.Said != "Done." || s.PID != 0 || s.Cwd != "/started/here" || s.WorkDir != "/w" {
		t.Errorf("closed: %+v", s)
	}
	if s := by["crashed"]; s.State != StateClosed || s.Running {
		t.Errorf("a dead process's file does not make a session run: %+v", s)
	}
	if s := by["fresh"]; s.State != StateYou || !s.Running || s.Cache != nil || !s.LastAt.Equal(base.Add(95*time.Second)) {
		t.Errorf("a process with no transcript yet: %+v", s)
	}
	if s := by["again"]; s.State != StateModel || !s.Since.Equal(base.Add(99*time.Second)) {
		t.Errorf("busy after an ended turn: %+v", s)
	}
	if _, listed := by["quiet"]; listed {
		t.Error("a session quiet for longer than the window is not listed")
	}
	// The latest first: the process that just opened, then the transcripts by their last record.
	if by["fresh"].Bytes != 0 || by["tool"].Bytes < by["you"].Bytes {
		t.Errorf("order: fresh at %d, you at %d, tool at %d", by["fresh"].Bytes, by["you"].Bytes, by["tool"].Bytes)
	}
	// A wider window lists the quiet one, and nothing runs outside it.
	wide := h.read(r, 100, Options{Window: 3 * time.Hour})
	if s, ok := wide["quiet"]; !ok || s.State != StateYou || wide[""].Subagents != 0 {
		t.Errorf("a wider window: %+v", wide["quiet"])
	}
}

func TestCacheExpiry(t *testing.T) {
	h := newHome(t)
	r := &Reader{Alive: func(int) bool { return false }}
	// An hour's cache, last used when the last request was sent (not when it was answered).
	h.session("hour", 130, prompt("u1", 0, "x"), request(1), answer("a1", 20, "tool_use", bash("t1"), hour), result("r1", 100, "t1"), request(101), answer("a2", 130, "end_turn", `{"type":"text","text":"ok"}`, hour))
	// Five minutes; a request that wrote nothing keeps the lifetime of the one before.
	h.session("five", 130, prompt("u1", 0, "x"), request(1), answer("a1", 20, "tool_use", bash("t1"), five), result("r1", 100, "t1"), request(101),
		answer("a2", 130, "end_turn", `{"type":"text","text":"ok"}`, `"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0`))
	// A transcript that keeps no copy of its requests: the answer's time stands in.
	h.session("nocopy", 130, prompt("u1", 0, "x"), answer("a1", 130, "end_turn", `{"type":"text","text":"ok"}`, hour))
	// No request at all yet.
	h.session("empty", 130, prompt("u1", 120, "x"))

	by := h.read(r, 200, Options{})
	c := by["hour"].Cache
	if c == nil || c.TTLSeconds != 3600 || !c.LastRequestAt.Equal(base.Add(101*time.Second)) || c.ExpiresAt == nil || !c.ExpiresAt.Equal(base.Add(3701*time.Second)) || c.SecondsLeft != 3501 {
		t.Fatalf("an hour's cache: %+v", c)
	}
	if c.ReadTokens != 900 || c.WrittenTokens != 90 || c.InputTokens != 10 || c.ContextTokens != 1000 || c.HitRatio != 0.9 {
		t.Errorf("the last request's input: %+v", c)
	}
	if c := by["five"].Cache; c.TTLSeconds != 300 || c.SecondsLeft != 201 {
		t.Errorf("five minutes: %+v", c)
	}
	if c := by["nocopy"].Cache; !c.LastRequestAt.Equal(base.Add(130*time.Second)) || c.SecondsLeft != 3530 {
		t.Errorf("no copy of the request: %+v", c)
	}
	if by["empty"].Cache != nil {
		t.Errorf("no request, no cache: %+v", by["empty"].Cache)
	}
	// Past its end: nothing left, and the moment it ended is still told.
	late := h.read(r, 3400, Options{Window: 2 * time.Hour})
	if c := late["five"].Cache; c.SecondsLeft != 0 || c.ExpiresAt == nil || !c.ExpiresAt.Equal(base.Add(401*time.Second)) {
		t.Errorf("expired: %+v", c)
	}
}

// TestTheTailIsReadNotTheFile: what is needed is found behind megabytes of
// earlier lines, a huge line near the end does not hide it, a line still
// being written is left out, and an unchanged file is not read twice.
func TestTheTailIsReadNotTheFile(t *testing.T) {
	h := newHome(t)
	r := &Reader{Alive: func(int) bool { return true }}
	filler := fmt.Sprintf(`{"type":"api-request-blob","hash":"h","message":{"role":"user","content":%q}}`, strings.Repeat("x", 64<<10))
	var lines []string
	lines = append(lines, prompt("u0", -500, "An old prompt"), answer("old", -400, "tool_use", bash("t-old"), five), result("r-old", -390, "t-old"))
	for i := 0; i < 40; i++ { // 2.5 MB the tail never needs
		lines = append(lines, filler)
	}
	huge := fmt.Sprintf(`{"type":"api-request-blob","hash":"big","message":{"role":"user","content":%q}}`, strings.Repeat("y", 3<<20))
	lines = append(lines, title, prompt("u1", 0, "Fix the build"), lastWord, request(1), answer("a1", 60, "tool_use", bash("t1"), hour), huge)
	p := h.session("big", 62, lines...)
	h.process(1, "big", "busy", "", 0)

	by := h.read(r, 100, Options{})
	s := by["big"]
	if s.State != StateTool || len(s.Tools) != 1 || s.Tools[0].ID != "t1" || s.Title != "Fixing the build" || s.Cache == nil || s.Cache.TTLSeconds != 3600 {
		t.Fatalf("behind a 3 MB line: %+v cache %+v", s, s.Cache)
	}
	first := r.tails[p].tail

	// Unchanged: the same reading is handed back.
	h.read(r, 101, Options{})
	if r.tails[p].tail != first {
		t.Error("an unchanged transcript was read again")
	}
	// A line being written (no newline yet) is not taken for a record; the result before it is.
	f, _ := os.OpenFile(p, os.O_APPEND|os.O_WRONLY, 0o644)
	f.WriteString(result("r1", 90, "t1") + "\n" + `{"type":"assistant","uuid":"half","message":{"content":[{"type":"tool_use","id":"t2"`)
	f.Close()
	when := base.Add(91 * time.Second)
	os.Chtimes(p, when, when)
	by = h.read(r, 100, Options{})
	if s := by["big"]; s.State != StateModel || len(s.Tools) != 0 || r.tails[p].tail == first {
		t.Errorf("after the result: %+v", s)
	}
	// Out of the window, its tail is forgotten.
	h.read(r, 100000, Options{})
	if len(r.tails) != 0 {
		t.Errorf("tails kept for sessions out of the window: %d", len(r.tails))
	}
}

// TestRequestTimeWithoutCopies: a transcript that keeps no copies of its
// requests counts its cache from the last answer, not the first.
func TestRequestTimeWithoutCopies(t *testing.T) {
	h := newHome(t)
	r := &Reader{Alive: func(int) bool { return false }}
	h.session("nocopy", 130, prompt("u1", 0, "x"), answer("a1", 20, "tool_use", bash("t1"), hour), result("r1", 100, "t1"), answer("a2", 130, "end_turn", `{"type":"text","text":"ok"}`, hour))
	// Copies were kept once and are not any more: the old copy is not the last use.
	h.session("hour", 2000, prompt("u1", 0, "x"), request(1), answer("a1", 20, "tool_use", bash("t1"), hour), result("r1", 1900, "t1"), answer("a2", 2000, "end_turn", `{"type":"text","text":"ok"}`, hour))
	by := h.read(r, 2100, Options{})
	if c := by["nocopy"].Cache; !c.LastRequestAt.Equal(base.Add(130 * time.Second)) {
		t.Errorf("no copies: last request at %v", c.LastRequestAt)
	}
	if c := by["hour"].Cache; !c.LastRequestAt.Equal(base.Add(2000 * time.Second)) {
		t.Errorf("copies no longer kept: last request at %v", c.LastRequestAt)
	}
}

// TestWhatTheTranscriptSaysOfWaiting: a call that is a question to the person
// is "blocked" whatever the process says; a file tool that has been out for a
// while is suspected of waiting for a permission; and the last call that came
// back is told while the model works.
func TestWhatTheTranscriptSaysOfWaiting(t *testing.T) {
	h := newHome(t)
	r := &Reader{Alive: func(int) bool { return true }}
	tool := func(id, name string) string {
		return fmt.Sprintf(`{"type":"tool_use","id":%q,"name":%q,"input":{"file_path":"/w/a.go"}}`, id, name)
	}
	h.session("blocked", 62, prompt("u1", 0, "x"), request(1), answer("a1", 60, "tool_use", tool("q1", "AskUserQuestion"), hour))
	h.process(1, "blocked", "busy", "", 0)
	h.session("again", 62, prompt("u1", 0, "x"), request(1), answer("a1", 60, "tool_use", tool("p1", "ExitPlanMode"), hour))
	h.process(2, "again", "busy", "", 0)
	h.session("tool", 62, prompt("u1", 0, "x"), request(1), answer("a1", 60, "tool_use", tool("e1", "Edit"), hour))
	h.process(3, "tool", "busy", "", 0)
	// A shell command may take as long as it likes.
	h.session("model", 62, prompt("u1", 0, "x"), request(1), answer("a1", 60, "tool_use", bash("b1"), hour))
	h.process(4, "model", "busy", "", 0)
	// A call that came back with an error, and the model at work on it.
	failed := fmt.Sprintf(`{"type":"user","uuid":"r1","timestamp":%q,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"b1","is_error":true,"content":"exit 1"}]}}`, at(70))
	h.session("you", 70, prompt("u1", 0, "x"), request(1), answer("a1", 60, "tool_use", bash("b1"), hour), failed)
	h.process(5, "you", "busy", "", 0)

	by := h.read(r, 65, Options{})
	if s := by["blocked"]; s.State != StateBlocked || s.WaitingFor != "an answer to its question" || !s.Since.Equal(base.Add(60*time.Second)) || len(s.Tools) != 1 {
		t.Errorf("a question to the person: %+v", s)
	}
	if s := by["again"]; s.State != StateBlocked || s.WaitingFor != "your word on its plan" {
		t.Errorf("a plan to approve: %+v", s)
	}
	if s := by["tool"]; s.State != StateTool || s.MaybePermission {
		t.Errorf("an edit out for five seconds: %+v", s)
	}
	by = h.read(r, 75, Options{})
	if s := by["tool"]; s.State != StateTool || !s.MaybePermission {
		t.Errorf("an edit out for fifteen seconds: %+v", s)
	}
	if s := by["model"]; s.State != StateTool || s.MaybePermission {
		t.Errorf("a command out for fifteen seconds: %+v", s)
	}
	s := by["you"]
	if s.State != StateModel || s.LastTool == nil || s.LastTool.Name != "Bash" || !s.LastTool.Failed || s.LastTool.Summary != "Run the tests" ||
		s.LastTool.EndedAt == nil || !s.LastTool.EndedAt.Equal(base.Add(70*time.Second)) || !s.LastTool.Since.Equal(base.Add(60*time.Second)) {
		t.Errorf("the call that came back last: %+v %+v", s, s.LastTool)
	}
}
