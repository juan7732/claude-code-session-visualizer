package search

import (
	"context"
	"errors"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/store"
)

// MatchBoth marks a hybrid hit that is close in meaning and has the words.
const MatchBoth = "both"

// Hybrid answers with both searches: first the segments that pass meaning
// search's gate, nearest first, then the keyword hits that are not among them,
// in keyword order. A segment found both ways is listed once, in its place
// among the meaning hits, marked "both", with the keyword snippet (the one
// that shows the words) and the cosine beside it.
//
// DECISION: one list after the other, not a blend of scores. The eval of
// 2026-11-10 (53 queries, 26 with answers) against keyword search alone:
//
//	keyword                         R@1 0.62  R@5 0.77  R@10 0.85  MRR 0.68
//	meaning first, then keyword     R@1 0.69  R@5 0.81  R@10 0.88  MRR 0.75
//	reciprocal-rank fusion (k=60)   R@1 0.62  R@5 0.77  R@10 0.92  MRR 0.69
//	weighted sum of the two scores  R@1 0.62 to 0.65, MRR 0.68 to 0.71 over a grid of weights
//
// The reason it works is the gate: what passes it is short (a median of four
// segments a query) and usually right, so it can go first whole; the keyword
// list is long and catches what meaning cannot reach (a name, an id, text
// inside tool output). It is also the rule a person can predict.
//
// REVIEW: hybrid can no more say "nothing found" than keyword can: when no
// passage is close in meaning, the keyword hits are all there is, and for a
// question on a subject the archive lacks they are tool output that shares a
// few common words (14 of 19 such queries get hits). A face can tell: no hit
// is marked "meaning" or "both". Weighting matched words by how rare they are
// was tried and cut those to 9 of 19 at the cost of right answers; not kept.
func Hybrid(ctx context.Context, st *store.Store, e QueryEmbedder, query string, opt Options) ([]Hit, error) {
	if opt.Limit <= 0 {
		opt.Limit = 20
	}
	near, err := Meaning(ctx, st, e, query, opt)
	if err != nil {
		return nil, err
	}
	// Enough keyword hits that the list is full even if the first ones are
	// already there as meaning hits.
	wordOpt := opt
	wordOpt.Limit = opt.Limit + len(near)
	words, err := Run(st, query, wordOpt)
	if errors.Is(err, ErrEmptyQuery) {
		// A question made of words keyword search ignores ("what is it that
		// they were doing") still has a meaning.
		words, err = nil, nil
	}
	if err != nil {
		return nil, err
	}

	bySeg := make(map[int64]*Hit, len(words))
	top := 0.0
	for i := range words {
		bySeg[words[i].seg] = &words[i]
		top = max(top, words[i].Score)
	}
	hits := make([]Hit, 0, opt.Limit)
	listed := make(map[int64]bool, len(near))
	for _, h := range near {
		if len(hits) == opt.Limit {
			break
		}
		if k := bySeg[h.seg]; k != nil {
			h.Match = MatchBoth
			h.Snippet = k.Snippet
		}
		// Scores only order one result: meaning's tier sits above keyword's.
		h.Score = 1 + h.Cosine
		listed[h.seg] = true
		hits = append(hits, h)
	}
	for _, h := range words {
		if len(hits) == opt.Limit {
			break
		}
		if listed[h.seg] {
			continue
		}
		h.Score = h.Score / (top + 1)
		hits = append(hits, h)
	}
	return hits, nil
}
