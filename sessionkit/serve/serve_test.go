package serve

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
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
	var cb map[string]any
	if code := get(t, h, "/v0/sessions/"+fixtureID+"/actions/0/context", &cb); code != 200 || cb["available"] != true {
		t.Fatalf("context route: %d %v", code, cb["reason"])
	}
	var cd map[string]any
	if code := get(t, h, "/v0/sessions/"+fixtureID+"/compactions/0", &cd); code != 200 || cd["pre_tokens"] != float64(6400) {
		t.Fatalf("compaction route: %d %v", code, cd)
	}
	var rel map[string]any
	if code := get(t, h, "/v0/sessions/"+fixtureID+"/relations", &rel); code != 200 || len(rel["spans"].([]any)) != 6 || rel["files"] == nil {
		t.Fatalf("relations route: %d %v", code, rel)
	}
	var imgs []map[string]any
	if code := get(t, h, "/v0/sessions/"+fixtureID+"/images", &imgs); code != 200 || imgs == nil {
		t.Fatalf("images route: %d %v", code, imgs)
	}
	var ann map[string]any
	if code := get(t, h, "/v0/sessions/aaaaaaaa/annotations", &ann); code != 200 || ann["pinned"] != false {
		t.Fatalf("annotations before any: %d %v", code, ann)
	}
	prec := httptest.NewRecorder()
	h.ServeHTTP(prec, httptest.NewRequest("PATCH", "/v0/sessions/aaaaaaaa/annotations", strings.NewReader(`{"pinned":true,"add_tags":["keep"],"notes":{"turn:0":"n"}}`)))
	var all map[string]map[string]any
	if code := get(t, h, "/v0/annotations", &all); prec.Code != 200 || code != 200 || all[fixtureID]["pinned"] != true {
		t.Fatalf("annotate then list: %d %d %v", prec.Code, code, all)
	}
	var snap map[string]any
	if code := get(t, h, "/v0/claude", &snap); code != 200 || snap["experiments"] == nil || snap["identity"] == nil {
		t.Fatalf("claude route: %d %v", code, snap)
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

// TestConcurrentReadsShareOneParse hits every read route of one session from
// many goroutines. Run under -race it proves a cached session is only read;
// the image route proves no request stripped the payloads another one needs.
func TestConcurrentReadsShareOneParse(t *testing.T) {
	s, _ := newTestServer(t)
	h := s.Handler()
	base := "/v0/sessions/" + fixtureID
	paths := []string{base, base + "/stats", base + "/turns/0", base + "/actions/3", base + "/actions/0/context", base + "/compactions/0",
		base + "/relations", base + "/images", "/v0/sessions", "/v0/status", "/v0/search?q=Bash", "/v0/archive/verify"}
	var imgs []map[string]any
	get(t, h, base+"/images", &imgs)

	var wg sync.WaitGroup
	fail := make(chan string, 256)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for _, p := range paths {
				rec := httptest.NewRecorder()
				h.ServeHTTP(rec, httptest.NewRequest("GET", p, nil))
				if rec.Code != 200 {
					fail <- p + ": " + rec.Body.String()
				}
			}
			if len(imgs) > 0 {
				rec := httptest.NewRecorder()
				h.ServeHTTP(rec, httptest.NewRequest("GET", base+"/images/0", nil))
				if rec.Code != 200 || rec.Body.Len() == 0 {
					fail <- "image bytes after a document was served: " + rec.Body.String()
				}
			}
		}()
	}
	wg.Wait()
	close(fail)
	for f := range fail {
		t.Error(f)
	}
	var st Status
	if get(t, h, "/v0/status", &st); st.Cached != 1 {
		t.Fatalf("one session should be held in the cache, got %d", st.Cached)
	}
	// The document never carries image payloads.
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", base, nil))
	if strings.Contains(rec.Body.String(), `"data"`) {
		t.Fatal("the session document must not carry image payloads")
	}
}

// TestCacheFollowsTheSource: a transcript that grows is parsed again, and the
// watcher's ingest leaves the archive complete.
func TestCacheFollowsTheSource(t *testing.T) {
	s, claude := newTestServer(t)
	h := s.Handler()
	var doc archive.SessionDoc
	get(t, h, "/v0/sessions/"+fixtureID, &doc)
	before := len(doc.Prompts)

	src := filepath.Join(claude, "projects", "-Users-xxxx-work", fixtureID+".jsonl")
	if _, err := s.IngestPath(src); err != nil {
		t.Fatal(err)
	}
	f, _ := os.OpenFile(src, os.O_APPEND|os.O_WRONLY, 0o644)
	f.WriteString(`{"type":"user","uuid":"u9","parentUuid":"a8","turnOrigin":"human","sessionId":"` + fixtureID + `","timestamp":"2026-11-08T10:02:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Appended prompt about zebras"}]}}` + "\n")
	f.Close()

	var rows []archive.ListRow
	get(t, h, "/v0/sessions", &rows) // the client lists before the watcher fires
	get(t, h, "/v0/sessions/"+fixtureID, &doc)
	if len(doc.Prompts) != before+1 {
		t.Fatalf("the grown transcript should be parsed again: %d prompts, want %d", len(doc.Prompts), before+1)
	}
	res, err := s.IngestPath(src)
	if err != nil || res.Action != "updated" {
		t.Fatalf("watcher ingest after a list = %+v %v", res, err)
	}
	var checks []archive.Check
	if get(t, h, "/v0/archive/verify", &checks); len(checks) != 1 || checks[0].Status != "ok" || checks[0].Records != res.Records {
		t.Fatalf("verify = %+v (ingest covered %d records)", checks, res.Records)
	}
	var hits []map[string]any
	if get(t, h, "/v0/search?q=zebras", &hits); len(hits) != 1 {
		t.Fatalf("the appended prompt should be searchable: %v", hits)
	}
}
