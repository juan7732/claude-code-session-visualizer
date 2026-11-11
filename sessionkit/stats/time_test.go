package stats

import (
	"encoding/json"
	"math"
	"path/filepath"
	"strings"
	"testing"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/transcript"
)

func load(t *testing.T, dir, file string) *transcript.Session {
	t.Helper()
	s, err := transcript.Load(filepath.Join("..", "..", "internal", "testdata", "sessions", dir, file))
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func near(a, b float64) bool { return math.Abs(a-b) < 0.002 }

// TestTimeOfSyntheticBasics pins the split on the fixture whose clock is known:
// turn 0 runs 10:00:00 to 10:00:09.5 with four actions, turn 1 starts a minute in.
func TestTimeOfSyntheticBasics(t *testing.T) {
	s := load(t, "synthetic-basics", "aaaaaaaa-0000-0000-0000-000000000001.jsonl")
	tm := TimeOf(s, s.Relations(), 0)
	// Turn 1 spoke at 10:01:03 and a message of Claude Code's own followed half a second later:
	// no hand-back arrived, so that half second is the human's, not the turn's.
	if tm.Wall != 64 || tm.ForYou != 51.5 || tm.ForBackground != 0 || tm.InTurns.Seconds != 12.5 {
		t.Fatalf("wall %v = for you %v + background %v + in turns %v", tm.Wall, tm.ForYou, tm.ForBackground, tm.InTurns.Seconds)
	}
	// The model's share includes the two seconds before the first action's first block.
	in := tm.InTurns
	if !near(in.Model, 10.5) || !near(in.Tools, 1.8) || !near(in.Subagents, 0.2) || in.Waiting != 0 || !near(tm.Turns[1].ForYou, 0.5) {
		t.Fatalf("in turns = %+v", in)
	}
	if len(tm.Turns) != 2 || tm.Turns[0].Actions != 4 || !near(tm.Turns[0].Model, 7.5) || !near(tm.Turns[0].Seconds, 9.5) {
		t.Fatalf("turns = %+v", tm.Turns)
	}
	if len(tm.SlowestCalls) != 4 || tm.SlowestCalls[0].Name != "Bash" || !near(tm.SlowestCalls[0].Seconds, 0.8) || tm.SlowestCalls[0].Summary == "" {
		t.Fatalf("slowest calls = %+v", tm.SlowestCalls)
	}
	if last := tm.SlowestCalls[3]; last.Name != "Agent" || !last.Subagent {
		t.Fatalf("the subagent's call is marked: %+v", last)
	}
	// The wait between the turns, then the half second inside turn 1.
	if len(tm.LongestWaits) != 2 || tm.LongestWaits[0].For != "you" || !near(tm.LongestWaits[0].Seconds, 50.5) || tm.LongestWaits[0].BeforeTurn != 1 || tm.LongestWaits[1].AfterTurn != 1 {
		t.Fatalf("waits = %+v", tm.LongestWaits)
	}
	if top := TimeOf(s, s.Relations(), 2); len(top.SlowestCalls) != 2 {
		t.Fatalf("top 2 lists two calls, got %d", len(top.SlowestCalls))
	}
}

// TestTimeAddsUp: on a real session's shape (subagents, background tasks,
// notification turns) the parts equal the whole, turn by turn and in total.
func TestTimeAddsUp(t *testing.T) {
	s := load(t, "bootstrap-session", "36086585-e295-4279-a0c2-ef7b1901e080.jsonl")
	rel := s.Relations()
	tm := TimeOf(s, rel, 5)
	for _, sp := range rel.Spans {
		if sp.Start.IsZero() || sp.Start.After(sp.At) || sp.At.After(sp.GenEnd) || sp.GenEnd.After(sp.ToolsEnd) {
			t.Fatalf("span %d is out of order: %+v", sp.Action, sp)
		}
		if sp.Said && !sp.GenEnd.Equal(sp.At) {
			t.Fatalf("span %d spoke: it wrote until its block, the rest is waiting: %+v", sp.Action, sp)
		}
	}
	if !near(tm.Wall, tm.ForYou+tm.ForBackground+tm.InTurns.Seconds) {
		t.Fatalf("wall %v != %v + %v + %v", tm.Wall, tm.ForYou, tm.ForBackground, tm.InTurns.Seconds)
	}
	var sum float64
	for _, x := range tm.Turns {
		if !near(x.Seconds, x.Model+x.Tools+x.Subagents+x.Waiting) || x.ForYou < 0 {
			t.Fatalf("turn %d does not add up: %+v", x.Turn, x)
		}
		if x.Model < 0 || x.Tools < 0 || x.Subagents < 0 || x.Waiting < 0 {
			t.Fatalf("turn %d has a negative share: %+v", x.Turn, x)
		}
		sum += x.Seconds
	}
	if math.Abs(sum-tm.InTurns.Seconds) > 0.05 {
		t.Fatalf("turns sum to %v, in turns says %v", sum, tm.InTurns.Seconds)
	}
	if tm.InTurns.Subagents <= 0 {
		t.Fatalf("the session ran subagents in the foreground: %+v", tm.InTurns)
	}
	if len(tm.SlowestCalls) != 5 || tm.SlowestCalls[0].Seconds < tm.SlowestCalls[4].Seconds {
		t.Fatalf("slowest first, five of them: %+v", tm.SlowestCalls)
	}
	hasBackground := false
	for _, turn := range s.Turns {
		hasBackground = hasBackground || turn.Origin != "human"
	}
	if hasBackground && tm.ForBackground <= 0 {
		t.Fatalf("a turn a notification started waited on background work: %+v", tm)
	}
}

// TestTimeOfEmptySession: no turns, and still lists.
func TestTimeOfEmptySession(t *testing.T) {
	s, err := transcript.Parse(strings.NewReader(`{"type":"queue-operation","sessionId":"e","timestamp":"2026-11-08T10:00:00Z"}` + "\n"))
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(TimeOf(s, s.Relations(), 0))
	for _, want := range []string{`"turns":[]`, `"slowest_calls":[]`, `"longest_waits":[]`, `"wall_seconds":0`} {
		if !strings.Contains(string(b), want) {
			t.Fatalf("an empty session lacks %s: %s", want, b)
		}
	}
}
