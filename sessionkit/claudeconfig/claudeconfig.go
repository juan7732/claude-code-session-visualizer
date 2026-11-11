// Package claudeconfig reads how Claude Code itself is configured on this
// machine: the settings layers and which one wins, the experiments the install
// is assigned to, the cached feature flags, known projects, memory files and
// skills. It is read-only and never writes under ~/.claude.
//
// DECISION: a whitelist. ~/.claude.json holds the account, tokens and ids next
// to the flags. Only named, harmless fields are copied; for identity the
// snapshot says "set" or "not set" and nothing else.
//
// The settings layers cannot be a whitelist: their keys are Claude Code's to
// add. They are copied with their credentials replaced (redact.go): a value
// whose name says key, token, secret or helper, every header, and any value
// that looks like a credential wherever it sits.
package claudeconfig

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Snapshot is `skit claude --json` and GET /v0/claude.
type Snapshot struct {
	ClaudeDir   string            `json:"claude_dir"`
	Layers      []Layer           `json:"layers"`
	Effective   []Setting         `json:"effective"`
	Experiments []Experiment      `json:"experiments"`
	Flags       []Flag            `json:"flags"`
	FlagsAt     *time.Time        `json:"flags_cached_at,omitempty"`
	Projects    []Project         `json:"projects"`
	Connectors  []string          `json:"connectors"`
	Memory      []File            `json:"memory"`
	Skills      []Skill           `json:"skills"`
	State       map[string]any    `json:"state"`
	Identity    map[string]string `json:"identity"`
}

// Layer is one settings file, lowest precedence first.
type Layer struct {
	Name     string         `json:"name"`
	Path     string         `json:"path"`
	Exists   bool           `json:"exists"`
	Modified *time.Time     `json:"modified,omitempty"`
	Settings map[string]any `json:"settings,omitempty"`
}

// Setting is one dotted key with the value in effect and every layer that sets it.
type Setting struct {
	Key   string   `json:"key"`
	Value any      `json:"value"`
	From  string   `json:"from"`           // the layer that wins
	Also  []string `json:"also,omitempty"` // lower layers it overrides
}

// Experiment is one cached assignment.
type Experiment struct {
	Flag         string `json:"flag"`
	ExperimentID string `json:"experiment_id"`
	VariationID  int    `json:"variation_id"`
	Value        any    `json:"value"`
}

// Flag is one cached remote feature flag.
type Flag struct {
	Key          string `json:"key"`
	Value        any    `json:"value"`
	InExperiment bool   `json:"in_experiment,omitempty"`
}

// Project is a directory Claude Code has state for.
type Project struct {
	Path         string   `json:"path"`
	AllowedTools int      `json:"allowed_tools"`
	MCPServers   []string `json:"mcp_servers"`
	Trusted      bool     `json:"trusted"`
}

// File is a file by path, size and age. For a memory file, Kind says which
// sort it is: "instructions" (a CLAUDE.md a person wrote) or "memory" (a note
// Claude Code keeps for itself under projects/<slug>/memory), and Project the
// directory or the slug it belongs to.
type File struct {
	Path     string    `json:"path"`
	Bytes    int64     `json:"bytes"`
	Lines    int       `json:"lines"`
	Modified time.Time `json:"modified"`
	Kind     string    `json:"kind,omitempty"`
	Project  string    `json:"project,omitempty"`
}

// Skill is a skill found on disk or in the usage record.
type Skill struct {
	Name   string `json:"name"`
	Path   string `json:"path,omitempty"`
	Uses   int    `json:"uses,omitempty"`
	OnDisk bool   `json:"on_disk"`
}

var stateKeys = []string{"numStartups", "firstStartTime", "claudeCodeFirstTokenDate", "autoCompactEnabled", "verbose",
	"migrationVersion", "lastOnboardingVersion", "lastReleaseNotesSeen", "cachedExtraUsageDisabledReason", "deepLinkTerminal"}

var identityKeys = []string{"userID", "machineID", "oauthAccount"}

