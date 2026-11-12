// Package primitives answers two questions about what Claude Code is extended
// with (skills, agents, slash commands, connectors, hooks, plugins, the
// instructions and memory files): what is installed and where, and how much
// each is used, from the sessions the index keeps. It is read-only and never
// writes under ~/.claude.
//
// SPEC: the places and the order of precedence are the ones Claude Code's own
// documentation gives (code.claude.com/docs: skills, sub-agents, slash
// commands, hooks, mcp, plugins, memory; read 2026-11-10).
package primitives

import (
	"bytes"
	"encoding/json"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/transcript"
)

// KindPlugin is the one kind no session uses directly: a plugin is what the
// skills, agents, commands, hooks and connectors inside it are installed by.
const KindPlugin = "plugin"

// Kinds in the order they are listed.
var Kinds = []string{transcript.KindSkill, transcript.KindAgent, transcript.KindCommand, transcript.KindConnector,
	transcript.KindHook, KindPlugin, transcript.KindInstructions, transcript.KindMemory}

// Scopes a definition can have.
const (
	ScopeManaged = "managed" // set by an organisation, under the managed settings directory
	ScopeUser    = "user"    // ~/.claude
	ScopeAccount = "account" // synced from the claude.ai account
	ScopePlugin  = "plugin"  // inside an installed plugin
	ScopeProject = "project" // a project's .claude folder, .mcp.json or CLAUDE.md
	ScopeLocal   = "local"   // for one project, kept out of it: settings.local.json, ~/.claude.json
)

// Definition is one place a primitive is defined.
type Definition struct {
	Scope string `json:"scope"`
	// Where is the project directory for the project and local scopes, the
	// plugin ("name@marketplace") for the plugin scope.
	Where       string `json:"where,omitempty"`
	Path        string `json:"path,omitempty"`
	Description string `json:"description,omitempty"`
	Bytes       int64  `json:"bytes,omitempty"`
	// Lines counts the lines of the file at Path, for a definition that is a
	// file of its own (a skill, an agent, a command, an instructions or memory
	// file): with Bytes, how much it adds to what the model reads. A settings
	// file that holds a hook or a connector among other things is not counted.
	Lines    int        `json:"lines,omitempty"`
	Modified *time.Time `json:"modified,omitempty"`
	// Detail holds what is particular to a kind: a hook's event, matcher and
	// command; a connector's transport and host or program; a plugin's version.
	Detail map[string]string `json:"detail,omitempty"`
	// Calls is how many of the item's calls the transcripts tie to this very
	// definition (a skill names its folder when it is loaded).
	Calls int `json:"calls,omitempty"`
}

// found is a definition with the item it belongs to.
type found struct {
	kind, name, title string
	def               Definition
}

// Places is where Discover looks.
type Places struct {
	// ClaudeDir is Claude Code's data directory (~/.claude); its sibling
	// <ClaudeDir>.json holds the global state.
	ClaudeDir string
	// Managed is the managed settings directory, "" for none.
	Managed string
	// Dirs are project directories: the ones sessions started in. The projects
	// Claude Code itself remembers are added to them.
	Dirs []string
}

// ManagedDir is where an organisation's settings live on macOS.
const ManagedDir = "/Library/Application Support/ClaudeCode"

// nestedDepth is how far below a project directory a folder with its own
// .claude is looked for: a workspace of repositories keeps them one or two
// levels down, and Claude Code picks those up when it works in them.
const nestedDepth = 2

var skipDirs = map[string]bool{"node_modules": true, "vendor": true, "target": true, "build": true, "dist": true, "Pods": true,
	"DerivedData": true, "venv": true, "__pycache__": true}

// globalState is the part of ~/.claude.json this package reads.
type globalState struct {
	Projects map[string]struct {
		MCPServers map[string]json.RawMessage `json:"mcpServers"`
	} `json:"projects"`
	MCPServers    map[string]json.RawMessage `json:"mcpServers"`
	EverConnected []string                   `json:"claudeAiMcpEverConnected"`
	SkillUsage    map[string]struct {
		UsageCount int   `json:"usageCount"`
		LastUsedAt int64 `json:"lastUsedAt"`
	} `json:"skillUsage"`
}

func readGlobal(claudeDir string) globalState {
	var g globalState
	if b, err := os.ReadFile(claudeDir + ".json"); err == nil {
		_ = json.Unmarshal(b, &g)
	}
	return g
}

