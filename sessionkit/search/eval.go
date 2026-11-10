package search

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/store"
)

// An eval is a list of queries with the turns they should find. Running it
// against a mode says how often the right turn comes first, in the first five
// and in the first ten. It is how a scoring change is judged (design
// principle "Measure before you tune"): the same file before and after.
//
//	{"queries": [
//	  {"q": "why does my history vanish after a month", "expect": ["bbbbbbbb@0"], "tag": "paraphrase"},
//	  {"q": "ENOTFOUND", "expect": ["bbbbbbbb@4"], "tag": "lookup"},
//	  {"q": "a recipe for dinner", "expect": [], "tag": "nothing"}
//	]}
//
// A target is a session id (or a unique prefix of one), optionally followed by
// @N for an agent turn of the main transcript or @A-B for any turn in a range.
// Without @, any hit in the session counts. A query that expects nothing is
// there to measure the opposite: whether search can say it found nothing.
//
// "exclude" lists sessions (id prefixes) whose hits are left out before
// anything is counted. The sessions in which the queries were written belong
// there: they quote every query word for word, so they would come first for
// each one and "answer" the queries that should find nothing.

// EvalFile is the parsed query file.
type EvalFile struct {
	// Exclude holds session id prefixes whose hits do not count.
	Exclude []string    `json:"exclude,omitempty"`
	Queries []EvalQuery `json:"queries"`
}

// EvalQuery is one query and where its answer is.
type EvalQuery struct {
	Q      string   `json:"q"`
	Expect []string `json:"expect"`
	Tag    string   `json:"tag,omitempty"`
	// Note is for whoever maintains the file (why this target, who wrote the
	// query). It plays no part in the scores.
	Note string `json:"note,omitempty"`
}

// evalTarget is a parsed, resolved expectation.
type evalTarget struct {
	session string // full id
	anyTurn bool
	lo, hi  int
}

// Eval is a query file checked against an index and ready to run.
type Eval struct {
	File    EvalFile
	targets [][]evalTarget // per query
}

