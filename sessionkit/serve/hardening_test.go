package serve

import (
	"context"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// Every answer says how long it is, so a client that reads to the end of the
// connection can tell a whole body from one cut short.
func TestEveryAnswerCarriesItsLength(t *testing.T) {
	s, _ := newTestServer(t)
	h := s.Handler()
	base := "/v0/sessions/" + fixtureID
	for _, path := range []string{"/v0", "/v0/status", "/v0/sessions", base, base + "/stats", base + "/turns/0", base + "/relations",
		base + "/export", base + "/images", base + "/images/0", base + "/annotations", "/v0/nowhere", base + "/turns/999"} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("GET", path, nil))
		n, err := strconv.Atoi(rec.Header().Get("Content-Length"))
		if err != nil || n != rec.Body.Len() || n == 0 {
			t.Errorf("%s (%d): Content-Length %q, body %d bytes", path, rec.Code, rec.Header().Get("Content-Length"), rec.Body.Len())
		}
	}
}

// A request body is a note or a list of ids. More than a megabyte is refused, not read.
func TestOversizedBodiesAreRefused(t *testing.T) {
	s, _ := newTestServer(t)
	h := s.Handler()
	big := `{"notes":{"session":"` + strings.Repeat("x", maxBody+1) + `"}}`
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("PATCH", "/v0/sessions/"+fixtureID+"/annotations", strings.NewReader(big)))
	if rec.Code != 400 {
		t.Fatalf("PATCH with %d bytes: %d %s", len(big), rec.Code, rec.Body.String())
	}
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("POST", "/v0/archive", strings.NewReader(`{"ids":["`+strings.Repeat("x", maxBody+1)+`"]}`)))
	if rec.Code != 400 {
		t.Fatalf("POST with an oversized body: %d", rec.Code)
	}
}

// skit never writes under ~/.claude: a projects directory that is not there is
// waited for, not made.
func TestWatchWaitsForTheProjectsDirectoryAndNeverMakesIt(t *testing.T) {
	s, _ := newTestServer(t)
	claude := t.TempDir()
	projects := filepath.Join(claude, "projects")
	old := waitForProjects
	waitForProjects = 10 * time.Millisecond
	t.Cleanup(func() { waitForProjects = old })

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- s.Watch(ctx, projects, 10*time.Millisecond) }()
	time.Sleep(60 * time.Millisecond)
	if _, err := os.Stat(projects); !os.IsNotExist(err) {
		t.Fatalf("Watch made %s (stat: %v)", projects, err)
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Watch: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Watch did not stop while waiting for the directory")
	}
}

// A tool result that names a file as its "full output" is not obeyed unless
// the file is where Claude Code keeps spilled output.
func TestActionDoesNotReadAFileATranscriptNames(t *testing.T) {
	s, claude := newTestServer(t)
	secret := filepath.Join(t.TempDir(), "id_rsa")
	if err := os.WriteFile(secret, []byte("PRIVATE-KEY-BYTES"), 0o600); err != nil {
		t.Fatal(err)
	}
	id := "eeeeeeee-0000-0000-0000-000000000005"
	lines := `{"type":"user","uuid":"u1","sessionId":"` + id + `","turnOrigin":"human","timestamp":"2026-11-08T01:00:00Z","message":{"role":"user","content":"go"}}
{"type":"assistant","uuid":"a1","parentUuid":"u1","requestId":"r1","timestamp":"2026-11-08T01:00:01Z","message":{"model":"m","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"WebFetch","input":{}},{"type":"tool_use","id":"t2","name":"mcp__x__y","input":{}}],"usage":{"input_tokens":1,"output_tokens":1}}}
{"type":"user","uuid":"r1","parentUuid":"a1","timestamp":"2026-11-08T01:00:02Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"<persisted-output>\nFull output saved to: ` + secret + `\n"}]}}
{"type":"user","uuid":"r2","parentUuid":"a1","timestamp":"2026-11-08T01:00:03Z","toolUseResult":{"persistedOutputPath":"/dev/zero"},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"structured"}]}}
`
	if err := os.WriteFile(filepath.Join(claude, "projects", "-Users-xxxx-work", id+".jsonl"), []byte(lines), 0o644); err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, httptest.NewRequest("GET", "/v0/sessions/"+id+"/actions/0", nil))
	body := rec.Body.String()
	if rec.Code != 200 || strings.Contains(body, "PRIVATE-KEY-BYTES") || !strings.Contains(body, `"result_source":"transcript"`) {
		t.Fatalf("the action must show what the transcript holds and nothing else: %d %s", rec.Code, body)
	}
}