// discover finds every definition on disk and says where it looked.
func discover(p Places, g globalState) (defs []found, looked []string) {
	d := &discovery{seen: map[string]bool{}, claudeDir: p.ClaudeDir}

	if p.Managed != "" {
		if st, err := os.Stat(p.Managed); err == nil && st.IsDir() {
			d.looked = append(d.looked, p.Managed)
			d.claudeFolder(filepath.Join(p.Managed, ".claude"), ScopeManaged, "")
			d.instructions(filepath.Join(p.Managed, "CLAUDE.md"), ScopeManaged, "")
			d.hooks(filepath.Join(p.Managed, "managed-settings.json"), ScopeManaged, "")
		}
	}

	// The user's own.
	d.looked = append(d.looked, p.ClaudeDir)
	d.claudeFolder(p.ClaudeDir, ScopeUser, "")
	d.instructions(filepath.Join(p.ClaudeDir, "CLAUDE.md"), ScopeUser, "")
	d.hooks(filepath.Join(p.ClaudeDir, "settings.json"), ScopeUser, "")
	d.hooks(filepath.Join(p.ClaudeDir, "settings.local.json"), ScopeUser, "")
	for name, raw := range g.MCPServers {
		d.connector(name, raw, ScopeUser, "", p.ClaudeDir+".json")
	}
	for _, name := range g.EverConnected {
		// A connector of the claude.ai account: Claude Code remembers its name
		// once it has connected, and nothing else about it.
		d.add(transcript.KindConnector, transcript.ConnectorKey(name), name, Definition{Scope: ScopeAccount})
	}

	// Skills synced from the claude.ai account.
	// DECISION: named "anthropic-skills:<folder>", which is what every session
	// on this install calls them (the folder's manifest does not say).
	// REVIEW: an account with skills of another origin may name them otherwise.
	synced, _ := filepath.Glob(filepath.Join(p.ClaudeDir, "skills", "synced", "*", "*", "SKILL.md"))
	for _, path := range synced {
		fm, def := readDefinition(path, ScopeAccount, "")
		d.add(transcript.KindSkill, "anthropic-skills:"+nameOr(fm, filepath.Base(filepath.Dir(path))), "", def)
	}

	d.plugins(p.ClaudeDir)

	// Notes Claude Code keeps for itself, one folder per project.
	notes, _ := filepath.Glob(filepath.Join(p.ClaudeDir, "projects", "*", "memory", "*.md"))
	for _, path := range notes {
		_, def := readDefinition(path, ScopeProject, filepath.Base(filepath.Dir(filepath.Dir(path))))
		def.Description = "" // listed, never read out
		d.add(transcript.KindMemory, path, "", def)
	}

	// Projects: where sessions started, and the ones Claude Code remembers.
	home := filepath.Dir(p.ClaudeDir)
	roots := append([]string{}, p.Dirs...)
	for dir, proj := range g.Projects {
		roots = append(roots, dir)
		for name, raw := range proj.MCPServers {
			d.connector(name, raw, ScopeLocal, dir, p.ClaudeDir+".json")
		}
	}
	sort.Strings(roots)
	for _, root := range roots {
		root = filepath.Clean(root)
		if st, err := os.Stat(root); err != nil || !st.IsDir() {
			continue
		}
		// DECISION: the home directory is a project when a session started
		// there, but it is not searched for nested ones: that is every project
		// on the machine and Library besides.
		depth := nestedDepth
		if root == home || root == "/" {
			depth = 0
		}
		d.walk(root, depth)
	}
	sort.Strings(d.looked)
	return d.defs, d.looked
}

type discovery struct {
	defs   []found
	looked []string
	seen   map[string]bool // project directories already read
	// claudeDir is ~/.claude: the home directory's .claude is the user's, not a project's.
	claudeDir string
}

func (d *discovery) add(kind, name, title string, def Definition) {
	if name == "" {
		return
	}
	d.defs = append(d.defs, found{kind: kind, name: name, title: title, def: def})
}

