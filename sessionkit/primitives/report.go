package primitives

import (
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/store"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/transcript"
)

// Options narrow a report.
type Options struct {
	// Since counts only uses at or after it; zero counts everything kept.
	Since time.Time
	// Kind keeps one kind; with Name, one item, which then lists its sessions.
	Kind string
	Name string
	// Unused keeps what is there to be used and was not, since Since.
	Unused bool
}

// Report is what `skit primitives` prints and GET /v0/primitives returns.
type Report struct {
	Since *time.Time `json:"since,omitempty"`
	// Sessions is how many sessions the index keeps that were active since Since.
	Sessions int         `json:"sessions"`
	Kinds    []KindCount `json:"kinds"`
	Items    []Item      `json:"items"`
	// LookedIn lists the directories something was found in.
	LookedIn []string `json:"looked_in"`
}

// KindCount adds up one kind, before Options.Unused and Options.Name narrow the items.
type KindCount struct {
	Kind string `json:"kind"`
	// Items is everything known of the kind: defined on disk, offered to a
	// session, or used by one. Installed is the part with a definition.
	Items     int `json:"items"`
	Installed int `json:"installed"`
	Used      int `json:"used"`
	// Unused is what was there to be used (installed, or offered to a session)
	// and was not. Not counted for hooks, which leave no trace when they run
	// quietly, or for plugins, which are used through what they bring.
	Unused int `json:"unused"`
}

// Item is one primitive: every place it is defined, and its use.
type Item struct {
	Kind string `json:"kind"`
	// Name is the name it is used by: "cruise", "anthropic-skills:pdf",
	// "Explore", "claude_ai_Gmail" (a connector, as in its tools' names),
	// "PostToolUse:Edit", or a memory file's path.
	Name string `json:"name"`
	// Title is the name as a person wrote it, when Name is a key made from it.
	Title       string `json:"title,omitempty"`
	Description string `json:"description,omitempty"`
	// Installed is true when a definition was found. An item that is not
	// installed was offered to a session or used by one: it comes with Claude
	// Code, or it was there once and is gone.
	Installed bool `json:"installed"`
	// BuiltIn is true when Claude Code said so itself (agent types).
	BuiltIn bool `json:"built_in,omitempty"`
	// Order says how Claude Code chooses when Definitions has more than one
	// that applies, and Definitions are in that order: "user-first" (managed,
	// user, project: skills and commands), "project-first" (managed, project,
	// user, plugin: agents), "local-first" (local, project, user, plugin,
	// account: connectors) or "merged" (all apply: hooks, memory files).
	Order       string       `json:"order"`
	Definitions []Definition `json:"definitions"`
	Usage       Usage        `json:"usage"`
	// LastUsedAt is the last use in any session kept, whatever Since is.
	LastUsedAt *time.Time `json:"last_used_at,omitempty"`
	// Counter is Claude Code's own count (skills only). It counts on this
	// machine since it began counting, sessions no longer kept included.
	Counter *Counter `json:"claude_code_counter,omitempty"`
	// Sessions are the sessions that used it, latest first: only when one item was asked for.
	Sessions []SessionUse `json:"sessions,omitempty"`
}

// Counter is a count Claude Code keeps itself.
type Counter struct {
	Uses       int        `json:"uses"`
	LastUsedAt *time.Time `json:"last_used_at,omitempty"`
}

// Usage is an item's use since Options.Since.
type Usage struct {
	Sessions int `json:"sessions"`
	Calls    int `json:"calls"`
	Errors   int `json:"errors"`
	// ByUser is how many calls the person typed as a slash command.
	ByUser       int        `json:"by_user"`
	Seconds      float64    `json:"seconds"`
	OutputTokens int        `json:"output_tokens"`
	FirstAt      *time.Time `json:"first_at,omitempty"`
	LastAt       *time.Time `json:"last_at,omitempty"`
	// OfferedSessions is how many sessions had it on offer.
	OfferedSessions int          `json:"offered_sessions"`
	OfferedLastAt   *time.Time   `json:"offered_last_at,omitempty"`
	Projects        []ProjectUse `json:"projects"`
	Days            []DayUse     `json:"days"`
}

// ProjectUse is an item's use in one project.
type ProjectUse struct {
	Project  string `json:"project"` // the slug Claude Code files its sessions under
	Cwd      string `json:"cwd,omitempty"`
	Sessions int    `json:"sessions"`
	Calls    int    `json:"calls"`
}

