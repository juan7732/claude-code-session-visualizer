// Package search finds segments by words. FTS5 with bm25 supplies candidates;
// the final score adds how many of the query's words each segment contains,
// and a query made of ids or codes ("E1234", "toolu_01…") weighs words more.
// Meaning (vectors) joins in v0.5 with DigUp's z-scaled fusion.
package search

import (
	"database/sql"
	"fmt"
	"math"
	"sort"
	"strings"
	"time"
	"unicode"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/store"
)

// Hit is one matching segment.
type Hit struct {
	Session  string    `json:"session"`
	Project  string    `json:"project"`
	Title    string    `json:"title"`
	Agent    string    `json:"agent,omitempty"`
	Turn     int       `json:"turn"`   // agent turn, -1 for session-level pieces
	Action   int       `json:"action"` // action within the session, -1 for prompts and summaries
	Kind     string    `json:"kind"`
	Tool     string    `json:"tool,omitempty"`
	At       time.Time `json:"at"`
	Snippet  string    `json:"snippet"`
	Coverage float64   `json:"coverage"`
	Score    float64   `json:"score"`
}

// Options narrow a search.
type Options struct {
	Limit      int
	Project    string // substring of the project slug
	Session    string // exact session id
	Kind       string // prompt | assistant | thinking | tool_use | tool_result | context | summary
	PrefixLast bool   // the last word is still being typed
}

var stopwords = map[string]bool{
	"a": true, "an": true, "the": true, "of": true, "in": true, "on": true, "at": true, "to": true, "for": true, "with": true,
	"and": true, "or": true, "my": true, "me": true, "that": true, "this": true, "these": true, "those": true, "from": true,
	"about": true, "where": true, "what": true, "which": true, "who": true, "when": true, "is": true, "was": true, "are": true,
	"were": true, "be": true, "it": true, "its": true, "some": true, "any": true, "find": true, "show": true, "did": true,
	"we": true, "i": true, "you": true, "do": true, "session": true, "sessions": true,
}

// Terms are the content words of a query: lowercased, split on anything that
// is not a letter or digit, stopwords and single characters dropped.
func Terms(q string) []string {
	seen := map[string]bool{}
	var out []string
	for _, w := range strings.FieldsFunc(strings.ToLower(q), func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) }) {
		if len([]rune(w)) < 2 || stopwords[w] || seen[w] {
			continue
		}
		seen[w] = true
		out = append(out, w)
	}
	return out
}

// IsLookup is true when every term looks like an identifier (has a digit and
// either a letter or four or more characters): ids, error codes, versions.
func IsLookup(terms []string) bool {
	if len(terms) == 0 {
		return false
	}
	for _, t := range terms {
		hasDigit, hasLetter := false, false
		for _, r := range t {
			hasDigit = hasDigit || unicode.IsDigit(r)
			hasLetter = hasLetter || unicode.IsLetter(r)
		}
		if !hasDigit || !(hasLetter || len(t) >= 4) {
			return false
		}
	}
	return true
}

// FTSQuery renders terms as an FTS5 OR query of quoted words, the last one as a
// prefix when prefixLast is set.
func FTSQuery(terms []string, prefixLast bool) string {
	parts := make([]string, len(terms))
	for i, t := range terms {
		parts[i] = `"` + strings.ReplaceAll(t, `"`, `""`) + `"`
		if prefixLast && i == len(terms)-1 {
			parts[i] += "*"
		}
	}
	return strings.Join(parts, " OR ")
}

// Run searches the index.
func Run(st *store.Store, query string, opt Options) ([]Hit, error) {
	terms := Terms(query)
	if len(terms) == 0 {
		return nil, fmt.Errorf("nothing to search for in %q", query)
	}
	if opt.Limit <= 0 {
		opt.Limit = 20
	}
	where := []string{"fts MATCH ?"}
	args := []any{FTSQuery(terms, opt.PrefixLast)}
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
	q := `SELECT g.session, s.project, s.title, g.agent, g.turn, g.action, g.kind, g.tool, g.at, g.text,
	             snippet(fts, 0, '«', '»', '…', 14), bm25(fts)
	      FROM fts JOIN segments g ON g.id = fts.rowid JOIN sessions s ON s.id = g.session
	      WHERE ` + strings.Join(where, " AND ") + ` ORDER BY bm25(fts) LIMIT 1000`
	rows, err := st.DB().Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	lookup := IsLookup(terms)
	wordWeight := 2.0
	if lookup {
		wordWeight = 4.0
	}
	var hits []Hit
	best := 0.0
	for rows.Next() {
		var h Hit
		var at sql.NullString
		var text string
		var bm float64
		if err := rows.Scan(&h.Session, &h.Project, &h.Title, &h.Agent, &h.Turn, &h.Action, &h.Kind, &h.Tool, &at, &text, &h.Snippet, &bm); err != nil {
			return nil, err
		}
		if at.Valid {
			h.At, _ = time.Parse(time.RFC3339Nano, at.String)
		}
		h.Coverage = coverage(terms, text)
		if len(terms) > 1 && h.Coverage < 0.5 {
			continue // one common word is not a match
		}
		h.Score = -bm // bm25 is negative, more negative is better
		if h.Score > best {
			best = h.Score
		}
		hits = append(hits, h)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for i := range hits {
		rel := 0.0
		if best > 0 {
			rel = hits[i].Score / best
		}
		hits[i].Score = rel + wordWeight*math.Pow(hits[i].Coverage, 1.5)
	}
	sort.SliceStable(hits, func(i, j int) bool { return hits[i].Score > hits[j].Score })
	if len(hits) > opt.Limit {
		hits = hits[:opt.Limit]
	}
	return hits, nil
}

// coverage is the share of terms found in text (prefix match on word starts,
// so "grok" counts for "grokking" as the porter stemmer would).
func coverage(terms []string, text string) float64 {
	words := strings.FieldsFunc(strings.ToLower(text), func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) })
	found := 0
	for _, t := range terms {
		for _, w := range words {
			if w == t || strings.HasPrefix(w, t) {
				found++
				break
			}
		}
	}
	return float64(found) / float64(len(terms))
}
