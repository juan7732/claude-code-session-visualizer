package transcript

import (
	"encoding/json"
	"regexp"
	"sort"
	"strings"
	"time"
)

// Kinds of primitive: the things Claude Code is extended with.
const (
	KindSkill        = "skill"
	KindAgent        = "agent"
	KindCommand      = "command"
	KindConnector    = "connector"
	KindHook         = "hook"
	KindInstructions = "instructions"
	KindMemory       = "memory"
)

// Primitives is what a session was offered of the things Claude Code is
// extended with, and what it used of them.
type Primitives struct {
	Uses    []PrimitiveUse   `json:"uses"`
	Offered []PrimitiveOffer `json:"offered"`
}

// PrimitiveUse is one primitive's use on one day of a session.
//
// DECISION: a row per UTC day, so that "this month" can be asked of a session
// that ran for weeks. The day is UTC because the index must read the same on
// a machine in another zone; FirstAt and LastAt are exact.
type PrimitiveUse struct {
	Kind string `json:"kind"`
	Name string `json:"name"`
	Day  string `json:"day"` // 2026-11-07, UTC
	// Calls is how often it was used; ByUser is how many of those the person
	// asked for by typing a slash command, the rest being the model's choice.
	Calls  int `json:"calls"`
	Errors int `json:"errors,omitempty"`
	ByUser int `json:"by_user,omitempty"`
	// Seconds is the time its calls ran, where a transcript can say: the run
	// of a subagent, the wait for a connector's answer. OutputTokens is what a
	// subagent wrote.
	Seconds      float64   `json:"seconds,omitempty"`
	OutputTokens int       `json:"output_tokens,omitempty"`
	FirstAt      time.Time `json:"first_at"`
	LastAt       time.Time `json:"last_at"`
	// Turn is the turn of the first use that day, -1 when it was outside one.
	Turn int `json:"turn"`
	// Path is where the session found it, when the transcript says: a skill's
	// folder. It tells two definitions of one name apart.
	Path string `json:"path,omitempty"`
}

// PrimitiveOffer is a primitive the session had on offer, used or not.
type PrimitiveOffer struct {
	Kind string `json:"kind"`
	Name string `json:"name"`
	// BuiltIn is true when Claude Code said it ships with it (agent types).
	BuiltIn bool `json:"built_in,omitempty"`
}

var (
	commandName  = regexp.MustCompile(`<command-name>\s*/?([^<\s]+)\s*</command-name>`)
	memoryNote   = regexp.MustCompile(`/projects/[^/]+/memory/[^/]+\.md$`)
	notToolChars = regexp.MustCompile(`[^A-Za-z0-9_-]`)
)

const skillBase = "Base directory for this skill:"

// ConnectorKey is a connector's name as it appears in tool names
// (mcp__<key>__<tool>): "claude.ai Google Drive" is "claude_ai_Google_Drive".
func ConnectorKey(name string) string { return notToolChars.ReplaceAllString(name, "_") }