// DayUse is an item's use on one UTC day.
type DayUse struct {
	Day   string `json:"day"`
	Calls int    `json:"calls"`
}

// SessionUse is an item's use in one session.
type SessionUse struct {
	Session string    `json:"session"`
	Title   string    `json:"title"`
	Project string    `json:"project"`
	Cwd     string    `json:"cwd,omitempty"`
	Calls   int       `json:"calls"`
	Errors  int       `json:"errors"`
	ByUser  int       `json:"by_user"`
	Seconds float64   `json:"seconds"`
	FirstAt time.Time `json:"first_at"`
	LastAt  time.Time `json:"last_at"`
	// Turn is the turn of the first use, -1 when it was outside one.
	Turn int `json:"turn"`
}

// Read builds the report from the disk and the index.
func Read(st *store.Store, p Places, opt Options) (*Report, error) {
	dirs, err := st.StartDirs()
	if err != nil {
		return nil, err
	}
	p.Dirs = append(append([]string{}, p.Dirs...), dirs...)
	uses, err := st.Uses("", "")
	if err != nil {
		return nil, err
	}
	offers, err := st.Offers(opt.Since)
	if err != nil {
		return nil, err
	}
	sessions, err := st.SessionsSince(opt.Since)
	if err != nil {
		return nil, err
	}
	g := readGlobal(p.ClaudeDir)
	defs, looked := discover(p, g)
	return build(defs, looked, g, uses, offers, sessions, opt), nil
}

func order(kind string) string {
	switch kind {
	case transcript.KindSkill, transcript.KindCommand:
		return "user-first"
	case transcript.KindAgent:
		return "project-first"
	case transcript.KindConnector:
		return "local-first"
	}
	return "merged"
}

// rank places a definition among the others of its item: lower wins.
func rank(kind, scope string) int {
	var scopes []string
	switch order(kind) {
	case "user-first":
		scopes = []string{ScopeManaged, ScopeUser, ScopeProject, ScopeLocal, ScopeAccount, ScopePlugin}
	case "project-first":
		scopes = []string{ScopeManaged, ScopeProject, ScopeLocal, ScopeUser, ScopePlugin, ScopeAccount}
	case "local-first":
		scopes = []string{ScopeManaged, ScopeLocal, ScopeProject, ScopeUser, ScopePlugin, ScopeAccount}
	default:
		scopes = []string{ScopeManaged, ScopeUser, ScopeProject, ScopeLocal, ScopePlugin, ScopeAccount}
	}
	for i, s := range scopes {
		if s == scope {
			return i
		}
	}
	return len(scopes)
}

type builder struct {
	items map[string]*Item
	rows  map[*Item][]store.SessionUse
}

func (b *builder) item(kind, name string) *Item {
	k := kind + "\x00" + name
	it := b.items[k]
	if it == nil {
		it = &Item{Kind: kind, Name: name, Order: order(kind), Definitions: []Definition{}}
		it.Usage.Projects, it.Usage.Days = []ProjectUse{}, []DayUse{}
		b.items[k] = it
	}
	return it
}

// find returns the items a use belongs to. A use names its kind as the
// transcript showed it, which is not always how it is defined: Claude Code
// lists a command file among the skills, and a hook's use names the tool it
// ran for where its definition has a matcher.
func (b *builder) find(u store.SessionUse) []*Item {
	if it := b.items[u.Kind+"\x00"+u.Name]; it != nil {
		return []*Item{it}
	}
	switch u.Kind {
	case transcript.KindSkill:
		if it := b.items[transcript.KindCommand+"\x00"+u.Name]; it != nil && it.Installed {
			return []*Item{it}
		}
	case transcript.KindCommand:
		if it := b.items[transcript.KindSkill+"\x00"+u.Name]; it != nil && it.Installed {
			return []*Item{it}
		}
	case transcript.KindHook:
		event, tool, _ := strings.Cut(u.Name, ":")
		var out []*Item
		for _, it := range b.items {
			if it.Kind != transcript.KindHook || !it.Installed {
				continue
			}
			for _, d := range it.Definitions {
				if d.Detail["event"] == event && hookMatches(d.Detail["matcher"], tool) {
					out = append(out, it)
					break
				}
			}
		}
		if len(out) > 0 {
			sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
			return out
		}
	}
	return []*Item{b.item(u.Kind, u.Name)}
}

var plainMatcher = regexp.MustCompile(`^[A-Za-z0-9_\- ,|]*$`)

