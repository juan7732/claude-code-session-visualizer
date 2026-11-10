package search

import (
	"context"
	"errors"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/archive"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/embed"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/embed/embedtest"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/store"
)

const proseID = "bbbbbbbb-0000-0000-0000-000000000002"

// proseArchive archives the prose-search fixture (five turns in plain
// sentences: retention, compression, a blank page with a paragraph about a
// flaky payments test at the end, "ok", a DNS error) into a temporary home.
func proseArchive(t *testing.T) *archive.Archive {
	t.Helper()
	claude := t.TempDir()
	proj := filepath.Join(claude, "projects", "-Users-xxxx-work")
	if err := os.MkdirAll(proj, 0o755); err != nil {
		t.Fatal(err)
	}
	src := filepath.Join("..", "..", "internal", "testdata", "sessions", "prose-search", proseID+".jsonl")
	b, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(proj, proseID+".jsonl"), b, 0o644); err != nil {
		t.Fatal(err)
	}
	rep, err := catalog.InspectDir(claude)
	if err != nil {
		t.Fatal(err)
	}
	l, err := rep.Find(proseID)
	if err != nil {
		t.Fatal(err)
	}
	a, err := archive.OpenAt(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { a.Close() })
	if _, err := a.Ingest(l, archive.Options{}); err != nil {
		t.Fatal(err)
	}
	return a
}

// fakeEmbedder is the real embed.Embedder over a stand-in for llama-server
// whose vectors come from a text's words: close in "meaning" here means
// sharing words, which is enough to test ranking, pieces and plumbing. What
// the real model adds is measured by `skit eval` on real sessions.
func fakeEmbedder(t *testing.T, source string) *embed.Embedder {
	t.Helper()
	srv := httptest.NewServer(&embedtest.Server{})
	t.Cleanup(srv.Close)
	return embed.NewClientEmbedder(&embed.Client{BaseURL: srv.URL}, source)
}

func embedded(t *testing.T) (*archive.Archive, *embed.Embedder) {
	t.Helper()
	a := proseArchive(t)
	e := fakeEmbedder(t, "fake v1")
	if _, err := a.Embed(context.Background(), e, nil); err != nil {
		t.Fatal(err)
	}
	return a, e
}

func TestMeaningRanksTheClosestPiece(t *testing.T) {
	a, e := embedded(t)
	ctx := context.Background()

	// The stand-in's cosines are word overlaps, far below a real model's, so
	// the ranking is looked at without the gate; the gate has its own test.
	hits, err := Meaning(ctx, a.Store, e, "a retention sweep deletes the session files", Options{NoGate: true})
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) == 0 {
		t.Fatal("no hits")
	}
	h := hits[0]
	if h.Session != proseID || h.Turn != 0 || h.Kind != "assistant" || h.Match != ModeMeaning {
		t.Fatalf("first hit = %+v", h)
	}
	if h.Cosine <= 0 || h.Z <= 1 || h.Score != h.Cosine || !strings.HasPrefix(h.Snippet, "Claude Code removes them on purpose.") {
		t.Fatalf("first hit should carry its cosine, a z above the crowd and the piece as snippet: %+v", h)
	}
	for i := 1; i < len(hits); i++ {
		if hits[i].Cosine > hits[i-1].Cosine {
			t.Fatalf("hits are not in order of cosine at %d", i)
		}
	}
	// One hit per segment: the long reply has two pieces and appears once.
	seen := map[string]int{}
	for _, h := range hits {
		if h.Kind == "assistant" && h.Turn == 2 {
			seen["long"]++
		}
	}
	if seen["long"] != 1 {
		t.Fatalf("the two-piece reply appears %d times", seen["long"])
	}

	// A subject buried in the last paragraph of a long reply about something
	// else is found, and the snippet is that paragraph, not the reply's start.
	hits, err = Meaning(ctx, a.Store, e, "payments test retry with exponential backoff", Options{Limit: 3, NoGate: true})
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) != 3 || hits[0].Turn != 2 || !strings.HasPrefix(hits[0].Snippet, "One more thing I noticed") {
		t.Fatalf("buried subject: %d hits, first %+v", len(hits), hits[0])
	}

	// Filters narrow what is scored.
	hits, err = Meaning(ctx, a.Store, e, "a retention sweep deletes the session files", Options{Kind: "prompt", NoGate: true})
	if err != nil || len(hits) != 4 {
		t.Fatalf("kind filter: %d hits %v, want the four prompts with vectors", len(hits), err)
	}
	for _, h := range hits {
		if h.Kind != "prompt" {
			t.Fatalf("kind filter let through %+v", h)
		}
	}
	// Narrowing the search does not change what z means: the first prompt has
	// the z it had among everything.
	everything, _ := Meaning(ctx, a.Store, e, "a retention sweep deletes the session files", Options{NoGate: true})
	for _, h := range everything {
		if h.Kind == "prompt" && h.Turn == hits[0].Turn && h.Z != hits[0].Z {
			t.Fatalf("z of the same prompt: %g among everything, %g among prompts", h.Z, hits[0].Z)
		}
	}
	hits, err = Meaning(ctx, a.Store, e, "a retention sweep deletes the session files", Options{Kinds: []string{"prompt", "thinking"}, NoGate: true})
	if err != nil || len(hits) != 5 {
		t.Fatalf("two kinds: %d hits %v, want four prompts and the thinking block", len(hits), err)
	}
	if hits, _ := Meaning(ctx, a.Store, e, "retention", Options{Session: "another-session", NoGate: true}); len(hits) != 0 {
		t.Fatalf("session filter: %d hits", len(hits))
	}
	if hits, _ := Meaning(ctx, a.Store, e, "retention", Options{Project: "xxxx-WORK", NoGate: true}); len(hits) == 0 {
		t.Fatal("project filter should match a part of the slug, whatever its case")
	}
	if _, err := Meaning(ctx, a.Store, e, "retention", Options{Kind: "tool"}); !errors.Is(err, ErrUnknownKind) {
		t.Fatalf("unknown kind: %v", err)
	}
}

