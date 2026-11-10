package transcript

import (
	"encoding/json"
	"sort"
	"strings"
)

// DisplayTitle is the generated title, else the first line of the first
// prompt, else the slug, else the id.
func (s *Session) DisplayTitle() string {
	if s.Title != "" {
		return s.Title
	}
	if len(s.Prompts) > 0 {
		if line := FirstLine(s.Prompts[0].Text); line != "" {
			return line
		}
	}
	if s.Slug != "" {
		return s.Slug
	}
	return s.ID
}

// SubagentSession is the transcript of the subagent with this agent id, nil
// when the session has none by that name or it was not loaded.
func (s *Session) SubagentSession(agentID string) *Session {
	for _, sa := range s.Subagents {
		if sa.AgentID == agentID {
			return sa.Session
		}
	}
	return nil
}

// FirstLine returns the first non-empty line of text, trimmed.
func FirstLine(text string) string {
	for _, line := range strings.Split(text, "\n") {
		if t := strings.TrimSpace(line); t != "" {
			return t
		}
	}
	return ""
}

// ToolSummary is a one-line description of a tool call from its input: what
// the model said the call was for when it said so, else the argument that
// names its target.
func ToolSummary(name string, input json.RawMessage) string {
	var m map[string]any
	if json.Unmarshal(input, &m) != nil {
		return ""
	}
	pick := func(keys ...string) string {
		for _, k := range keys {
			if v, ok := m[k].(string); ok && v != "" {
				return v
			}
		}
		return ""
	}
	switch name {
	case "Bash":
		if d := pick("description"); d != "" {
			return d
		}
		return pick("command")
	case "Read", "Edit", "Write", "NotebookEdit":
		return pick("file_path", "notebook_path")
	case "Grep", "Glob":
		return pick("pattern")
	case "Agent", "Task":
		return pick("description")
	case "Skill":
		return pick("skill")
	case "WebFetch", "WebSearch":
		return pick("url", "query")
	}
	// The longest string field; of two as long, the one whose key sorts first.
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	best := ""
	for _, k := range keys {
		if s, ok := m[k].(string); ok && len(s) > len(best) {
			best = s
		}
	}
	return best
}
