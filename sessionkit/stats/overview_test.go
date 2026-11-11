package stats

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// TestSummaryCarriesWhatOverviewAddsUp: activity by hour, actions per prompt
// and the time split are in the summary, so the index can answer for a session
// without reading it again.
func TestSummaryCarriesWhatOverviewAddsUp(t *testing.T) {
	s := load(t, "synthetic-basics", "aaaaaaaa-0000-0000-0000-000000000001.jsonl")
	sum := Compute(s, "-Users-xxxx-work", Options{})
	// Everything in the fixture happens between 10:00 and 10:02 UTC: one hour.
	if len(sum.Activity) != 1 || !sum.Activity[0].Hour.Equal(time.Date(2026, 11, 8, 10, 0, 0, 0, time.UTC)) {
		t.Fatalf("activity = %+v", sum.Activity)
	}
	h := sum.Activity[0]
	// The hour holds what the totals hold: every request and tool call, subagents included, and no synthetic message.
	if h.Actions != sum.Requests || h.ToolCalls != sum.ToolCalls || h.ToolErrors != sum.ToolErrors || h.OutputTokens != sum.Usage.OutputTokens {
		t.Fatalf("the one hour %+v should equal the totals: requests %d, tool calls %d, errors %d, output %d", h, sum.Requests, sum.ToolCalls, sum.ToolErrors, sum.Usage.OutputTokens)
	}
	// Turn 0 started four actions; turn 1 one, and a message Claude Code wrote itself.
	if len(sum.Shape) != 2 || sum.Shape[0] != 4 {
		t.Fatalf("shape = %v", sum.Shape)
	}
	if sum.Time == nil || sum.Time.Wall != 64 || !near(sum.Time.Wall, sum.Time.ForYou+sum.Time.ForBackground+sum.Time.Seconds) {
		t.Fatalf("time = %+v", sum.Time)
	}
}

func TestOverallAddsSessionsUp(t *testing.T) {
	cost := 1.5
	utc := func(day, hour int) time.Time { return time.Date(2026, 11, day, hour, 0, 0, 0, time.UTC) }
	a := Summary{ID: "a", Project: "-p-one", Cwd: "/p/one", LastAt: utc(8, 12), Turns: 3, Requests: 10, ToolCalls: 7, ToolErrors: 1, Subagents: 1,
		ClaudeCodeCostUSD: &cost, Tools: []ToolCount{{"Bash", 6, 1}, {"Read", 1, 0}}, Models: []Count{{"m1", 10}},
		Activity: []HourActivity{{Hour: utc(7, 23), Actions: 4, ToolCalls: 3}, {Hour: utc(8, 1), Actions: 6, ToolCalls: 4, ToolErrors: 1}},
		Time:     &TimeTotals{Wall: 100, ForYou: 60, Split: Split{Seconds: 40, Model: 30, Tools: 10}}}
	a.Usage.OutputTokens, a.Usage.InputTokens, a.Usage.CacheReadInputTokens = 500, 100, 900
	b := Summary{ID: "b", Project: "-p-two", Cwd: "/p/two", LastAt: utc(9, 9), Turns: 1, Requests: 2, ToolCalls: 2,
		Tools: []ToolCount{{"Bash", 2, 0}}, Models: []Count{{"m2", 2}}, Activity: []HourActivity{{Hour: utc(8, 1), Actions: 2, ToolCalls: 2}}}
	old := Summary{ID: "c", Project: "-p-two", Requests: 5} // indexed before activity was kept

	o := Overall([]Summary{a, b, old}, time.UTC)
	if o.Sessions != 3 || o.Totals.Actions != 17 || o.Totals.ToolCalls != 9 || o.Totals.ToolErrors != 1 || o.Totals.OutputTokens != 500 {
		t.Fatalf("totals = %+v", o.Totals)
	}
	if o.Totals.CostUSD != 1.5 || o.Totals.CostSessions != 1 {
		t.Fatalf("cost is summed over the sessions that have one: %+v", o.Totals)
	}
	// Projects by actions; the directory is the latest session's.
	if len(o.Projects) != 2 || o.Projects[0].Project != "-p-one" || o.Projects[0].Actions != 10 || o.Projects[1].Sessions != 2 || o.Projects[1].Cwd != "/p/two" {
		t.Fatalf("projects = %+v", o.Projects)
	}
	// Two days in UTC; the second is shared by both sessions.
	if len(o.Days) != 2 || o.Days[0].Day != "2026-11-07" || o.Days[0].Actions != 4 || o.Days[1].Actions != 8 || len(o.Days[1].Sessions) != 2 {
		t.Fatalf("days = %+v", o.Days)
	}
	if o.Tools[0].Name != "Bash" || o.Tools[0].Calls != 8 || o.Tools[0].Errors != 1 || o.Models[0].Name != "m1" {
		t.Fatalf("tools = %+v models = %+v", o.Tools, o.Models)
	}
	if o.CacheHitRatio != 0.9 || o.CacheRead != 900 || o.Time.Wall != 100 || o.Time.Model != 30 || o.WithoutActivity != 1 {
		t.Fatalf("cache %v read %d time %+v without activity %d", o.CacheHitRatio, o.CacheRead, o.Time, o.WithoutActivity)
	}

	// The same hours are other days in another zone: 23:00 and 01:00 UTC are both the 7th in New York.
	ny, err := time.LoadLocation("America/New_York")
	if err != nil {
		t.Skip("no time zone database here")
	}
	west := Overall([]Summary{a}, ny)
	if len(west.Days) != 1 || west.Days[0].Day != "2026-11-07" || west.Days[0].Actions != 10 || west.Timezone != "America/New_York" {
		t.Fatalf("days in New York = %+v", west.Days)
	}
}

func TestOverallOfNothingHasEmptyLists(t *testing.T) {
	b, _ := json.Marshal(Overall(nil, time.UTC))
	for _, want := range []string{`"projects":[]`, `"days":[]`, `"tools":[]`, `"models":[]`, `"sessions":0`} {
		if !strings.Contains(string(b), want) {
			t.Fatalf("an empty overview lacks %s: %s", want, b)
		}
	}
}
