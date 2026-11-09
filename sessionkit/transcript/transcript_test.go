package transcript

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReaderPartialLineAndMalformed(t *testing.T) {
	in := "{\"type\":\"user\",\"uuid\":\"a\"}\nnot json\n\n{\"type\":\"assistant\",\"uuid\":\"b\",\"parentUuid\":\"a\"}\n{\"type\":\"user\",\"uuid\":\"c\""
	rd := NewReader(strings.NewReader(in))
	var types []string
	for {
		rec, err := rd.Next()
		if err != nil {
			if !errors.Is(err, ErrPartialLine) {
				t.Fatalf("want ErrPartialLine at the end, got %v", err)
			}
			break
		}
		types = append(types, rec.Type)
		if rec.Type == MalformedType && rec.Malformed == nil {
			t.Fatal("malformed record must carry its error")
		}
	}
	if got := strings.Join(types, ","); got != "user,<malformed>,assistant" {
		t.Fatalf("types = %s", got)
	}
	if rd.Offset() != int64(strings.LastIndex(in, "{")) {
		t.Fatalf("offset %d should point at the partial line", rd.Offset())
	}
	if rd.Line() != 4 {
		t.Fatalf("lines = %d, want 4 (blank line counts)", rd.Line())
	}
}

func TestRecordKeepsRawAndOffsets(t *testing.T) {
	in := "{\"type\":\"cost-state\",\"totalCostUSD\":1.5}\n{\"type\":\"user\",\"uuid\":\"a\"}\n"
	recs, err := ReadAll(strings.NewReader(in))
	if err != nil || len(recs) != 2 {
		t.Fatalf("recs=%d err=%v", len(recs), err)
	}
	var c CostState
	if err := recs[0].Decode(&c); err != nil || c.TotalCostUSD != 1.5 {
		t.Fatalf("Decode must see the raw line: %v %+v (raw=%q)", err, c, recs[0].Raw)
	}
	if recs[0].Offset != 0 || recs[0].Line != 1 || recs[1].Offset != int64(strings.Index(in, "\n")+1) || recs[1].Line != 2 {
		t.Fatalf("offsets/lines wrong: %d/%d %d/%d", recs[0].Offset, recs[0].Line, recs[1].Offset, recs[1].Line)
	}
}

func TestStringContentAndUsage(t *testing.T) {
	in := `{"type":"user","uuid":"u1","turnOrigin":"human","timestamp":"2026-11-08T01:00:00.000Z","message":{"role":"user","content":"hello"}}
{"type":"assistant","uuid":"a1","parentUuid":"u1","requestId":"req_1","apiBlockIndex":0,"timestamp":"2026-11-08T01:00:01.000Z","message":{"id":"msg_1","model":"m","role":"assistant","content":[{"type":"thinking","thinking":"hm","signature":"x"}],"usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":4,"output_tokens_details":{"thinking_tokens":1}}}}
{"type":"assistant","uuid":"a2","parentUuid":"a1","requestId":"req_1","apiBlockIndex":1,"timestamp":"2026-11-08T01:00:01.500Z","message":{"id":"msg_1","model":"m","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}],"stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":4}}}
{"type":"user","uuid":"u2","parentUuid":"a2","timestamp":"2026-11-08T01:00:02.000Z","toolUseResult":{"ok":true},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"a.txt"}]}}
{"type":"assistant","uuid":"a3","parentUuid":"u2","requestId":"req_2","apiBlockIndex":0,"timestamp":"2026-11-08T01:00:03.000Z","message":{"id":"msg_2","model":"m","role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Read","input":{}}],"usage":{"input_tokens":10,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
{"type":"last-prompt","lastPrompt":"hello","leafUuid":"a3"}
{"type":"ai-title","aiTitle":"first"}
{"type":"ai-title","aiTitle":"final"}
{"type":"brand-new-thing","x":1}
`
	s, err := Parse(strings.NewReader(in))
	if err != nil {
		t.Fatal(err)
	}
	tt := s.Totals
	if tt.Prompts != 1 || tt.Requests != 2 || tt.AssistantRecords != 3 || tt.ToolCalls != 2 || tt.ToolResults != 1 || tt.UnpairedToolUses != 1 {
		t.Fatalf("totals = %+v", tt)
	}
	if tt.Usage.InputTokens != 11 || tt.Usage.OutputTokens != 3 || tt.Usage.CacheReadInputTokens != 4 || tt.Usage.ThinkingTokens != 1 {
		t.Fatalf("usage must be counted once per request: %+v", tt.Usage)
	}
	if s.Title != "final" || s.UnknownTypes["brand-new-thing"] != 1 {
		t.Fatalf("title=%q unknown=%v", s.Title, s.UnknownTypes)
	}
	if s.Prompts[0].Text != "hello" {
		t.Fatalf("string content should become a text block: %q", s.Prompts[0].Text)
	}
	if len(s.Actions[0].Blocks) != 2 || s.Actions[0].Blocks[1].Type != "tool_use" || s.Actions[0].StopReason != "tool_use" {
		t.Fatalf("action 0 blocks = %+v", s.Actions[0].Blocks)
	}
	if len(s.Turns) != 1 || s.Turns[0].Origin != "human" || len(s.Turns[0].Actions) != 2 || s.Turns[0].ToolCalls != 2 || s.Turns[0].Usage.OutputTokens != 3 {
		t.Fatalf("one human turn with two actions expected: %+v", s.Turns)
	}
	if s.Actions[1].Turn != 0 || s.ToolCalls[1].Turn != 0 || s.ToolCalls[1].Action != 1 {
		t.Fatalf("actions and tool calls must know their turn: %+v %+v", s.Actions[1], s.ToolCalls[1])
	}
	if !s.Turns[0].EndAt.Equal(s.Actions[1].At) {
		t.Fatalf("turn end should be the last action (01:00:03), got %v", s.Turns[0].EndAt)
	}
	if !s.ToolCalls[0].Paired || s.ToolCalls[0].ResultText() != "a.txt" || s.ToolCalls[1].Paired {
		t.Fatalf("tool pairing wrong: %+v %+v", s.ToolCalls[0], s.ToolCalls[1])
	}
	if strings.Join(s.Chain, ">") != "u1>a1>a2>u2>a3" {
		t.Fatalf("chain = %v", s.Chain)
	}
}

