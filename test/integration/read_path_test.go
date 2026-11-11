//go:build integration

package integration

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

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

// TestFile_HistoryOfATouchedFile: after archiving, a file a session touched has
// a history, says it is gone when it is, and a file nobody touched is refused.
func TestFile_HistoryOfATouchedFile(t *testing.T) {
	t.Parallel()
	h := harness.New(t)
	id := h.SeedFixture("synthetic-basics", "-Users-me-work")
	h.Run("archive").AssertOK(t)

	res := h.Run("file", "/xxx/y.go")
	res.AssertOK(t)
	for _, want := range []string{"File      /xxx/y.go", "deleted or moved", "Sessions (1)", id[:8]} {
		if !strings.Contains(res.Stdout, want) {
			t.Errorf("file lacks %q:\n%s", want, res.Stdout)
		}
	}
	res = h.Run("file", "/xxx/y.go", "--session", id, "--json")
	res.AssertOK(t)
	var v struct {
		Path     string `json:"path"`
		Exists   bool   `json:"exists"`
		Reason   string `json:"reason"`
		Sessions []struct {
			Session string `json:"session"`
			Writes  int    `json:"writes"`
		} `json:"sessions"`
	}
	if err := json.Unmarshal([]byte(res.Stdout), &v); err != nil || v.Exists || v.Reason != "deleted" || len(v.Sessions) != 1 || v.Sessions[0].Session != id || v.Sessions[0].Writes != 1 {
		t.Fatalf("file --json: %v %+v", err, v)
	}
	if res = h.Run("file", "/etc/hosts"); res.ExitCode == 0 || !strings.Contains(res.Stderr, "no archived session touched this path") {
		t.Fatalf("a file nobody touched must be refused: %d %s", res.ExitCode, res.Stderr)
	}
}

// TestOverview_AddsSessionsUpFromTheIndex: totals, projects and days for a person
// and as JSON; the second run reads summaries from the index.
func TestOverview_AddsSessionsUpFromTheIndex(t *testing.T) {
	t.Parallel()
	h := harness.New(t)
	h.SeedFixture("synthetic-basics", "-Users-me-work")

	res := h.Run("overview")
	res.AssertOK(t)
	for _, want := range []string{"Sessions  1 in 1 project", "By project", "-Users-me-work", "By day", "Tools", "Bash", "Models", "Time      wall"} {
		if !strings.Contains(res.Stdout, want) {
			t.Errorf("overview lacks %q:\n%s", want, res.Stdout)
		}
	}
	res = h.Run("overview", "--json")
	res.AssertOK(t)
	var o struct {
		Sessions int `json:"sessions"`
		Totals   struct {
			Actions   int `json:"actions"`
			ToolCalls int `json:"tool_calls"`
		} `json:"totals"`
		Days []struct {
			Day      string   `json:"day"`
			Actions  int      `json:"actions"`
			Sessions []string `json:"sessions"`
		} `json:"days"`
		Time struct {
			Wall float64 `json:"wall_seconds"`
		} `json:"time"`
	}
	if err := json.Unmarshal([]byte(res.Stdout), &o); err != nil {
		t.Fatalf("overview --json: %v\n%s", err, res.Stdout)
	}
	var onDays int
	for _, d := range o.Days {
		onDays += d.Actions
	}
	if o.Sessions != 1 || o.Totals.Actions != 7 || o.Totals.ToolCalls != 5 || onDays != o.Totals.Actions || o.Time.Wall != 64 || len(o.Days[0].Sessions) != 1 {
		t.Fatalf("the days must hold what the totals hold: %+v", o)
	}
	if res = h.Run("overview", "-p", "nowhere", "--json"); !strings.Contains(res.Stdout, `"sessions": 0`) {
		t.Fatalf("a project nothing matches: %s", res.Stdout)
	}
}

