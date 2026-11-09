//go:build integration

package integration

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/juan7732/claude-code-session-visualizer/test/integration/harness"
)

func TestList_ShowsSeededSession(t *testing.T) {
	t.Parallel()
	h := harness.New(t)
	id := h.SeedFixture("synthetic-basics", "-Users-me-work")

	res := h.Run("list")
	res.AssertOK(t)
	if !strings.Contains(res.Stdout, id[:8]) || !strings.Contains(res.Stdout, "Synthetic basics") {
		t.Fatalf("list output:\n%s", res.Stdout)
	}

	res = h.Run("list", "--json")
	res.AssertOK(t)
	var rows []struct {
		ID       string   `json:"id"`
		Requests int      `json:"requests"`
		Cost     *float64 `json:"claude_code_cost_usd"`
	}
	if err := json.Unmarshal([]byte(res.Stdout), &rows); err != nil {
		t.Fatalf("not JSON: %v\n%s", err, res.Stdout)
	}
	if len(rows) != 1 || rows[0].ID != id || rows[0].Requests != 7 || rows[0].Cost == nil || *rows[0].Cost != 0.42 {
		t.Fatalf("rows = %+v", rows)
	}

	res = h.Run("list", "--project", "nomatch", "--json")
	res.AssertOK(t)
	if strings.TrimSpace(res.Stdout) != "[]" {
		t.Fatalf("filtered list should be an empty JSON array: %q", res.Stdout)
	}
}

func TestShow_TimelineAndTurn(t *testing.T) {
	t.Parallel()
	h := harness.New(t)
	id := h.SeedFixture("synthetic-basics", "-Users-me-work")

	res := h.Run("show", id[:8])
	res.AssertOK(t)
	for _, want := range []string{"Session  " + id, "turn 0", "action 0", "⚙ Bash", "⚙ Agent", "→ subagent a1b2c3d4e5f607182", "compaction 0 (auto): 6.4k → 900 tokens", "api_error", "/Users/xxxx/work/sub", "↳ end", "turn 1"} {
		if !strings.Contains(res.Stdout, want) {
			t.Errorf("timeline lacks %q:\n%s", want, res.Stdout)
		}
	}

	res = h.Run("show", id, "--action", "3")
	res.AssertOK(t)
	if !strings.Contains(res.Stdout, "tool_use Edit") || !strings.Contains(res.Stdout, "full output from") || !strings.Contains(res.Stdout, "full output line 1") {
		t.Fatalf("action view should show the Edit call and its spilled result:\n%s", res.Stdout)
	}
	res = h.Run("show", id, "--turn", "0")
	res.AssertOK(t)
	if !strings.Contains(res.Stdout, "Turn 0") || !strings.Contains(res.Stdout, "══ human ══") || !strings.Contains(res.Stdout, "action 3") || !strings.Contains(res.Stdout, "💭 thinking") {
		t.Fatalf("turn view should print the prompt and every action with thinking:\n%s", res.Stdout)
	}
	res = h.Run("show", id, "--thinking")
	res.AssertOK(t)
	if !strings.Contains(res.Stdout, "💭") {
		t.Fatalf("--thinking should add thinking lines:\n%s", res.Stdout)
	}

	res = h.Run("show", id, "--json")
	res.AssertOK(t)
	var doc struct {
		ID      string `json:"id"`
		Turns   []any  `json:"turns"`
		Actions []any  `json:"actions"`
		Summary struct {
			Requests int `json:"requests"`
		} `json:"summary"`
	}
	if err := json.Unmarshal([]byte(res.Stdout), &doc); err != nil || doc.ID != id || len(doc.Turns) != 2 || len(doc.Actions) != 6 || doc.Summary.Requests != 7 {
		t.Fatalf("show --json: %v id=%s turns=%d actions=%d summary=%+v", err, doc.ID, len(doc.Turns), len(doc.Actions), doc.Summary)
	}
	if strings.Contains(res.Stdout, "iVBORw0KGgo=") {
		t.Fatal("show --json must strip inline image bytes")
	}
}

func TestStats_HumanAndJSON(t *testing.T) {
	t.Parallel()
	h := harness.New(t)
	id := h.SeedFixture("synthetic-basics", "-Users-me-work")

	res := h.Run("stats", id, "--context")
	res.AssertOK(t)
	for _, want := range []string{"Tokens (once per action, subagents included)", "claude-haiku-5-5", "Bash", "Compactions", "Context window per action", "$0.42"} {
		if !strings.Contains(res.Stdout, want) {
			t.Errorf("stats lacks %q:\n%s", want, res.Stdout)
		}
	}
	res = h.Run("stats", id, "--json")
	res.AssertOK(t)
	var sum struct {
		Usage struct {
			Output int `json:"output_tokens"`
		} `json:"usage"`
		Context []any `json:"context"`
	}
	if err := json.Unmarshal([]byte(res.Stdout), &sum); err != nil || sum.Usage.Output != 236 || len(sum.Context) != 5 {
		t.Fatalf("stats --json: %v %+v", err, sum)
	}
}

