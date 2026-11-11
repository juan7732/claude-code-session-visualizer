package transcript

import (
	"strings"
	"testing"
)

// The shapes are the ones Claude Code 2.1.x writes, cut down (measured 2026-11-10).
const primitivesTranscript = `{"type":"attachment","uuid":"at1","timestamp":"2026-11-07T23:50:00.000Z","attachment":{"type":"skill_listing","names":["cruise","anthropic-skills:pdf","init"],"isInitial":true}}
{"type":"attachment","uuid":"at2","timestamp":"2026-11-07T23:50:00.000Z","attachment":{"type":"agent_listing_delta","addedTypes":["Explore","reviewer"],"builtInTypes":["Explore"]}}
{"type":"attachment","uuid":"at3","timestamp":"2026-11-07T23:50:00.000Z","attachment":{"type":"deferred_tools_delta","addedNames":["CronCreate","mcp__claude_ai_Gmail__send"],"surfacedNames":[]}}
{"type":"attachment","uuid":"at4","timestamp":"2026-11-07T23:50:00.000Z","attachment":{"type":"mcp_instructions_delta","addedNames":["claude.ai Claude Docs"]}}
{"type":"attachment","uuid":"at5","timestamp":"2026-11-07T23:50:00.000Z","attachment":{"type":"instructions","files":[{"path":"/w/CLAUDE.md","type":"Project","content":"SECRET"},{"path":"/h/.claude/projects/-w/memory/MEMORY.md","type":"AutoMem","content":"SECRET"}]}}
{"type":"user","uuid":"u1","turnOrigin":"human","timestamp":"2026-11-07T23:59:00.000Z","message":{"role":"user","content":"<command-message>cruise</command-message>\n<command-name>/cruise</command-name>\n<command-args>go</command-args>"}}
{"type":"user","uuid":"u1m","parentUuid":"u1","isMeta":true,"timestamp":"2026-11-07T23:59:00.100Z","message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /w/skills/.claude/skills/cruise\n\n# Cruise"}]}}
{"type":"assistant","uuid":"a1","parentUuid":"u1m","requestId":"req_1","timestamp":"2026-11-07T23:59:05.000Z","message":{"id":"msg_1","model":"m","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Skill","input":{"skill":"anthropic-skills:pdf"}},{"type":"tool_use","id":"t2","name":"mcp__claude_ai_Gmail__send","input":{}},{"type":"tool_use","id":"t3","name":"Agent","input":{"subagent_type":"Explore","description":"look"}},{"type":"tool_use","id":"t4","name":"Agent","input":{"description":"untyped"}},{"type":"tool_use","id":"t5","name":"Read","input":{"file_path":"/h/.claude/projects/-w/memory/a-note.md"}},{"type":"tool_use","id":"t6","name":"Read","input":{"file_path":"/w/docs/memory/notes.md"}}],"usage":{"input_tokens":1,"output_tokens":2}}}
{"type":"user","uuid":"r1","parentUuid":"a1","timestamp":"2026-11-07T23:59:06.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"Launching skill"}]}}
{"type":"user","uuid":"r1m","parentUuid":"r1","isMeta":true,"sourceToolUseID":"t1","timestamp":"2026-11-07T23:59:06.100Z","message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /h/.claude/skills/synced/b/pdf\n\n# PDF"}]}}
{"type":"user","uuid":"r2","parentUuid":"r1m","timestamp":"2026-11-07T23:59:09.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"no"}]}}
{"type":"user","uuid":"r3","parentUuid":"r2","timestamp":"2026-11-07T23:59:35.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","content":"found"}]}}
{"type":"user","uuid":"r4","parentUuid":"r3","timestamp":"2026-11-07T23:59:45.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t4","content":"done"}]}}
{"type":"attachment","uuid":"at6","parentUuid":"r4","timestamp":"2026-11-07T23:59:46.000Z","attachment":{"type":"hook_additional_context","hookName":"PostToolUse:Edit","hookEvent":"PostToolUse","content":["x"]}}
{"type":"attachment","uuid":"at7","parentUuid":"r4","timestamp":"2026-11-07T23:59:47.000Z","attachment":{"type":"nested_memory","path":"/w/sub/CLAUDE.md","content":{"type":"Project","content":"SECRET"}}}
{"type":"user","uuid":"u2","timestamp":"2026-11-08T00:10:00.000Z","message":{"role":"user","content":"<command-name>/model</command-name>\n<command-message>model</command-message>"}}
{"type":"user","uuid":"u3","turnOrigin":"human","timestamp":"2026-11-08T00:11:00.000Z","message":{"role":"user","content":"how does <command-name>/init</command-name> show in a transcript?"}}
{"type":"user","uuid":"u4","isCompactSummary":true,"timestamp":"2026-11-08T00:12:00.000Z","message":{"role":"user","content":"<command-name>/cruise</command-name> was run earlier"}}
{"type":"user","uuid":"u5","turnOrigin":"human","timestamp":"2026-11-08T00:13:00.000Z","message":{"role":"user","content":"<command-message>cruise</command-message>\n<command-name>/cruise</command-name>"}}
`