func TestMeaningSaysWhyItCannotAnswer(t *testing.T) {
	a := proseArchive(t)
	e := fakeEmbedder(t, "fake v1")
	ctx := context.Background()

	if _, err := Meaning(ctx, a.Store, nil, "retention", Options{}); !errors.Is(err, ErrNoEmbedder) {
		t.Fatalf("without an embedder: %v", err)
	}
	if _, err := Meaning(ctx, a.Store, e, "retention", Options{}); !errors.Is(err, ErrNoVectors) {
		t.Fatalf("before embedding: %v", err)
	}
	if _, err := a.Embed(ctx, e, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := Meaning(ctx, a.Store, fakeEmbedder(t, "fake v2"), "retention", Options{}); !errors.Is(err, ErrStaleVectors) {
		t.Fatalf("vectors from another source: %v", err)
	}
	if _, err := Meaning(ctx, a.Store, e, "  ", Options{}); !errors.Is(err, ErrEmptyQuery) {
		t.Fatalf("empty query: %v", err)
	}
	if _, err := Search(ctx, a.Store, e, "retention", Options{Mode: "telepathy"}); !errors.Is(err, ErrUnknownMode) {
		t.Fatalf("unknown mode: %v", err)
	}
	// Keyword is the default, needs no embedder, and says so on each hit.
	hits, err := Search(ctx, a.Store, nil, "retention sweep", Options{})
	if err != nil || len(hits) == 0 || hits[0].Match != ModeKeyword || hits[0].Cosine != 0 {
		t.Fatalf("keyword through Search: %v %+v", err, hits)
	}
	if _, err := Search(ctx, a.Store, nil, "the of and", Options{}); !errors.Is(err, ErrEmptyQuery) {
		t.Fatalf("a query of stopwords: %v", err)
	}
}

func TestEvalScoresWhereTheAnswerLands(t *testing.T) {
	a, e := embedded(t)
	ctx := context.Background()
	run := func(ctx context.Context, q string, opt Options) ([]Hit, error) {
		opt.NoGate = true // the stand-in's cosines are not a real model's
		return Search(ctx, a.Store, e, q, opt)
	}
	file := `{"queries": [
	  {"q": "retention sweep deletes session files", "expect": ["bbbbbbbb@0"], "tag": "words"},
	  {"q": "ENOTFOUND", "expect": ["bbbbbbbb@3-4"], "tag": "lookup"},
	  {"q": "Zstandard", "expect": ["bbbbbbbb"], "tag": "lookup"},
	  {"q": "Zstandard", "expect": ["bbbbbbbb@4"], "tag": "wrong-on-purpose"},
	  {"q": "the of and", "expect": ["bbbbbbbb@0"], "tag": "stopwords"},
	  {"q": "quantum chromodynamics lattice", "expect": []}
	]}`
	ev, err := LoadEval(a.Store, []byte(file))
	if err != nil {
		t.Fatal(err)
	}
	rep, err := ev.Run(ctx, []string{ModeKeyword, ModeMeaning}, run)
	if err != nil {
		t.Fatal(err)
	}
	if rep.Queries != 6 || len(rep.Modes) != 2 || rep.Modes[0].Mode != ModeKeyword {
		t.Fatalf("report header = %+v", rep)
	}
	kw := rep.Modes[0]
	ranks := make([]int, len(kw.Outcomes))
	for i, o := range kw.Outcomes {
		ranks[i] = o.Rank
	}
	// Found first, found first (range), found first (any turn of the session),
	// not at turn 4 (Zstandard is turn 1; a later turn mentions nothing of it),
	// no hits at all for stopwords, and nothing expected.
	if want := []int{1, 1, 1, 0, 0, 0}; !equalInts(ranks, want) {
		t.Fatalf("keyword ranks = %v, want %v", ranks, want)
	}
	if kw.Overall.N != 5 || kw.Overall.R1 != 0.6 || kw.Overall.R10 != 0.6 || kw.Overall.MRR != 0.6 {
		t.Fatalf("keyword overall = %+v, want 3 of 5", kw.Overall)
	}
	if kw.Nothing.N != 1 || kw.Nothing.Answered != 0 {
		t.Fatalf("keyword should find nothing for the query that expects nothing: %+v", kw.Nothing)
	}
	if len(kw.Tags) != 4 || kw.Tags[0].Tag != "lookup" || kw.Tags[0].N != 2 || kw.Tags[0].R1 != 1 {
		t.Fatalf("tags = %+v", kw.Tags)
	}
	if kw.Outcomes[0].Top != "bbbbbbbb@0 assistant" && kw.Outcomes[0].Top != "bbbbbbbb@0 thinking" {
		t.Fatalf("top of the first query = %q", kw.Outcomes[0].Top)
	}
	if kw.Outcomes[4].Hits != 0 || kw.Outcomes[5].Expect == nil {
		t.Fatalf("stopword query hits=%d; empty expect must stay a list: %+v", kw.Outcomes[4].Hits, kw.Outcomes[5])
	}

	// Plain meaning search always answers: that is what the gate is for.
	mn := rep.Modes[1]
	if mn.Outcomes[0].Rank != 1 || mn.Outcomes[0].TopCosine == 0 || mn.Nothing.Answered != 1 {
		t.Fatalf("meaning: first query rank %d cosine %g, nothing-expected answered %d", mn.Outcomes[0].Rank, mn.Outcomes[0].TopCosine, mn.Nothing.Answered)
	}
}

func TestEvalRefusesTargetsItCannotResolve(t *testing.T) {
	a := proseArchive(t)
	// A second session with the same first characters.
	if err := a.Store.UpsertSummary(store.SessionRow{ID: "bbbbbbbb-1111", Project: "p", SourcePath: "/x", Summary: []byte(`{}`)}); err != nil {
		t.Fatal(err)
	}
	cases := map[string]string{
		`{"queries": [{"q": "x", "expect": ["cccccccc@1"]}]}`:        "no archived session",
		`{"queries": [{"q": "x", "expect": ["bbbbbbbb@1"]}]}`:        "2 sessions start with",
		`{"queries": [{"q": "x", "expect": ["bbbbbbbb-0000@one"]}]}`: "must be a number",
		`{"queries": [{"q": "x", "expect": ["bbbbbbbb-0000@5-2"]}]}`: "A-B",
		`{"queries": [{"q": "x", "expect": ["@3"]}]}`:                "no session id",
		`{"queries": [{"q": " ", "expect": []}]}`:                    "no text",
		`{"queries": []}`: "no queries",
		`{"queries": [{"q": "x", "expected": ["bbbbbbbb-0000"]}]}`:           "unknown field",
		`{"queries": [{"q": "x", "expect": ["bbbbbbbb-0000@2"], "tag": 3}]}`: "eval file",
	}
	for file, want := range cases {
		if _, err := LoadEval(a.Store, []byte(file)); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%s\n  err = %v, want it to mention %q", file, err, want)
		}
	}
	if _, err := LoadEval(a.Store, []byte(`{"queries": [{"q": "x", "expect": ["bbbbbbbb-0000@2", "bbbbbbbb-1"]}]}`)); err != nil {
		t.Fatalf("unique prefixes should resolve: %v", err)
	}
}