func TestShow_UnknownSessionIsJSONError(t *testing.T) {
	t.Parallel()
	h := harness.New(t)
	res := h.Run("show", "deadbeef", "--json")
	if res.ExitCode == 0 || !strings.Contains(res.Stderr, `"error"`) {
		t.Fatalf("expected JSON error, got exit %d stderr %q", res.ExitCode, res.Stderr)
	}
}

func TestShow_ContextAndSynthetic(t *testing.T) {
	t.Parallel()
	h := harness.New(t)
	id := h.SeedFixture("synthetic-basics", "-Users-me-work")

	res := h.Run("show", id)
	res.AssertOK(t)
	if strings.Contains(res.Stdout, "ide_opened_file") || !strings.Contains(res.Stdout, "1 injected blocks in prompts · 3 attachments   (--context to show them)") {
		t.Fatalf("default timeline should summarise context, not print it:\n%s", res.Stdout)
	}
	if !strings.Contains(res.Stdout, "· note") || !strings.Contains(res.Stdout, "written by Claude Code, no request") {
		t.Fatalf("synthetic message should appear as a note:\n%s", res.Stdout)
	}

	res = h.Run("show", id, "--context")
	res.AssertOK(t)
	for _, want := range []string{"ctx ide_opened_file", "attachment environment"} {
		if !strings.Contains(res.Stdout, want) {
			t.Errorf("--context lacks %q:\n%s", want, res.Stdout)
		}
	}
}

func TestList_UsesIndexAsCache(t *testing.T) {
	t.Parallel()
	h := harness.New(t)
	h.SeedFixture("synthetic-basics", "-Users-me-work")

	first := h.Run("list", "--json")
	first.AssertOK(t)
	if _, err := os.Stat(filepath.Join(h.Home, ".sessionkit", "skit.sqlite")); err != nil {
		t.Fatalf("list should create the index under ~/.sessionkit: %v", err)
	}
	second := h.Run("list", "--json")
	second.AssertOK(t)
	if first.Stdout != second.Stdout {
		t.Fatalf("indexed and parsed list output differ:\n%s\n---\n%s", first.Stdout, second.Stdout)
	}
	third := h.Run("list", "--json", "--no-cache")
	third.AssertOK(t)
	if first.Stdout != third.Stdout {
		t.Fatal("--no-cache output must match")
	}
}

func TestContext_SeedBreakdown(t *testing.T) {
	t.Parallel()
	h := harness.New(t)
	id := h.SeedFixture("synthetic-basics", "-Users-me-work")
	res := h.Run("context", id)
	res.AssertOK(t)
	for _, want := range []string{"Context of action 0 (turn 0)", "System prompt         2 blocks", "Tool definitions      2 tools", "CLAUDE.md and user instructions", "Injected this action  1 attachments", "environment"} {
		if !strings.Contains(res.Stdout, want) {
			t.Errorf("context lacks %q:\n%s", want, res.Stdout)
		}
	}
	res = h.Run("context", id, "--show", "instructions")
	res.AssertOK(t)
	if !strings.Contains(res.Stdout, "Contents of /Xxxxx/xxxx/xxxx/CLAUDE.md") {
		t.Fatalf("--show instructions should print the injected CLAUDE.md block:\n%s", res.Stdout)
	}
	res = h.Run("context", id, "--action", "1")
	res.AssertOK(t)
	if !strings.Contains(res.Stdout, "unavailable") {
		t.Fatalf("action without request records should say so:\n%s", res.Stdout)
	}
	res = h.Run("context", id, "--json")
	res.AssertOK(t)
	var cb struct {
		Available bool `json:"available"`
		Tools     []struct {
			Name string `json:"name"`
		} `json:"tools"`
	}
	if err := json.Unmarshal([]byte(res.Stdout), &cb); err != nil || !cb.Available || len(cb.Tools) != 2 {
		t.Fatalf("context --json: %v %+v", err, cb)
	}
}

func TestContext_Compaction(t *testing.T) {
	t.Parallel()
	h := harness.New(t)
	id := h.SeedFixture("synthetic-basics", "-Users-me-work")
	res := h.Run("context", id, "--compaction", "0")
	res.AssertOK(t)
	for _, want := range []string{"Compaction 0 (turn 0)", "Before    action 3 reported 6.3k tokens", "900 tokens remained", "Primary Request and Intent", "Preserved verbatim", "Re-injected after the boundary", "← CLAUDE.md", "notes.md"} {
		if !strings.Contains(res.Stdout, want) {
			t.Errorf("compaction view lacks %q:\n%s", want, res.Stdout)
		}
	}
	res = h.Run("context", id, "--compaction", "0", "--show", "summary")
	res.AssertOK(t)
	if !strings.Contains(res.Stdout, "Pending Tasks") {
		t.Fatalf("--show summary should print the summary text:\n%s", res.Stdout)
	}
	res = h.Run("show", id)
	res.AssertOK(t)
	if !strings.Contains(res.Stdout, "compaction 0 (auto)") {
		t.Fatalf("timeline should number compactions:\n%s", res.Stdout)
	}
}
