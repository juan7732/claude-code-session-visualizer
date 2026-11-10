// Package search finds segments, by words or by meaning.
//
// By words (Run): FTS5 with bm25 supplies candidates; the final score adds how
// many of the query's words each segment contains, and a query made of ids or
// codes ("E1234", "toolu_01…") weighs words more.
//
// By meaning (Meaning, in meaning.go): the query and every piece of prose in
// the index have a vector; the nearest pieces win, shared words or not.
//
// Evaluate (eval.go) measures either against queries with known answers, which
// is how a scoring change is judged.
package search

import (
	"database/sql"
	"errors"
	"fmt"
	"math"
	"slices"
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
	Coverage float64   `json:"coverage"` // share of the query's words found in the text
	Score    float64   `json:"score"`    // what the hits are ordered by; comparable within one result only
	// Match says why the hit is here: "keyword" (it has the words) or "meaning"
	// (its text is close to the query's).
	Match string `json:"match"`
	// Cosine and Z are set on meaning hits: the similarity of the closest piece
	// of the segment, and how many standard deviations that stands above the
	// mean over every piece scored for this query. The snippet is that piece.
	Cosine float64 `json:"cosine,omitempty"`
	Z      float64 `json:"z,omitempty"`
}

// Options narrow a search.
type Options struct {
	Mode       string // keyword (default) | meaning; see Search
	Limit      int
	Project    string   // substring of the project slug
	Session    string   // exact session id
	Kinds      []string // only these kinds (see Kinds); empty means every kind
	Kind       string   // one more kind for Kinds; kept for callers that pass a single one
	NoTools    bool     // leave out tool calls and their results
	PrefixLast bool     // the last word is still being typed

	// The gate of meaning search (see Meaning). Zero means the default.
	MinCosine float64
	MinZ      float64
	// NoGate returns the nearest pieces however far they are.
	NoGate bool
}

// Kinds are the kinds of segment a search can be narrowed to.
var Kinds = []string{"prompt", "assistant", "thinking", "tool_use", "tool_result", "context", "summary"}

// ErrUnknownKind: a kind filter names no kind.
var ErrUnknownKind = errors.New("unknown kind")

// filter renders the narrowing options as SQL conditions over segments g and
// sessions s. It is the same for both modes.
func (opt Options) filter() (conds []string, args []any, err error) {
	if opt.Session != "" {
		conds = append(conds, "g.session = ?")
		args = append(args, opt.Session)
	}
	if opt.Project != "" {
		conds = append(conds, "instr(lower(s.project), lower(?)) > 0")
		args = append(args, opt.Project)
	}
	kinds := opt.Kinds
	if opt.Kind != "" {
		kinds = append(append([]string{}, kinds...), opt.Kind)
	}
	for _, k := range kinds {
		if !slices.Contains(Kinds, k) {
			return nil, nil, fmt.Errorf("%w %q (one of: %s)", ErrUnknownKind, k, strings.Join(Kinds, ", "))
		}
	}
	if len(kinds) > 0 {
		conds = append(conds, "g.kind IN (?"+strings.Repeat(",?", len(kinds)-1)+")")
		for _, k := range kinds {
			args = append(args, k)
		}
	}
	if opt.NoTools {
		conds = append(conds, "g.kind NOT IN ('tool_use', 'tool_result')")
	}
	return conds, args, nil
}

// stopwords are words a query can hold without being about them. Search takes
// a question as it is typed ("how did we figure out ..."), and without this
// list every "how" and "out" in a tool result counts as a match.
//
// DECISION: the list is the common English function words (the NLTK set:
// articles, pronouns, prepositions, auxiliaries, question words), plus four
// words that in this tool mean "search" and not a subject: find, show,
// session, sessions. It was not picked by looking at the eval's queries.
// Measured on the 33-query eval of 2026-11-10, keyword mode: R@1 0.42 → 0.58,
// MRR 0.51 → 0.64, R@10 unchanged at 0.81 (docs/meaning-search.md).
var stopwords = wordSet(`
	a an the and but if or because as until while of at by for with about against between into through during
	before after above below to from up down in out on off over under again further then once here there when where
	why how all any both each few more most other some such no nor not only own same so than too very
	i me my myself we our ours ourselves you your yours yourself yourselves he him his himself she her hers
	herself it its itself they them their theirs themselves what which who whom this that these those
	am is are was were be been being have has had having do does did doing can will just don should now
	ve ll re
	find show session sessions`)

