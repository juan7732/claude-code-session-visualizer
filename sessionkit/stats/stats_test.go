package stats

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/transcript"
)

func TestComputeRollsSubagentsIn(t *testing.T) {
	s, err := transcript.Load(filepath.Join("..", "..", "internal", "testdata", "sessions", "synthetic-basics", "aaaaaaaa-0000-0000-0000-000000000001.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	sum := Compute(s, "-Users-xxxx-work", Options{Context: true})
	if sum.Requests != 7 { // 5 parent (one synthetic turn excluded) + 2 subagent
		t.Fatalf("requests = %d", sum.Requests)
	}
	if sum.ToolCalls != 5 || sum.Usage.OutputTokens != 236 { // parent 230 + subagent 6
		t.Fatalf("tool calls %d, output tokens %d", sum.ToolCalls, sum.Usage.OutputTokens)
	}
	if len(sum.Models) != 2 || sum.Models[0].Name != "claude-fable-5-1" {
		t.Fatalf("models = %+v", sum.Models)
	}
	if sum.Tools[0].Name != "Bash" || sum.Tools[0].Calls != 2 {
		t.Fatalf("tools = %+v", sum.Tools)
	}
	if sum.ClaudeCodeCostUSD == nil || *sum.ClaudeCodeCostUSD != 0.42 || sum.Compactions != 1 || len(sum.Context) != 5 {
		t.Fatalf("cost=%v compactions=%d context=%d", sum.ClaudeCodeCostUSD, sum.Compactions, len(sum.Context))
	}
	if sum.Context[0].Tokens != 6002 {
		t.Fatalf("context of first request = %d, want input+cache_creation+cache_read", sum.Context[0].Tokens)
	}
	if sum.Turns != 2 || sum.SystemTurns != 0 || sum.Context[0].Turn != 0 {
		t.Fatalf("turns=%d system=%d first context point turn=%d", sum.Turns, sum.SystemTurns, sum.Context[0].Turn)
	}
	if sum.Title != "Synthetic basics" || len(sum.Cwds) != 2 {
		t.Fatalf("title=%q cwds=%v", sum.Title, sum.Cwds)
	}
}

func TestFormatters(t *testing.T) {
	cases := map[time.Duration]string{42 * time.Second: "42s", 7*time.Minute + 3*time.Second: "7m 03s", 2*time.Hour + 14*time.Minute: "2h 14m", 74 * time.Hour: "3d 2h"}
	for d, want := range cases {
		if got := FormatDuration(d); got != want {
			t.Errorf("FormatDuration(%v) = %q, want %q", d, got, want)
		}
	}
	tok := map[int]string{950: "950", 12_300: "12.3k", 4_600_000: "4.6M", 249_262: "249k", 1_000: "1k"}
	for n, want := range tok {
		if got := FormatTokens(n); got != want {
			t.Errorf("FormatTokens(%d) = %q, want %q", n, got, want)
		}
	}
}
