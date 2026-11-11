// Package stats turns a parsed session into the numbers skit reports: counts,
// token usage once per request, models and tools, compactions, cost, and the
// context-window curve. Subagent work rolls into the parent (decided
// 2026-11-08): it was done for that session.
package stats

import (
	"sort"
	"time"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/transcript"
)

// Summary is the per-session report.
type Summary struct {
	ID        string    `json:"id"`
	Path      string    `json:"path,omitempty"`
	Project   string    `json:"project,omitempty"`
	Title     string    `json:"title"`
	Slug      string    `json:"slug,omitempty"`
	Cwd       string    `json:"cwd,omitempty"`
	Cwds      []string  `json:"cwds,omitempty"`
	GitBranch string    `json:"git_branch,omitempty"`
	Versions  []string  `json:"claude_code_versions,omitempty"`
	FirstAt   time.Time `json:"first_at"`
	LastAt    time.Time `json:"last_at"`
	Duration  string    `json:"duration"`
	// InTurns is the part of Duration spent inside turns, as `skit time` counts
	// it. The rest was the session waiting, for its human or for background work.
	InTurns string `json:"in_turns,omitempty"`
	Partial bool   `json:"partial,omitempty"`

	Prompts     int `json:"prompts"`
	Turns       int `json:"turns"`        // agent turns answering a prompt
	SystemTurns int `json:"system_turns"` // agent turns started by notifications etc.
	// Rewound turns and actions sit on branches the conversation left (/rewind).
	// Every other count and Usage include them; RewoundUsage is their share.
	RewoundTurns   int               `json:"rewound_turns"`
	RewoundActions int               `json:"rewound_actions"`
	RewoundUsage   *transcript.Usage `json:"rewound_usage,omitempty"`
	Requests       int               `json:"requests"` // API requests = actions (subagents included)
	ToolCalls      int               `json:"tool_calls"`
	ToolErrors     int               `json:"tool_errors"`
	Unpaired       int               `json:"unpaired_tool_calls"`
	Images         int               `json:"images"`
	Compactions    int               `json:"compactions"`
	APIErrors      int               `json:"api_errors"`
	Subagents      int               `json:"subagents"`
	Branches       int               `json:"branches"`
	Synthetic      int               `json:"synthetic_messages"`
	Injected       int               `json:"injected_blocks"`
	Attachments    int               `json:"attachments"`

	Usage          transcript.Usage    `json:"usage"`           // parent + subagents, once per request
	CacheHitRatio  float64             `json:"cache_hit_ratio"` // cache reads / all input
	Models         []Count             `json:"models"`
	Tools          []ToolCount         `json:"tools"`
	CompactionList []CompactionInfo    `json:"compaction_list,omitempty"`
	PRLinks        []transcript.PRLink `json:"pr_links,omitempty"`

	// ClaudeCodeCostUSD is Claude Code's own figure from cost-state, when present.
	ClaudeCodeCostUSD *float64 `json:"claude_code_cost_usd,omitempty"`
	LinesAdded        int      `json:"lines_added,omitempty"`
	LinesRemoved      int      `json:"lines_removed,omitempty"`

	// Context is the context-window size at each request, in order.
	Context []ContextPoint `json:"context,omitempty"`

	// Activity is what happened in each hour the session worked, so that a
	// calendar across sessions needs no transcript. Shape is how many actions
	// each prompt of the human's started, in order. Time is where the wall
	// time went (`skit time`, without its lists). All three are kept with the
	// summary in the index: `skit overview` adds them up.
	Activity []HourActivity `json:"activity,omitempty"`
	Shape    []int          `json:"shape,omitempty"`
	Time     *TimeTotals    `json:"time,omitempty"`
}

// HourActivity is one hour of a session, by the clock on the wall in UTC:
// a reader turns hours into its own days. Subagents count at their own times.
type HourActivity struct {
	Hour         time.Time `json:"hour"`
	Actions      int       `json:"actions"`
	ToolCalls    int       `json:"tool_calls"`
	ToolErrors   int       `json:"tool_errors"`
	OutputTokens int       `json:"output_tokens"`
}

// TimeTotals is the split of `skit time` in seconds, without its lists.
type TimeTotals struct {
	Wall          float64 `json:"wall_seconds"`
	ForYou        float64 `json:"waiting_for_you_seconds"`
	ForBackground float64 `json:"waiting_for_background_seconds"`
	Split
}

// Count is a name with a count.
type Count struct {
	Name  string `json:"name"`
	Count int    `json:"count"`
}