func TestRankCountsDistinctTurns(t *testing.T) {
	hit := func(session, agent string, turn int) Hit { return Hit{Session: session, Agent: agent, Turn: turn} }
	hits := []Hit{
		hit("s1", "", 3), hit("s1", "", 3), hit("s1", "", 3), // three segments of one turn: one place
		hit("s1", "sub", 7), // a subagent's turn 7 is not the main transcript's turn 7
		hit("s2", "", 0),
		hit("s1", "", 7),
	}
	turn := func(s string, lo, hi int) []evalTarget { return []evalTarget{{session: s, lo: lo, hi: hi}} }
	if got := rankOf(hits, turn("s1", 7, 7)); got != 4 {
		t.Fatalf("s1@7 is the fourth distinct turn, got %d", got)
	}
	if got := rankOf(hits, turn("s1", 3, 3)); got != 1 {
		t.Fatalf("s1@3 = %d", got)
	}
	if got := rankOf(hits, []evalTarget{{session: "s2", anyTurn: true}}); got != 2 {
		t.Fatalf("session s2 is the second distinct session, got %d", got)
	}
	if got := rankOf(hits, turn("s9", 0, 0)); got != 0 {
		t.Fatalf("a turn that is not there = %d", got)
	}
	// Any one target is enough; the best place counts.
	if got := rankOf(hits, append(turn("s1", 7, 7), turn("s2", 0, 5)...)); got != 3 {
		t.Fatalf("best of two targets = %d, want 3", got)
	}
	// Beyond the depth is not found.
	var deep []Hit
	for i := 0; i < 12; i++ {
		deep = append(deep, hit("s1", "", i))
	}
	if rankOf(deep, turn("s1", 9, 9)) != 10 || rankOf(deep, turn("s1", 10, 10)) != 0 {
		t.Fatal("the depth is ten distinct turns")
	}
}