// Read builds the snapshot. claudeDir is Claude Code's data directory
// (~/.claude); its sibling <claudeDir>.json holds the global state. roots are
// project directories whose own settings, memory and skills are included.
func Read(claudeDir string, roots []string) (*Snapshot, error) {
	snap := &Snapshot{ClaudeDir: claudeDir, Layers: []Layer{}, Effective: []Setting{}, Experiments: []Experiment{}, Flags: []Flag{},
		Projects: []Project{}, Connectors: []string{}, Memory: []File{}, Skills: []Skill{}, State: map[string]any{}, Identity: map[string]string{}}

	layers := []Layer{{Name: "user", Path: filepath.Join(claudeDir, "settings.json")}, {Name: "user local", Path: filepath.Join(claudeDir, "settings.local.json")}}
	for _, r := range roots {
		base := filepath.Base(r)
		layers = append(layers, Layer{Name: "project · " + base, Path: filepath.Join(r, ".claude", "settings.json")},
			Layer{Name: "project local · " + base, Path: filepath.Join(r, ".claude", "settings.local.json")})
	}
	type src struct {
		v    any
		from string
	}
	eff := map[string][]src{}
	for _, l := range layers {
		if st, err := os.Stat(l.Path); err == nil {
			var m map[string]any
			b, _ := os.ReadFile(l.Path)
			if json.Unmarshal(b, &m) == nil {
				// Redacted before anything is built from it: the layer and the effective list both come from m.
				m = redactSettings(m)
				mt := st.ModTime()
				l.Exists, l.Modified, l.Settings = true, &mt, m
				for k, v := range flatten("", m) {
					eff[k] = append(eff[k], src{v, l.Name})
				}
			}
		}
		snap.Layers = append(snap.Layers, l)
	}
	for k, xs := range eff {
		s := Setting{Key: k, Value: xs[len(xs)-1].v, From: xs[len(xs)-1].from}
		for _, x := range xs[:len(xs)-1] {
			s.Also = append(s.Also, x.from)
		}
		snap.Effective = append(snap.Effective, s)
	}
	sort.Slice(snap.Effective, func(i, j int) bool { return snap.Effective[i].Key < snap.Effective[j].Key })

	var g map[string]json.RawMessage
	b, err := os.ReadFile(claudeDir + ".json")
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	if err == nil {
		if err := json.Unmarshal(b, &g); err != nil {
			return nil, err
		}
	}
	get := func(k string, v any) bool { return len(g[k]) > 0 && json.Unmarshal(g[k], v) == nil }

	var expData map[string]struct {
		ExperimentID string `json:"experimentId"`
		VariationID  int    `json:"variationId"`
		Value        any    `json:"value"`
	}
	get("cachedExperimentData", &expData)
	inExp := map[string]bool{}
	for k, e := range expData {
		inExp[k] = true
		snap.Experiments = append(snap.Experiments, Experiment{Flag: k, ExperimentID: e.ExperimentID, VariationID: e.VariationID, Value: e.Value})
	}
	sort.Slice(snap.Experiments, func(i, j int) bool { return snap.Experiments[i].Flag < snap.Experiments[j].Flag })
	var expList []string
	get("cachedExperimentFeatures", &expList)
	for _, k := range expList {
		inExp[k] = true
	}
	var flags map[string]any
	get("cachedGrowthBookFeatures", &flags)
	for k, v := range flags {
		snap.Flags = append(snap.Flags, Flag{Key: k, Value: v, InExperiment: inExp[k]})
	}
	sort.Slice(snap.Flags, func(i, j int) bool { return snap.Flags[i].Key < snap.Flags[j].Key })
	var at int64
	if get("cachedGrowthBookFeaturesAt", &at) && at > 0 {
		t := time.UnixMilli(at)
		snap.FlagsAt = &t
	}

	var projects map[string]struct {
		AllowedTools []any          `json:"allowedTools"`
		MCPServers   map[string]any `json:"mcpServers"`
		Trusted      bool           `json:"hasTrustDialogAccepted"`
	}
	get("projects", &projects)
	for p, v := range projects {
		pr := Project{Path: p, AllowedTools: len(v.AllowedTools), MCPServers: []string{}, Trusted: v.Trusted}
		for name := range v.MCPServers {
			pr.MCPServers = append(pr.MCPServers, name)
		}
		sort.Strings(pr.MCPServers)
		snap.Projects = append(snap.Projects, pr)
	}
	sort.Slice(snap.Projects, func(i, j int) bool { return snap.Projects[i].Path < snap.Projects[j].Path })

	var userMCP map[string]any
	get("mcpServers", &userMCP)
	for name := range userMCP {
		snap.Connectors = append(snap.Connectors, name)
	}
	var everConnected []string
	get("claudeAiMcpEverConnected", &everConnected)
	snap.Connectors = append(snap.Connectors, everConnected...)
	sort.Strings(snap.Connectors)

	for _, k := range stateKeys {
		var v any
		if get(k, &v) {
			snap.State[k] = v
		}
	}
	for _, k := range identityKeys {
		snap.Identity[k] = "not set"
		if raw := strings.TrimSpace(string(g[k])); raw != "" && raw != "null" && raw != `""` && raw != "{}" {
			snap.Identity[k] = "set"
		}
	}

	// Memory: the instructions people write (CLAUDE.md, for the user, for each
	// root given and for each project Claude Code knows), and the notes Claude
	// Code keeps for itself, one folder per project. Listed, never read out:
	// only where each is, how long and how old.
	type memFile struct{ path, kind, project string }
	mem := []memFile{{filepath.Join(claudeDir, "CLAUDE.md"), "instructions", ""}}
	dirs := append([]string{}, roots...)
	for _, p := range snap.Projects {
		dirs = append(dirs, p.Path)
	}
	for _, r := range dirs {
		for _, name := range []string{"CLAUDE.md", "CLAUDE.local.md", filepath.Join(".claude", "CLAUDE.md")} {
			mem = append(mem, memFile{filepath.Join(r, name), "instructions", r})
		}
	}
	for _, r := range roots {
		sub, _ := filepath.Glob(filepath.Join(r, "*", "CLAUDE.md"))
		for _, p := range sub {
			mem = append(mem, memFile{p, "instructions", r})
		}
	}
	notes, _ := filepath.Glob(filepath.Join(claudeDir, "projects", "*", "memory", "*.md"))
	sort.Strings(notes)
	for _, p := range notes {
		mem = append(mem, memFile{p, "memory", filepath.Base(filepath.Dir(filepath.Dir(p)))})
	}
	seen := map[string]bool{}
	for _, m := range mem {
		st, err := os.Stat(m.path)
		if err != nil || st.IsDir() || seen[m.path] {
			continue
		}
		seen[m.path] = true
		b, _ := os.ReadFile(m.path)
		snap.Memory = append(snap.Memory, File{Path: m.path, Bytes: st.Size(), Lines: strings.Count(string(b), "\n"), Modified: st.ModTime(), Kind: m.kind, Project: m.project})
	}

	var usage map[string]struct {
		UsageCount int `json:"usageCount"`
	}
	get("skillUsage", &usage)
	skills := map[string]*Skill{}
	for _, dir := range append([]string{claudeDir}, roots...) {
		for _, pat := range []string{".claude/skills/*/SKILL.md", "skills/*/SKILL.md", "*/.claude/skills/*/SKILL.md"} {
			found, _ := filepath.Glob(filepath.Join(dir, pat))
			for _, p := range found {
				name := filepath.Base(filepath.Dir(p))
				skills[name] = &Skill{Name: name, Path: p, OnDisk: true}
			}
		}
	}
	for name, u := range usage {
		if skills[name] == nil {
			skills[name] = &Skill{Name: name}
		}
		skills[name].Uses = u.UsageCount
	}
	for _, s := range skills {
		snap.Skills = append(snap.Skills, *s)
	}
	sort.Slice(snap.Skills, func(i, j int) bool { return snap.Skills[i].Name < snap.Skills[j].Name })
	return snap, nil
}

// flatten turns nested objects into dotted keys; arrays and scalars are leaves.
func flatten(prefix string, m map[string]any) map[string]any {
	out := map[string]any{}
	for k, v := range m {
		if sub, ok := v.(map[string]any); ok && len(sub) > 0 {
			for kk, vv := range flatten(prefix+k+".", sub) {
				out[kk] = vv
			}
			continue
		}
		out[prefix+k] = v
	}
	return out
}
