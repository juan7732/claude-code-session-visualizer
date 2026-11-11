package serve

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/archive"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/embed"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/embed/embedtest"
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
	var step ActionDoc
	if code := get(t, h, "/v0/sessions/"+fixtureID+"/actions/0?agent=a1b2c3d4e5f607182", &step); code != 200 || step.RequestID == act.RequestID {
		t.Fatalf("a subagent's action: %d %+v", code, step)
	}
	var none map[string]string
	if code := get(t, h, "/v0/sessions/"+fixtureID+"/actions/0?agent=nobody", &none); code != 404 || none["error"] == "" {
		t.Fatalf("an unknown subagent: %d %v", code, none)
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
	if rel["commits"] == nil {
		t.Fatalf("relations lists commits, empty when there are none: %v", rel["commits"])
	}
	var ov map[string]any
	if code := get(t, h, "/v0/overview", &ov); code != 200 || ov["sessions"].(float64) < 1 || len(ov["days"].([]any)) < 1 || len(ov["projects"].([]any)) < 1 {
		t.Fatalf("overview route: %d %v", code, ov)
	}
	if code := get(t, h, "/v0/overview?project=no-such-project", &ov); code != 200 || ov["sessions"] != float64(0) {
		t.Fatalf("overview of no project: %d %v", code, ov)
	}
	// slug is the whole slug or nothing: a part of one matches no project.
	if code := get(t, h, "/v0/overview?slug=work", &ov); code != 200 || ov["sessions"] != float64(0) {
		t.Fatalf("overview of a partial slug: %d %v", code, ov)
	}
	var tm map[string]any
	if code := get(t, h, "/v0/sessions/"+fixtureID+"/time?top=2", &tm); code != 200 || tm["wall_seconds"] != float64(64) || len(tm["slowest_calls"].([]any)) != 2 || len(tm["turns"].([]any)) != 2 {
		t.Fatalf("time route: %d %v", code, tm)
	}
	if code := get(t, h, "/v0/sessions/"+fixtureID+"/time?top=none", &none); code != 400 {
		t.Fatalf("time with a bad top: %d", code)
	}
	md := httptest.NewRecorder()
	h.ServeHTTP(md, httptest.NewRequest("GET", "/v0/sessions/"+fixtureID+"/export?turn=0", nil))
	if md.Code != 200 || !strings.HasPrefix(md.Header().Get("Content-Type"), "text/markdown") || !strings.HasPrefix(md.Body.String(), "## Turn 0 · ") || !strings.Contains(md.Body.String(), "- `Edit`") {
		t.Fatalf("export route: %d %q\n%s", md.Code, md.Header().Get("Content-Type"), md.Body.String())
	}
	whole := httptest.NewRecorder()
	h.ServeHTTP(whole, httptest.NewRequest("GET", "/v0/sessions/"+fixtureID+"/export", nil))
	if whole.Code != 200 || !strings.HasPrefix(whole.Body.String(), "# ") || !strings.Contains(whole.Body.String(), "> Context compacted") {
		t.Fatalf("export of the whole session: %d\n%s", whole.Code, whole.Body.String())
	}
	var bad map[string]string
	if code := get(t, h, "/v0/sessions/"+fixtureID+"/export?turn=99", &bad); code != 404 || bad["error"] == "" {
		t.Fatalf("export of a turn that is not there: %d %v", code, bad)
	}
	if code := get(t, h, "/v0/sessions/"+fixtureID+"/export?format=html", &bad); code != 400 {
		t.Fatalf("export in a format that is not there: %d %v", code, bad)
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
	// Once archived, a file the session touched can be asked about; one it did not touch cannot.
	var fv map[string]any
	if code := get(t, h, "/v0/file?path=/xxx/y.go", &fv); code != 200 || fv["exists"] != false || fv["reason"] != "deleted" || len(fv["sessions"].([]any)) != 1 {
		t.Fatalf("file route: %d %v", code, fv)
	}
	if code := get(t, h, "/v0/file?path=/xxx/y.go&session="+fixtureID+"&text=0", &fv); code != 200 || fv["path"] != "/xxx/y.go" {
		t.Fatalf("file route with a session: %d %v", code, fv)
	}
	var refused map[string]string
	if code := get(t, h, "/v0/file?path=/etc/hosts", &refused); code != 404 || refused["error"] == "" {
		t.Fatalf("a file no session touched: %d %v", code, refused)
	}
	if code := get(t, h, "/v0/file", &refused); code != 400 {
		t.Fatalf("file without a path: %d", code)
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
		base + "/relations", base + "/time", base + "/images", "/v0/sessions", "/v0/overview", "/v0/status", "/v0/search?q=Bash", "/v0/archive/verify"}
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

// TestSweepArchivesWhatChangedWhileNothingRan: no file event, no request.
func TestSweepArchivesWhatChangedWhileNothingRan(t *testing.T) {
	s, claude := newTestServer(t)
	if changed, failed := s.Sweep(); changed != 1 || failed != 0 {
		t.Fatalf("first sweep: changed=%d failed=%d", changed, failed)
	}
	if changed, failed := s.Sweep(); changed != 0 || failed != 0 {
		t.Fatalf("a second sweep finds nothing to do: changed=%d failed=%d", changed, failed)
	}
	rep, _ := s.Inspect()
	if p, err := s.Archive.Pending(rep); err != nil || p.Missing != 0 || p.Behind != 0 {
		t.Fatalf("pending after a sweep = %+v %v", p, err)
	}
	src := filepath.Join(claude, "projects", "-Users-xxxx-work", fixtureID+".jsonl")
	f, _ := os.OpenFile(src, os.O_APPEND|os.O_WRONLY, 0o644)
	f.WriteString(`{"type":"user","uuid":"u9","parentUuid":"a8","turnOrigin":"human","sessionId":"` + fixtureID + `","timestamp":"2026-11-08T10:02:00.000Z","message":{"role":"user","content":"later"}}` + "\n")
	f.Close()
	rep, _ = s.Inspect()
	if p, _ := s.Archive.Pending(rep); p.Behind != 1 {
		t.Fatalf("a grown source is behind until the next sweep: %+v", p)
	}
	if changed, _ := s.Sweep(); changed != 1 {
		t.Fatalf("the sweep should pick up the growth: changed=%d", changed)
	}
}

// TestSearchByMeaning walks /v0/search?mode=meaning from "cannot" to "can":
// no embedder, no vectors, then hits; and the two ways it can fail that are
// not the caller's doing or are.
func TestSearchByMeaning(t *testing.T) {
	s, _ := newTestServer(t)
	h := s.Handler()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("POST", "/v0/archive", strings.NewReader(`{}`)))
	if rec.Code != 200 {
		t.Fatalf("archive: %d %s", rec.Code, rec.Body.String())
	}
	const q = "/v0/search?mode=meaning&q=continued+from+a+previous+conversation"
	var e map[string]string
	if code := get(t, h, q, &e); code != 409 || !strings.Contains(e["error"], "skit embed") {
		t.Fatalf("without an embedder: %d %v", code, e)
	}

	fake := httptest.NewServer(&embedtest.Server{})
	defer fake.Close()
	emb := embed.NewClientEmbedder(&embed.Client{BaseURL: fake.URL}, "fake v1")
	s.Embedder = emb
	if code := get(t, h, q, &e); code != 409 || !strings.Contains(e["error"], "no vectors") {
		t.Fatalf("before embedding: %d %v", code, e)
	}
	if _, err := s.Archive.Embed(context.Background(), emb, nil); err != nil {
		t.Fatal(err)
	}
	// The stand-in's cosines are word overlaps, well under the gate a real
	// model is held to: by default the honest answer is "nothing close enough",
	// an empty list and not an error. all=1 returns the nearest anyway.
	var hits []map[string]any
	if code := get(t, h, q, &hits); code != 200 || len(hits) != 0 {
		t.Fatalf("gated: %d %v", code, hits)
	}
	if code := get(t, h, q+"&all=1", &hits); code != 200 || len(hits) == 0 {
		t.Fatalf("after embedding: %d %v", code, hits)
	}
	// The fixture is redacted to x's; its one passage in sentences is the compaction summary.
	if hits[0]["match"] != "meaning" || hits[0]["kind"] != "summary" || hits[0]["cosine"].(float64) <= 0 {
		t.Fatalf("first hit = %v", hits[0])
	}
	// Keyword hits say what they are too, and the default mode is unchanged.
	if code := get(t, h, "/v0/search?q=Bash&kind=tool_use", &hits); code != 200 || len(hits) == 0 || hits[0]["match"] != "keyword" {
		t.Fatalf("keyword: %d %v", code, hits)
	}
	if code := get(t, h, "/v0/search?mode=telepathy&q=x", &e); code != 400 || !strings.Contains(e["error"], "keyword, meaning") {
		t.Fatalf("unknown mode: %d %v", code, e)
	}
	// Narrowing: tools=0 leaves tool calls out, kind takes a list, and a kind
	// that does not exist is the caller's mistake.
	if code := get(t, h, "/v0/search?q=Bash&tools=0", &hits); code != 200 {
		t.Fatalf("tools=0: %d", code)
	}
	for _, hit := range hits {
		if k := hit["kind"]; k == "tool_use" || k == "tool_result" {
			t.Fatalf("tools=0 returned a %v", k)
		}
	}
	if code := get(t, h, "/v0/search?q=Bash&kind=tool_use,tool_result", &hits); code != 200 || len(hits) == 0 {
		t.Fatalf("kind list: %d %v", code, hits)
	}
	if code := get(t, h, "/v0/search?q=Bash&kind=tools", &e); code != 400 || !strings.Contains(e["error"], "unknown kind") {
		t.Fatalf("unknown kind: %d %v", code, e)
	}
	if code := get(t, h, q+"&min_cosine=0.01&min_z=99", &hits); code != 200 || len(hits) == 0 {
		t.Fatalf("a low cosine floor lets the stand-in's hits through: %d %v", code, hits)
	}
	// The embedding server going away is not a bad request.
	fake.Close()
	if code := get(t, h, q, &e); code != 503 {
		t.Fatalf("embedder down: %d %v", code, e)
	}
}

// TestEmbedPassKeepsMeaningSearchCurrent: the background pass embeds what has
// no vector, asks the model for nothing when there is nothing to do, and is
// what makes hybrid and meaning search work without anyone running skit embed.
func TestEmbedPassKeepsMeaningSearchCurrent(t *testing.T) {
	s, _ := newTestServer(t)
	h := s.Handler()
	var logged []string
	s.Logf = func(format string, args ...any) { logged = append(logged, fmt.Sprintf(format, args...)) }

	if n := s.EmbedPass(context.Background()); n != 0 {
		t.Fatalf("without an embedder the pass does nothing, embedded %d", n)
	}
	fake := &embedtest.Server{}
	srv := httptest.NewServer(fake)
	defer srv.Close()
	s.Embedder = embed.NewClientEmbedder(&embed.Client{BaseURL: srv.URL}, "fake v1")
	if n := s.EmbedPass(context.Background()); n != 0 || fake.Requests.Load() != 0 {
		t.Fatalf("an empty archive: embedded %d with %d requests to the model", n, fake.Requests.Load())
	}

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("POST", "/v0/archive", strings.NewReader(`{}`)))
	if rec.Code != 200 {
		t.Fatalf("archive: %d", rec.Code)
	}
	n := s.EmbedPass(context.Background())
	if n == 0 {
		t.Fatal("the archived session's text should have been embedded")
	}
	asked := fake.Requests.Load()
	if again := s.EmbedPass(context.Background()); again != 0 || fake.Requests.Load() != asked {
		t.Fatalf("a second pass with nothing new: embedded %d, requests %d → %d", again, asked, fake.Requests.Load())
	}
	found := false
	for _, l := range logged {
		found = found || strings.HasPrefix(l, "embed: ")
	}
	if !found {
		t.Fatalf("the pass should say what it did: %q", logged)
	}

	// Status says how far the vectors reach, when they were brought up to
	// date, and that a meaning query left them in memory.
	var st Status
	if code := get(t, h, "/v0/status", &st); code != 200 || st.Vectors.Vectors != n || st.Vectors.Vectors != st.Vectors.Texts || st.Vectors.EmbeddedAt == "" || st.VectorsHeld != 0 {
		t.Fatalf("status before a query: %d %+v held=%d", code, st.Vectors, st.VectorsHeld)
	}
	var hits []map[string]any
	if code := get(t, h, "/v0/search?mode=hybrid&all=1&q=continued+from+a+previous+conversation", &hits); code != 200 || len(hits) == 0 {
		t.Fatalf("hybrid: %d %v", code, hits)
	}
	if code := get(t, h, "/v0/status", &st); code != 200 || st.VectorsHeld != st.Vectors.Chunks {
		t.Fatalf("after a query the vectors are held: %d of %d", st.VectorsHeld, st.Vectors.Chunks)
	}

	// A failure is logged once, not at every interval.
	srv.Close()
	if _, err := s.Archive.Store.UseVectorSource("another model"); err != nil { // makes every text pending again
		t.Fatal(err)
	}
	s.Embedder = embed.NewClientEmbedder(&embed.Client{BaseURL: srv.URL}, "fake v1")
	before := len(logged)
	s.EmbedPass(context.Background())
	s.EmbedPass(context.Background())
	failures := 0
	for _, l := range logged[before:] {
		if strings.HasPrefix(l, "embed: ") {
			failures++
		}
	}
	if failures != 1 {
		t.Fatalf("the same failure twice should be logged once, got %d: %q", failures, logged[before:])
	}
}
