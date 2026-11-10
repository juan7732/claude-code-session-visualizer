package archive

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/embed"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/embed/embedtest"
)

// fakeEmbedder is the real embed.Embedder talking to a stand-in for
// llama-server over HTTP.
func fakeEmbedder(t *testing.T, source string) (*embed.Embedder, *embedtest.Server) {
	t.Helper()
	fake := &embedtest.Server{}
	srv := httptest.NewServer(fake)
	t.Cleanup(srv.Close)
	return embed.NewClientEmbedder(&embed.Client{BaseURL: srv.URL}, source), fake
}

func TestEmbedCoversTheIndexOnceAndSurvivesReindexing(t *testing.T) {
	_, l := seedProse(t)
	a, err := OpenAt(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	if _, err := a.Ingest(l, Options{}); err != nil {
		t.Fatal(err)
	}
	e, fake := fakeEmbedder(t, "fake v1")
	ctx := context.Background()

	var lastDone, lastTotal int
	res, err := a.Embed(ctx, e, func(done, total int) { lastDone, lastTotal = done, total })
	if err != nil {
		t.Fatal(err)
	}
	if res.Cut == 0 || res.Embedded == 0 || res.Texts == 0 || res.Vectors != res.Texts || res.Source != "fake v1" {
		t.Fatalf("first embed = %+v", res)
	}
	if lastDone != res.Embedded || lastTotal != res.Embedded {
		t.Fatalf("progress ended at %d of %d, embedded %d", lastDone, lastTotal, res.Embedded)
	}
	if res.Bytes != int64(res.Vectors)*2*embed.Dimensions {
		t.Fatalf("%d vectors take %d bytes, want 1,536 each", res.Vectors, res.Bytes)
	}
	first := res
	asked := fake.Texts.Load()
	if asked != int64(res.Embedded) {
		t.Fatalf("the server embedded %d texts for %d vectors", asked, res.Embedded)
	}

	// Nothing to do the second time: no segment cut, no text sent.
	res, err = a.Embed(ctx, e, nil)
	if err != nil || res.Cut != 0 || res.Embedded != 0 || fake.Texts.Load() != asked {
		t.Fatalf("second embed = %+v %v (server texts %d → %d)", res, err, asked, fake.Texts.Load())
	}

	// Re-indexing a session replaces its segments, which takes their chunks
	// with them. The text is the same, so the vectors are found again by hash
	// and the model is not asked.
	s, _, err := a.Load(proseID)
	if err != nil {
		t.Fatal(err)
	}
	segs := Segments(s)
	if err := a.Store.ReplaceSegments(proseID, segs); err != nil {
		t.Fatal(err)
	}
	if c, _ := a.Store.VectorCounts(); c.Chunks != 0 {
		t.Fatalf("chunks should go with their segments, %d left", c.Chunks)
	}
	res, err = a.Embed(ctx, e, nil)
	if err != nil || res.Cut != first.Cut || res.Embedded != 0 || res.Vectors != first.Vectors || fake.Texts.Load() != asked {
		t.Fatalf("after re-indexing = %+v %v (server texts %d → %d)", res, err, asked, fake.Texts.Load())
	}

	// A session that lost text loses the vectors nothing else uses.
	var fewer = segs[:0:0]
	dropped := false
	for _, g := range segs {
		if !dropped && g.Kind == "assistant" && len(embed.Chunks(g.Text, embed.MaxChunkRunes)) > 0 {
			dropped = true
			continue
		}
		fewer = append(fewer, g)
	}
	if !dropped {
		t.Fatal("the fixture has no assistant text worth a vector")
	}
	if err := a.Store.ReplaceSegments(proseID, fewer); err != nil {
		t.Fatal(err)
	}
	res, err = a.Embed(ctx, e, nil)
	if err != nil || res.Pruned == 0 || res.Vectors != res.Texts || res.Vectors >= first.Vectors {
		t.Fatalf("after losing a segment = %+v %v", res, err)
	}
	remaining := res.Vectors

	// Another model: every vector is dropped and made again, never mixed.
	e2, fake2 := fakeEmbedder(t, "fake v2")
	res, err = a.Embed(ctx, e2, nil)
	if err != nil || res.Dropped != remaining || res.Embedded != remaining || res.Source != "fake v2" || fake2.Texts.Load() != int64(remaining) {
		t.Fatalf("after changing the source = %+v %v", res, err)
	}
}

func TestEmbedLeavesToolOutputToKeywordSearch(t *testing.T) {
	_, l := seedProse(t)
	a, err := OpenAt(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	if _, err := a.Ingest(l, Options{}); err != nil {
		t.Fatal(err)
	}
	if _, err := a.Chunk(context.Background()); err != nil {
		t.Fatal(err)
	}
	rows, err := a.Store.DB().Query(`SELECT g.kind, count(*) FROM chunks c JOIN segments g ON g.id = c.segment GROUP BY g.kind`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	kinds := map[string]int{}
	for rows.Next() {
		var k string
		var n int
		rows.Scan(&k, &n)
		kinds[k] = n
	}
	// Four prompts (the fifth is "ok"), one thinking block, and six pieces of
	// replies: four short ones, the long reply in two (cut at the paragraph
	// where it changes subject), and "Done." left out.
	if kinds["prompt"] != 4 || kinds["thinking"] != 1 || kinds["assistant"] != 6 {
		t.Fatalf("chunks by kind = %v, want prompt 4, thinking 1, assistant 6", kinds)
	}
	var second string
	if err := a.Store.DB().QueryRow(`SELECT substr(CAST(g.text AS BLOB), c.start + 1, c.len) FROM chunks c JOIN segments g ON g.id = c.segment WHERE c.ord = 1`).Scan(&second); err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(second, "One more thing I noticed") || !strings.Contains(second, "exponential backoff") {
		t.Fatalf("the long reply's second piece should be its last paragraph, got %q", second)
	}
	for _, k := range []string{"tool_use", "tool_result", "context"} {
		if kinds[k] != 0 {
			t.Fatalf("%s should not be cut: %v", k, kinds)
		}
	}
}

func TestEmbedStoppedEarlyKeepsWhatLanded(t *testing.T) {
	_, l := seedProse(t)
	a, err := OpenAt(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	if _, err := a.Ingest(l, Options{}); err != nil {
		t.Fatal(err)
	}
	e, _ := fakeEmbedder(t, "fake v1")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	res, err := a.Embed(ctx, e, nil)
	if err == nil {
		t.Fatalf("a cancelled run should say so: %+v", res)
	}
	// Run again to completion: nothing is in a state that needs repair.
	res, err = a.Embed(context.Background(), e, nil)
	if err != nil || res.Vectors == 0 || res.Vectors != res.Texts {
		t.Fatalf("resumed run = %+v %v", res, err)
	}
}