// TestTime_WhereTheWallTimeWent: the split adds up, for a person and as JSON.
func TestTime_WhereTheWallTimeWent(t *testing.T) {
	t.Parallel()
	h := harness.New(t)
	id := h.SeedFixture("synthetic-basics", "-Users-me-work")

	res := h.Run("time", id)
	res.AssertOK(t)
	for _, want := range []string{"waiting for you", "in turns", "the model", "tools running", "subagents running", "Slowest tool calls (4)", "Longest waits (2)", "Turns (2), longest first"} {
		if !strings.Contains(res.Stdout, want) {
			t.Errorf("time lacks %q:\n%s", want, res.Stdout)
		}
	}
	res = h.Run("time", id, "--top", "1", "--json")
	res.AssertOK(t)
	var tm struct {
		Wall    float64 `json:"wall_seconds"`
		ForYou  float64 `json:"waiting_for_you_seconds"`
		InTurns struct {
			Seconds   float64 `json:"seconds"`
			Model     float64 `json:"model_seconds"`
			Tools     float64 `json:"tools_seconds"`
			Subagents float64 `json:"subagents_seconds"`
			Waiting   float64 `json:"waiting_seconds"`
		} `json:"in_turns"`
		Slowest []struct {
			Name    string  `json:"name"`
			Seconds float64 `json:"seconds"`
		} `json:"slowest_calls"`
	}
	if err := json.Unmarshal([]byte(res.Stdout), &tm); err != nil {
		t.Fatalf("time --json: %v\n%s", err, res.Stdout)
	}
	in := tm.InTurns
	if tm.Wall != 64 || tm.ForYou+in.Seconds != tm.Wall || in.Model+in.Tools+in.Subagents+in.Waiting != in.Seconds {
		t.Fatalf("the parts must add up: %+v", tm)
	}
	if len(tm.Slowest) != 1 || tm.Slowest[0].Name != "Bash" {
		t.Fatalf("--top 1 lists the slowest call: %+v", tm.Slowest)
	}
}

