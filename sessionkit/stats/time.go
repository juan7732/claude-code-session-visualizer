package stats

import (
	"math"
	"sort"
	"time"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/transcript"
)

// Time says where a session's wall time went. Everything is in seconds and the
// parts add up: Wall = ForYou + ForBackground + InTurns.Seconds, and a Split's
// Seconds = Model + Tools + Subagents + Waiting.
type Time struct {
	ID      string    `json:"id"`
	Title   string    `json:"title"`
	FirstAt time.Time `json:"first_at"`
	LastAt  time.Time `json:"last_at"`
	// Wall is the session from its first record to its last.
	Wall float64 `json:"wall_seconds"`
	// ForYou is the time outside turns before a prompt of the human's: the
	// session waited for them.
	ForYou float64 `json:"waiting_for_you_seconds"`
	// ForBackground is the time outside turns before a turn something else
	// started (a task notification): the session waited on background work.
	ForBackground float64 `json:"waiting_for_background_seconds"`
	InTurns       Split   `json:"in_turns"`

	Turns        []TurnTime `json:"turns"`
	SlowestCalls []SlowCall `json:"slowest_calls"`
	LongestWaits []Wait     `json:"longest_waits"`
}

// Split divides time spent inside turns.
type Split struct {
	Seconds float64 `json:"seconds"`
	// Model: waiting for the model's response, its thinking and its writing.
	Model float64 `json:"model_seconds"`
	// Tools: tool calls running, subagents left out. A call that waited for
	// the human's permission counts here: a transcript does not record the wait.
	Tools float64 `json:"tools_seconds"`
	// Subagents: tool calls that ran a subagent and waited for it.
	Subagents float64 `json:"subagents_seconds"`
	// Waiting: after the agent spoke and before something brought it back
	// inside the same turn: a subagent's hand-back or a notification.
	Waiting float64 `json:"waiting_seconds"`
}

func (s *Split) add(o Split) {
	s.Seconds += o.Seconds
	s.Model += o.Model
	s.Tools += o.Tools
	s.Subagents += o.Subagents
	s.Waiting += o.Waiting
}

// TurnTime is one turn's share.
type TurnTime struct {
	Turn    int       `json:"turn"`
	Origin  string    `json:"origin"`
	At      time.Time `json:"at"`
	End     time.Time `json:"end"`
	Actions int       `json:"actions"`
	Split
}

// SlowCall is a tool call and how long it ran.
type SlowCall struct {
	transcript.CallRef
	Name     string  `json:"name"`
	Summary  string  `json:"summary,omitempty"`
	Seconds  float64 `json:"seconds"`
	Subagent bool    `json:"subagent,omitempty"`
	IsError  bool    `json:"is_error,omitempty"`
}

// Wait is a stretch between two turns.
type Wait struct {
	AfterTurn  int       `json:"after_turn"`
	BeforeTurn int       `json:"before_turn"`
	At         time.Time `json:"at"`
	End        time.Time `json:"end"`
	Seconds    float64   `json:"seconds"`
	// For is "you" before a prompt of the human's, "background" otherwise.
	For string `json:"for"`
}

