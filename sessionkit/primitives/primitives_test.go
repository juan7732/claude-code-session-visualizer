package primitives

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/store"
)

func write(t *testing.T, path, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

// machine lays out a home with a user folder, an account's synced skills, a
// plugin, a managed folder and a workspace with a nested repository.
func machine(t *testing.T) (p Places, work string) {
	dir := t.TempDir()
	claude := filepath.Join(dir, "home", ".claude")
	work = filepath.Join(dir, "home", "work")
	managed := filepath.Join(dir, "managed")
	plugin := filepath.Join(claude, "plugins", "cache", "market", "tidy", "1.2.0")

	write(t, filepath.Join(claude, "skills", "deploy", "SKILL.md"), "---\nname: deploy\ndescription: >\n  Ship it,\n  carefully.\n---\nbody")
	write(t, filepath.Join(claude, "skills", "synced", "bucket", "pdf", "SKILL.md"), "---\nname: pdf\ndescription: \"PDF things\"\n---\n")
	write(t, filepath.Join(claude, "skills", "synced", "bucket", "manifest.json"), "{}")
	write(t, filepath.Join(claude, "agents", "reviewer.md"), "---\nname: reviewer\ndescription: The user's reviewer\n---\n")
	write(t, filepath.Join(claude, "commands", "git", "sync.md"), "Sync it")
	write(t, filepath.Join(claude, "CLAUDE.md"), "SECRET-NOTE user instructions")
	write(t, filepath.Join(claude, "rules", "style.md"), "SECRET-NOTE a rule")
	write(t, filepath.Join(claude, "projects", "-home-work", "memory", "MEMORY.md"), "---\ndescription: SECRET-NOTE\n---\nSECRET-NOTE")
	write(t, filepath.Join(claude, "settings.json"), `{"enabledPlugins":{"tidy@market":true},
		"hooks":{"PostToolUse":[{"matcher":"Edit|Write","hooks":[{"type":"command","command":"gofmt -w ."}]}],"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}`)
	write(t, claude+".json", `{"mcpServers":{"notes":{"command":"/opt/bin/notes-mcp","args":["--token","SECRET-TOKEN"],"env":{"KEY":"SECRET-TOKEN"}},
		"shared":{"type":"sse","url":"https://user.example.com/sse?key=SECRET-TOKEN"}},
		"claudeAiMcpEverConnected":["claude.ai Gmail"],
		"skillUsage":{"deploy":{"usageCount":9,"lastUsedAt":1794000000000},"gone":{"usageCount":2,"lastUsedAt":1}},
		"projects":{"`+work+`":{"mcpServers":{"shared":{"command":"local-shared","headers":{"Authorization":"SECRET-TOKEN"}}}}},
		"oauthAccount":{"emailAddress":"SECRET-TOKEN"}}`)

	write(t, filepath.Join(claude, "plugins", "installed_plugins.json"), `{"version":2,"plugins":{"tidy@market":[{"scope":"user","installPath":"`+plugin+`","version":"1.2.0"}],
		"missing@market":[{"scope":"user","installPath":"`+filepath.Join(dir, "nowhere")+`"}]}}`)
	write(t, filepath.Join(plugin, ".claude-plugin", "plugin.json"), `{"name":"tidy","description":"Keeps things tidy"}`)
	write(t, filepath.Join(plugin, "skills", "sweep", "SKILL.md"), "---\ndescription: Sweep up\n---\n")
	write(t, filepath.Join(plugin, "agents", "review", "security.md"), "---\nname: sec\ndescription: Security review\n---\n")
	write(t, filepath.Join(plugin, "commands", "db", "migrate.md"), "Migrate")
	write(t, filepath.Join(plugin, "hooks", "hooks.json"), `{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"tidy start"}]}]}}`)
	write(t, filepath.Join(plugin, ".mcp.json"), `{"mcpServers":{"db":{"command":"tidy-db"}}}`)

	write(t, filepath.Join(managed, ".claude", "skills", "deploy", "SKILL.md"), "---\ndescription: The organisation's deploy\n---\n")
	write(t, filepath.Join(managed, "CLAUDE.md"), "SECRET-NOTE managed")

	write(t, filepath.Join(work, "CLAUDE.md"), "SECRET-NOTE workspace")
	write(t, filepath.Join(work, ".mcp.json"), `{"mcpServers":{"shared":{"type":"http","url":"https://project.example.com/mcp"}}}`)
	write(t, filepath.Join(work, "repo", ".claude", "skills", "deploy", "SKILL.md"), "---\ndescription: The repository's deploy\n---\n")
	write(t, filepath.Join(work, "repo", ".claude", "agents", "reviewer.md"), "---\nname: reviewer\ndescription: The repository's reviewer\n---\n")
	write(t, filepath.Join(work, "repo", ".claude", "commands", "deploy.md"), "A command of the same name as a skill")
	write(t, filepath.Join(work, "repo", ".claude", "settings.local.json"), `{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"check"}]}]}}`)
	write(t, filepath.Join(work, "repo", "CLAUDE.local.md"), "SECRET-NOTE local")
	write(t, filepath.Join(work, "a", "b", "c", ".claude", "skills", "too-deep", "SKILL.md"), "---\n---\n")
	write(t, filepath.Join(work, "node_modules", "pkg", ".claude", "skills", "vendored", "SKILL.md"), "---\n---\n")
	return Places{ClaudeDir: claude, Managed: managed, Dirs: []string{work}}, work
}

func itemsOf(rep *Report) map[string]Item {
	out := map[string]Item{}
	for _, it := range rep.Items {
		out[it.Kind+" "+it.Name] = it
	}
	return out
}

func scopes(it Item) string {
	var s []string
	for _, d := range it.Definitions {
		s = append(s, d.Scope)
	}
	return strings.Join(s, ",")
}

func TestInventory(t *testing.T) {
	p, work := machine(t)
	g := readGlobal(p.ClaudeDir)
	defs, looked := discover(p, g)
	rep := build(defs, looked, g, nil, nil, 0, Options{})
	items := itemsOf(rep)

	// A name defined three times, in the order Claude Code prefers for a skill.
	deploy := items["skill deploy"]
	if scopes(deploy) != "managed,user,project" || deploy.Order != "user-first" || deploy.Description != "The organisation's deploy" {
		t.Errorf("skill deploy: %s %s %q", scopes(deploy), deploy.Order, deploy.Description)
	}
	if d := deploy.Definitions[1]; d.Description != "Ship it, carefully." || d.Bytes == 0 || d.Modified == nil {
		t.Errorf("a folded description: %+v", d)
	}
	if d := deploy.Definitions[2]; d.Where != filepath.Join(work, "repo") {
		t.Errorf("a nested repository's skill belongs to that repository: %+v", d)
	}
	if c := deploy.Counter; c == nil || c.Uses != 9 || c.LastUsedAt == nil {
		t.Errorf("Claude Code's counter: %+v", c)
	}
	// For an agent the project's definition comes before the user's.
	if r := items["agent reviewer"]; scopes(r) != "project,user" || r.Order != "project-first" || r.Description != "The repository's reviewer" {
		t.Errorf("agent reviewer: %s %s %q", scopes(r), r.Order, r.Description)
	}
	// A connector: local, then project, then user; the key is the name as tools carry it.
	shared := items["connector shared"]
	if scopes(shared) != "local,project,user" || shared.Order != "local-first" {
		t.Errorf("connector shared: %s %s", scopes(shared), shared.Order)
	}
	if d := shared.Definitions[1]; d.Detail["transport"] != "http" || d.Detail["host"] != "project.example.com" {
		t.Errorf("a connector says how it is reached: %+v", d.Detail)
	}
	if d := items["connector notes"].Definitions[0]; d.Detail["transport"] != "stdio" || d.Detail["program"] != "notes-mcp" {
		t.Errorf("a stdio connector: %+v", d.Detail)
	}
	if g := items["connector claude_ai_Gmail"]; g.Title != "claude.ai Gmail" || scopes(g) != "account" {
		t.Errorf("an account's connector: %+v", g)
	}

	for name, want := range map[string]string{
		"skill anthropic-skills:pdf": "account", "skill tidy:sweep": "plugin", "agent tidy:review:sec": "plugin",
		"command tidy:db:migrate": "plugin", "command git:sync": "user", "command deploy": "project",
		"connector plugin_tidy_db": "plugin", "plugin tidy": "plugin",
		"hook PostToolUse:Edit|Write": "user", "hook Stop": "user", "hook PreToolUse:Bash": "local", "hook SessionStart": "plugin",
		"instructions " + filepath.Join(p.ClaudeDir, "CLAUDE.md"):                               "user",
		"instructions " + filepath.Join(p.ClaudeDir, "rules", "style.md"):                       "user",
		"instructions " + filepath.Join(p.Managed, "CLAUDE.md"):                                 "managed",
		"instructions " + filepath.Join(work, "CLAUDE.md"):                                      "project",
		"instructions " + filepath.Join(work, "repo", "CLAUDE.local.md"):                        "local",
		"memory " + filepath.Join(p.ClaudeDir, "projects", "-home-work", "memory", "MEMORY.md"): "project",
	} {
		it, ok := items[name]
		if !ok || scopes(it) != want || !it.Installed {
			t.Errorf("%s: scopes %q, want %q (found %v)", name, scopes(it), want, ok)
		}
	}
	if pl := items["plugin tidy"].Definitions[0]; pl.Detail["version"] != "1.2.0" || pl.Detail["enabled"] != "yes" || pl.Description != "Keeps things tidy" {
		t.Errorf("plugin: %+v", pl)
	}
	if h := items["hook PostToolUse:Edit|Write"].Definitions[0]; h.Detail["event"] != "PostToolUse" || h.Detail["command"] != "gofmt -w ." {
		t.Errorf("hook: %+v", h.Detail)
	}
	// Claude Code counted a skill that is nowhere any more.
	if gone := items["skill gone"]; gone.Installed || gone.Counter == nil || gone.Counter.Uses != 2 {
		t.Errorf("a skill only the counter knows: %+v", gone)
	}
	for name := range items {
		if strings.Contains(name, "too-deep") || strings.Contains(name, "vendored") || strings.Contains(name, "missing") {
			t.Errorf("found what should not be looked for: %s", name)
		}
	}

	// Nothing a memory file says, and nothing a connector is given to
	// authenticate with, leaves the machine's disk.
	b, _ := json.Marshal(rep)
	for _, secret := range []string{"SECRET-NOTE", "SECRET-TOKEN"} {
		if strings.Contains(string(b), secret) {
			t.Errorf("the report carries %s", secret)
		}
	}
	if !strings.Contains(strings.Join(rep.LookedIn, " "), filepath.Join(work, "repo")) {
		t.Errorf("looked in: %v", rep.LookedIn)
	}
}

func TestUsageJoin(t *testing.T) {
	p, work := machine(t)
	g := readGlobal(p.ClaudeDir)
	defs, looked := discover(p, g)
	day := func(d int, h int) time.Time { return time.Date(2026, 11, d, h, 0, 0, 0, time.UTC) }
	use := func(session, project, kind, name string, at time.Time, calls int) store.SessionUse {
		return store.SessionUse{Session: session, Title: "title of " + session, Project: project, Cwd: "/cwd/" + project,
			UseRow: store.UseRow{Kind: kind, Name: name, Day: at.Format("2006-01-02"), Calls: calls, FirstAt: at, LastAt: at, Turn: 2}}
	}
	repoSkill := filepath.Join(work, "repo", ".claude", "skills", "deploy")
	u1 := use("s1", "p1", "skill", "deploy", day(1, 9), 2)
	u1.Path, u1.ByUser = repoSkill, 1
	u2 := use("s1", "p1", "skill", "deploy", day(3, 9), 1)
	u2.Path, u2.Errors, u2.Turn = repoSkill, 1, 7
	u3 := use("s2", "p2", "skill", "deploy", day(8, 9), 4)
	u3.Path = filepath.Join(p.ClaudeDir, "skills", "deploy")
	uses := []store.SessionUse{u1, u2, u3,
		use("s2", "p2", "agent", "Explore", day(8, 10), 3),
		use("s2", "p2", "skill", "git:sync", day(8, 10), 1),        // a command file, used as Claude Code lists it: among the skills
		use("s2", "p2", "hook", "PostToolUse:Edit", day(8, 11), 5), // the configured hook's matcher is Edit|Write
		use("s2", "p2", "hook", "PostToolUse:Bash", day(8, 11), 1), // no configured hook matches
		use("s2", "p2", "connector", "claude_ai_Gmail", day(8, 12), 6),
		use("s1", "p1", "command", "compact", day(1, 9), 1),
	}
	offers := []store.OfferCount{{Kind: "skill", Name: "deploy", Sessions: 2, LastAt: day(8, 12)}, {Kind: "skill", Name: "anthropic-skills:pdf", Sessions: 2, LastAt: day(8, 12)},
		{Kind: "skill", Name: "git:sync", Sessions: 1}, {Kind: "skill", Name: "init", Sessions: 2}, {Kind: "agent", Name: "Explore", Sessions: 2, BuiltIn: true}, {Kind: "agent", Name: "Plan", Sessions: 2, BuiltIn: true}}

	rep := build(defs, looked, g, uses, offers, 2, Options{})
	items := itemsOf(rep)
	d := items["skill deploy"]
	if d.Usage.Calls != 7 || d.Usage.Sessions != 2 || d.Usage.Errors != 1 || d.Usage.ByUser != 1 || d.Usage.OfferedSessions != 2 || len(d.Usage.Days) != 3 {
		t.Errorf("deploy usage: %+v", d.Usage)
	}
	if len(d.Usage.Projects) != 2 || d.Usage.Projects[0].Project != "p2" || d.Usage.Projects[0].Calls != 4 || d.Usage.Projects[1].Sessions != 1 || d.Usage.Projects[1].Cwd != "/cwd/p1" {
		t.Errorf("deploy by project: %+v", d.Usage.Projects)
	}
	// The transcripts say which definition each use loaded.
	if d.Definitions[0].Calls != 0 || d.Definitions[1].Calls != 4 || d.Definitions[2].Calls != 3 {
		t.Errorf("deploy per definition (managed, user, project): %d %d %d", d.Definitions[0].Calls, d.Definitions[1].Calls, d.Definitions[2].Calls)
	}
	if _, split := items["skill git:sync"]; split {
		t.Error("a command file offered and used as a skill is one item, the command")
	}
	if c := items["command git:sync"]; c.Usage.Calls != 1 || c.Usage.OfferedSessions != 1 {
		t.Errorf("command git:sync: %+v", c.Usage)
	}
	if h := items["hook PostToolUse:Edit|Write"]; h.Usage.Calls != 5 {
		t.Errorf("a hook's use is found by its matcher: %+v", h.Usage)
	}
	if h := items["hook PostToolUse:Bash"]; h.Installed || h.Usage.Calls != 1 {
		t.Errorf("a hook that ran and is configured nowhere: %+v", h)
	}
	if e := items["agent Explore"]; !e.BuiltIn || e.Installed || e.Usage.Calls != 3 {
		t.Errorf("a built-in agent: %+v", e)
	}
	if g := items["connector claude_ai_Gmail"]; g.Usage.Calls != 6 || g.LastUsedAt == nil {
		t.Errorf("a connector's use joins its key: %+v", g.Usage)
	}
	counts := map[string]KindCount{}
	for _, k := range rep.Kinds {
		counts[k.Kind] = k
	}
	// Skills: deploy, pdf, tidy:sweep installed; gone (counter only), init (offered only). Unused: pdf, tidy:sweep, init.
	if c := counts["skill"]; c.Items != 5 || c.Installed != 3 || c.Used != 1 || c.Unused != 3 {
		t.Errorf("skills: %+v", c)
	}
	if c := counts["agent"]; c.Items != 4 || c.Installed != 2 || c.Used != 1 || c.Unused != 3 {
		t.Errorf("agents: %+v", c)
	}
	if c := counts["hook"]; c.Unused != 0 || c.Used != 2 {
		t.Errorf("hooks are never counted unused: %+v", c)
	}

	// A window: uses before it do not count, but the item says when it was last used.
	since := day(5, 0)
	rep = build(defs, looked, g, uses, offers, 1, Options{Since: since, Kind: "skill", Name: "deploy"})
	if len(rep.Items) != 1 || len(rep.Kinds) != 1 {
		t.Fatalf("one item asked for: %d items, %d kinds", len(rep.Items), len(rep.Kinds))
	}
	d = rep.Items[0]
	if d.Usage.Calls != 4 || d.Usage.Sessions != 1 || rep.Since == nil || len(d.Sessions) != 1 || d.Sessions[0].Session != "s2" || d.Sessions[0].Title != "title of s2" {
		t.Errorf("deploy since the 5th: %+v sessions %+v", d.Usage, d.Sessions)
	}
	rep = build(defs, looked, g, uses, offers, 2, Options{Kind: "skill", Name: "deploy"})
	if s := rep.Items[0].Sessions; len(s) != 2 || s[0].Session != "s2" || s[1].Calls != 3 || s[1].Turn != 2 || s[1].Errors != 1 {
		t.Errorf("deploy's sessions, latest first, a session's days folded: %+v", s)
	}
	rep = build(defs, looked, g, uses[:3], offers, 2, Options{Since: day(9, 0)})
	if d := itemsOf(rep)["skill deploy"]; d.Usage.Calls != 0 || d.LastUsedAt == nil || !d.LastUsedAt.Equal(day(8, 9)) {
		t.Errorf("after its last use: %+v last %v", d.Usage, d.LastUsedAt)
	}

	// Unused keeps what was there and not used.
	rep = build(defs, looked, g, uses, offers, 2, Options{Unused: true, Kind: "skill"})
	var names []string
	for _, it := range rep.Items {
		names = append(names, it.Name)
	}
	if strings.Join(names, " ") != "anthropic-skills:pdf init tidy:sweep" {
		t.Errorf("unused skills: %v", names)
	}
}

func TestHookMatches(t *testing.T) {
	for _, c := range []struct {
		matcher, tool string
		want          bool
	}{{"", "Edit", true}, {"*", "Edit", true}, {"Edit", "Edit", true}, {"Edit", "MultiEdit", false}, {"Edit|Write", "Write", true},
		{"Edit, Write", "Write", true}, {"mcp__.*", "mcp__x__y", true}, {"^Bash$", "Bash", true}, {"Note.*", "Edit", false}, {"(", "Edit", false}} {
		if got := hookMatches(c.matcher, c.tool); got != c.want {
			t.Errorf("hookMatches(%q, %q) = %v", c.matcher, c.tool, got)
		}
	}
}