// ToolCount is a tool with calls and errors.
type ToolCount struct {
	Name   string `json:"name"`
	Calls  int    `json:"calls"`
	Errors int    `json:"errors"`
}

// CompactionInfo is one compaction.
type CompactionInfo struct {
	At         time.Time `json:"at"`
	Trigger    string    `json:"trigger,omitempty"`
	PreTokens  int       `json:"pre_tokens"`
	PostTokens int       `json:"post_tokens"`
}

// ContextPoint is one action's context size.
type ContextPoint struct {
	Index    int       `json:"index"` // action index
	Turn     int       `json:"turn"`
	At       time.Time `json:"at"`
	Tokens   int       `json:"tokens"`
	CacheHit int       `json:"cache_read"`
	Output   int       `json:"output"`
}

// Options controls what Compute includes.
type Options struct {
	// Context includes the per-request context curve (one point per request).
	Context bool
	// Relations are the session's, when the caller already has them; Compute
	// derives them otherwise (it needs the action spans for the time split).
	Relations *transcript.Relations
}

// Compute summarises a session, rolling subagents into the totals.
func Compute(s *transcript.Session, project string, opt Options) Summary {
	t := s.Totals
	sum := Summary{
		ID: s.ID, Path: s.Path, Project: project, Title: s.DisplayTitle(), Slug: s.Slug, Cwd: s.Cwd, Cwds: s.Cwds,
		GitBranch: s.GitBranch, Versions: s.Versions, FirstAt: s.FirstAt, LastAt: s.LastAt,
		Duration: FormatDuration(s.Duration()), Partial: s.Partial,
		Prompts: t.Prompts, Turns: t.Turns, SystemTurns: t.SystemTurns, Requests: t.Requests, ToolCalls: t.ToolCalls, ToolErrors: t.ToolErrors,
		Unpaired: t.UnpairedToolUses, Images: t.Images, Compactions: t.Compactions, APIErrors: t.APIErrors,
		Subagents: t.Subagents, Branches: s.Branches, Usage: t.Usage, PRLinks: s.PRLinks,
		Synthetic: t.Synthetic, Injected: t.InjectedBlocks, Attachments: t.Attachments,
	}
	sum.RewoundTurns, sum.RewoundActions = t.RewoundTurns, t.RewoundActions
	if t.RewoundActions > 0 {
		u := t.RewoundUsage
		sum.RewoundUsage = &u
	}
	models := map[string]int{}
	for m, n := range t.Models {
		models[m] += n
	}
	tools := map[string]*ToolCount{}
	addTools := func(sess *transcript.Session) {
		for _, c := range sess.ToolCalls {
			tc := tools[c.Name]
			if tc == nil {
				tc = &ToolCount{Name: c.Name}
				tools[c.Name] = tc
			}
			tc.Calls++
			if c.IsError {
				tc.Errors++
			}
		}
	}
	addTools(s)
	for _, sa := range s.Subagents {
		if sa.Session == nil {
			continue
		}
		st := sa.Session.Totals
		sum.Usage.Add(st.Usage)
		sum.Requests += st.Requests
		sum.ToolCalls += st.ToolCalls
		sum.ToolErrors += st.ToolErrors
		sum.Images += st.Images
		sum.APIErrors += st.APIErrors
		for m, n := range st.Models {
			models[m] += n
		}
		addTools(sa.Session)
	}
	// Lists are never null in the JSON: a session with no requests has empty
	// lists, so a client can decode every row the same way.
	sum.Models, sum.Tools = []Count{}, []ToolCount{}
	for m, n := range models {
		sum.Models = append(sum.Models, Count{m, n})
	}
	sort.Slice(sum.Models, func(i, j int) bool {
		return sum.Models[i].Count > sum.Models[j].Count || (sum.Models[i].Count == sum.Models[j].Count && sum.Models[i].Name < sum.Models[j].Name)
	})
	for _, tc := range tools {
		sum.Tools = append(sum.Tools, *tc)
	}
	sort.Slice(sum.Tools, func(i, j int) bool {
		return sum.Tools[i].Calls > sum.Tools[j].Calls || (sum.Tools[i].Calls == sum.Tools[j].Calls && sum.Tools[i].Name < sum.Tools[j].Name)
	})
	if in := sum.Usage.InputTokens + sum.Usage.CacheCreationInputTokens + sum.Usage.CacheReadInputTokens; in > 0 {
		sum.CacheHitRatio = float64(sum.Usage.CacheReadInputTokens) / float64(in)
	}
	for _, c := range s.Compactions {
		ci := CompactionInfo{At: c.At}
		if c.Metadata != nil {
			ci.Trigger, ci.PreTokens, ci.PostTokens = c.Metadata.Trigger, c.Metadata.PreTokens, c.Metadata.PostTokens
		}
		sum.CompactionList = append(sum.CompactionList, ci)
	}
	if s.Cost != nil {
		cost := s.Cost.TotalCostUSD
		sum.ClaudeCodeCostUSD = &cost
		sum.LinesAdded, sum.LinesRemoved = s.Cost.TotalLinesAdded, s.Cost.TotalLinesRemoved
	}
	sum.Activity = activity(s)
	for _, turn := range s.Turns {
		if turn.Origin == "human" {
			sum.Shape = append(sum.Shape, len(turn.Actions))
		}
	}
	rel := opt.Relations
	if rel == nil {
		rel = s.Relations()
	}
	t1 := TimeOf(s, rel, 1)
	sum.Time = &TimeTotals{Wall: t1.Wall, ForYou: t1.ForYou, ForBackground: t1.ForBackground, Split: t1.InTurns}
	sum.InTurns = FormatDuration(time.Duration(t1.InTurns.Seconds * float64(time.Second)))
	if opt.Context {
		for _, a := range s.Actions {
			if a.Synthetic {
				continue
			}
			sum.Context = append(sum.Context, ContextPoint{Index: a.Index, Turn: a.Turn, At: a.At, Tokens: a.Usage.ContextTokens(),
				CacheHit: a.Usage.CacheReadInputTokens, Output: a.Usage.OutputTokens})
		}
	}
	return sum
}