// LoadEval reads a query file and resolves every target against the index, so
// a typo or a session that is not archived fails here and not as a silent
// zero in the scores.
func LoadEval(st *store.Store, data []byte) (*Eval, error) {
	ev := &Eval{}
	dec := json.NewDecoder(strings.NewReader(string(data)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&ev.File); err != nil {
		return nil, fmt.Errorf("eval file: %w", err)
	}
	if len(ev.File.Queries) == 0 {
		return nil, errors.New("eval file has no queries")
	}
	for _, x := range ev.File.Exclude {
		if strings.TrimSpace(x) == "" {
			return nil, errors.New("eval file: an empty entry in \"exclude\" would leave out every session")
		}
	}
	ev.targets = make([][]evalTarget, len(ev.File.Queries))
	for i, q := range ev.File.Queries {
		if strings.TrimSpace(q.Q) == "" {
			return nil, fmt.Errorf("eval query %d has no text", i+1)
		}
		for _, raw := range q.Expect {
			t, err := resolveTarget(st, raw)
			if err != nil {
				return nil, fmt.Errorf("eval query %d (%q): %w", i+1, q.Q, err)
			}
			if ev.excluded(t.session) {
				return nil, fmt.Errorf("eval query %d (%q): target %q is in an excluded session", i+1, q.Q, raw)
			}
			ev.targets[i] = append(ev.targets[i], t)
		}
	}
	return ev, nil
}

// excluded reports whether a session's hits are left out of the eval. An
// excluded prefix that matches no archived session is not an error: the
// session may simply not be archived on this machine.
func (ev *Eval) excluded(session string) bool {
	for _, x := range ev.File.Exclude {
		if strings.HasPrefix(session, x) {
			return true
		}
	}
	return false
}

func resolveTarget(st *store.Store, raw string) (evalTarget, error) {
	t := evalTarget{anyTurn: true}
	id, turns, hasTurn := strings.Cut(strings.TrimSpace(raw), "@")
	if hasTurn {
		t.anyTurn = false
		lo, hi, isRange := strings.Cut(turns, "-")
		var err error
		if t.lo, err = strconv.Atoi(lo); err != nil || t.lo < 0 {
			return t, fmt.Errorf("target %q: the turn after @ must be a number", raw)
		}
		t.hi = t.lo
		if isRange {
			if t.hi, err = strconv.Atoi(hi); err != nil || t.hi < t.lo {
				return t, fmt.Errorf("target %q: the turn range must be A-B with B not below A", raw)
			}
		}
	}
	if id == "" {
		return t, fmt.Errorf("target %q has no session id", raw)
	}
	rows, err := st.SessionsByPrefix(id)
	if err != nil {
		return t, err
	}
	switch len(rows) {
	case 0:
		return t, fmt.Errorf("target %q: no archived session starts with %q", raw, id)
	case 1:
		t.session = rows[0].ID
		return t, nil
	default:
		return t, fmt.Errorf("target %q: %d sessions start with %q, use more of the id", raw, len(rows), id)
	}
}

func (t evalTarget) matches(h Hit) bool {
	if h.Session != t.session {
		return false
	}
	if t.anyTurn {
		return true
	}
	// Turn numbers belong to the main transcript; a subagent's turns are its own.
	return h.Agent == "" && h.Turn >= t.lo && h.Turn <= t.hi
}

// EvalReport is the outcome of an eval.
type EvalReport struct {
	Queries int        `json:"queries"`
	Depth   int        `json:"depth"` // places looked at per query
	Modes   []EvalMode `json:"modes"`
}

// EvalMode is how one mode did.
type EvalMode struct {
	Mode    string      `json:"mode"`
	Overall EvalScore   `json:"overall"`
	Tags    []EvalScore `json:"tags,omitempty"`
	// Nothing covers the queries that expect no answer.
	Nothing  EvalNothing   `json:"nothing_expected"`
	Outcomes []EvalOutcome `json:"outcomes"`
}

// EvalScore is recall and reciprocal rank over the queries that expect an answer.
type EvalScore struct {
	Tag string  `json:"tag"`
	N   int     `json:"n"`
	R1  float64 `json:"recall_at_1"`
	R5  float64 `json:"recall_at_5"`
	R10 float64 `json:"recall_at_10"`
	MRR float64 `json:"mrr"`
}

// EvalNothing counts the queries with no expected answer that got one anyway.
type EvalNothing struct {
	N        int `json:"n"`
	Answered int `json:"answered"` // returned at least one hit
}

// EvalOutcome is one query's result in one mode.
type EvalOutcome struct {
	Q      string   `json:"q"`
	Tag    string   `json:"tag,omitempty"`
	Expect []string `json:"expect"`
	// Rank is the place of the first expected turn among the distinct turns
	// returned, 1 for first; 0 when it is not in the places looked at.
	Rank int `json:"rank"`
	Hits int `json:"hits"`
	// Top describes the first hit, whatever it was.
	Top       string  `json:"top,omitempty"`
	TopScore  float64 `json:"top_score,omitempty"`
	TopCosine float64 `json:"top_cosine,omitempty"`
	TopZ      float64 `json:"top_z,omitempty"`
}

// evalDepth is how far down the results an eval looks.
const evalDepth = 10

// Run puts every query through search in each mode and scores where the
// expected turns land. search is the function under test: the faces pass
// Search with their embedder.
func (ev *Eval) Run(ctx context.Context, modes []string, search func(ctx context.Context, query string, opt Options) ([]Hit, error)) (EvalReport, error) {
	rep := EvalReport{Queries: len(ev.File.Queries), Depth: evalDepth}
	for _, mode := range modes {
		em := EvalMode{Mode: mode}
		for i, q := range ev.File.Queries {
			// Several segments of one turn can each be a hit. Ask for enough
			// that ten distinct turns are in there, and for more when some
			// sessions' hits will be dropped.
			limit := 5 * evalDepth
			if len(ev.File.Exclude) > 0 {
				limit *= 4
			}
			hits, err := search(ctx, q.Q, Options{Mode: mode, Limit: limit})
			if errors.Is(err, ErrEmptyQuery) {
				hits, err = nil, nil // a query of nothing but stopwords finds nothing by words; that is a result
			}
			if err != nil {
				return rep, fmt.Errorf("%s search for %q: %w", mode, q.Q, err)
			}
			if len(ev.File.Exclude) > 0 {
				kept := hits[:0:0]
				for _, h := range hits {
					if !ev.excluded(h.Session) {
						kept = append(kept, h)
					}
				}
				hits = kept
			}
			out := EvalOutcome{Q: q.Q, Tag: q.Tag, Expect: q.Expect, Hits: len(hits)}
			if out.Expect == nil {
				out.Expect = []string{}
			}
			if len(hits) > 0 {
				h := hits[0]
				out.Top = fmt.Sprintf("%s@%d %s", short(h.Session), h.Turn, h.Kind)
				out.TopScore, out.TopCosine, out.TopZ = h.Score, h.Cosine, h.Z
			}
			out.Rank = rankOf(hits, ev.targets[i])
			em.Outcomes = append(em.Outcomes, out)
		}
		em.Overall, em.Tags, em.Nothing = score(em.Outcomes)
		rep.Modes = append(rep.Modes, em)
	}
	return rep, nil
}

// rankOf is the best place any target reaches. A target with a turn is ranked
// among distinct turns, a session-only target among distinct sessions: five
// hits from one turn above the right one put it second, not sixth.
func rankOf(hits []Hit, targets []evalTarget) int {
	best := 0
	for _, t := range targets {
		seen := map[string]bool{}
		place := 0
		for _, h := range hits {
			key := h.Session
			if !t.anyTurn {
				key = fmt.Sprintf("%s\x00%s\x00%d", h.Session, h.Agent, h.Turn)
			}
			if seen[key] {
				continue
			}
			seen[key] = true
			place++
			if place > evalDepth {
				break
			}
			if t.matches(h) {
				if best == 0 || place < best {
					best = place
				}
				break
			}
		}
	}
	return best
}

func score(outcomes []EvalOutcome) (overall EvalScore, tags []EvalScore, nothing EvalNothing) {
	byTag := map[string]*EvalScore{}
	overall.Tag = "all"
	add := func(s *EvalScore, rank int) {
		s.N++
		if rank >= 1 {
			s.MRR += 1 / float64(rank)
			if rank == 1 {
				s.R1++
			}
			if rank <= 5 {
				s.R5++
			}
			if rank <= 10 {
				s.R10++
			}
		}
	}
	for _, o := range outcomes {
		if len(o.Expect) == 0 {
			nothing.N++
			if o.Hits > 0 {
				nothing.Answered++
			}
			continue
		}
		add(&overall, o.Rank)
		if o.Tag != "" {
			if byTag[o.Tag] == nil {
				byTag[o.Tag] = &EvalScore{Tag: o.Tag}
			}
			add(byTag[o.Tag], o.Rank)
		}
	}
	finish := func(s *EvalScore) {
		if s.N > 0 {
			n := float64(s.N)
			s.R1, s.R5, s.R10, s.MRR = s.R1/n, s.R5/n, s.R10/n, s.MRR/n
		}
	}
	finish(&overall)
	for _, s := range byTag {
		finish(s)
		tags = append(tags, *s)
	}
	sort.Slice(tags, func(i, j int) bool { return tags[i].Tag < tags[j].Tag })
	return overall, tags, nothing
}

func short(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}