// TimeOf accounts for a session's wall time from its turns and action spans.
// top bounds the two rankings; 0 means 10.
//
// DECISION: the split is the engine's, not a client's. It is arithmetic over
// spans, but it carries judgments (what counts as the model's time, what a gap
// before a notification means) that every face must make the same way.
func TimeOf(s *transcript.Session, rel *transcript.Relations, top int) Time {
	if top <= 0 {
		top = 10
	}
	out := Time{ID: s.ID, Title: s.DisplayTitle(), FirstAt: s.FirstAt, LastAt: s.LastAt,
		Turns: []TurnTime{}, SlowestCalls: []SlowCall{}, LongestWaits: []Wait{}}
	spans := map[int][]transcript.ActionSpan{}
	for _, sp := range rel.Spans {
		spans[sp.Turn] = append(spans[sp.Turn], sp)
	}
	calls := map[int][]*transcript.ToolCall{}
	for _, c := range s.ToolCalls {
		calls[c.Action] = append(calls[c.Action], c)
	}

	var inTurns, forBackground time.Duration
	for i, t := range s.Turns {
		tt := TurnTime{Turn: t.Index, Origin: t.Origin, At: t.StartAt, End: t.EndAt, Actions: len(t.Actions)}
		total := t.Duration()
		var model, tools, subs, waiting time.Duration
		cursor := t.StartAt
		for _, sp := range spans[t.Index] {
			model += positive(sp.GenEnd.Sub(cursor))
			ran := positive(sp.ToolsEnd.Sub(sp.GenEnd))
			sub := subagentTime(calls[sp.Action], sp.GenEnd, sp.ToolsEnd)
			subs += sub
			tools += ran - sub
			cursor = later(cursor, sp.ToolsEnd)
			if sp.Said {
				waiting += positive(sp.End.Sub(cursor))
				cursor = later(cursor, sp.End)
			}
		}
		// What is left after the last action is the model's: it was answering
		// when the turn ended (interrupted, or the last record came a moment later).
		model += positive(t.EndAt.Sub(cursor))
		// Clocks in a transcript are not perfectly ordered. Keep the parts
		// equal to the whole by letting the model's share absorb the difference.
		if diff := total - (model + tools + subs + waiting); diff != 0 {
			model = positive(model + diff)
		}
		tt.Split = Split{Seconds: secs(total), Model: secs(model), Tools: secs(tools), Subagents: secs(subs), Waiting: secs(waiting)}
		out.Turns = append(out.Turns, tt)
		out.InTurns.add(tt.Split)
		inTurns += total

		if i > 0 {
			prev := s.Turns[i-1]
			if gap := t.StartAt.Sub(prev.EndAt); gap > 0 {
				w := Wait{AfterTurn: prev.Index, BeforeTurn: t.Index, At: prev.EndAt, End: t.StartAt, Seconds: secs(gap), For: "you"}
				if t.Origin != "human" {
					w.For = "background"
					forBackground += gap
				}
				out.LongestWaits = append(out.LongestWaits, w)
			}
		}
	}
	out.InTurns = roundSplit(out.InTurns)
	wall := s.Duration()
	out.Wall = secs(wall)
	out.ForBackground = secs(forBackground)
	out.ForYou = secs(positive(wall - inTurns - forBackground))

	sort.SliceStable(out.LongestWaits, func(i, j int) bool { return out.LongestWaits[i].Seconds > out.LongestWaits[j].Seconds })
	if len(out.LongestWaits) > top {
		out.LongestWaits = out.LongestWaits[:top]
	}

	for _, c := range s.ToolCalls {
		if c.EndedAt.IsZero() || !c.EndedAt.After(c.At) {
			continue
		}
		out.SlowestCalls = append(out.SlowestCalls, SlowCall{CallRef: transcript.CallRef{ToolID: c.ID, Action: c.Action, Turn: c.Turn, At: c.At},
			Name: c.Name, Summary: transcript.ToolSummary(c.Name, c.Input), Seconds: secs(c.EndedAt.Sub(c.At)), Subagent: c.Subagent != nil, IsError: c.IsError})
	}
	sort.SliceStable(out.SlowestCalls, func(i, j int) bool { return out.SlowestCalls[i].Seconds > out.SlowestCalls[j].Seconds })
	if len(out.SlowestCalls) > top {
		out.SlowestCalls = out.SlowestCalls[:top]
	}
	return out
}

// subagentTime is how much of [from, to] was covered by calls that ran a
// subagent. Calls of one action run side by side, so their stretches are merged.
func subagentTime(calls []*transcript.ToolCall, from, to time.Time) time.Duration {
	type stretch struct{ a, b time.Time }
	var ss []stretch
	for _, c := range calls {
		if c.Subagent == nil || c.EndedAt.IsZero() {
			continue
		}
		a, b := later(c.At, from), c.EndedAt
		if b.After(to) {
			b = to
		}
		if b.After(a) {
			ss = append(ss, stretch{a, b})
		}
	}
	sort.Slice(ss, func(i, j int) bool { return ss[i].a.Before(ss[j].a) })
	var total time.Duration
	var end time.Time
	for _, x := range ss {
		if x.a.After(end) {
			total += x.b.Sub(x.a)
			end = x.b
		} else if x.b.After(end) {
			total += x.b.Sub(end)
			end = x.b
		}
	}
	return total
}

func positive(d time.Duration) time.Duration {
	if d < 0 {
		return 0
	}
	return d
}

func later(a, b time.Time) time.Time {
	if b.After(a) {
		return b
	}
	return a
}

// secs is a duration in seconds, to the millisecond a transcript records.
func secs(d time.Duration) float64 { return math.Round(d.Seconds()*1000) / 1000 }

func roundSplit(s Split) Split {
	r := func(f float64) float64 { return math.Round(f*1000) / 1000 }
	return Split{Seconds: r(s.Seconds), Model: r(s.Model), Tools: r(s.Tools), Subagents: r(s.Subagents), Waiting: r(s.Waiting)}
}