func TestCompactionChain(t *testing.T) {
	in := `{"type":"user","uuid":"u1","turnOrigin":"human","timestamp":"2026-11-08T01:00:00Z","message":{"role":"user","content":[{"type":"text","text":"go"}]}}
{"type":"assistant","uuid":"a1","parentUuid":"u1","requestId":"r1","timestamp":"2026-11-08T01:00:01Z","message":{"model":"m","role":"assistant","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":1,"output_tokens":1}}}
{"type":"system","subtype":"compact_boundary","uuid":"c1","parentUuid":null,"logicalParentUuid":"a1","timestamp":"2026-11-08T01:00:02Z","compactMetadata":{"trigger":"auto","preTokens":1000,"postTokens":100}}
{"type":"user","uuid":"s1","parentUuid":"c1","isCompactSummary":true,"turnOrigin":"human","timestamp":"2026-11-08T01:00:03Z","message":{"role":"user","content":"This session is being continued"}}
{"type":"user","uuid":"u2","parentUuid":"s1","turnOrigin":"human","timestamp":"2026-11-08T01:00:04Z","message":{"role":"user","content":[{"type":"text","text":"next"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AAAA"}}]}}
{"type":"system","subtype":"api_error","uuid":"e1","parentUuid":"u2","timestamp":"2026-11-08T01:00:05Z","retryAttempt":1}
`
	s, err := Parse(strings.NewReader(in))
	if err != nil {
		t.Fatal(err)
	}
	if s.Totals.Compactions != 1 || s.Compactions[0].Metadata.PreTokens != 1000 || s.Compactions[0].Summary == nil {
		t.Fatalf("compaction = %+v", s.Compactions)
	}
	if s.Totals.Prompts != 2 || s.Totals.Images != 1 || s.Totals.APIErrors != 1 {
		t.Fatalf("totals = %+v", s.Totals)
	}
	if strings.Join(s.Chain, ">") != "u1>a1>c1>s1>u2>e1" {
		t.Fatalf("chain must cross the compaction via logicalParentUuid: %v", s.Chain)
	}
}