// walk reads dir as a project and looks below it for folders that are one too.
func (d *discovery) walk(dir string, depth int) {
	if d.seen[dir] || dir == d.claudeDir {
		return
	}
	d.seen[dir] = true
	d.project(dir)
	if depth == 0 {
		return
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	for _, e := range entries {
		name := e.Name()
		if !e.IsDir() || strings.HasPrefix(name, ".") || skipDirs[name] {
			continue
		}
		d.walk(filepath.Join(dir, name), depth-1)
	}
}

// project reads what one directory defines for the sessions that work in it.
func (d *discovery) project(dir string) {
	before := len(d.defs)
	d.instructions(filepath.Join(dir, "CLAUDE.md"), ScopeProject, dir)
	d.instructions(filepath.Join(dir, "CLAUDE.local.md"), ScopeLocal, dir)
	if folder := filepath.Join(dir, ".claude"); folder != d.claudeDir {
		d.claudeFolder(folder, ScopeProject, dir)
		d.instructions(filepath.Join(folder, "CLAUDE.md"), ScopeProject, dir)
		d.hooks(filepath.Join(folder, "settings.json"), ScopeProject, dir)
		d.hooks(filepath.Join(folder, "settings.local.json"), ScopeLocal, dir)
	}
	d.mcpFile(filepath.Join(dir, ".mcp.json"), ScopeProject, dir, "")
	if len(d.defs) > before {
		d.looked = append(d.looked, dir)
	}
}

// claudeFolder reads the skills, agents, commands and rules of a .claude
// folder (or of ~/.claude itself, which has the same layout).
func (d *discovery) claudeFolder(folder, scope, where string) {
	skills, _ := filepath.Glob(filepath.Join(folder, "skills", "*", "SKILL.md"))
	for _, path := range skills {
		fm, def := readDefinition(path, scope, where)
		d.add(transcript.KindSkill, nameOr(fm, filepath.Base(filepath.Dir(path))), "", def)
	}
	for _, path := range markdownUnder(filepath.Join(folder, "agents")) {
		fm, def := readDefinition(path, scope, where)
		d.add(transcript.KindAgent, nameOr(fm, strings.TrimSuffix(filepath.Base(path), ".md")), "", def)
	}
	commands := filepath.Join(folder, "commands")
	for _, path := range markdownUnder(commands) {
		_, def := readDefinition(path, scope, where)
		d.add(transcript.KindCommand, colonName(commands, path), "", def)
	}
	for _, path := range markdownUnder(filepath.Join(folder, "rules")) {
		d.instructions(path, scope, where)
	}
}

func (d *discovery) instructions(path, scope, where string) {
	if st, err := os.Stat(path); err != nil || st.IsDir() {
		return
	}
	_, def := readDefinition(path, scope, where)
	def.Description = "" // listed, never read out
	d.add(transcript.KindInstructions, path, "", def)
}

// hooks reads the hooks of one settings file: an item per event and matcher.
func (d *discovery) hooks(path, scope, where string) {
	b, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var settings struct {
		Hooks map[string][]hookGroup `json:"hooks"`
	}
	if json.Unmarshal(b, &settings) != nil {
		return
	}
	d.hookGroups(settings.Hooks, path, scope, where)
}

type hookGroup struct {
	Matcher string `json:"matcher"`
	Hooks   []struct {
		Type    string `json:"type"`
		Command string `json:"command"`
	} `json:"hooks"`
}

func (d *discovery) hookGroups(groups map[string][]hookGroup, path, scope, where string) {
	mod, size := stat(path)
	for event, list := range groups {
		for _, g := range list {
			for _, h := range g.Hooks {
				name := event
				if g.Matcher != "" && g.Matcher != "*" {
					name += ":" + g.Matcher
				}
				detail := map[string]string{"event": event}
				if g.Matcher != "" {
					detail["matcher"] = g.Matcher
				}
				if h.Type != "" {
					detail["type"] = h.Type
				}
				if h.Command != "" {
					detail["command"] = clip(h.Command, 400)
				}
				d.add(transcript.KindHook, name, "", Definition{Scope: scope, Where: where, Path: path, Bytes: size, Modified: mod, Detail: detail})
			}
		}
	}
}

// mcpFile reads a .mcp.json; prefix is put before each server's key (a
// plugin's servers are "plugin_<plugin>_<server>" in tool names).
func (d *discovery) mcpFile(path, scope, where, prefix string) {
	b, err := os.ReadFile(path)
	if err != nil {
		return
	}
	var f struct {
		Servers map[string]json.RawMessage `json:"mcpServers"`
	}
	if json.Unmarshal(b, &f) != nil {
		return
	}
	for name, raw := range f.Servers {
		d.connectorNamed(prefix+name, name, raw, scope, where, path)
	}
}

func (d *discovery) connector(name string, raw json.RawMessage, scope, where, path string) {
	d.connectorNamed(name, name, raw, scope, where, path)
}

// connectorNamed adds a connector.
//
// DECISION: of a server's configuration only how it is reached is kept: the
// transport, and the program's name or the host. Arguments, environment and
// headers are where keys and tokens are put, so they are never copied.
func (d *discovery) connectorNamed(keyName, title string, raw json.RawMessage, scope, where, path string) {
	var s struct {
		Type    string `json:"type"`
		Command string `json:"command"`
		URL     string `json:"url"`
	}
	_ = json.Unmarshal(raw, &s)
	detail := map[string]string{}
	switch {
	case s.URL != "":
		detail["transport"] = s.Type
		if s.Type == "" {
			detail["transport"] = "http"
		}
		if u, err := url.Parse(s.URL); err == nil && u.Host != "" {
			detail["host"] = u.Host
		}
	case s.Command != "":
		detail["transport"] = "stdio"
		detail["program"] = filepath.Base(s.Command)
	}
	mod, size := stat(path)
	if path != "" && strings.HasSuffix(path, ".claude.json") {
		size = 0 // the state file's size says nothing about one server
	}
	d.add(transcript.KindConnector, transcript.ConnectorKey(keyName), title, Definition{Scope: scope, Where: where, Path: path, Bytes: size, Modified: mod, Detail: detail})
}

// plugins reads the installed plugins and what each brings.
//
// REVIEW: written from the documented layout and Claude Code 2.1's
// installed_plugins.json (version 2: a list of installs per plugin; version 1:
// one object). No plugin was installed on the machine this was built on, so
// only the tests have exercised it.
func (d *discovery) plugins(claudeDir string) {
	b, err := os.ReadFile(filepath.Join(claudeDir, "plugins", "installed_plugins.json"))
	if err != nil {
		return
	}
	type install struct {
		Scope       string `json:"scope"`
		InstallPath string `json:"installPath"`
		Version     string `json:"version"`
		ProjectPath string `json:"projectPath"`
	}
	var file struct {
		Plugins map[string]json.RawMessage `json:"plugins"`
	}
	if json.Unmarshal(b, &file) != nil {
		return
	}
	enabled := map[string]bool{}
	if sb, err := os.ReadFile(filepath.Join(claudeDir, "settings.json")); err == nil {
		var s struct {
			Enabled map[string]bool `json:"enabledPlugins"`
		}
		if json.Unmarshal(sb, &s) == nil {
			enabled = s.Enabled
		}
	}
	ids := make([]string, 0, len(file.Plugins))
	for id := range file.Plugins {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		var installs []install
		if json.Unmarshal(file.Plugins[id], &installs) != nil {
			var one install
			if json.Unmarshal(file.Plugins[id], &one) != nil {
				continue
			}
			installs = []install{one}
		}
		plugin, _, _ := strings.Cut(id, "@")
		for _, in := range installs {
			root := in.InstallPath
			if st, err := os.Stat(root); err != nil || !st.IsDir() {
				continue
			}
			detail := map[string]string{}
			if in.Version != "" {
				detail["version"] = in.Version
			}
			if in.Scope != "" {
				detail["installed_for"] = in.Scope
			}
			if on, ok := enabled[id]; ok {
				detail["enabled"] = map[bool]string{true: "yes", false: "no"}[on]
			}
			def := Definition{Scope: ScopePlugin, Where: id, Path: root, Detail: detail}
			manifest := filepath.Join(root, ".claude-plugin", "plugin.json")
			if mb, err := os.ReadFile(manifest); err == nil {
				var m struct {
					Name        string `json:"name"`
					Description string `json:"description"`
				}
				if json.Unmarshal(mb, &m) == nil {
					def.Description = clip(m.Description, 600)
					if m.Name != "" {
						plugin = m.Name
					}
				}
				def.Modified, _ = stat(manifest)
			}
			d.add(KindPlugin, plugin, "", def)

			skills, _ := filepath.Glob(filepath.Join(root, "skills", "*", "SKILL.md"))
			for _, path := range skills {
				fm, sd := readDefinition(path, ScopePlugin, id)
				d.add(transcript.KindSkill, plugin+":"+nameOr(fm, filepath.Base(filepath.Dir(path))), "", sd)
			}
			agents := filepath.Join(root, "agents")
			for _, path := range markdownUnder(agents) {
				fm, ad := readDefinition(path, ScopePlugin, id)
				name := colonName(agents, path)
				if n := fm["name"]; n != "" {
					// The name in the file replaces the last segment.
					name = name[:strings.LastIndex(name, ":")+1] + n
				}
				d.add(transcript.KindAgent, plugin+":"+name, "", ad)
			}
			commands := filepath.Join(root, "commands")
			for _, path := range markdownUnder(commands) {
				_, cd := readDefinition(path, ScopePlugin, id)
				d.add(transcript.KindCommand, plugin+":"+colonName(commands, path), "", cd)
			}
			hooksPath := filepath.Join(root, "hooks", "hooks.json")
			if hb, err := os.ReadFile(hooksPath); err == nil {
				var h struct {
					Hooks map[string][]hookGroup `json:"hooks"`
				}
				if json.Unmarshal(hb, &h) == nil {
					d.hookGroups(h.Hooks, hooksPath, ScopePlugin, id)
				}
			}
			d.mcpFile(filepath.Join(root, ".mcp.json"), ScopePlugin, id, "plugin_"+plugin+"_")
		}
	}
}

// readDefinition stats a markdown definition, reads its front matter and
// counts its lines.
func readDefinition(path, scope, where string) (map[string]string, Definition) {
	def := Definition{Scope: scope, Where: where, Path: path}
	def.Modified, def.Bytes = stat(path)
	fm := map[string]string{}
	if f, err := os.Open(path); err == nil {
		buf := make([]byte, 64<<10)
		n, _ := io.ReadFull(f, buf)
		fm = frontMatter(string(buf[:n]))
		// The front matter is in the first block; the lines are counted to the end.
		def.Lines = countLines(io.MultiReader(bytes.NewReader(buf[:n]), f))
		f.Close()
	}
	def.Description = clip(fm["description"], 600)
	return fm, def
}

// countLines counts the lines of a text: its newlines, and one more for a
// last line that does not end with one. Nothing read is kept.
func countLines(r io.Reader) int {
	buf := make([]byte, 64<<10)
	lines, last := 0, byte('\n')
	for {
		n, err := r.Read(buf)
		if n > 0 {
			lines += bytes.Count(buf[:n], []byte{'\n'})
			last = buf[n-1]
		}
		if err != nil {
			break
		}
	}
	if last != '\n' {
		lines++
	}
	return lines
}

// frontMatter reads the "key: value" lines between the leading --- lines of a
// markdown file. A value continued on indented lines is joined with spaces.
// It is not a YAML parser: lists and nested maps are skipped.
func frontMatter(text string) map[string]string {
	out := map[string]string{}
	lines := strings.Split(text, "\n")
	if len(lines) == 0 || strings.TrimSpace(lines[0]) != "---" {
		return out
	}
	key := ""
	for _, line := range lines[1:] {
		line = strings.TrimRight(line, "\r")
		if strings.TrimSpace(line) == "---" {
			break
		}
		if strings.HasPrefix(line, " ") || strings.HasPrefix(line, "\t") {
			if t := strings.TrimSpace(line); key != "" && t != "" && !strings.HasPrefix(t, "- ") {
				out[key] = strings.TrimSpace(out[key] + " " + t)
			}
			continue
		}
		k, v, ok := strings.Cut(line, ":")
		if !ok || strings.HasPrefix(line, "#") {
			key = ""
			continue
		}
		key, v = strings.TrimSpace(k), strings.TrimSpace(v)
		switch v {
		case ">", "|", ">-", "|-", ">+", "|+":
			v = ""
		}
		if len(v) >= 2 && (v[0] == '"' || v[0] == '\'') && v[len(v)-1] == v[0] {
			v = v[1 : len(v)-1]
		}
		out[key] = v
	}
	return out
}

func nameOr(fm map[string]string, fallback string) string {
	if n := fm["name"]; n != "" {
		return n
	}
	return fallback
}

// markdownUnder lists the .md files below dir, at any depth.
func markdownUnder(dir string) []string {
	var out []string
	_ = filepath.WalkDir(dir, func(path string, e os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".md") {
			out = append(out, path)
		}
		return nil
	})
	sort.Strings(out)
	return out
}

// colonName names a file by its path below base, folders becoming segments:
// commands/frontend/component.md is "frontend:component".
func colonName(base, path string) string {
	rel, err := filepath.Rel(base, path)
	if err != nil {
		rel = filepath.Base(path)
	}
	return strings.ReplaceAll(strings.TrimSuffix(filepath.ToSlash(rel), ".md"), "/", ":")
}

func stat(path string) (*time.Time, int64) {
	st, err := os.Stat(path)
	if err != nil {
		return nil, 0
	}
	mod := st.ModTime()
	return &mod, st.Size()
}

func clip(s string, max int) string {
	s = strings.TrimSpace(s)
	if len(s) <= max {
		return s
	}
	cut := max
	for cut > 0 && s[cut]&0xC0 == 0x80 {
		cut--
	}
	return s[:cut] + "…"
}