// activity buckets the session's actions and tool calls, its subagents'
// included, into the UTC hours they happened in, oldest first.
func activity(s *transcript.Session) []HourActivity {
	hours := map[time.Time]*HourActivity{}
	at := func(t time.Time) *HourActivity {
		h := t.UTC().Truncate(time.Hour)
		a := hours[h]
		if a == nil {
			a = &HourActivity{Hour: h}
			hours[h] = a
		}
		return a
	}
	add := func(sess *transcript.Session) {
		for _, a := range sess.Actions {
			if a.Synthetic || a.At.IsZero() {
				continue
			}
			h := at(a.At)
			h.Actions++
			h.OutputTokens += a.Usage.OutputTokens
		}
		for _, c := range sess.ToolCalls {
			if c.At.IsZero() {
				continue
			}
			h := at(c.At)
			h.ToolCalls++
			if c.IsError {
				h.ToolErrors++
			}
		}
	}
	add(s)
	for _, sa := range s.Subagents {
		if sa.Session != nil {
			add(sa.Session)
		}
	}
	out := make([]HourActivity, 0, len(hours))
	for _, a := range hours {
		out = append(out, *a)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Hour.Before(out[j].Hour) })
	return out
}

// FormatDuration renders a duration for humans: 42s, 7m 03s, 2h 14m, 3d 2h.
func FormatDuration(d time.Duration) string {
	if d < 0 {
		d = -d
	}
	switch {
	case d < time.Minute:
		return formatInt(int(d.Seconds())) + "s"
	case d < time.Hour:
		return formatInt(int(d.Minutes())) + "m " + pad2(int(d.Seconds())%60) + "s"
	case d < 24*time.Hour:
		return formatInt(int(d.Hours())) + "h " + pad2(int(d.Minutes())%60) + "m"
	default:
		return formatInt(int(d.Hours())/24) + "d " + formatInt(int(d.Hours())%24) + "h"
	}
}

func formatInt(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	if neg {
		b = append([]byte{'-'}, b...)
	}
	return string(b)
}

func pad2(n int) string {
	if n < 10 {
		return "0" + formatInt(n)
	}
	return formatInt(n)
}

// FormatTokens renders a token count compactly: 950, 12.3k, 4.6M.
func FormatTokens(n int) string {
	switch {
	case n >= 1_000_000:
		return trimZero(float64(n)/1_000_000) + "M"
	case n >= 1_000:
		return trimZero(float64(n)/1_000) + "k"
	}
	return formatInt(n)
}

func trimZero(f float64) string {
	whole := int(f)
	frac := int((f-float64(whole))*10 + 0.5)
	if frac == 10 {
		whole++
		frac = 0
	}
	if whole >= 100 || frac == 0 {
		if frac >= 5 && whole < 100 {
			whole++
		}
		return formatInt(whole)
	}
	return formatInt(whole) + "." + formatInt(frac)
}