// expected.json next to each fixture pins the counts; see internal/tools/expected.
type expected struct {
	Title            string         `json:"title"`
	Records          int            `json:"records"`
	Prompts          int            `json:"prompts"`
	Turns            int            `json:"turns"`
	SystemTurns      int            `json:"system_turns"`
	Requests         int            `json:"requests"`
	AssistantRecords int            `json:"assistant_records"`
	ToolCalls        int            `json:"tool_calls"`
	ToolResults      int            `json:"tool_results"`
	Images           int            `json:"images"`
	Compactions      int            `json:"compactions"`
	APIErrors        int            `json:"api_errors"`
	Subagents        int            `json:"subagents"`
	OutputTokens     int            `json:"output_tokens"`
	CacheRead        int            `json:"cache_read_input_tokens"`
	Models           map[string]int `json:"models"`
	Tools            map[string]int `json:"tools"`
	ChainLen         int            `json:"chain_len"`
}

func TestFixtures(t *testing.T) {
	root := filepath.Join("..", "..", "internal", "testdata", "sessions")
	dirs, err := os.ReadDir(root)
	if err != nil {
		t.Skip("no fixtures:", err)
	}
	ran := 0
	for _, d := range dirs {
		if !d.IsDir() {
			continue
		}
		dir := filepath.Join(root, d.Name())
		expB, err := os.ReadFile(filepath.Join(dir, "expected.json"))
		if err != nil {
			continue
		}
		var exp expected
		if err := json.Unmarshal(expB, &exp); err != nil {
			t.Fatalf("%s: %v", dir, err)
		}
		files, _ := filepath.Glob(filepath.Join(dir, "*.jsonl"))
		if len(files) != 1 {
			t.Fatalf("%s: want exactly one transcript, got %v", dir, files)
		}
		ran++
		t.Run(d.Name(), func(t *testing.T) {
			s, err := Load(files[0])
			if err != nil {
				t.Fatal(err)
			}
			got := s.Totals
			check := func(name string, got, want int) {
				if got != want {
					t.Errorf("%s: got %d, want %d", name, got, want)
				}
			}
			check("records", got.Records, exp.Records)
			check("prompts", got.Prompts, exp.Prompts)
			check("turns", got.Turns, exp.Turns)
			check("system_turns", got.SystemTurns, exp.SystemTurns)
			check("requests", got.Requests, exp.Requests)
			check("assistant_records", got.AssistantRecords, exp.AssistantRecords)
			check("tool_calls", got.ToolCalls, exp.ToolCalls)
			check("tool_results", got.ToolResults, exp.ToolResults)
			check("images", got.Images, exp.Images)
			check("compactions", got.Compactions, exp.Compactions)
			check("api_errors", got.APIErrors, exp.APIErrors)
			check("subagents", got.Subagents, exp.Subagents)
			check("output_tokens", got.Usage.OutputTokens, exp.OutputTokens)
			check("cache_read_input_tokens", got.Usage.CacheReadInputTokens, exp.CacheRead)
			check("chain_len", len(s.Chain), exp.ChainLen)
			if s.Title != exp.Title {
				t.Errorf("title: got %q, want %q", s.Title, exp.Title)
			}
			for m, n := range exp.Models {
				check("model "+m, got.Models[m], n)
			}
			for name, n := range exp.Tools {
				check("tool "+name, got.Tools[name], n)
			}
			if len(s.UnknownTypes) > 0 {
				t.Logf("unknown record types (fine, but worth modelling): %v", s.UnknownTypes)
			}
		})
	}
	if ran == 0 {
		t.Skip("no fixtures with expected.json")
	}
}

