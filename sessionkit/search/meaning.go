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

// Meaning ranks segments by the cosine between the query's vector and the
// vector of their closest piece. Every piece is scored (brute force: at this
// scale that is milliseconds, and it makes the whole distribution available),
// so each hit also carries z: how many standard deviations its cosine stands
// above the mean of all pieces for this query.
//
// REVIEW: this is the plain form. It always returns the nearest pieces, even
// for a query nothing in the archive is about, and it does not look at words
// at all. The gate that lets it say "nothing found" and the fusion with
// keyword scores are tuned on the eval (docs/plan-v0.md, M14), not guessed here.
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

	where := []string{"1"}
	var args []any
	if opt.Session != "" {
		where = append(where, "g.session = ?")
		args = append(args, opt.Session)
	}
	if opt.Project != "" {
		where = append(where, "instr(lower(s.project), lower(?)) > 0")
		args = append(args, opt.Project)
	}
	if opt.Kind != "" {
		where = append(where, "g.kind = ?")
		args = append(args, opt.Kind)
	}
	// TODO: skit serve should keep the decoded vectors in memory between
	// queries; reading and decoding them each time is fine for thousands of
	// pieces and will not be for hundreds of thousands.
	rows, err := st.DB().QueryContext(ctx, `SELECT c.segment, c.start, c.len, v.vec
		FROM chunks c JOIN vectors v ON v.hash = c.hash JOIN segments g ON g.id = c.segment JOIN sessions s ON s.id = g.session
		WHERE `+strings.Join(where, " AND "), args...)
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
		if err := rows.Scan(&p.segment, &p.start, &p.len, &blob); err != nil {
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

	ranked := make([]piece, 0, len(best))
	for _, p := range best {
		ranked = append(ranked, p)
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
		if std > 0 {
			h.Z = round4((p.cos - mean) / std)
		}
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
