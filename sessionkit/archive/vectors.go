package archive

import (
	"context"
	"time"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/embed"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/store"
)

// Embedder is what the archive needs to give text a vector: package embed's
// Embedder, over a llama-server sidecar.
type Embedder interface {
	// Source names the model and settings; vectors from two sources never mix.
	Source() string
	// Documents returns one unit vector per text.
	Documents(ctx context.Context, texts []string) ([][]float32, error)
}

// EmbedKinds are the segment kinds that get vectors: what a person or the
// model wrote in sentences.
//
// DECISION: tool calls, tool results and injected context are left to keyword
// search for now. They are JSON, command output and repeated boilerplate, they
// are two thirds of all segments, and what people look for in them (a path, an
// id, an error string) is what FTS already finds. The eval decides whether to
// widen this; a kind added here is picked up by the next Embed.
var EmbedKinds = []string{"prompt", "assistant", "thinking", "summary"}

// EmbedResult says what Embed did.
type EmbedResult struct {
	Source   string  `json:"source"`
	Cut      int     `json:"segments_cut"`     // segments cut into chunks in this run
	Embedded int     `json:"embedded"`         // texts given a vector in this run
	Dropped  int     `json:"dropped"`          // vectors discarded because another source made them
	Pruned   int     `json:"pruned"`           // vectors discarded because no text uses them any more
	Seconds  float64 `json:"embed_seconds"`    // time spent embedding
	PerSec   float64 `json:"texts_per_second"` // 0 when nothing was embedded
	store.VectorCounts
}

// chunkBatch and embedBatch bound one transaction and one round of requests.
const (
	chunkBatch = 500
	embedBatch = 256
)

// Chunk cuts every segment that should have vectors and has not been cut yet.
// It needs no model. It returns how many segments it cut.
func (a *Archive) Chunk(ctx context.Context) (int, error) {
	cut := 0
	for {
		if err := ctx.Err(); err != nil {
			return cut, err
		}
		segs, err := a.Store.UnchunkedSegments(EmbedKinds, chunkBatch)
		if err != nil {
			return cut, err
		}
		if len(segs) == 0 {
			return cut, nil
		}
		ids := make([]int64, len(segs))
		var chunks []store.Chunk
		for i, g := range segs {
			ids[i] = g.ID
			for ord, p := range embed.Chunks(g.Text, embed.MaxChunkRunes) {
				chunks = append(chunks, store.Chunk{Segment: g.ID, Ord: ord, Start: p.Start, Len: p.Len, Hash: store.ChunkHash(g.Text[p.Start : p.Start+p.Len])})
			}
		}
		if err := a.Store.PutChunks(ids, chunks); err != nil {
			return cut, err
		}
		cut += len(segs)
	}
}

// EmbedPending cuts what is not cut and reports how many distinct texts have
// no vector made by source yet. It needs no model, so a caller can ask before
// deciding to start one. When the stored vectors come from another source,
// every text is pending.
func (a *Archive) EmbedPending(ctx context.Context, source string) (int, error) {
	if _, err := a.Chunk(ctx); err != nil {
		return 0, err
	}
	c, err := a.Store.VectorCounts()
	if err != nil {
		return 0, err
	}
	if c.Source != "" && c.Source != source {
		return c.Texts, nil
	}
	return c.Texts - c.Vectors, nil
}

// Embed brings the vectors up to date with the segments: it cuts what is not
// cut, embeds every distinct text that has no vector, and drops vectors
// nothing uses. It is safe to stop and run again; each batch is kept as it
// lands. progress, when set, is called with the texts embedded so far and the
// number this run set out to embed.
//
// It does not hold the archive lock: an ingest may replace a session's
// segments meanwhile. Vectors are keyed by text, so whatever that session
// still says keeps its vector, and the next Embed covers what is new.
func (a *Archive) Embed(ctx context.Context, e Embedder, progress func(done, total int)) (EmbedResult, error) {
	res := EmbedResult{Source: e.Source()}
	var err error
	if res.Dropped, err = a.Store.UseVectorSource(res.Source); err != nil {
		return res, err
	}
	if res.Cut, err = a.Chunk(ctx); err != nil {
		return res, err
	}
	before, err := a.Store.VectorCounts()
	if err != nil {
		return res, err
	}
	total := before.Texts - before.Vectors
	started := time.Now()
	for {
		if err = ctx.Err(); err != nil {
			break
		}
		var batch []store.ChunkText
		if batch, err = a.Store.ChunksWithoutVector(embedBatch); err != nil || len(batch) == 0 {
			break
		}
		texts := make([]string, len(batch))
		hashes := make([][]byte, len(batch))
		for i, c := range batch {
			texts[i], hashes[i] = c.Text, c.Hash
		}
		var vecs [][]float32
		if vecs, err = e.Documents(ctx, texts); err != nil {
			break
		}
		packed := make([][]byte, len(vecs))
		for i, v := range vecs {
			packed[i] = embed.Pack(v)
		}
		if err = a.Store.PutVectors(hashes, packed); err != nil {
			break
		}
		res.Embedded += len(batch)
		if progress != nil {
			progress(res.Embedded, max(total, res.Embedded))
		}
	}
	if res.Embedded > 0 {
		res.Seconds = time.Since(started).Seconds()
		res.PerSec = float64(res.Embedded) / res.Seconds
	}
	if err == nil {
		res.Pruned, err = a.Store.PruneVectors()
	}
	if err == nil {
		err = a.Store.MarkEmbedded(time.Now())
	}
	// The counts are reported even when the run stopped early: what landed is kept.
	if counts, cerr := a.Store.VectorCounts(); cerr == nil {
		res.VectorCounts = counts
	}
	return res, err
}
