package archive

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/klauspost/compress/zstd"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/search"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/transcript"
)

const fixtureID = "aaaaaaaa-0000-0000-0000-000000000001"

// seed copies the synthetic fixture into a fake ~/.claude project and returns a Located for it.
func seed(t *testing.T) (claude string, l catalog.Located) {
	t.Helper()
	return seedFixture(t, "synthetic-basics", fixtureID)
}

// proseID is the prose-search fixture: five turns in plain sentences on
// different subjects, for search and vectors (the other fixtures are redacted
// to x's, which no chunk of is worth a vector).
const proseID = "bbbbbbbb-0000-0000-0000-000000000002"

func seedProse(t *testing.T) (claude string, l catalog.Located) {
	t.Helper()
	return seedFixture(t, "prose-search", proseID)
}

func seedFixture(t *testing.T, name, id string) (claude string, l catalog.Located) {
	t.Helper()
	src := filepath.Join("..", "..", "internal", "testdata", "sessions", name)
	claude = t.TempDir()
	proj := filepath.Join(claude, "projects", "-Users-xxxx-work")
	copyTree(t, src, proj)
	os.Remove(filepath.Join(proj, "expected.json"))
	rep, err := catalog.InspectDir(claude)
	if err != nil {
		t.Fatal(err)
	}
	l, err = rep.Find(id)
	if err != nil {
		t.Fatal(err)
	}
	return claude, l
}

