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
)

// Modes lists the modes Search accepts.
var Modes = []string{ModeKeyword, ModeMeaning}

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
	default:
		return nil, fmt.Errorf("%w %q (one of: %s)", ErrUnknownMode, opt.Mode, strings.Join(Modes, ", "))
	}
}

// The gate: a piece counts as a match when its cosine reaches DefaultMinCosine
// or its z reaches DefaultMinZ. Below both it is only the nearest thing in an
// archive that has nothing on the subject, and it is not returned.
//
// DECISION: the two values come from the eval of 2026-11-10 (33 queries, 7 of
// which should find nothing; 1,393 pieces). The nearest piece to a query the
// archive has nothing on reached cosine 0.649 to 0.724 and z 2.95 to 3.59; the
// right first hit for a query it does answer had cosine 0.707 to 0.883 and z
// 3.68 to 9.38. With "cosine ≥ 0.73 or z ≥ 3.6" none of the 7 gets an answer
// and R@1 (0.65) and R@5 (0.77) are unchanged; R@10 goes from 0.81 to 0.77
// (one right turn sat in eighth place below the gate). Either test alone
// costs more: the cosine floor alone leaves 2 answerable queries with no hit,
// the z gate alone 3.
//
// REVIEW: the margins are thin (0.724 against 0.73, 3.59 against 3.6) and
// seven queries drew the line, so these are provisional: more "nothing"
// queries should move them before anything else does. And z is not stable as
// an archive grows: the largest of n unrelated scores rises with n (about
// √(2 ln n) standard deviations for a bell curve: 3.8 at 1,400 pieces, 5.0 at
// 225,000), so a fixed MinZ lets more noise through in a larger archive. The
// cosine floor does not have that problem and is the one to trust long-term.
const (
	DefaultMinCosine = 0.73
	DefaultMinZ      = 3.6
)

// Meaning ranks segments by the cosine between the query's vector and the
// vector of their closest piece. Every piece is scored (brute force: at this
// scale that is milliseconds, and it makes the whole distribution available),
// so each hit also carries z: how many standard deviations its cosine stands
// above the mean of all pieces for this query. The mean and deviation are
// taken over the whole index even when the search is narrowed to a session or
// a kind, so z means the same thing however small the part searched. Pieces
// below the gate are left out unless opt.NoGate is set.
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

	// Every piece is read, so the score distribution is the whole index's;
	// the narrowing options only decide which pieces may be hits.
	conds, args, err := opt.filter()
	if err != nil {
		return nil, err
	}
	keep := "1"
	if len(conds) > 0 {
		keep = "(" + strings.Join(conds, " AND ") + ")"
	}
	// TODO: skit serve should keep the decoded vectors in memory between
	// queries; reading and decoding them each time is fine for thousands of
	// pieces and will not be for hundreds of thousands.
	rows, err := st.DB().QueryContext(ctx, `SELECT c.segment, c.start, c.len, v.vec, `+keep+`
		FROM chunks c JOIN vectors v ON v.hash = c.hash JOIN segments g ON g.id = c.segment JOIN sessions s ON s.id = g.session`, args...)
	if err != nil {
		return nil, err
	}
	type piece struct {
		segment    int64
		start, len int
		cos        float64
	}
	best := map[int64]piece{}
	var n int
	var sum, sumSq float64
	vec := make([]float32, len(qvec))
	for rows.Next() {
		var p piece
		var blob []byte
		var wanted bool
		if err := rows.Scan(&p.segment, &p.start, &p.len, &blob, &wanted); err != nil {
			rows.Close()
			return nil, err
		}
		if err := embed.Unpack(vec, blob); err != nil {
			rows.Close()
			return nil, err
		}
		p.cos = float64(embed.Dot(qvec, vec))
		n++
		sum += p.cos
		sumSq += p.cos * p.cos
		if !wanted {
			continue
		}
		if b, ok := best[p.segment]; !ok || p.cos > b.cos {
			best[p.segment] = p
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if n == 0 {
		return nil, nil
	}
	mean := sum / float64(n)
	std := math.Sqrt(math.Max(sumSq/float64(n)-mean*mean, 0))

	minCos, minZ := opt.MinCosine, opt.MinZ
	if minCos == 0 {
		minCos = DefaultMinCosine
	}
	if minZ == 0 {
		minZ = DefaultMinZ
	}
	zOf := func(cos float64) float64 {
		if std == 0 {
			return 0
		}
		return (cos - mean) / std
	}
	ranked := make([]piece, 0, len(best))
	for _, p := range best {
		if opt.NoGate || p.cos >= minCos || zOf(p.cos) >= minZ {
			ranked = append(ranked, p)
		}
	}
	sort.Slice(ranked, func(i, j int) bool {
		if ranked[i].cos != ranked[j].cos {
			return ranked[i].cos > ranked[j].cos
		}
		return ranked[i].segment < ranked[j].segment
	})
	if len(ranked) > opt.Limit {
		ranked = ranked[:opt.Limit]
	}

	terms := Terms(query)
	hits := make([]Hit, 0, len(ranked))
	for _, p := range ranked {
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
		h.Match = ModeMeaning
		h.Snippet = excerpt(string(text), 160)
		if len(terms) > 0 {
			h.Coverage = coverage(terms, string(text))
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
