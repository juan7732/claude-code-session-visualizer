package stats

import (
	"sort"
	"time"
)

// Overview is every session added up: what `skit overview` prints and the
// Stats page shows. It is made from the summaries kept in the index, so no
// transcript is read.
type Overview struct {
	Sessions int `json:"sessions"`
	// Timezone names the zone the days are in: the machine's own.
	Timezone string          `json:"timezone"`
	Totals   Totals          `json:"totals"`
	Projects []ProjectTotals `json:"projects"`
	// Days are the days anything happened on, oldest first.
	Days   []DayActivity `json:"days"`
	Tools  []ToolCount   `json:"tools"`
	Models []Count       `json:"models"`
	// CacheHitRatio is cache reads over all input, across the sessions.
	CacheHitRatio float64 `json:"cache_hit_ratio"`
	CacheRead     int     `json:"cache_read_tokens"`
	// Time is the split of `skit time`, added up over the sessions that have one.
	Time TimeTotals `json:"time"`
	// WithoutActivity counts sessions whose summary was written before the
	// index kept activity (their source is gone, so they cannot be read
	// again): they are in the totals and on no day.
	WithoutActivity int `json:"sessions_without_activity"`
}

// Totals are counts over a set of sessions.
type Totals struct {
	Turns        int `json:"turns"`
	SystemTurns  int `json:"system_turns"`
	Actions      int `json:"actions"`
	ToolCalls    int `json:"tool_calls"`
	ToolErrors   int `json:"tool_errors"`
	OutputTokens int `json:"output_tokens"`
	Subagents    int `json:"subagents"`
	Compactions  int `json:"compactions"`
	Images       int `json:"images"`
	APIErrors    int `json:"api_errors"`
	// CostUSD is Claude Code's own figure, over the sessions that recorded one.
	CostUSD      float64 `json:"claude_code_cost_usd"`
	CostSessions int     `json:"sessions_with_cost"`
}

func (t *Totals) add(s Summary) {
	t.Turns += s.Turns
	t.SystemTurns += s.SystemTurns
	t.Actions += s.Requests
	t.ToolCalls += s.ToolCalls
	t.ToolErrors += s.ToolErrors
	t.OutputTokens += s.Usage.OutputTokens
	t.Subagents += s.Subagents
	t.Compactions += s.Compactions
	t.Images += s.Images
	t.APIErrors += s.APIErrors
	if s.ClaudeCodeCostUSD != nil {
		t.CostUSD += *s.ClaudeCodeCostUSD
		t.CostSessions++
	}
}

// ProjectTotals are one project's sessions added up. Project is the slug
// Claude Code files it under; Cwd is the directory its latest session started in.
type ProjectTotals struct {
	Project  string    `json:"project"`
	Cwd      string    `json:"cwd,omitempty"`
	Sessions int       `json:"sessions"`
	LastAt   time.Time `json:"last_at"`
	Totals
}

// DayActivity is one day, in Overview.Timezone.
type DayActivity struct {
	Day          string `json:"day"` // 2026-11-07
	Actions      int    `json:"actions"`
	ToolCalls    int    `json:"tool_calls"`
	ToolErrors   int    `json:"tool_errors"`
	OutputTokens int    `json:"output_tokens"`
	// Sessions are the ids of the sessions that did something that day.
	Sessions []string `json:"sessions"`
}

// Overall adds the summaries up. Days are days in loc.
func Overall(rows []Summary, loc *time.Location) Overview {
	if loc == nil {
		loc = time.Local
	}
	out := Overview{Sessions: len(rows), Timezone: loc.String(), Projects: []ProjectTotals{}, Days: []DayActivity{}, Tools: []ToolCount{}, Models: []Count{}}
	projects := map[string]*ProjectTotals{}
	days := map[string]*DayActivity{}
	seen := map[string]map[string]bool{}
	tools := map[string]*ToolCount{}
	models := map[string]int{}
	var input, read int
	for _, s := range rows {
		out.Totals.add(s)
		p := projects[s.Project]
		if p == nil {
			p = &ProjectTotals{Project: s.Project}
			projects[s.Project] = p
		}
		p.Sessions++
		p.add(s)
		if s.LastAt.After(p.LastAt) {
			p.LastAt, p.Cwd = s.LastAt, s.Cwd
		}
		for _, t := range s.Tools {
			tc := tools[t.Name]
			if tc == nil {
				tc = &ToolCount{Name: t.Name}
				tools[t.Name] = tc
			}
			tc.Calls += t.Calls
			tc.Errors += t.Errors
		}
		for _, m := range s.Models {
			models[m.Name] += m.Count
		}
		input += s.Usage.InputTokens + s.Usage.CacheCreationInputTokens + s.Usage.CacheReadInputTokens
		read += s.Usage.CacheReadInputTokens
		if s.Time != nil {
			out.Time.Wall += s.Time.Wall
			out.Time.ForYou += s.Time.ForYou
			out.Time.ForBackground += s.Time.ForBackground
			out.Time.Split.add(s.Time.Split)
		}
		if len(s.Activity) == 0 && s.Requests > 0 {
			out.WithoutActivity++
		}
		for _, h := range s.Activity {
			key := h.Hour.In(loc).Format("2006-01-02")
			d := days[key]
			if d == nil {
				d = &DayActivity{Day: key, Sessions: []string{}}
				days[key] = d
				seen[key] = map[string]bool{}
			}
			d.Actions += h.Actions
			d.ToolCalls += h.ToolCalls
			d.ToolErrors += h.ToolErrors
			d.OutputTokens += h.OutputTokens
			if !seen[key][s.ID] {
				seen[key][s.ID] = true
				d.Sessions = append(d.Sessions, s.ID)
			}
		}
	}
	out.Time.Split = roundSplit(out.Time.Split)
	out.CacheRead = read
	if input > 0 {
		out.CacheHitRatio = float64(read) / float64(input)
	}
	for _, p := range projects {
		out.Projects = append(out.Projects, *p)
	}
	sort.Slice(out.Projects, func(i, j int) bool {
		a, b := out.Projects[i], out.Projects[j]
		return a.Actions > b.Actions || (a.Actions == b.Actions && a.Project < b.Project)
	})
	for _, d := range days {
		out.Days = append(out.Days, *d)
	}
	sort.Slice(out.Days, func(i, j int) bool { return out.Days[i].Day < out.Days[j].Day })
	for _, t := range tools {
		out.Tools = append(out.Tools, *t)
	}
	sort.Slice(out.Tools, func(i, j int) bool {
		return out.Tools[i].Calls > out.Tools[j].Calls || (out.Tools[i].Calls == out.Tools[j].Calls && out.Tools[i].Name < out.Tools[j].Name)
	})
	for m, n := range models {
		out.Models = append(out.Models, Count{m, n})
	}
	sort.Slice(out.Models, func(i, j int) bool {
		return out.Models[i].Count > out.Models[j].Count || (out.Models[i].Count == out.Models[j].Count && out.Models[i].Name < out.Models[j].Name)
	})
	return out
}
