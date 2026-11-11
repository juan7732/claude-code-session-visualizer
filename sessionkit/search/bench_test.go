package search

import (
	"context"
	"fmt"
	"math/rand"
	"path/filepath"
	"testing"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/embed"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/store"
)

// fixedQuery answers every query with the same vector: the benchmark measures
// the scan, not the model.
type fixedQuery struct{ v []float32 }

func (f fixedQuery) Source() string                                   { return "bench" }
func (f fixedQuery) Query(context.Context, string) ([]float32, error) { return f.v, nil }

func randomUnit(r *rand.Rand) []float32 {
	v := make([]float32, embed.Dimensions)
	for i := range v {
		v[i] = float32(r.NormFloat64())
	}
	return embed.Normalize(v)
}

// benchIndex builds an index of n one-piece segments with random vectors.
func benchIndex(b *testing.B, n int) *store.Store {
	b.Helper()
	st, err := store.Open(filepath.Join(b.TempDir(), "skit.sqlite"))
	if err != nil {
		b.Fatal(err)
	}
	b.Cleanup(func() { st.Close() })
	if err := st.UpsertSummary(store.SessionRow{ID: "s1", Project: "p", SourcePath: "/x", Summary: []byte(`{}`)}); err != nil {
		b.Fatal(err)
	}
	segs := make([]store.Segment, n)
	for i := range segs {
		segs[i] = store.Segment{Session: "s1", Kind: "assistant", Turn: i, Text: fmt.Sprintf("piece number %d of the benchmark index", i)}
	}
	if err := st.ReplaceSegments("s1", segs); err != nil {
		b.Fatal(err)
	}
	if _, err := st.UseVectorSource("bench"); err != nil {
		b.Fatal(err)
	}
	r := rand.New(rand.NewSource(1))
	for {
		todo, err := st.UnchunkedSegments([]string{"assistant"}, 2000)
		if err != nil {
			b.Fatal(err)
		}
		if len(todo) == 0 {
			break
		}
		ids := make([]int64, len(todo))
		chunks := make([]store.Chunk, len(todo))
		hashes := make([][]byte, len(todo))
		vecs := make([][]byte, len(todo))
		for i, g := range todo {
			ids[i] = g.ID
			hashes[i] = store.ChunkHash(g.Text)
			chunks[i] = store.Chunk{Segment: g.ID, Len: len(g.Text), Hash: hashes[i]}
			vecs[i] = embed.Pack(randomUnit(r))
		}
		if err := st.PutChunks(ids, chunks); err != nil {
			b.Fatal(err)
		}
		if err := st.PutVectors(hashes, vecs); err != nil {
			b.Fatal(err)
		}
	}
	return st
}

// BenchmarkMeaning compares a meaning query that reads the index each time
// (the CLI) with one over vectors held in memory (skit serve):
//
//	go test -run xxx -bench Meaning -benchtime 20x ./sessionkit/search/
func BenchmarkMeaning(b *testing.B) {
	for _, n := range []int{2000, 20000, 100000} {
		st := benchIndex(b, n)
		q := fixedQuery{randomUnit(rand.New(rand.NewSource(2)))}
		ctx := context.Background()
		b.Run(fmt.Sprintf("pieces=%d/from-index", n), func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				if _, err := Meaning(ctx, st, q, "anything", Options{NoGate: true, Limit: 10}); err != nil {
					b.Fatal(err)
				}
			}
		})
		held := &Vectors{}
		if _, err := Meaning(ctx, st, q, "anything", Options{NoGate: true, Limit: 10, Vectors: held}); err != nil {
			b.Fatal(err)
		}
		b.Run(fmt.Sprintf("pieces=%d/held-in-memory", n), func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				if _, err := Meaning(ctx, st, q, "anything", Options{NoGate: true, Limit: 10, Vectors: held}); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}