// PrimitivesOf reads what a session was offered and what it used. Subagents
// must be loaded for their runs and for what they used themselves.
//
// What counts as a use, as measured on real transcripts (2026-11-10):
//   - a skill: a Skill tool call (the model chose it), or a slash command whose
//     name is a skill (the person typed it; there is then no tool call);
//   - an agent: an Agent or Task call, by the type of agent it spawned;
//   - a command: any other slash command, Claude Code's own included;
//   - a connector: a call to one of its tools (mcp__<connector>__<tool>);
//   - a hook: a record Claude Code wrote because a hook ran and said something
//     (a hook that ran silently leaves nothing behind);
//   - instructions and memory: a file loaded into the context, and a note of
//     Claude Code's own memory read back with the Read tool (the index of the
//     notes is loaded; a note itself is read when it is wanted).
func PrimitivesOf(s *Session) *Primitives {
	b := &primBuilder{uses: map[string]*PrimitiveUse{}, offered: map[string]*PrimitiveOffer{}, pathOfCall: map[string]string{}}

	promptTurn := map[string]int{}
	for _, t := range s.Turns {
		if t.Prompt != nil {
			promptTurn[t.Prompt.UUID] = t.Index
		}
	}
	turnAt := func(r *Record) int {
		if n, ok := promptTurn[r.UUID]; ok {
			return n
		}
		turn := -1
		for _, t := range s.Turns {
			if !t.StartAt.IsZero() && !t.StartAt.After(r.Timestamp) {
				turn = t.Index
			}
		}
		return turn
	}

	type typed struct {
		name string
		at   time.Time
		turn int
		path string
		// skill is true once the skill's text followed the command.
		skill bool
	}
	var commands []*typed
	var pending *typed
	for _, r := range s.Records {
		if r.IsSidechain {
			continue
		}
		switch r.Type {
		case "attachment":
			b.attachment(r, turnAt)
		case "assistant":
			pending = nil
		case "user":
			if r.Message == nil || r.IsCompactSummary {
				continue
			}
			text := strings.TrimSpace(firstText(r.Message.Content))
			if r.IsMeta {
				// A skill's text arrives as a companion record naming its folder:
				// after a Skill call (it says which), or after a typed command.
				if dir, ok := strings.CutPrefix(text, skillBase); ok {
					dir = strings.TrimSpace(firstLine(dir, 4096))
					var src struct {
						SourceToolUseID string `json:"sourceToolUseID"`
					}
					_ = r.Decode(&src)
					switch {
					case src.SourceToolUseID != "":
						b.pathOfCall[src.SourceToolUseID] = dir
					case pending != nil:
						pending.path, pending.skill = dir, true
						pending = nil
					}
				}
				continue
			}
			// Only a message that is the command: a prompt quoting the tag is not one.
			if !strings.HasPrefix(text, "<command-name>") && !strings.HasPrefix(text, "<command-message>") {
				pending = nil
				continue
			}
			if m := commandName.FindStringSubmatch(text); m != nil {
				pending = &typed{name: m[1], at: r.Timestamp, turn: turnAt(r)}
				commands = append(commands, pending)
			}
		}
	}

	b.calls(s, -1)
	for _, sa := range s.Subagents {
		if sa.Session == nil {
			continue
		}
		turn := -1
		for _, c := range s.ToolCalls {
			if c.Subagent == sa {
				turn = c.Turn
				break
			}
		}
		b.calls(sa.Session, turn)
	}

	// A typed command is a skill when the skill's text followed it, or when its
	// name was on the list of skills the session was offered.
	for _, c := range commands {
		kind := KindCommand
		if c.skill || b.offered[KindSkill+"\x00"+c.name] != nil {
			kind = KindSkill
		}
		u := b.use(kind, c.name, c.at, c.turn)
		u.ByUser++
		if c.path != "" {
			u.Path = c.path
		}
	}

	out := &Primitives{Uses: []PrimitiveUse{}, Offered: []PrimitiveOffer{}}
	for _, u := range b.uses {
		out.Uses = append(out.Uses, *u)
	}
	sort.Slice(out.Uses, func(i, j int) bool {
		a, c := out.Uses[i], out.Uses[j]
		if a.Kind != c.Kind {
			return a.Kind < c.Kind
		}
		if a.Name != c.Name {
			return a.Name < c.Name
		}
		return a.Day < c.Day
	})
	for _, o := range b.offered {
		out.Offered = append(out.Offered, *o)
	}
	sort.Slice(out.Offered, func(i, j int) bool {
		a, c := out.Offered[i], out.Offered[j]
		if a.Kind != c.Kind {
			return a.Kind < c.Kind
		}
		return a.Name < c.Name
	})
	return out
}

type primBuilder struct {
	uses       map[string]*PrimitiveUse
	offered    map[string]*PrimitiveOffer
	pathOfCall map[string]string
}

// use counts one use and returns its row for the caller to add to.
func (b *primBuilder) use(kind, name string, at time.Time, turn int) *PrimitiveUse {
	day := at.UTC().Format("2006-01-02")
	k := kind + "\x00" + name + "\x00" + day
	u := b.uses[k]
	if u == nil {
		u = &PrimitiveUse{Kind: kind, Name: name, Day: day, FirstAt: at, LastAt: at, Turn: turn}
		b.uses[k] = u
	}
	u.Calls++
	if at.Before(u.FirstAt) {
		u.FirstAt, u.Turn = at, turn
	}
	if at.After(u.LastAt) {
		u.LastAt = at
	}
	return u
}

func (b *primBuilder) offer(kind, name string, builtIn bool) {
	if name == "" {
		return
	}
	k := kind + "\x00" + name
	if o := b.offered[k]; o != nil {
		o.BuiltIn = o.BuiltIn || builtIn
		return
	}
	b.offered[k] = &PrimitiveOffer{Kind: kind, Name: name, BuiltIn: builtIn}
}

// calls counts the tool calls of a session or of one of its subagents. turn,
// when not negative, is the parent's turn a subagent's calls are filed under.
func (b *primBuilder) calls(s *Session, turn int) {
	for _, c := range s.ToolCalls {
		at := turn
		if at < 0 {
			at = c.Turn
		}
		var in struct {
			Skill        string `json:"skill"`
			SubagentType string `json:"subagent_type"`
			FilePath     string `json:"file_path"`
		}
		_ = json.Unmarshal(c.Input, &in)
		var u *PrimitiveUse
		switch {
		case c.Name == "Skill" && in.Skill != "":
			u = b.use(KindSkill, in.Skill, c.At, at)
			if p := b.pathOfCall[c.ID]; p != "" {
				u.Path = p
			}
		case c.Name == "Agent" || c.Name == "Task":
			// DECISION: the type the subagent's own file records wins over the
			// call's input; a call that names none started a general-purpose one,
			// which is what Claude Code does with an Agent call without a type.
			kind := in.SubagentType
			if c.Subagent != nil && c.Subagent.Meta != nil && c.Subagent.Meta.AgentType != "" {
				kind = c.Subagent.Meta.AgentType
			}
			if kind == "" {
				kind = "general-purpose"
			}
			u = b.use(KindAgent, kind, c.At, at)
			if sa := c.Subagent; sa != nil && sa.Session != nil {
				u.Seconds += sa.Session.Duration().Seconds()
				u.OutputTokens += sa.Session.Totals.Usage.OutputTokens
			} else if c.Paired && c.EndedAt.After(c.At) {
				u.Seconds += c.EndedAt.Sub(c.At).Seconds()
			}
		case c.Name == "Read" && memoryNote.MatchString(in.FilePath):
			u = b.use(KindMemory, in.FilePath, c.At, at)
		case strings.HasPrefix(c.Name, "mcp__"):
			parts := strings.SplitN(c.Name, "__", 3)
			if len(parts) < 2 || parts[1] == "" {
				continue
			}
			u = b.use(KindConnector, parts[1], c.At, at)
			if c.Paired && c.EndedAt.After(c.At) {
				u.Seconds += c.EndedAt.Sub(c.At).Seconds()
			}
		default:
			continue
		}
		if c.IsError {
			u.Errors++
		}
	}
}