func wordSet(words string) map[string]bool {
	set := map[string]bool{}
	for _, w := range strings.Fields(words) {
		set[w] = true
	}
	return set
}

// Terms are what a query is searched for: its content words, lowercased, with
// stopwords and single characters dropped. A word split on anything that is
// not a letter or digit gives several terms ("retention-sweep" is two), with
// one exception: a version, a date or a numbered name ("0.5.1", "2026-11-10",
// "issue-3") stays one term, its parts separated by spaces, and is searched
// as a phrase. Split, its digits would be dropped as single characters or
// matched one by one wherever a 5 or a 2026 appears.
func Terms(q string) []string {
	seen := map[string]bool{}
	var out []string
	add := func(t string) {
		if !seen[t] {
			seen[t] = true
			out = append(out, t)
		}
	}
	for _, raw := range strings.Fields(strings.ToLower(q)) {
		parts := strings.FieldsFunc(raw, notWordRune)
		if isNumbered(parts) {
			add(strings.Join(parts, " "))
			continue
		}
		for _, w := range parts {
			if len([]rune(w)) < 2 || stopwords[w] {
				continue
			}
			add(w)
		}
	}
	return out
}

func notWordRune(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) }

// isNumbered reports whether the parts of one written word belong together:
// there are several, and at least one is a number or a single character next
// to a number ("0.5.1", "v0.6.0", "gemma-embedding-2", "3.5"). Parts that are
// all words ("co-authored-by") and ids with a letter in every part
// ("toolu_01abc") are left to be searched part by part.
func isNumbered(parts []string) bool {
	if len(parts) < 2 {
		return false
	}
	anyDigit, joins := false, false
	for _, p := range parts {
		digits := 0
		for _, r := range p {
			if unicode.IsDigit(r) {
				digits++
			}
		}
		anyDigit = anyDigit || digits > 0
		joins = joins || digits == len([]rune(p)) || len([]rune(p)) == 1
	}
	return anyDigit && joins
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
// prefix when prefixLast is set. A term with spaces in it (see Terms) is an
// FTS5 phrase: its parts must follow one another.
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

// ErrEmptyQuery: the query has no word to look for (it is empty, or made of
// words like "the" and "where" that keyword search ignores).
var ErrEmptyQuery = errors.New("nothing to search for")

// Run searches the index by words.
func Run(st *store.Store, query string, opt Options) ([]Hit, error) {
	terms := Terms(query)
	if len(terms) == 0 {
		return nil, fmt.Errorf("%w in %q", ErrEmptyQuery, query)
	}
	if opt.Limit <= 0 {
		opt.Limit = 20
	}
	conds, condArgs, err := opt.filter()
	if err != nil {
		return nil, err
	}
	where := append([]string{"fts MATCH ?"}, conds...)
	args := append([]any{FTSQuery(terms, opt.PrefixLast)}, condArgs...)
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
		h.Match = ModeKeyword
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
// so "grok" counts for "grokking" as the porter stemmer would). A term of
// several parts counts when the parts follow one another.
func coverage(terms []string, text string) float64 {
	words := strings.FieldsFunc(strings.ToLower(text), notWordRune)
	found := 0
	for _, t := range terms {
		if strings.Contains(t, " ") {
			if hasPhrase(words, strings.Fields(t)) {
				found++
			}
			continue
		}
		for _, w := range words {
			if w == t || strings.HasPrefix(w, t) {
				found++
				break
			}
		}
	}
	return float64(found) / float64(len(terms))
}

func hasPhrase(words, parts []string) bool {
	for i := 0; i+len(parts) <= len(words); i++ {
		match := true
		for k, p := range parts {
			if words[i+k] != p {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}
