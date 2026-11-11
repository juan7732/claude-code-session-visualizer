package search

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/embed"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/store"
)

// Modes of search.
const (
	// ModeKeyword finds the query's words (FTS5; see Run). The default.
	ModeKeyword = "keyword"
	// ModeMeaning ranks text by how close it is to the query in meaning,
	// whether or not they share a word (vectors; see Meaning).
	ModeMeaning = "meaning"
	// ModeHybrid puts what is close in meaning first and what has the words
	// after it (see Hybrid).
	ModeHybrid = "hybrid"
)

// Modes lists the modes Search accepts.
var Modes = []string{ModeKeyword, ModeMeaning, ModeHybrid}

// QueryEmbedder turns a query into a vector: package embed's Embedder.
type QueryEmbedder interface {
	Source() string
	Query(ctx context.Context, text string) ([]float32, error)
}

// ErrUnknownMode: opt.Mode names no mode.
var ErrUnknownMode = errors.New("unknown search mode")

// Why meaning search cannot answer. The faces turn these into advice.
var (
	// ErrNoEmbedder: this process has no model to embed the query with.
	ErrNoEmbedder = errors.New("meaning search is not set up")
	// ErrNoVectors: nothing in the index has a vector yet.
	ErrNoVectors = errors.New("the index has no vectors yet")
	// ErrStaleVectors: the index's vectors were made by another model or
	// framing than the one that would embed the query; the two cannot be compared.
	ErrStaleVectors = errors.New("the index's vectors were made by another model")
)

// Search runs a query in the mode opt.Mode names (keyword when empty). e may
// be nil for keyword search.
func Search(ctx context.Context, st *store.Store, e QueryEmbedder, query string, opt Options) ([]Hit, error) {
	switch opt.Mode {
	case "", ModeKeyword:
		return Run(st, query, opt)
	case ModeMeaning:
		return Meaning(ctx, st, e, query, opt)
	case ModeHybrid:
		return Hybrid(ctx, st, e, query, opt)
	default:
		return nil, fmt.Errorf("%w %q (one of: %s)", ErrUnknownMode, opt.Mode, strings.Join(Modes, ", "))
	}
}

// The gate: a piece counts as a match when its cosine reaches DefaultMinCosine.
// Below that it is only the nearest thing in an archive that has nothing on
// the subject, and it is not returned.
//
// DECISION: 0.73, from the eval of 2026-11-10 (53 queries: 26 with an answer,
// 19 about subjects the archive has nothing on, 8 near misses; about 1,400
// pieces). No query written in sentences about an absent subject has a piece
// at or above it (the nearest reach 0.724), and the right first hit of an
// answerable query is at 0.745 or more, with one exception: a query that is
// only a name ("denelon", 0.707), which keyword search finds first.
//
// A first version also let a piece through on z ≥ 3.6. Twenty new "nothing"
// queries showed that test to be the leak: "mortgage refinance rate" has
// cosine 0.65 and z 3.69. z rises with the size of the archive (the largest of
// n unrelated scores is about √(2 ln n) standard deviations up), so no fixed
// value holds. MinZ remains as an option for experiments and is off.
//
// DECISION: a query that is only an id, a version or a code ("v3.2.1",
// "JIRA-4821") matches a piece only when the piece contains it. An id has no
// meaning to be near: "v3.2.1" sits at cosine 0.76 from a turn about 0.5.1.
//
// REVIEW: a threshold cannot tell a near miss from an answer. "How did we
// fine-tune the embedding model on my own sessions?" (never done) scores 0.775
// against a turn about measuring it, above several right answers. The vector
// says "same subject", not "answers this". 6 of the 8 near misses in the eval
// get hits, and that is left as it is: the hits are related, and telling them
// apart needs a model that reads query and passage together (a reranker).
const DefaultMinCosine = 0.73