func TestSpilledToolResultResolvesLocally(t *testing.T) {
	s, err := Load(filepath.Join("..", "..", "internal", "testdata", "sessions", "synthetic-basics", "aaaaaaaa-0000-0000-0000-000000000001.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	var edit *ToolCall
	for _, c := range s.ToolCalls {
		if c.ID == "toolu_04" {
			edit = c
		}
	}
	if edit == nil || !edit.Paired || !strings.HasSuffix(edit.Spilled, "tool-results/toolu_04.txt") {
		t.Fatalf("toolu_04 = %+v", edit)
	}
	p, ok := s.SpilledPath(edit)
	if !ok {
		t.Fatal("spilled output should resolve under the fixture's companion dir")
	}
	b, err := os.ReadFile(p)
	if err != nil || !strings.HasPrefix(string(b), "full output line 1") {
		t.Fatalf("read %s: %v %q", p, err, b)
	}
	var agent *ToolCall
	for _, c := range s.ToolCalls {
		if c.Name == "Agent" {
			agent = c
		}
	}
	if agent == nil || agent.Subagent == nil || agent.Subagent.AgentID != "a1b2c3d4e5f607182" || agent.Subagent.Session.Totals.Requests != 2 {
		t.Fatalf("Agent call should link to its subagent: %+v", agent)
	}
	if strings.Join(s.Cwds, ",") != "/Users/xxxx/work,/Users/xxxx/work/sub" || s.Cwd != "/Users/xxxx/work" {
		t.Fatalf("cwds = %v (first %q)", s.Cwds, s.Cwd)
	}
	if s.Cost == nil || s.Cost.TotalCostUSD != 0.42 || len(s.PRLinks) != 1 || s.Totals.Malformed != 1 || s.UnknownTypes["future-record-kind"] != 1 {
		t.Fatalf("metadata: cost=%+v pr=%v malformed=%d unknown=%v", s.Cost, s.PRLinks, s.Totals.Malformed, s.UnknownTypes)
	}
}

func TestInjectedBlocksBranchesAndSynthetic(t *testing.T) {
	in := `{"type":"user","uuid":"u1","turnOrigin":"human","timestamp":"2026-11-08T01:00:00Z","message":{"role":"user","content":[{"type":"text","text":"<ide_opened_file>The user opened x</ide_opened_file>"},{"type":"text","text":"real question"}]}}
{"type":"attachment","uuid":"at1","parentUuid":"u1","timestamp":"2026-11-08T01:00:00Z","attachment":{"type":"date"}}
{"type":"assistant","uuid":"a1","parentUuid":"u1","requestId":"r1","timestamp":"2026-11-08T01:00:01Z","message":{"model":"m","role":"assistant","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":1,"output_tokens":1}}}
{"type":"assistant","uuid":"a2","parentUuid":"a1","timestamp":"2026-11-08T01:00:02Z","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"Claude Code says hi"}],"usage":{"input_tokens":0,"output_tokens":0}}}
`
	s, err := Parse(strings.NewReader(in))
	if err != nil {
		t.Fatal(err)
	}
	if s.Prompts[0].Text != "real question" {
		t.Fatalf("injected IDE block must not be prompt text: %q", s.Prompts[0].Text)
	}
	if s.Branches != 0 {
		t.Fatalf("an attachment sibling is not a branch: %d", s.Branches)
	}
	if len(s.Actions) != 2 || !s.Actions[1].Synthetic || s.Totals.Requests != 1 || s.Totals.Models["<synthetic>"] != 0 {
		t.Fatalf("synthetic action handling: actions=%d requests=%d models=%v", len(s.Actions), s.Totals.Requests, s.Totals.Models)
	}
	if s.Actions[1].SyntheticKind != "other" || s.Totals.Synthetic != 1 || s.Totals.SyntheticErrors != 0 {
		t.Fatalf("synthetic kind = %q, totals %+v", s.Actions[1].SyntheticKind, s.Totals)
	}
	if len(s.Prompts[0].Context) != 1 || InjectedKind(s.Prompts[0].Context[0].Text) != "ide_opened_file" || s.Totals.InjectedBlocks != 1 {
		t.Fatalf("injected block must be kept as prompt context: %+v", s.Prompts[0].Context)
	}
}

func TestParallelToolCallsAreNotBranches(t *testing.T) {
	// One request split into two tool_use records; both results point at the record that holds their tool_use.
	in := `{"type":"user","uuid":"u1","turnOrigin":"human","timestamp":"2026-11-08T01:00:00Z","message":{"role":"user","content":"do two things"}}
{"type":"assistant","uuid":"a1","parentUuid":"u1","requestId":"r1","apiBlockIndex":0,"timestamp":"2026-11-08T01:00:01Z","message":{"model":"m","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}],"usage":{"input_tokens":1,"output_tokens":1}}}
{"type":"assistant","uuid":"a2","parentUuid":"a1","requestId":"r1","apiBlockIndex":1,"timestamp":"2026-11-08T01:00:01Z","message":{"model":"m","role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Read","input":{}}],"usage":{"input_tokens":1,"output_tokens":1}}}
{"type":"user","uuid":"r1","parentUuid":"a1","timestamp":"2026-11-08T01:00:02Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"x"}]}}
{"type":"user","uuid":"r2","parentUuid":"a2","timestamp":"2026-11-08T01:00:02Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"y"}]}}
{"type":"assistant","uuid":"a3","parentUuid":"r2","requestId":"r2","timestamp":"2026-11-08T01:00:03Z","message":{"model":"m","role":"assistant","content":[{"type":"text","text":"done"}],"usage":{"input_tokens":1,"output_tokens":1}}}
{"type":"user","uuid":"u2","parentUuid":"a3","turnOrigin":"human","timestamp":"2026-11-08T01:00:04Z","message":{"role":"user","content":"rewind here"}}
{"type":"user","uuid":"u2b","parentUuid":"a3","turnOrigin":"human","timestamp":"2026-11-08T01:00:05Z","message":{"role":"user","content":"a real second branch"}}
`
	s, err := Parse(strings.NewReader(in))
	if err != nil {
		t.Fatal(err)
	}
	if s.Branches != 1 {
		t.Fatalf("branches = %d: parallel tool results must not count, the two human prompts under a3 must", s.Branches)
	}
	if s.Totals.Requests != 2 || s.Totals.ToolCalls != 2 || s.Totals.UnpairedToolUses != 0 {
		t.Fatalf("totals = %+v", s.Totals)
	}
}

func TestSyntheticKinds(t *testing.T) {
	in := `{"type":"assistant","uuid":"a1","timestamp":"2026-11-08T01:00:00Z","isApiErrorMessage":true,"error":"server_error","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"API Error: Connection dropped (ECONNRESET)"}],"stop_reason":"stop_sequence","usage":{"input_tokens":0,"output_tokens":0}}}
{"type":"assistant","uuid":"a2","parentUuid":"a1","timestamp":"2026-11-08T01:00:01Z","isApiErrorMessage":false,"message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"No response requested."}],"stop_reason":"stop_sequence","usage":{"input_tokens":0,"output_tokens":0}}}
{"type":"system","subtype":"api_error","uuid":"e1","parentUuid":"a2","timestamp":"2026-11-08T01:00:02Z","error":{"status":529,"message":"overloaded"},"retryAttempt":1,"maxRetries":10}
`
	s, err := Parse(strings.NewReader(in))
	if err != nil {
		t.Fatal(err)
	}
	if s.Totals.Synthetic != 2 || s.Totals.SyntheticErrors != 1 || s.Totals.Requests != 0 || s.Totals.APIErrors != 1 {
		t.Fatalf("totals = %+v", s.Totals)
	}
	if s.Actions[0].SyntheticKind != "api_error" || s.Actions[1].SyntheticKind != "no_response" {
		t.Fatalf("kinds = %q %q", s.Actions[0].SyntheticKind, s.Actions[1].SyntheticKind)
	}
	if len(s.Turns) != 1 || s.Turns[0].Origin != "system" || s.Turns[0].Prompt != nil {
		t.Fatalf("actions before any prompt belong to a leading system turn: %+v", s.Turns)
	}
	if s.Totals.Malformed != 0 {
		t.Fatal("an object-valued error field must not break parsing")
	}
}

func TestTurnsGroupActionsAndSystemOrigins(t *testing.T) {
	in := `{"type":"user","uuid":"u1","turnOrigin":"human","timestamp":"2026-11-08T01:00:00Z","message":{"role":"user","content":"first"}}
{"type":"assistant","uuid":"a1","parentUuid":"u1","requestId":"r1","timestamp":"2026-11-08T01:00:01Z","message":{"model":"m","role":"assistant","content":[{"type":"thinking","thinking":"let me think","signature":"x"},{"type":"tool_use","id":"t1","name":"Bash","input":{}}],"usage":{"input_tokens":1,"output_tokens":5}}}
{"type":"user","uuid":"r1","parentUuid":"a1","timestamp":"2026-11-08T01:00:02Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}
{"type":"assistant","uuid":"a2","parentUuid":"r1","requestId":"r2","timestamp":"2026-11-08T01:00:03Z","message":{"model":"m","role":"assistant","content":[{"type":"text","text":"done with the first"}],"usage":{"input_tokens":1,"output_tokens":2}}}
{"type":"system","subtype":"compact_boundary","uuid":"c1","parentUuid":null,"logicalParentUuid":"a2","timestamp":"2026-11-08T01:00:04Z","compactMetadata":{"trigger":"auto","preTokens":100,"postTokens":10}}
{"type":"user","uuid":"s1","parentUuid":"c1","isCompactSummary":true,"turnOrigin":"human","timestamp":"2026-11-08T01:00:05Z","message":{"role":"user","content":"This session is being continued"}}
{"type":"user","uuid":"n1","parentUuid":"s1","turnOrigin":"task_notification","timestamp":"2026-11-08T01:00:06Z","message":{"role":"user","content":[{"type":"text","text":"<task-notification>background task finished</task-notification>"}]}}
{"type":"assistant","uuid":"a3","parentUuid":"n1","requestId":"r3","timestamp":"2026-11-08T01:00:07Z","message":{"model":"m","role":"assistant","content":[{"type":"text","text":"noted"}],"usage":{"input_tokens":1,"output_tokens":1}}}
{"type":"user","uuid":"u2","parentUuid":"a3","turnOrigin":"human","timestamp":"2026-11-08T01:00:08Z","message":{"role":"user","content":"second"}}
{"type":"assistant","uuid":"a4","parentUuid":"u2","requestId":"r4","timestamp":"2026-11-08T01:00:09Z","message":{"model":"m","role":"assistant","content":[{"type":"text","text":"final"}],"usage":{"input_tokens":1,"output_tokens":3}}}
`
	s, err := Parse(strings.NewReader(in))
	if err != nil {
		t.Fatal(err)
	}
	if len(s.Turns) != 3 || s.Totals.Turns != 2 || s.Totals.SystemTurns != 1 {
		t.Fatalf("turns = %d (human %d, system %d)", len(s.Turns), s.Totals.Turns, s.Totals.SystemTurns)
	}
	first := s.Turns[0]
	if first.Origin != "human" || first.Prompt == nil || first.Prompt.Text != "first" || len(first.Actions) != 2 || first.ToolCalls != 1 || first.Usage.OutputTokens != 7 {
		t.Fatalf("turn 0 = %+v", first)
	}
	if len(first.Compactions) != 1 || first.FinalText() != "done with the first" {
		t.Fatalf("turn 0 should own the compaction and end on its last text: %+v %q", first.Compactions, first.FinalText())
	}
	if s.Actions[0].Thinking() != "let me think" {
		t.Fatalf("thinking text = %q", s.Actions[0].Thinking())
	}
	sys := s.Turns[1]
	if sys.Origin != "task_notification" || sys.Prompt != nil || len(sys.Actions) != 1 || s.Totals.Prompts != 2 {
		t.Fatalf("task notification should open a system turn, not a prompt: %+v prompts=%d", sys, s.Totals.Prompts)
	}
	if s.Turns[2].Prompt.Text != "second" || s.Actions[3].Turn != 2 {
		t.Fatalf("turn 2 = %+v, action 3 turn = %d", s.Turns[2], s.Actions[3].Turn)
	}
}

func TestContextOf(t *testing.T) {
	s, err := Load(filepath.Join("..", "..", "internal", "testdata", "sessions", "synthetic-basics", "aaaaaaaa-0000-0000-0000-000000000001.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	cb, err := s.ContextOf(0, true)
	if err != nil || !cb.Available {
		t.Fatalf("context of action 0: %v available=%v reason=%q", err, cb.Available, cb.Reason)
	}
	if len(cb.System) != 2 || len(cb.Tools) != 2 || cb.Tools[0].Name != "Bash" || cb.Keep != 0 || len(cb.Messages) != 1 {
		t.Fatalf("breakdown = system %d tools %d keep %d messages %d", len(cb.System), len(cb.Tools), cb.Keep, len(cb.Messages))
	}
	if cb.Messages[0].Blocks[0].Label != "CLAUDE.md and user instructions" || !strings.Contains(cb.Messages[0].Blocks[0].Text, "CLAUDE.md") {
		t.Fatalf("CLAUDE.md block not recognised: %+v", cb.Messages[0].Blocks[0])
	}
	if len(cb.Attachments) != 1 || cb.Attachments[0].Type != "environment" || cb.ReportedTokens != 6002 || cb.EstimatedTokens == 0 {
		t.Fatalf("attachments=%+v reported=%d estimated=%d", cb.Attachments, cb.ReportedTokens, cb.EstimatedTokens)
	}
	if len(cb.CacheBreaks) != 1 || cb.CacheBreaks[0] != "system.1" {
		t.Fatalf("cache breaks = %v", cb.CacheBreaks)
	}
	cb1, _ := s.ContextOf(1, false)
	if cb1.Available || !strings.Contains(cb1.Reason, "no api-request record") {
		t.Fatalf("action 1 has no request record in the fixture: %+v", cb1)
	}
	if _, err := s.ContextOf(99, false); err == nil {
		t.Fatal("out of range must error")
	}
}