func TestPrimitivesOf(t *testing.T) {
	s, err := Parse(strings.NewReader(primitivesTranscript))
	if err != nil {
		t.Fatal(err)
	}
	p := PrimitivesOf(s)
	use := map[string]PrimitiveUse{}
	for _, u := range p.Uses {
		use[u.Kind+" "+u.Name+" "+u.Day] = u
	}
	// A typed skill: no tool call, known by the skill's text that followed it.
	c := use["skill cruise 2026-11-07"]
	if c.Calls != 1 || c.ByUser != 1 || c.Path != "/w/skills/.claude/skills/cruise" || c.Turn != 0 {
		t.Errorf("typed skill: %+v", c)
	}
	// The same skill on the next UTC day is its own row; known by the listing alone.
	if c := use["skill cruise 2026-11-08"]; c.Calls != 1 || c.ByUser != 1 {
		t.Errorf("typed skill, second day: %+v", c)
	}
	if u := use["skill anthropic-skills:pdf 2026-11-07"]; u.Calls != 1 || u.ByUser != 0 || u.Path != "/h/.claude/skills/synced/b/pdf" {
		t.Errorf("model's skill: %+v", u)
	}
	if u := use["connector claude_ai_Gmail 2026-11-07"]; u.Calls != 1 || u.Errors != 1 || u.Seconds != 4 {
		t.Errorf("connector: %+v", u)
	}
	if u := use["agent Explore 2026-11-07"]; u.Calls != 1 || u.Seconds != 30 {
		t.Errorf("agent: %+v", u)
	}
	if u := use["agent general-purpose 2026-11-07"]; u.Calls != 1 {
		t.Errorf("an Agent call without a type is general-purpose: %+v", u)
	}
	if u := use["command model 2026-11-08"]; u.Calls != 1 || u.ByUser != 1 {
		t.Errorf("Claude Code's own command: %+v", u)
	}
	if _, quoted := use["skill init 2026-11-08"]; quoted {
		t.Error("a prompt that quotes a command tag is not a command")
	}
	if u := use["hook PostToolUse:Edit 2026-11-07"]; u.Calls != 1 {
		t.Errorf("hook: %+v", u)
	}
	if use["instructions /w/CLAUDE.md 2026-11-07"].Calls != 1 || use["instructions /w/sub/CLAUDE.md 2026-11-07"].Calls != 1 ||
		use["memory /h/.claude/projects/-w/memory/MEMORY.md 2026-11-07"].Calls != 1 {
		t.Errorf("memory files loaded: %+v", p.Uses)
	}
	// A note of Claude Code's memory read back is a use of it; any other file named memory is not.
	if u := use["memory /h/.claude/projects/-w/memory/a-note.md 2026-11-07"]; u.Calls != 1 {
		t.Errorf("a memory note read back: %+v", u)
	}
	if len(p.Uses) != 12 {
		t.Errorf("uses = %d, want 12: %+v", len(p.Uses), p.Uses)
	}
	offered := map[string]PrimitiveOffer{}
	for _, o := range p.Offered {
		offered[o.Kind+" "+o.Name] = o
	}
	for _, want := range []string{"skill cruise", "skill anthropic-skills:pdf", "skill init", "agent Explore", "agent reviewer", "connector claude_ai_Gmail", "connector claude_ai_Claude_Docs"} {
		if _, ok := offered[want]; !ok {
			t.Errorf("not offered: %s (%+v)", want, p.Offered)
		}
	}
	if !offered["agent Explore"].BuiltIn || offered["agent reviewer"].BuiltIn {
		t.Errorf("built-in agents: %+v", p.Offered)
	}
	if len(p.Offered) != 7 {
		t.Errorf("offered = %d, want 7", len(p.Offered))
	}
}
