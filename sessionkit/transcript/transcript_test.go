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

func TestCompactionOf(t *testing.T) {
	s, err := Load(filepath.Join("..", "..", "internal", "testdata", "sessions", "synthetic-basics", "aaaaaaaa-0000-0000-0000-000000000001.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	d, err := s.CompactionOf(0, true)
	if err != nil {
		t.Fatal(err)
	}
	if d.Trigger != "auto" || d.PreTokens != 6400 || d.PostTokens != 900 || d.Turn != 0 {
		t.Fatalf("metadata = %+v", d)
	}
	if d.LastActionBefore == nil || *d.LastActionBefore != 3 || d.FirstActionAfter == nil || *d.FirstActionAfter != 4 || d.ContextBefore != 6301 || d.ContextAfter != 903 {
		t.Fatalf("around: before=%v (%d) after=%v (%d)", d.LastActionBefore, d.ContextBefore, d.FirstActionAfter, d.ContextAfter)
	}
	if len(d.Summary.Sections) != 3 || d.Summary.Sections[0].Title != "Primary Request and Intent" || d.SummarisedPrompts != 1 || !strings.Contains(d.Summary.Text, "Pending Tasks") {
		t.Fatalf("summary = %+v", d.Summary)
	}
	if len(d.Preserved) != 2 || d.Preserved[0].Type != "assistant" || d.Preserved[0].Action != 3 || d.Preserved[1].Type != "user" || d.Preserved[1].Kind != "tool_result" {
		t.Fatalf("preserved = %+v", d.Preserved)
	}
	if len(d.Reinjected) != 2 || d.Reinjected[0].Type != "instructions" || len(d.FileRefs) != 1 || d.FileRefs[0] != "/Xxxxx/xxxx/xxxx/notes.md" {
		t.Fatalf("reinjected = %+v files = %v", d.Reinjected, d.FileRefs)
	}
	if _, err := s.CompactionOf(5, false); err == nil {
		t.Fatal("out of range must error")
	}
}

func TestRelationsOnBootstrapFixture(t *testing.T) {
	s, err := Load(filepath.Join("..", "..", "internal", "testdata", "sessions", "bootstrap-session", "36086585-e295-4279-a0c2-ef7b1901e080.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	rel := s.Relations()
	if len(rel.Spans) != len(s.Actions) {
		t.Fatalf("one span per action: %d spans, %d actions", len(rel.Spans), len(s.Actions))
	}
	for _, sp := range rel.Spans {
		if sp.GenEnd.Before(sp.At) || sp.ToolsEnd.Before(sp.GenEnd) || sp.End.Before(sp.At) {
			t.Fatalf("span %d is out of order: %+v", sp.Action, sp)
		}
	}
	if len(rel.Handbacks) != len(s.Subagents) {
		t.Fatalf("one hand-back per subagent: %d vs %d", len(rel.Handbacks), len(s.Subagents))
	}
	for _, h := range rel.Handbacks {
		if h.Action >= 0 && h.Action <= h.Spawn.Action {
			t.Fatalf("a hand-back lands after its spawn: %+v", h)
		}
	}
	for _, tk := range rel.Tasks {
		for _, p := range tk.Pickups {
			if p.At.Before(tk.Launch.At) {
				t.Fatalf("task %s read before launch", tk.ID)
			}
		}
	}
	for _, r := range rel.Retries {
		if r.Retry.Turn != r.Failed.Turn || !r.Retry.At.After(r.Failed.At) {
			t.Fatalf("a retry follows its failure in the same turn: %+v", r)
		}
	}
	if len(rel.Retries) == 0 || len(rel.Outside) == 0 {
		t.Fatalf("the bootstrap session has failed calls and web fetches: retries=%d outside=%d", len(rel.Retries), len(rel.Outside))
	}
	if got := len(s.Images()); got != s.Totals.Images {
		t.Fatalf("Images lists every counted image: %d vs %d", got, s.Totals.Images)
	}
	for _, a := range s.Actions {
		if !a.Synthetic && a.Cwd == "" {
			t.Fatalf("action %d has no cwd", a.Index)
		}
	}
}

func TestRelationsHeuristics(t *testing.T) {
	if !writesTo("cat > docs/a.md <<'EOF'", "docs/a.md") || !writesTo("sed -i '' s/x/y/ src/b.go", "src/b.go") || writesTo("cat docs/a.md", "docs/a.md") ||
		// The second mention is the one that writes; cp and mv write their destination, not their source.
		!writesTo("cat docs/a.md && echo x >> docs/a.md", "docs/a.md") || !writesTo("cp src/b.go docs/a.md", "docs/a.md") || writesTo("cp docs/a.md /tmp/x", "docs/a.md") ||
		!writesTo("ls | tee -a out/log.txt", "out/log.txt") || !writesTo("touch notes/n.md", "notes/n.md") {
		t.Fatal("writesTo: redirects and in-place edits write, cat reads")
	}
	if got := errorText(json.RawMessage(`{"status":529,"error":{"message":"Overloaded"}}`)); got != "529 Overloaded" {
		t.Fatalf("errorText = %q", got)
	}
	if got := errorText(json.RawMessage(`"plain"`)); got != "plain" {
		t.Fatalf("errorText = %q", got)
	}
}

// TestRelationsCommits: a commit is a `git commit` that did not fail. Its id
// comes from the output when the output names it.
func TestRelationsCommits(t *testing.T) {
	ref := CallRef{ToolID: "t1"}
	cases := []struct {
		name, cmd, out string
		want           []Commit
	}{
		{"git's own lines win", "git add -A && git commit -m 'First' && git commit --allow-empty -m 'Second'",
			"[main (root-commit) 2b4b1ec] First\n 2 files changed\n[main 93c045c1] Second: with [brackets] in it\n",
			[]Commit{{SHA: "2b4b1ec", Branch: "main", Subject: "First", Call: ref}, {SHA: "93c045c1", Branch: "main", Subject: "Second: with [brackets] in it", Call: ref}}},
		{"quiet, then the log line", `cd agent && git add -A && git commit -q -m "Session log: M9 \"started\"" && git log --oneline | head -1`,
			`666d121 Session log: M9 "started"`, []Commit{{SHA: "666d121", Subject: `Session log: M9 "started"`, Call: ref}}},
		{"quiet, nothing printed", `git -C ../agent commit -qam "Notes"`, "", []Commit{{Subject: "Notes", Call: ref}}},
		{"a heredoc message", "git commit -q -m \"$(cat <<'EOF'\nThe subject\n\nThe body.\nEOF\n)\"", "", []Commit{{Subject: "The subject", Call: ref}}},
		{"nothing to commit", "git commit -m 'Nothing'; echo done", "On branch main\nnothing to commit, working tree clean\ndone", nil},
		{"a dry run", "git commit --dry-run -m 'Later'", "", nil},
		{"words, not a command", "echo 'then run git commit -m x' && grep -n 'git commit' docs/a.md", "", nil},
		{"another git command", "git log --oneline | head -3", "2b4b1ec A commit\n93c045c Another", nil},
	}
	for _, c := range cases {
		got := commitsIn(c.cmd, c.out, ref)
		if len(got) != len(c.want) {
			t.Fatalf("%s: commits = %+v, want %+v", c.name, got, c.want)
		}
		for i := range got {
			if got[i] != c.want[i] {
				t.Fatalf("%s: commit %d = %+v, want %+v", c.name, i, got[i], c.want[i])
			}
		}
	}

	// Through a session: a commit whose call failed is not one.
	const in = `{"type":"user","uuid":"u1","turnOrigin":"human","timestamp":"2026-11-08T10:00:00Z","message":{"role":"user","content":"commit it"}}
{"type":"assistant","uuid":"a1","parentUuid":"u1","requestId":"r1","timestamp":"2026-11-08T10:00:01Z","message":{"model":"m","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"git commit -qm 'Kept'"}}],"usage":{"output_tokens":5}}}
{"type":"user","uuid":"res1","parentUuid":"a1","timestamp":"2026-11-08T10:00:02Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":""}]}}
{"type":"assistant","uuid":"a2","parentUuid":"res1","requestId":"r2","timestamp":"2026-11-08T10:00:03Z","message":{"model":"m","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"git commit -qm 'Denied'"}}],"usage":{"output_tokens":5}}}
{"type":"user","uuid":"res2","parentUuid":"a2","timestamp":"2026-11-08T10:00:04Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"Permission for this action was denied"}]}}
`
	s, err := Parse(strings.NewReader(in))
	if err != nil {
		t.Fatal(err)
	}
	if got := s.Relations().Commits; len(got) != 1 || got[0].Subject != "Kept" || got[0].Call.ToolID != "t1" {
		t.Fatalf("commits = %+v, want the one that did not fail", got)
	}
}

// TestRewoundBranch: the human rewinds past the second prompt and asks
// something else. The abandoned prompt and its reply stay on the timeline and
// in the totals, flagged; the parallel tool result that is off the chain
// without being abandoned is not flagged.
func TestRewoundBranch(t *testing.T) {
	const in = `{"type":"user","uuid":"u1","turnOrigin":"human","timestamp":"2026-11-08T10:00:00Z","message":{"role":"user","content":"first"}}
{"type":"assistant","uuid":"a1","parentUuid":"u1","requestId":"r1","timestamp":"2026-11-08T10:00:01Z","message":{"model":"m","content":[{"type":"tool_use","id":"t1","name":"Read","input":{}}],"usage":{"output_tokens":5}}}
{"type":"assistant","uuid":"a1b","parentUuid":"a1","requestId":"r1","timestamp":"2026-11-08T10:00:01Z","message":{"model":"m","content":[{"type":"tool_use","id":"t2","name":"Read","input":{}}],"usage":{"output_tokens":5}}}
{"type":"user","uuid":"res1","parentUuid":"a1","timestamp":"2026-11-08T10:00:02Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"one"}]}}
{"type":"user","uuid":"res2","parentUuid":"a1b","timestamp":"2026-11-08T10:00:02Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"two"}]}}
{"type":"assistant","uuid":"a2","parentUuid":"res2","requestId":"r2","timestamp":"2026-11-08T10:00:03Z","message":{"model":"m","content":[{"type":"text","text":"done"}],"usage":{"output_tokens":7}}}
{"type":"user","uuid":"u2","parentUuid":"a2","turnOrigin":"human","timestamp":"2026-11-08T10:01:00Z","message":{"role":"user","content":"the abandoned question"}}
{"type":"assistant","uuid":"a3","parentUuid":"u2","requestId":"r3","timestamp":"2026-11-08T10:01:01Z","message":{"model":"m","content":[{"type":"text","text":"the abandoned answer"}],"usage":{"output_tokens":11}}}
{"type":"user","uuid":"u3","parentUuid":"a2","turnOrigin":"human","timestamp":"2026-11-08T10:02:00Z","message":{"role":"user","content":"the question that stayed"}}
{"type":"last-prompt","leafUuid":"u3","lastPrompt":"the question that stayed"}
{"type":"assistant","uuid":"a4","parentUuid":"u3","requestId":"r4","timestamp":"2026-11-08T10:02:01Z","message":{"model":"m","content":[{"type":"text","text":"the answer that stayed"}],"usage":{"output_tokens":13}}}
`
	s, err := Parse(strings.NewReader(in))
	if err != nil {
		t.Fatal(err)
	}
	if s.Branches != 1 {
		t.Fatalf("branches = %d, want 1", s.Branches)
	}
	var flagged []string
	for _, p := range s.Prompts {
		if p.Rewound {
			flagged = append(flagged, "prompt:"+p.UUID)
		}
	}
	for _, a := range s.Actions {
		if a.Rewound {
			flagged = append(flagged, "action:"+a.RequestID)
		}
	}
	if got := strings.Join(flagged, " "); got != "prompt:u2 action:r3" {
		t.Fatalf("rewound = %q, want only the abandoned prompt and its reply (the reply written after the stale tip and the parallel tool result are not rewound)", got)
	}
	if !s.Turns[1].Rewound || s.Turns[0].Rewound || s.Turns[2].Rewound {
		t.Fatalf("turn flags = %v %v %v", s.Turns[0].Rewound, s.Turns[1].Rewound, s.Turns[2].Rewound)
	}
	tot := s.Totals
	if tot.RewoundTurns != 1 || tot.RewoundActions != 1 || tot.RewoundUsage.OutputTokens != 11 {
		t.Fatalf("rewound totals = %d turns, %d actions, %d output tokens", tot.RewoundTurns, tot.RewoundActions, tot.RewoundUsage.OutputTokens)
	}
	// Everything else still counts the abandoned work: it was done and paid for.
	if tot.Turns != 3 || tot.Requests != 4 || tot.Usage.OutputTokens != 5+7+11+13 {
		t.Fatalf("totals must include rewound work: turns=%d requests=%d out=%d", tot.Turns, tot.Requests, tot.Usage.OutputTokens)
	}
}

// TestLastLineWithoutNewline: a whole JSON value at the end of the file is a
// record even when its newline is missing; only an unfinished value is partial.
func TestLastLineWithoutNewline(t *testing.T) {
	in := "{\"type\":\"user\",\"uuid\":\"a\"}\n{\"type\":\"assistant\",\"uuid\":\"b\",\"parentUuid\":\"a\"}"
	recs, err := ReadAll(strings.NewReader(in))
	if err != nil || len(recs) != 2 || recs[1].UUID != "b" || recs[1].Offset != int64(strings.LastIndex(in, "{")) {
		t.Fatalf("records=%d err=%v", len(recs), err)
	}
	if _, err := ReadAll(strings.NewReader(in + "\n  \n")); err != nil {
		t.Fatalf("trailing blank lines are the end, not a partial line: %v", err)
	}
	s, err := Parse(strings.NewReader(in))
	if err != nil || s.Partial || s.Totals.Records != 2 {
		t.Fatalf("partial=%v records=%d err=%v", s.Partial, s.Totals.Records, err)
	}
}

// TestDocumentListsAndResultHeads: the session document a client reads has no
// null where a list belongs, and every answered tool call says what came back.
func TestDocumentListsAndResultHeads(t *testing.T) {
	s, err := Load(filepath.Join("..", "..", "internal", "testdata", "sessions", "synthetic-basics", "aaaaaaaa-0000-0000-0000-000000000001.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	heads := 0
	for _, c := range s.ToolCalls {
		if !c.Paired && (c.ResultHead != "" || c.ResultBytes != 0) {
			t.Fatalf("an unanswered tool call has no result to describe: %s head=%q bytes=%d", c.ID, c.ResultHead, c.ResultBytes)
		}
		if c.ResultHead != "" {
			heads++
			if strings.Contains(c.ResultHead, "\n") || len([]rune(c.ResultHead)) > maxResultHead {
				t.Fatalf("a result head is one short line: %q", c.ResultHead)
			}
		}
	}
	if heads == 0 {
		t.Fatal("the fixture's answered tool calls should carry a result head")
	}
	if got := headLine("\n\n   first   real\tline  \nsecond", 200); got != "first real line" {
		t.Fatalf("headLine = %q", got)
	}
	if got := headLine(strings.Repeat("é", 300), 10); got != strings.Repeat("é", 9)+"…" {
		t.Fatalf("headLine must cut on runes: %q", got)
	}

	for name, in := range map[string]string{
		"unused session":        `{"type":"queue-operation","sessionId":"e","timestamp":"2026-11-08T10:00:00Z"}` + "\n",
		"prompt with no answer": `{"type":"user","uuid":"u1","turnOrigin":"human","timestamp":"2026-11-08T10:00:00Z","message":{"role":"user","content":"hi"}}` + "\n",
		"assistant with no blocks": `{"type":"user","uuid":"u1","turnOrigin":"human","timestamp":"2026-11-08T10:00:00Z","message":{"role":"user","content":"hi"}}` + "\n" +
			`{"type":"assistant","uuid":"a1","parentUuid":"u1","requestId":"r1","timestamp":"2026-11-08T10:00:01Z","message":{"model":"m","content":[]}}` + "\n",
	} {
		s, err := Parse(strings.NewReader(in))
		if err != nil {
			t.Fatal(err)
		}
		b, _ := json.Marshal(s)
		for _, key := range []string{"prompts", "turns", "actions", "tool_calls", "compactions", "blocks"} {
			if strings.Contains(string(b), `"`+key+`":null`) {
				t.Fatalf("%s: %q must be a list, never null: %s", name, key, b)
			}
		}
	}
}

// TestResolvePath: where a path a session wrote is on disk.
func TestResolvePath(t *testing.T) {
	cases := []struct{ raw, cwd, command, want string }{
		{"/a/b/../c.go", "/Users/me/work", "", "/a/c.go"},
		{"docs/plan.md", "/Users/me/work", "", "/Users/me/work/docs/plan.md"},
		{"./docs/plan.md", "/Users/me/work", "", "/Users/me/work/docs/plan.md"},
		{"~/notes/x.md", "/Users/me/work/deep", "", "/Users/me/notes/x.md"},
		// The command went somewhere else before it named the file.
		{"sessions/x.md", "/Users/me/work", "cd /Users/me/agent && cat > sessions/x.md <<'EOF'", "/Users/me/agent/sessions/x.md"},
		{"sessions/x.md", "/Users/me/work", "cd agent && git add -A; cat sessions/x.md", "/Users/me/work/agent/sessions/x.md"},
		{"x.md", "/Users/me/work", "cd a && cd ../b && cat x.md", "/Users/me/work/b/x.md"},
		// A cd after the file is named does not move it; a cd to a variable is not followed.
		{"x.md", "/Users/me/work", "cat x.md && cd /tmp", "/Users/me/work/x.md"},
		{"x.md", "/Users/me/work", `cd "$ROOT" && cat x.md`, "/Users/me/work/x.md"},
		// Nothing to resolve against.
		{"x.md", "", "", ""},
		{"~/x.md", "/srv/app", "", ""},
	}
	for _, c := range cases {
		if got := resolvePath(c.raw, c.cwd, c.command); got != c.want {
			t.Errorf("resolvePath(%q, %q, %q) = %q, want %q", c.raw, c.cwd, c.command, got, c.want)
		}
	}
}

// What a transcript says is not trusted to name a file: only a result that
// opens as Claude Code's own spill does, and only a file in a tool-results directory.
func TestSpilledPathIsNotAnyPath(t *testing.T) {
	dir := t.TempDir()
	secret := filepath.Join(dir, "id_rsa")
	os.WriteFile(secret, []byte("PRIVATE"), 0o600)
	os.MkdirAll(filepath.Join(dir, "elsewhere", "tool-results"), 0o700)
	real := filepath.Join(dir, "elsewhere", "tool-results", "toolu_9.txt")
	os.WriteFile(real, []byte(strings.Repeat("é", 10)), 0o600)
	os.Symlink(secret, filepath.Join(dir, "elsewhere", "tool-results", "link.txt"))

	// A result that only quotes the sentence is not a spill.
	if got := spilledPath(nil, "grep found: Full output saved to: "+secret); got != "" {
		t.Fatalf("a quoted marker became a path: %q", got)
	}
	if got := spilledPath(nil, "<persisted-output>\nOutput too large (1MB). Full output saved to: "+real+"\n\nPreview"); got != real {
		t.Fatalf("a real spill's path = %q, want %q", got, real)
	}
	s := &Session{ID: "s", Path: filepath.Join(dir, "s.jsonl")}
	for _, path := range []string{secret, "/dev/zero", filepath.Join(dir, "elsewhere", "tool-results", "link.txt"), "tool-results/relative.txt", dir} {
		if p, ok := s.SpilledPath(&ToolCall{Spilled: path}); ok {
			t.Errorf("SpilledPath accepted %q as %q", path, p)
		}
		if text, _, _, ok := s.SpilledText(&ToolCall{Spilled: path}); ok || text != "" {
			t.Errorf("SpilledText read %q", path)
		}
	}
	text, p, cut, ok := s.SpilledText(&ToolCall{Spilled: real})
	if !ok || p != real || cut || text != strings.Repeat("é", 10) {
		t.Fatalf("a spill in a tool-results directory: %q %q %v %v", text, p, cut, ok)
	}
}

// Claude Code 2.1.263 and 2.1.267 wrote who started a turn in origin.kind and
// left turnOrigin out. Those prompts are prompts.
func TestPromptsAreReadFromOriginWhenTurnOriginIsAbsent(t *testing.T) {
	in := `{"type":"user","uuid":"u1","origin":{"kind":"human"},"promptSource":"typed","timestamp":"2026-11-08T01:00:00Z","message":{"role":"user","content":"first"}}
{"type":"assistant","uuid":"a1","parentUuid":"u1","requestId":"r1","timestamp":"2026-11-08T01:00:01Z","message":{"model":"m","role":"assistant","content":[{"type":"text","text":"one"}],"usage":{"input_tokens":1,"output_tokens":1}}}
{"type":"user","uuid":"n1","parentUuid":"a1","origin":{"kind":"task-notification"},"timestamp":"2026-11-08T01:00:02Z","message":{"role":"user","content":"<task-notification>done</task-notification>"}}
{"type":"assistant","uuid":"a2","parentUuid":"n1","requestId":"r2","timestamp":"2026-11-08T01:00:03Z","message":{"model":"m","role":"assistant","content":[{"type":"text","text":"noted"}],"usage":{"input_tokens":1,"output_tokens":1}}}
{"type":"user","uuid":"u2","parentUuid":"a2","turnOrigin":"human","origin":{"kind":"human"},"timestamp":"2026-11-08T01:00:04Z","message":{"role":"user","content":"second"}}
{"type":"assistant","uuid":"a3","parentUuid":"u2","requestId":"r3","timestamp":"2026-11-08T01:00:05Z","message":{"model":"m","role":"assistant","content":[{"type":"text","text":"two"}],"usage":{"input_tokens":1,"output_tokens":1}}}
{"type":"user","uuid":"c1","parentUuid":"a3","timestamp":"2026-11-08T01:00:06Z","message":{"role":"user","content":"<local-command-stdout>ok</local-command-stdout>"}}
{"type":"user","uuid":"m1","parentUuid":"c1","isMeta":true,"origin":"human","timestamp":"2026-11-08T01:00:07Z","message":{"role":"user","content":"injected"}}
`
	s, err := Parse(strings.NewReader(in))
	if err != nil {
		t.Fatal(err)
	}
	if s.Totals.Prompts != 2 || len(s.Prompts) != 2 || s.Prompts[0].Text != "first" || s.Prompts[1].Text != "second" {
		t.Fatalf("prompts = %d %+v, want first and second", s.Totals.Prompts, s.Prompts)
	}
	if len(s.Turns) != 3 || s.Turns[0].Origin != "human" || s.Turns[1].Origin != "task_notification" || s.Turns[2].Origin != "human" {
		t.Fatalf("turns = %d, want human, task_notification, human", len(s.Turns))
	}
	if len(s.Turns[2].Actions) != 1 {
		t.Fatalf("a record with neither field, and a meta record, open no turn: %+v", s.Turns[2])
	}
}

// A field of a type this parser does not expect costs that field, not the record.
func TestRecordsSurviveAFieldOfAnotherType(t *testing.T) {
	in := `{"type":"user","uuid":"u1","turnOrigin":"human","imagePasteIds":"one,two","timestamp":"2026-11-08T01:00:00Z","message":{"role":"user","content":"look at this"}}
{"type":"assistant","uuid":"a1","parentUuid":"u1","requestId":"r1","timestamp":"2026-11-08T01:00:01Z","message":{"model":"m","role":"assistant","content":[{"type":"web_search_tool_result","tool_use_id":"srv_1","content":{"type":"web_search_tool_result_error","error_code":"unavailable"}},{"type":"search_result","source":"https://example.com","text":"a page"},"a bare string",{"type":"text","text":"answer"}],"usage":{"input_tokens":3,"output_tokens":500,"cache_creation":"none"}}}
{"type":"user","uuid":"u2","parentUuid":"a1","turnOrigin":"human","cwd":17,"timestamp":"2026-11-08T01:00:02Z","message":{"role":"user","content":"again"}}
not json at all
`
	s, err := Parse(strings.NewReader(in))
	if err != nil {
		t.Fatal(err)
	}
	if s.Totals.Malformed != 1 || s.Totals.Mismatched != 2 {
		t.Fatalf("malformed %d mismatched %d, want 1 and 2 (the blocks are read by their own rules)", s.Totals.Malformed, s.Totals.Mismatched)
	}
	if s.Totals.Prompts != 2 || s.Totals.Requests != 1 || s.Totals.Usage.OutputTokens != 500 {
		t.Fatalf("prompts %d requests %d output %d: nothing but the odd fields is lost", s.Totals.Prompts, s.Totals.Requests, s.Totals.Usage.OutputTokens)
	}
	blocks := s.Actions[0].Records[0].Message.Content
	if len(blocks) != 4 || blocks[0].Type != "web_search_tool_result" || len(blocks[0].Content) != 1 || blocks[0].Content[0].Type != "web_search_tool_result_error" ||
		blocks[1].Text != "a page" || blocks[1].Source != nil || blocks[2].Text != "a bare string" || blocks[3].Text != "answer" {
		t.Fatalf("blocks = %+v", blocks)
	}
}

// The images a subagent read are listed with the session's own, so the list
// is as long as the count beside it (which has always added the subagents').
func TestImagesIncludeTheSubagents(t *testing.T) {
	parent, err := Parse(strings.NewReader(`{"type":"user","uuid":"u1","turnOrigin":"human","timestamp":"2026-11-08T01:00:00Z","message":{"role":"user","content":"start"}}
{"type":"assistant","uuid":"a1","parentUuid":"u1","requestId":"r1","timestamp":"2026-11-08T01:00:01Z","message":{"model":"m","role":"assistant","content":[{"type":"text","text":"ok"}],"usage":{"input_tokens":1,"output_tokens":1}}}
{"type":"user","uuid":"u2","parentUuid":"a1","turnOrigin":"human","timestamp":"2026-11-08T01:00:02Z","message":{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"UEFSRU5U"}},{"type":"text","text":"look"}]}}
{"type":"assistant","uuid":"a2","parentUuid":"u2","requestId":"r2","timestamp":"2026-11-08T01:00:03Z","message":{"model":"m","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Agent","input":{}}],"usage":{"input_tokens":1,"output_tokens":1}}}
{"type":"user","uuid":"r1","parentUuid":"a2","timestamp":"2026-11-08T01:00:09Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"done"}]}}
`))
	if err != nil {
		t.Fatal(err)
	}
	child, err := Parse(strings.NewReader(`{"type":"user","uuid":"c1","timestamp":"2026-11-08T01:00:04Z","message":{"role":"user","content":"look at the icon"}}
{"type":"assistant","uuid":"c2","parentUuid":"c1","requestId":"q1","timestamp":"2026-11-08T01:00:05Z","message":{"model":"m","role":"assistant","content":[{"type":"tool_use","id":"t9","name":"Read","input":{}}],"usage":{"input_tokens":1,"output_tokens":1}}}
{"type":"user","uuid":"c3","parentUuid":"c2","timestamp":"2026-11-08T01:00:06Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t9","content":[{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"Q0hJTEQ="}}]}]}}
`))
	if err != nil {
		t.Fatal(err)
	}
	parent.AttachSubagent(&Subagent{AgentID: "abc", ToolUseID: "t1", Session: child})

	imgs := parent.Images()
	if len(imgs) != parent.Totals.Images+child.Totals.Images || len(imgs) != 2 {
		t.Fatalf("%d images listed, %d + %d counted", len(imgs), parent.Totals.Images, child.Totals.Images)
	}
	if imgs[0].Agent != "" || imgs[0].Where != "prompt" || imgs[0].Turn != 1 || imgs[0].Index != 0 {
		t.Fatalf("the session's own image: %+v", imgs[0])
	}
	if imgs[1].Agent != "abc" || imgs[1].Where != "tool_result" || imgs[1].ToolID != "t9" || imgs[1].Turn != 1 || imgs[1].Index != 1 || imgs[1].MediaType != "image/jpeg" {
		t.Fatalf("the subagent's image, in the turn that started it: %+v", imgs[1])
	}
	if mt, data, err := parent.ImageData(1); err != nil || mt != "image/jpeg" || data != "Q0hJTEQ=" {
		t.Fatalf("the subagent's image by its index: %q %q %v", mt, data, err)
	}
	if _, _, err := parent.ImageData(2); err == nil {
		t.Fatal("there is no third image")
	}
}