func equalInts(a, b []int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// TestEvalLeavesOutExcludedSessions: the session in which the queries were
// written quotes each of them, so it would come first for every one. Its hits
// are dropped before anything is counted.
func TestEvalLeavesOutExcludedSessions(t *testing.T) {
	a, e := embedded(t)
	run := func(ctx context.Context, q string, opt Options) ([]Hit, error) {
		opt.NoGate = true // the stand-in's cosines are not a real model's
		return Search(ctx, a.Store, e, q, opt)
	}
	const queries = `"queries": [{"q": "retention sweep deletes session files", "expect": [], "tag": "nothing", "note": "answered only by the excluded session"}]`

	ev, err := LoadEval(a.Store, []byte(`{`+queries+`}`))
	if err != nil {
		t.Fatal(err)
	}
	rep, err := ev.Run(context.Background(), []string{ModeKeyword, ModeMeaning}, run)
	if err != nil || rep.Modes[0].Nothing.Answered != 1 || rep.Modes[1].Nothing.Answered != 1 {
		t.Fatalf("without exclude both modes answer: %+v %v", rep.Modes, err)
	}

	// A prefix that matches nothing on this machine is fine; the one that
	// matches takes every hit of that session out.
	ev, err = LoadEval(a.Store, []byte(`{"exclude": ["ffffffff", "bbbbbbbb-0000"], `+queries+`}`))
	if err != nil {
		t.Fatal(err)
	}
	rep, err = ev.Run(context.Background(), []string{ModeKeyword, ModeMeaning}, run)
	if err != nil {
		t.Fatal(err)
	}
	for _, m := range rep.Modes {
		if o := m.Outcomes[0]; o.Hits != 0 || o.Top != "" || m.Nothing.Answered != 0 {
			t.Fatalf("%s still counts hits from an excluded session: %+v", m.Mode, o)
		}
	}

	// Expecting an answer inside an excluded session can never succeed: say so.
	if _, err := LoadEval(a.Store, []byte(`{"exclude": ["bbbbbbbb"], "queries": [{"q": "x", "expect": ["bbbbbbbb@0"]}]}`)); err == nil || !strings.Contains(err.Error(), "excluded session") {
		t.Fatalf("target in an excluded session: %v", err)
	}
	if _, err := LoadEval(a.Store, []byte(`{"exclude": [""], `+queries+`}`)); err == nil || !strings.Contains(err.Error(), "every session") {
		t.Fatalf("empty exclude entry: %v", err)
	}
}

// TestMeaningGate: a piece is a match when its cosine or its z reaches the
// gate; otherwise it is only the nearest thing there is, and is not returned.
func TestMeaningGate(t *testing.T) {
	a, e := embedded(t)
	ctx := context.Background()
	const q = "a retention sweep deletes the session files"
	all, err := Meaning(ctx, a.Store, e, q, Options{NoGate: true})
	if err != nil || len(all) < 3 || all[0].Cosine <= all[1].Cosine || all[0].Z <= all[1].Z {
		t.Fatalf("need a clear first hit to test with: %v %+v", err, all)
	}
	// A cosine floor between the first and the second hit keeps only the
	// first; so does a z gate between them. The test not in use is set out of reach.
	between := func(x, y float64) float64 { return (x + y) / 2 }
	hits, err := Meaning(ctx, a.Store, e, q, Options{MinCosine: between(all[0].Cosine, all[1].Cosine), MinZ: 99})
	if err != nil || len(hits) != 1 || hits[0].Turn != all[0].Turn {
		t.Fatalf("cosine floor: %d hits %v", len(hits), err)
	}
	hits, err = Meaning(ctx, a.Store, e, q, Options{MinCosine: 2, MinZ: between(all[0].Z, all[1].Z)})
	if err != nil || len(hits) != 1 || hits[0].Turn != all[0].Turn {
		t.Fatalf("z gate: %d hits %v", len(hits), err)
	}
	// Either test passing is enough.
	hits, _ = Meaning(ctx, a.Store, e, q, Options{MinCosine: between(all[1].Cosine, all[2].Cosine), MinZ: 99})
	both, _ := Meaning(ctx, a.Store, e, q, Options{MinCosine: between(all[1].Cosine, all[2].Cosine), MinZ: between(all[0].Z, all[1].Z)})
	if len(hits) != 2 || len(both) != 2 {
		t.Fatalf("cosine floor under the second hit: %d hits alone, %d with a stricter z gate beside it; want 2 and 2", len(hits), len(both))
	}
	// By default the gate is on, and a query about nothing in the archive
	// gets no answer instead of its nearest neighbours.
	hits, err = Meaning(ctx, a.Store, e, "quantum chromodynamics on a lattice", Options{})
	if err != nil || len(hits) != 0 {
		t.Fatalf("a query nothing is about: %d hits %v", len(hits), err)
	}
	if n, _ := Meaning(ctx, a.Store, e, "quantum chromodynamics on a lattice", Options{NoGate: true}); len(n) == 0 {
		t.Fatal("without the gate the nearest pieces come back, whatever they are")
	}
}

func TestKindFiltersInKeywordSearch(t *testing.T) {
	a := proseArchive(t)
	kinds := func(opt Options) map[string]int {
		t.Helper()
		hits, err := Run(a.Store, "Zstandard version", opt)
		if err != nil {
			t.Fatal(err)
		}
		out := map[string]int{}
		for _, h := range hits {
			out[h.Kind]++
		}
		return out
	}
	everything := kinds(Options{})
	if everything["tool_use"] == 0 || everything["tool_result"] == 0 || everything["assistant"] == 0 {
		t.Fatalf("the fixture's zstd turn has a reply, a call and a result: %v", everything)
	}
	if got := kinds(Options{NoTools: true}); got["tool_use"]+got["tool_result"] != 0 || got["assistant"] != everything["assistant"] {
		t.Fatalf("without tools: %v (everything: %v)", got, everything)
	}
	if got := kinds(Options{Kinds: []string{"tool_use", "tool_result"}}); got["assistant"] != 0 || got["tool_result"] != everything["tool_result"] {
		t.Fatalf("only tools: %v", got)
	}
	if got := kinds(Options{Kinds: []string{"tool_result"}, Kind: "assistant"}); len(got) != 2 {
		t.Fatalf("Kind adds to Kinds: %v", got)
	}
	if got := kinds(Options{Kinds: []string{"tool_result"}, NoTools: true}); len(got) != 0 {
		t.Fatalf("asking for tools and for no tools finds nothing: %v", got)
	}
	if _, err := Run(a.Store, "Zstandard", Options{Kinds: []string{"assistant", "tools"}}); !errors.Is(err, ErrUnknownKind) {
		t.Fatalf("unknown kind: %v", err)
	}
}