// Meaning ranks segments by the cosine between the query's vector and the
// vector of their closest piece. Every piece is scored (brute force: at this
// scale that is milliseconds, and it makes the whole distribution available),
// so each hit also carries z: how many standard deviations its cosine stands
// above the mean of all pieces for this query. The mean and deviation are
// taken over the whole index even when the search is narrowed to a session or
// a kind, so z means the same thing however small the part searched. Pieces
// that do not pass the gate are left out unless opt.NoGate is set.
//
// REVIEW: it does not look at words at all. Fusing it with keyword scores is
// the next step (docs/plan-v0.md, M14).
func Meaning(ctx context.Context, st *store.Store, e QueryEmbedder, query string, opt Options) ([]Hit, error) {
	if strings.TrimSpace(query) == "" {
		return nil, fmt.Errorf("%w in %q", ErrEmptyQuery, query)
	}
	if e == nil {
		return nil, ErrNoEmbedder
	}
	if opt.Limit <= 0 {
		opt.Limit = 20
	}
	have, err := st.VectorSource()
	if err != nil {
		return nil, err
	}
	if have == "" {
		return nil, ErrNoVectors
	}
	if have != e.Source() {
		return nil, fmt.Errorf("%w (%s)", ErrStaleVectors, have)
	}
	qvec, err := e.Query(ctx, query)
	if err != nil {
		return nil, err
	}

	// Every piece is scored, so the score distribution is the whole index's;
	// the narrowing options only decide which pieces may be hits.
	if _, _, err := opt.filter(); err != nil {
		return nil, err // an unknown kind
	}
	var all *pieces
	if opt.Vectors != nil {
		all, err = opt.Vectors.get(ctx, st)
	} else {
		all, err = loadPieces(ctx, st)
	}
	if err != nil {
		return nil, err
	}
	type piece struct {
		segment    int64
		start, len int
		cos        float64
	}
	best := map[int64]piece{}
	n := len(all.rows)
	var sum, sumSq float64
	wanted, lastInfo := false, int32(-1)
	for i, r := range all.rows {
		cos := float64(embed.DotPacked(qvec, all.vec(i)))
		sum += cos
		sumSq += cos * cos
		if r.info != lastInfo {
			wanted, lastInfo = opt.keeps(all.segs[r.info]), r.info
		}
		if !wanted {
			continue
		}
		if b, ok := best[r.segment]; !ok || cos > b.cos {
			best[r.segment] = piece{segment: r.segment, start: int(r.start), len: int(r.len), cos: cos}
		}
	}
	if n == 0 {
		return nil, nil
	}
	mean := sum / float64(n)
	std := math.Sqrt(math.Max(sumSq/float64(n)-mean*mean, 0))

	minCos := opt.MinCosine
	if minCos == 0 {
		minCos = DefaultMinCosine
	}
	zOf := func(cos float64) float64 {
		if std == 0 {
			return 0
		}
		return (cos - mean) / std
	}
	ranked := make([]piece, 0, len(best))
	for _, p := range best {
		if opt.NoGate || p.cos >= minCos || (opt.MinZ > 0 && zOf(p.cos) >= opt.MinZ) {
			ranked = append(ranked, p)
		}
	}
	sort.Slice(ranked, func(i, j int) bool {
		if ranked[i].cos != ranked[j].cos {
			return ranked[i].cos > ranked[j].cos
		}
		return ranked[i].segment < ranked[j].segment
	})

	terms := Terms(query)
	// An id is matched by its characters, not by its neighbours (see the gate).
	mustContain := !opt.NoGate && IsLookup(terms)
	hits := make([]Hit, 0, min(len(ranked), opt.Limit))
	for _, p := range ranked {
		if len(hits) == opt.Limit {
			break
		}
		var h Hit
		var at sql.NullString
		var text []byte
		err := st.DB().QueryRowContext(ctx, `SELECT g.session, s.project, s.title, g.agent, g.turn, g.action, g.kind, g.tool, g.at,
			substr(CAST(g.text AS BLOB), ?, ?) FROM segments g JOIN sessions s ON s.id = g.session WHERE g.id = ?`, p.start+1, p.len, p.segment).
			Scan(&h.Session, &h.Project, &h.Title, &h.Agent, &h.Turn, &h.Action, &h.Kind, &h.Tool, &at, &text)
		if errors.Is(err, sql.ErrNoRows) {
			continue // the session was re-indexed between the two reads
		}
		if err != nil {
			return nil, err
		}
		if at.Valid {
			h.At, _ = time.Parse(time.RFC3339Nano, at.String)
		}
		h.seg = p.segment
		h.Match = ModeMeaning
		h.Snippet = excerpt(string(text), 160)
		if len(terms) > 0 {
			h.Coverage = coverage(terms, string(text))
		}
		if mustContain && h.Coverage == 0 {
			continue
		}
		h.Cosine = round4(p.cos)
		h.Z = round4(zOf(p.cos))
		h.Score = h.Cosine
		hits = append(hits, h)
	}
	return hits, nil
}

func round4(x float64) float64 { return math.Round(x*1e4) / 1e4 }

// excerpt is the start of a piece on one line, cut at a word when it is longer
// than max runes.
func excerpt(text string, max int) string {
	text = strings.Join(strings.Fields(text), " ")
	if utf8.RuneCountInString(text) <= max {
		return text
	}
	cut := string([]rune(text)[:max])
	if i := strings.LastIndexByte(cut, ' '); i > max/2 {
		cut = cut[:i]
	}
	return cut + "…"
}