// TestExport_MarkdownOfASessionAndATurn: the conversation leaves the tool as
// Markdown, to stdout, to a file, or inside a JSON object.
func TestExport_MarkdownOfASessionAndATurn(t *testing.T) {
	t.Parallel()
	h := harness.New(t)
	id := h.SeedFixture("synthetic-basics", "-Users-me-work")

	res := h.Run("export", id[:8])
	res.AssertOK(t)
	for _, want := range []string{"# Synthetic basics\n", "Session `" + id + "`", "## Turn 0 · ", "**You**", "**Claude**", "- `Edit` /xxx/y.go", "> Context compacted (auto): 6.4k → 900 tokens", "## Turn 1 · "} {
		if !strings.Contains(res.Stdout, want) {
			t.Errorf("export lacks %q:\n%s", want, res.Stdout)
		}
	}
	if strings.Contains(res.Stdout, "Thinking") {
		t.Errorf("thinking is left out unless asked for:\n%s", res.Stdout)
	}

	out := filepath.Join(t.TempDir(), "turn.md")
	res = h.Run("export", id, "--turn", "1", "--thinking", "--out", out)
	res.AssertOK(t)
	written, err := os.ReadFile(out)
	if err != nil || !strings.HasPrefix(string(written), "## Turn 1 · ") || strings.Contains(string(written), "Turn 0") || res.Stdout != "" {
		t.Fatalf("--turn 1 --out writes that turn to the file and nothing to stdout: %v\n%s\nstdout %q", err, written, res.Stdout)
	}

	res = h.Run("export", id, "--turn", "0", "--json")
	res.AssertOK(t)
	var doc struct {
		Session, Format, Text string
		Turn                  *int
	}
	if err := json.Unmarshal([]byte(res.Stdout), &doc); err != nil || doc.Session != id || doc.Format != "markdown" || doc.Turn == nil || *doc.Turn != 0 || !strings.HasPrefix(doc.Text, "## Turn 0") {
		t.Fatalf("--json wraps the text: %v %+v", err, doc)
	}

	res = h.Run("export", id, "--turn", "9", "--json")
	if res.ExitCode == 0 || !strings.Contains(res.Stderr, `"error"`) {
		t.Fatalf("a turn that is not there is a JSON error, got exit %d stderr %q", res.ExitCode, res.Stderr)
	}

	// One step of a subagent, in full.
	res = h.Run("show", id, "--agent", "a1b2c3d4e5f607182", "--action", "0")
	res.AssertOK(t)
	if !strings.Contains(res.Stdout, "── action 0") || !strings.Contains(res.Stdout, "tool_use Bash") {
		t.Fatalf("show --agent --action prints the subagent's step:\n%s", res.Stdout)
	}
	if res = h.Run("show", id, "--agent", "nobody", "--action", "0"); res.ExitCode == 0 {
		t.Fatalf("an unknown subagent is an error:\n%s", res.Stdout)
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

// TestPrimitives_InstalledOfferedAndUsed: a skill defined in a project and used
// twice (once typed, once by the model), one installed for the user and never
// used, from the disk and one archived session.
func TestPrimitives_InstalledOfferedAndUsed(t *testing.T) {
	t.Parallel()
	h := harness.New(t)
	work := filepath.Join(h.Home, "work")
	skill := filepath.Join(work, ".claude", "skills", "deploy")
	h.WriteFile("../work/.claude/skills/deploy/SKILL.md", "---\nname: deploy\ndescription: Ship the thing\n---\nSteps.")
	h.WriteFile("skills/tidy/SKILL.md", "---\ndescription: Tidy up\n---\n")
	h.WriteFile("CLAUDE.md", "never printed")
	id := "dddddddd-0000-0000-0000-000000000004"
	q := func(s string) string { b, _ := json.Marshal(s); return string(b) }
	h.SeedSession("-work", id,
		`{"type":"attachment","uuid":"at1","sessionId":"`+id+`","cwd":`+q(work)+`,"timestamp":"2026-11-08T11:00:00Z","attachment":{"type":"skill_listing","names":["deploy","tidy"],"isInitial":true}}`,
		`{"type":"user","uuid":"u1","parentUuid":"at1","sessionId":"`+id+`","cwd":`+q(work)+`,"turnOrigin":"human","timestamp":"2026-11-08T11:00:01Z","message":{"role":"user","content":"<command-message>deploy</command-message>\n<command-name>/deploy</command-name>"}}`,
		`{"type":"user","uuid":"u1m","parentUuid":"u1","isMeta":true,"timestamp":"2026-11-08T11:00:01.1Z","message":{"role":"user","content":[{"type":"text","text":`+q("Base directory for this skill: "+skill+"\n\nSteps.")+`}]}}`,
		`{"type":"assistant","uuid":"a1","parentUuid":"u1m","requestId":"r1","timestamp":"2026-11-08T11:00:03Z","message":{"model":"claude-fable-5-1","content":[{"type":"tool_use","id":"toolu_s1","name":"Skill","input":{"skill":"deploy"}},{"type":"tool_use","id":"toolu_m1","name":"mcp__notes__search","input":{"query":"x"}}],"usage":{"input_tokens":10,"output_tokens":5}}}`,
		`{"type":"user","uuid":"r1a","parentUuid":"a1","timestamp":"2026-11-08T11:00:04Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_s1","content":"Launching skill: deploy"}]}}`,
		`{"type":"user","uuid":"r1m","parentUuid":"r1a","isMeta":true,"sourceToolUseID":"toolu_s1","timestamp":"2026-11-08T11:00:04.1Z","message":{"role":"user","content":[{"type":"text","text":`+q("Base directory for this skill: "+skill+"\n\nSteps.")+`}]}}`,
		`{"type":"user","uuid":"r1b","parentUuid":"r1m","timestamp":"2026-11-08T11:00:06Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_m1","is_error":true,"content":"no"}]}}`,
		`{"type":"assistant","uuid":"a2","parentUuid":"r1b","requestId":"r2","timestamp":"2026-11-08T11:00:07Z","message":{"model":"claude-fable-5-1","stop_reason":"end_turn","content":[{"type":"text","text":"Deployed."}],"usage":{"input_tokens":12,"output_tokens":5}}}`)
	h.Run("archive").AssertOK(t)

	res := h.Run("primitives")
	res.AssertOK(t)
	for _, want := range []string{"Primitives  1 session, every session kept", "2 uses in 1 session (1 typed)", "never used · on offer in 1 session",
		"1 use in 1 session · 1 failed", "user", "project"} {
		if !strings.Contains(res.Stdout, want) {
			t.Errorf("primitives lacks %q:\n%s", want, res.Stdout)
		}
	}
	if strings.Contains(res.Stdout, "never printed") {
		t.Errorf("a memory file's text was printed:\n%s", res.Stdout)
	}

	res = h.Run("primitives", "skills", "deploy", "--json")
	res.AssertOK(t)
	var rep struct {
		Items []struct {
			Name        string `json:"name"`
			Description string `json:"description"`
			Definitions []struct {
				Scope string `json:"scope"`
				Where string `json:"where"`
				Calls int    `json:"calls"`
			} `json:"definitions"`
			Usage struct {
				Calls  int `json:"calls"`
				ByUser int `json:"by_user"`
			} `json:"usage"`
			Sessions []struct {
				Session string `json:"session"`
				Turn    int    `json:"turn"`
			} `json:"sessions"`
		} `json:"items"`
	}
	if err := json.Unmarshal([]byte(res.Stdout), &rep); err != nil || len(rep.Items) != 1 {
		t.Fatalf("primitives skill deploy --json: %v\n%s", err, res.Stdout)
	}
	it := rep.Items[0]
	// On macOS the temp directory is reached through a symlink; compare what the engine was told.
	if it.Description != "Ship the thing" || len(it.Definitions) != 1 || it.Definitions[0].Scope != "project" || it.Definitions[0].Where != work ||
		it.Definitions[0].Calls != 2 || it.Usage.Calls != 2 || it.Usage.ByUser != 1 || len(it.Sessions) != 1 || it.Sessions[0].Session != id || it.Sessions[0].Turn != 0 {
		t.Fatalf("skill deploy: %+v", it)
	}

	res = h.Run("primitives", "skill", "--unused", "--json")
	res.AssertOK(t)
	if !strings.Contains(res.Stdout, `"name": "tidy"`) || strings.Contains(res.Stdout, `"name": "deploy"`) {
		t.Fatalf("unused skills:\n%s", res.Stdout)
	}
	if res = h.Run("primitives", "skill", "nope"); res.ExitCode == 0 || !strings.Contains(res.Stderr, `no skill named "nope"`) {
		t.Fatalf("an unknown skill: %d %s", res.ExitCode, res.Stderr)
	}
	if res = h.Run("primitives", "widgets"); res.ExitCode == 0 || !strings.Contains(res.Stderr, "unknown kind") {
		t.Fatalf("an unknown kind: %d %s", res.ExitCode, res.Stderr)
	}
}

// TestNow_WhatSessionsAreDoing: one session a live process has open with a tool
// out, one that ended and was closed; and the cache's end, counted from the
// last request.
func TestNow_WhatSessionsAreDoing(t *testing.T) {
	t.Parallel()
	h := harness.New(t)
	now := time.Now().UTC()
	at := func(ago time.Duration) string { return now.Add(-ago).Format(time.RFC3339Nano) }
	busy, closed := "eeeeeeee-0000-0000-0000-000000000005", "ffffffff-0000-0000-0000-000000000006"
	usage := `"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":900,"cache_creation_input_tokens":90,"cache_creation":{"ephemeral_1h_input_tokens":90,"ephemeral_5m_input_tokens":0}}`
	h.SeedSession("-work", busy,
		`{"type":"user","uuid":"u1","sessionId":"`+busy+`","cwd":"/work","turnOrigin":"human","timestamp":"`+at(90*time.Second)+`","message":{"role":"user","content":"Run the tests"}}`,
		`{"type":"last-prompt","lastPrompt":"Run the tests","sessionId":"`+busy+`"}`,
		`{"type":"ai-title","aiTitle":"Running the tests","sessionId":"`+busy+`"}`,
		`{"type":"api-request","id":"ar1","timestamp":"`+at(80*time.Second)+`"}`,
		`{"type":"assistant","uuid":"a1","parentUuid":"u1","requestId":"r1","timestamp":"`+at(60*time.Second)+`","message":{"model":"claude-fable-5-1","stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_n1","name":"Bash","input":{"command":"go test ./...","description":"Run every test"}}],`+usage+`}}`)
	old := h.SeedSession("-work", closed,
		`{"type":"user","uuid":"u1","sessionId":"`+closed+`","cwd":"/work","turnOrigin":"human","timestamp":"`+at(20*time.Minute)+`","message":{"role":"user","content":"Say hello"}}`,
		`{"type":"assistant","uuid":"a1","parentUuid":"u1","requestId":"r1","timestamp":"`+at(19*time.Minute)+`","message":{"model":"claude-fable-5-1","stop_reason":"end_turn","content":[{"type":"text","text":"Hello."}],`+usage+`}}`)
	// A session is in the window by when its transcript was last written.
	if err := os.Chtimes(old, now.Add(-19*time.Minute), now.Add(-19*time.Minute)); err != nil {
		t.Fatal(err)
	}
	// The test's own process stands in for Claude Code's: it runs for as long as the test does.
	h.WriteFile(fmt.Sprintf("sessions/%d.json", os.Getpid()), fmt.Sprintf(`{"pid":%d,"sessionId":%q,"cwd":"/work","name":"work-1","status":"busy","entrypoint":"cli","updatedAt":%d,"statusUpdatedAt":%d}`,
		os.Getpid(), busy, now.UnixMilli(), now.Add(-90*time.Second).UnixMilli()))

	res := h.Run("now")
	res.AssertOK(t)
	for _, want := range []string{"Now  2 sessions at work in the last 60 minutes", "Running the tests", "running Bash Run every test, for 1m", "work-1",
		"cache  90% of the last request read · context 1k · expires in 58m", "closed 19m", "said   Hello.", "asked  Run the tests"} {
		if !strings.Contains(res.Stdout, want) {
			t.Errorf("now lacks %q:\n%s", want, res.Stdout)
		}
	}
	res = h.Run("now", "--json")
	res.AssertOK(t)
	var rep struct {
		Sessions []struct {
			ID      string `json:"id"`
			State   string `json:"state"`
			Running bool   `json:"running"`
			PID     int    `json:"pid"`
			Tools   []struct {
				Name string `json:"name"`
			} `json:"tools"`
			Cache struct {
				TTL  int `json:"ttl_seconds"`
				Left int `json:"seconds_left"`
			} `json:"cache"`
		} `json:"sessions"`
	}
	if err := json.Unmarshal([]byte(res.Stdout), &rep); err != nil || len(rep.Sessions) != 2 {
		t.Fatalf("now --json: %v\n%s", err, res.Stdout)
	}
	first, second := rep.Sessions[0], rep.Sessions[1]
	if first.ID != busy || first.State != "tool" || !first.Running || first.PID != os.Getpid() || len(first.Tools) != 1 || first.Tools[0].Name != "Bash" ||
		first.Cache.TTL != 3600 || first.Cache.Left < 3500 || first.Cache.Left > 3520 {
		t.Fatalf("the running session: %+v", first)
	}
	if second.ID != closed || second.State != "closed" || second.Running || second.Cache.Left < 2400 || second.Cache.Left > 2470 {
		t.Fatalf("the closed session: %+v", second)
	}
	// A window that the closed one fell out of.
	if res = h.Run("now", "--minutes", "5", "--json"); !strings.Contains(res.Stdout, busy) || strings.Contains(res.Stdout, closed) {
		t.Fatalf("a five-minute window:\n%s", res.Stdout)
	}
}