// hookMatches applies a hook's matcher to a tool name as Claude Code does:
// empty or "*" matches all, a list of plain names matches exactly, anything
// else is a regular expression.
func hookMatches(matcher, tool string) bool {
	if matcher == "" || matcher == "*" {
		return true
	}
	if plainMatcher.MatchString(matcher) {
		for _, m := range strings.FieldsFunc(matcher, func(r rune) bool { return r == '|' || r == ',' }) {
			if strings.TrimSpace(m) == tool {
				return true
			}
		}
		return false
	}
	re, err := regexp.Compile(matcher)
	return err == nil && re.MatchString(tool)
}

func build(defs []found, looked []string, g globalState, uses []store.SessionUse, offers []store.OfferCount, sessions int, opt Options) *Report {
	b := &builder{items: map[string]*Item{}, rows: map[*Item][]store.SessionUse{}}
	for _, f := range defs {
		it := b.item(f.kind, f.name)
		it.Installed = true
		if it.Title == "" {
			it.Title = f.title
		}
		it.Definitions = append(it.Definitions, f.def)
	}
	for _, it := range b.items {
		sort.SliceStable(it.Definitions, func(i, j int) bool {
			a, c := it.Definitions[i], it.Definitions[j]
			if ra, rc := rank(it.Kind, a.Scope), rank(it.Kind, c.Scope); ra != rc {
				return ra < rc
			}
			if a.Where != c.Where {
				return a.Where < c.Where
			}
			return a.Path < c.Path
		})
		for _, d := range it.Definitions {
			if d.Description != "" {
				it.Description = d.Description
				break
			}
		}
	}

	inWindow := func(t time.Time) bool { return opt.Since.IsZero() || !t.Before(opt.Since) }
	for _, u := range uses {
		for _, it := range b.find(u) {
			if last := u.LastAt; it.LastUsedAt == nil || last.After(*it.LastUsedAt) {
				it.LastUsedAt = &last
			}
			if !inWindow(u.LastAt) {
				continue
			}
			b.rows[it] = append(b.rows[it], u)
			if u.Path != "" {
				for i := range it.Definitions {
					if filepath.Dir(it.Definitions[i].Path) == u.Path || it.Definitions[i].Path == u.Path {
						it.Definitions[i].Calls += u.Calls
					}
				}
			}
		}
	}
	for it, rows := range b.rows {
		it.Usage = usageOf(rows, it.Usage)
	}
	for _, o := range offers {
		it := b.item(o.Kind, o.Name)
		if !it.Installed && o.Kind == transcript.KindSkill {
			// A command file is offered to the model among the skills.
			if c := b.items[transcript.KindCommand+"\x00"+o.Name]; c != nil && c.Installed {
				delete(b.items, o.Kind+"\x00"+o.Name)
				it = c
			}
		}
		it.BuiltIn = it.BuiltIn || o.BuiltIn
		it.Usage.OfferedSessions += o.Sessions
		if last := o.LastAt; !last.IsZero() && (it.Usage.OfferedLastAt == nil || last.After(*it.Usage.OfferedLastAt)) {
			it.Usage.OfferedLastAt = &last
		}
	}
	for name, c := range g.SkillUsage {
		it := b.items[transcript.KindSkill+"\x00"+name]
		if it == nil {
			if cmd := b.items[transcript.KindCommand+"\x00"+name]; cmd != nil {
				it = cmd
			} else {
				it = b.item(transcript.KindSkill, name)
			}
		}
		it.Counter = &Counter{Uses: c.UsageCount}
		if c.LastUsedAt > 0 {
			t := time.UnixMilli(c.LastUsedAt).UTC()
			it.Counter.LastUsedAt = &t
		}
	}

	rep := &Report{Sessions: sessions, Kinds: []KindCount{}, Items: []Item{}, LookedIn: looked}
	if rep.LookedIn == nil {
		rep.LookedIn = []string{}
	}
	if !opt.Since.IsZero() {
		since := opt.Since
		rep.Since = &since
	}
	counts := map[string]*KindCount{}
	for _, k := range Kinds {
		counts[k] = &KindCount{Kind: k}
	}
	for _, it := range b.items {
		c := counts[it.Kind]
		if c == nil {
			c = &KindCount{Kind: it.Kind}
			counts[it.Kind] = c
		}
		c.Items++
		if it.Installed {
			c.Installed++
		}
		if it.Usage.Calls > 0 {
			c.Used++
		}
		if unused(it) {
			c.Unused++
		}
		if opt.Kind != "" && it.Kind != opt.Kind || opt.Name != "" && it.Name != opt.Name || opt.Unused && !unused(it) {
			continue
		}
		out := *it
		if opt.Kind != "" && opt.Name != "" {
			out.Sessions = sessionsOf(b.rows[it])
		}
		rep.Items = append(rep.Items, out)
	}
	for _, k := range Kinds {
		if opt.Kind == "" || opt.Kind == k {
			rep.Kinds = append(rep.Kinds, *counts[k])
		}
	}
	kindAt := map[string]int{}
	for i, k := range Kinds {
		kindAt[k] = i
	}
	sort.Slice(rep.Items, func(i, j int) bool {
		a, c := rep.Items[i], rep.Items[j]
		if a.Kind != c.Kind {
			return kindAt[a.Kind] < kindAt[c.Kind]
		}
		if la, lc := strings.ToLower(a.Name), strings.ToLower(c.Name); la != lc {
			return la < lc
		}
		return a.Name < c.Name
	})
	return rep
}