func copyTree(t *testing.T, src, dst string) {
	t.Helper()
	err := filepath.Walk(src, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		target := filepath.Join(dst, rel)
		if info.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		return os.WriteFile(target, b, 0o644)
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestIngestLoadRoundTrip(t *testing.T) {
	claude, l := seed(t)
	a, err := OpenAt(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()

	res, err := a.Ingest(l, Options{})
	if err != nil {
		t.Fatal(err)
	}
	if res.Action != "archived" || res.Records != 31 || res.Bytes != l.File.Bytes {
		t.Fatalf("first ingest = %+v (source %d bytes)", res, l.File.Bytes)
	}
	again, err := a.Ingest(l, Options{})
	if err != nil || again.Action != "unchanged" {
		t.Fatalf("second ingest = %+v %v", again, err)
	}

	// The raw copy is lossless (api-request* included) and is plain JSONL once decompressed.
	f, _ := os.Open(res.Path)
	dec, _ := zstd.NewReader(f)
	recs, err := transcript.ReadAll(dec)
	dec.Close()
	f.Close()
	if err != nil {
		t.Fatal(err)
	}
	if len(recs) != 31 {
		t.Fatalf("raw copy has %d records, want 31 (lossless)", len(recs))
	}
	apiRecs := 0
	for _, r := range recs {
		if r.IsAPIRequest() {
			apiRecs++
		}
	}
	if apiRecs != 3 {
		t.Fatalf("api-request records must be kept by default, got %d", apiRecs)
	}

	// Load from the archive matches the original, subagent and spilled result included.
	orig, _ := transcript.Load(l.File.Path)
	s, row, err := a.Load(fixtureID)
	if err != nil {
		t.Fatal(err)
	}
	if !row.Archived() || s.Totals.Prompts != orig.Totals.Prompts || s.Totals.Requests != orig.Totals.Requests || s.Totals.ToolCalls != orig.Totals.ToolCalls || len(s.Subagents) != 1 || s.Subagents[0].ToolUseID != "toolu_03" {
		t.Fatalf("archived session differs: %+v vs %+v, subagents %d", s.Totals, orig.Totals, len(s.Subagents))
	}
	var edit *transcript.ToolCall
	for _, c := range s.ToolCalls {
		if c.ID == "toolu_04" {
			edit = c
		}
	}
	if p, ok := s.SpilledPath(edit); !ok || !filepath.IsAbs(p) {
		t.Fatalf("spilled output should resolve inside the archive: %q %v", p, ok)
	}
	if s.OwnerAccount != "acc" || s.OwnerOrg != "org" {
		t.Fatalf("owner = %q/%q", s.OwnerAccount, s.OwnerOrg)
	}

	// Search works over the segments.
	hits, err := search.Run(a.Store, "Bash", search.Options{})
	if err != nil || len(hits) == 0 || hits[0].Session != fixtureID {
		t.Fatalf("search: %v %+v", err, hits)
	}
	kinds := map[string]bool{}
	for _, h := range hits {
		kinds[h.Kind] = true
	}
	if !kinds["tool_use"] {
		t.Fatalf("expected tool_use hits for Bash, got kinds %v", kinds)
	}

	// Append path: the source grows by one complete line plus a partial one.
	line := `{"type":"user","uuid":"u9","parentUuid":"a8","turnOrigin":"human","sessionId":"` + fixtureID + `","timestamp":"2026-11-08T10:02:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Appended prompt about zebras"}]}}` + "\n"
	fh, _ := os.OpenFile(l.File.Path, os.O_APPEND|os.O_WRONLY, 0o644)
	fh.WriteString(line + `{"type":"user","uuid":"partial"`)
	fh.Close()
	time.Sleep(10 * time.Millisecond)
	rep, _ := catalog.InspectDir(claude)
	l2, _ := rep.Find(fixtureID)
	res2, err := a.Ingest(l2, Options{})
	if err != nil || res2.Action != "updated" || res2.Records != 32 {
		t.Fatalf("append ingest = %+v %v", res2, err)
	}
	if res2.Bytes != l2.File.Bytes {
		t.Fatalf("covered bytes %d should be the whole file, unfinished last line included (%d)", res2.Bytes, l2.File.Bytes)
	}
	s2, _, err := a.Load(fixtureID)
	if err != nil || s2.Totals.Prompts != 3 {
		t.Fatalf("archived copy after append: prompts=%d err=%v", s2.Totals.Prompts, err)
	}
	if hits, _ := search.Run(a.Store, "zebras", search.Options{}); len(hits) != 1 || hits[0].Kind != "prompt" || hits[0].Turn != 2 || hits[0].Action != -1 {
		t.Fatalf("new prompt should be searchable: %+v", hits)
	}

	// Stripping requests rewrites the copy without api-request* records.
	res3, err := a.Ingest(l2, Options{StripRequests: true})
	if err != nil || res3.Action != "updated" {
		t.Fatalf("strip ingest = %+v %v", res3, err)
	}
	f, _ = os.Open(res3.Path)
	dec, _ = zstd.NewReader(f)
	recs, _ = transcript.ReadAll(dec)
	dec.Close()
	f.Close()
	if len(recs) != 29 { // 32 minus the three api-request* records
		t.Fatalf("stripped copy has %d records, want 29", len(recs))
	}
	// Context from the archived (lossless) copy works.
	if _, err := a.Ingest(l2, Options{}); err != nil {
		t.Fatal(err)
	}
	s3, _, err := a.Load(fixtureID)
	if err != nil {
		t.Fatal(err)
	}
	if cb, err := s3.ContextOf(0, false); err != nil || !cb.Available || len(cb.Tools) != 2 {
		t.Fatalf("context from the archive should be available: %v %+v", err, cb)
	}
}

func TestSummaryActsAsCache(t *testing.T) {
	_, l := seed(t)
	a, err := OpenAt(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	sum, fresh, err := a.Summary(l)
	if err != nil || fresh || sum.Requests != 7 {
		t.Fatalf("first summary: fresh=%v requests=%d err=%v", fresh, sum.Requests, err)
	}
	sum2, fresh, err := a.Summary(l)
	if err != nil || !fresh || sum2.Requests != 7 {
		t.Fatalf("second summary should come from the index: fresh=%v err=%v", fresh, err)
	}
	row, _ := a.Store.Session(fixtureID)
	if row == nil || row.Archived() {
		t.Fatal("summary-only indexing must not mark the session archived")
	}
}
