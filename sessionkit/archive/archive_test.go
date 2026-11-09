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
	src := filepath.Join("..", "..", "internal", "testdata", "sessions", "synthetic-basics")
	claude = t.TempDir()
	proj := filepath.Join(claude, "projects", "-Users-xxxx-work")
	copyTree(t, src, proj)
	os.Remove(filepath.Join(proj, "expected.json"))
	rep, err := catalog.InspectDir(claude)
	if err != nil {
		t.Fatal(err)
	}
	l, err = rep.Find(fixtureID)
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
	if res.Action != "archived" || res.Records != 28 || res.Bytes != l.File.Bytes {
		t.Fatalf("first ingest = %+v (source %d bytes)", res, l.File.Bytes)
	}
	again, err := a.Ingest(l, Options{})
	if err != nil || again.Action != "unchanged" {
		t.Fatalf("second ingest = %+v %v", again, err)
	}

	// The raw copy drops api-request* and is plain JSONL once decompressed.
	f, _ := os.Open(res.Path)
	dec, _ := zstd.NewReader(f)
	recs, err := transcript.ReadAll(dec)
	dec.Close()
	f.Close()
	if err != nil {
		t.Fatal(err)
	}
	if len(recs) != 26 { // 28 minus api-request and api-request-blob
		t.Fatalf("raw copy has %d records, want 26", len(recs))
	}
	for _, r := range recs {
		if r.IsAPIRequest() {
			t.Fatal("api-request records must be dropped without --debug")
		}
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
	if err != nil || res2.Action != "updated" || res2.Records != 29 {
		t.Fatalf("append ingest = %+v %v", res2, err)
	}
	if res2.Bytes != l.File.Bytes+int64(len(line)) {
		t.Fatalf("covered bytes %d should stop before the partial line (%d)", res2.Bytes, l.File.Bytes+int64(len(line)))
	}
	s2, _, err := a.Load(fixtureID)
	if err != nil || s2.Totals.Prompts != 3 {
		t.Fatalf("archived copy after append: prompts=%d err=%v", s2.Totals.Prompts, err)
	}
	if hits, _ := search.Run(a.Store, "zebras", search.Options{}); len(hits) != 1 || hits[0].Kind != "prompt" {
		t.Fatalf("new prompt should be searchable: %+v", hits)
	}

	// Debug mode rewrites and keeps api-request* records.
	res3, err := a.Ingest(l2, Options{Debug: true})
	if err != nil || res3.Action != "updated" {
		t.Fatalf("debug ingest = %+v %v", res3, err)
	}
	f, _ = os.Open(res3.Path)
	dec, _ = zstd.NewReader(f)
	recs, _ = transcript.ReadAll(dec)
	dec.Close()
	f.Close()
	if len(recs) != 29 {
		t.Fatalf("debug copy has %d records, want 29", len(recs))
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