// unused: there to be used, and not used. See KindCount.Unused.
func unused(it *Item) bool {
	if it.Kind == transcript.KindHook || it.Kind == KindPlugin {
		return false
	}
	return (it.Installed || it.Usage.OfferedSessions > 0) && it.Usage.Calls == 0
}

func usageOf(rows []store.SessionUse, u Usage) Usage {
	type proj struct {
		cwd      string
		lastAt   time.Time
		sessions map[string]bool
		calls    int
	}
	sessions := map[string]bool{}
	projects := map[string]*proj{}
	days := map[string]int{}
	for _, r := range rows {
		sessions[r.Session] = true
		u.Calls += r.Calls
		u.Errors += r.Errors
		u.ByUser += r.ByUser
		u.Seconds += r.Seconds
		u.OutputTokens += r.Tokens
		if first := r.FirstAt; !first.IsZero() && (u.FirstAt == nil || first.Before(*u.FirstAt)) {
			u.FirstAt = &first
		}
		if last := r.LastAt; !last.IsZero() && (u.LastAt == nil || last.After(*u.LastAt)) {
			u.LastAt = &last
		}
		p := projects[r.Project]
		if p == nil {
			p = &proj{sessions: map[string]bool{}}
			projects[r.Project] = p
		}
		p.sessions[r.Session] = true
		p.calls += r.Calls
		if r.Cwd != "" && !r.LastAt.Before(p.lastAt) {
			p.cwd, p.lastAt = r.Cwd, r.LastAt
		}
		days[r.Day] += r.Calls
	}
	u.Sessions = len(sessions)
	u.Projects, u.Days = []ProjectUse{}, []DayUse{}
	for slug, p := range projects {
		u.Projects = append(u.Projects, ProjectUse{Project: slug, Cwd: p.cwd, Sessions: len(p.sessions), Calls: p.calls})
	}
	sort.Slice(u.Projects, func(i, j int) bool {
		if u.Projects[i].Calls != u.Projects[j].Calls {
			return u.Projects[i].Calls > u.Projects[j].Calls
		}
		return u.Projects[i].Project < u.Projects[j].Project
	})
	for day, calls := range days {
		u.Days = append(u.Days, DayUse{Day: day, Calls: calls})
	}
	sort.Slice(u.Days, func(i, j int) bool { return u.Days[i].Day < u.Days[j].Day })
	return u
}

// sessionsOf folds an item's rows into one per session, latest first.
func sessionsOf(rows []store.SessionUse) []SessionUse {
	by := map[string]*SessionUse{}
	for _, r := range rows {
		s := by[r.Session]
		if s == nil {
			s = &SessionUse{Session: r.Session, Title: r.Title, Project: r.Project, Cwd: r.Cwd, FirstAt: r.FirstAt, LastAt: r.LastAt, Turn: r.Turn}
			by[r.Session] = s
		}
		s.Calls += r.Calls
		s.Errors += r.Errors
		s.ByUser += r.ByUser
		s.Seconds += r.Seconds
		if r.FirstAt.Before(s.FirstAt) {
			s.FirstAt, s.Turn = r.FirstAt, r.Turn
		}
		if r.LastAt.After(s.LastAt) {
			s.LastAt = r.LastAt
		}
	}
	out := make([]SessionUse, 0, len(by))
	for _, s := range by {
		out = append(out, *s)
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].LastAt.Equal(out[j].LastAt) {
			return out[i].LastAt.After(out[j].LastAt)
		}
		return out[i].Session < out[j].Session
	})
	return out
}
