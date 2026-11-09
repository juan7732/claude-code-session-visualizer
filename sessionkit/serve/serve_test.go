package serve

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/archive"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
)

const fixtureID = "aaaaaaaa-0000-0000-0000-000000000001"

func newTestServer(t *testing.T) (*Server, string) {
	t.Helper()
	claude := t.TempDir()
	src := filepath.Join("..", "..", "internal", "testdata", "sessions", "synthetic-basics")
	dst := filepath.Join(claude, "projects", "-Users-xxxx-work")
	if err := filepath.Walk(src, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		if info.IsDir() {
			return os.MkdirAll(filepath.Join(dst, rel), 0o755)
		}
		if filepath.Base(p) == "expected.json" {
			return nil
		}
		b, _ := os.ReadFile(p)
		return os.WriteFile(filepath.Join(dst, rel), b, 0o644)
	}); err != nil {
		t.Fatal(err)
	}
	a, err := archive.OpenAt(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { a.Close() })
	s := New("test", a)
	s.Inspect = func() (*catalog.Report, error) { return catalog.InspectDir(claude) }
	return s, claude
}

func get(t *testing.T, h http.Handler, path string, v any) int {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", path, nil))
	if v != nil {
		if err := json.Unmarshal(rec.Body.Bytes(), v); err != nil {
			t.Fatalf("%s: not JSON: %v\n%s", path, err, rec.Body.String())
		}
	}
	return rec.Code
}

func TestRoutes(t *testing.T) {
	s, _ := newTestServer(t)
	h := s.Handler()

	var st Status
	if code := get(t, h, "/v0/status", &st); code != 200 || st.Version != "test" || st.Sessions != 1 {
		t.Fatalf("status %d %+v", code, st)
	}
	var rows []archive.ListRow
	if code := get(t, h, "/v0/sessions", &rows); code != 200 || len(rows) != 1 || rows[0].ID != fixtureID || rows[0].Requests != 7 {
		t.Fatalf("sessions %d %+v", code, rows)
	}
	var doc archive.SessionDoc
	if code := get(t, h, "/v0/sessions/aaaaaaaa", &doc); code != 200 || doc.ID != fixtureID || len(doc.Actions) != 6 || len(doc.Turns) != 2 || doc.Summary.Requests != 7 {
		t.Fatalf("session %d id=%s actions=%d turns=%d", code, doc.ID, len(doc.Actions), len(doc.Turns))
	}
	var turn TurnDoc
	if code := get(t, h, "/v0/sessions/"+fixtureID+"/turns/0", &turn); code != 200 || turn.Origin != "human" || len(turn.Actions) != 4 || turn.ToolCalls != 4 {
		t.Fatalf("turn %d origin=%s actions=%d tools=%d", code, turn.Origin, len(turn.Actions), turn.ToolCalls)
	}
	var act ActionDoc
	if code := get(t, h, "/v0/sessions/"+fixtureID+"/actions/3", &act); code != 200 || len(act.ToolCalls) != 1 || act.ToolCalls[0].Name != "Edit" || !strings.HasPrefix(act.ToolCalls[0].Result, "full output line 1") || act.Turn != 0 {
		t.Fatalf("action %d %+v", code, act)
	}
	if code := get(t, h, "/v0/sessions/"+fixtureID+"/actions/0", &act); code != 200 || act.Thinking != "xxxx" {
		t.Fatalf("action 0 should expose its thinking text: %d %q", code, act.Thinking)
	}
	var e map[string]string
	if code := get(t, h, "/v0/sessions/"+fixtureID+"/turns/99", &e); code != 404 || e["error"] == "" {
		t.Fatalf("out-of-range turn: %d %v", code, e)
	}
	if code := get(t, h, "/v0/sessions/nope", &e); code != 404 {
		t.Fatalf("unknown session should be 404, got %d", code)
	}
	if code := get(t, h, "/nowhere", &e); code != 404 || !strings.Contains(e["error"], "GET /v0") {
		t.Fatalf("unknown route: %d %v", code, e)
	}

	// Nothing archived yet, so search is empty; archive via POST, then search hits.
	var hits []map[string]any
	if code := get(t, h, "/v0/search?q=Bash", &hits); code != 200 || len(hits) != 0 {
		t.Fatalf("search before archive: %d %v", code, hits)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("POST", "/v0/archive", strings.NewReader(`{}`)))
	var results []archive.Result
	if err := json.Unmarshal(rec.Body.Bytes(), &results); err != nil || rec.Code != 200 || len(results) != 1 || results[0].Action != "archived" {
		t.Fatalf("archive: %d %v %+v", rec.Code, err, results)
	}
	if code := get(t, h, "/v0/search?q=Bash&kind=tool_use", &hits); code != 200 || len(hits) == 0 {
		t.Fatalf("search after archive: %d %v", code, hits)
	}
	if code := get(t, h, "/v0/search?q=", &e); code != 400 {
		t.Fatalf("empty query should be 400, got %d", code)
	}
}