// attachment reads the records Claude Code writes when it tells the model what
// is on offer, loads a memory file or passes on what a hook said.
func (b *primBuilder) attachment(r *Record, turnAt func(*Record) int) {
	if r.Attachment == nil {
		return
	}
	var env struct {
		Attachment json.RawMessage `json:"attachment"`
	}
	decode := func(v any) bool {
		if env.Attachment == nil && r.Decode(&env) != nil {
			return false
		}
		return json.Unmarshal(env.Attachment, v) == nil
	}
	typ := r.Attachment.Type
	switch {
	case typ == "skill_listing":
		var a struct {
			Names   []string `json:"names"`
			Content string   `json:"content"`
		}
		if !decode(&a) {
			return
		}
		if len(a.Names) == 0 {
			// Older records carry only the text: "- name: description" per line.
			for _, line := range strings.Split(a.Content, "\n") {
				if rest, ok := strings.CutPrefix(line, "- "); ok {
					if name, _, ok := strings.Cut(rest, ": "); ok {
						a.Names = append(a.Names, name)
					}
				}
			}
		}
		for _, n := range a.Names {
			b.offer(KindSkill, n, false)
		}
	case typ == "agent_listing_delta":
		var a struct {
			Added   []string `json:"addedTypes"`
			BuiltIn []string `json:"builtInTypes"`
		}
		if !decode(&a) {
			return
		}
		builtIn := map[string]bool{}
		for _, n := range a.BuiltIn {
			builtIn[n] = true
		}
		for _, n := range a.Added {
			b.offer(KindAgent, n, builtIn[n])
		}
	case typ == "deferred_tools_delta":
		var a struct {
			Added    []string `json:"addedNames"`
			Surfaced []string `json:"surfacedNames"`
		}
		if !decode(&a) {
			return
		}
		for _, n := range append(a.Added, a.Surfaced...) {
			if parts := strings.SplitN(n, "__", 3); len(parts) == 3 && parts[0] == "mcp" {
				b.offer(KindConnector, parts[1], false)
			}
		}
	case typ == "mcp_instructions_delta":
		var a struct {
			Added []string `json:"addedNames"`
		}
		if !decode(&a) {
			return
		}
		for _, n := range a.Added {
			b.offer(KindConnector, ConnectorKey(n), false)
		}
	case typ == "instructions":
		var a struct {
			Files []struct {
				Path string `json:"path"`
				Type string `json:"type"`
			} `json:"files"`
		}
		if !decode(&a) {
			return
		}
		for _, f := range a.Files {
			if f.Path != "" {
				b.use(memoryKind(f.Type), f.Path, r.Timestamp, turnAt(r))
			}
		}
	case typ == "nested_memory":
		var a struct {
			Path    string `json:"path"`
			Content struct {
				Type string `json:"type"`
			} `json:"content"`
		}
		if decode(&a) && a.Path != "" {
			b.use(memoryKind(a.Content.Type), a.Path, r.Timestamp, turnAt(r))
		}
	case strings.HasPrefix(typ, "hook_"):
		var a struct {
			Name  string `json:"hookName"`
			Event string `json:"hookEvent"`
		}
		if !decode(&a) {
			return
		}
		name := a.Name
		if name == "" {
			name = a.Event
		}
		if name == "" {
			return
		}
		u := b.use(KindHook, name, r.Timestamp, turnAt(r))
		if strings.Contains(typ, "error") {
			u.Errors++
		}
	}
}

// memoryKind tells the notes Claude Code keeps for itself ("AutoMem") from the
// instructions a person wrote.
func memoryKind(typ string) string {
	if strings.Contains(typ, "Mem") {
		return KindMemory
	}
	return KindInstructions
}

// firstText is the first text block of a message, injected or not.
func firstText(blocks Blocks) string {
	for _, b := range blocks {
		if b.Type == "text" {
			return b.Text
		}
	}
	return ""
}
