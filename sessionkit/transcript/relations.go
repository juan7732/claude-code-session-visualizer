package transcript

import (
	"encoding/json"
	"fmt"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"time"
)

// Relations are the links between a session's parts that the uuid tree does not
// state: how long each action really took, which tool calls ran in the
// background and where their output was read, where a subagent handed back,
// which calls were retries, which files and outside services the work touched,
// and the errors that happened along the way. Every face (CLI, API, client)
// reads them from here so they agree.
//
// DECISION: relations are derived on read, not stored. They are cheap to
// compute from a parsed session and the heuristics will keep improving; an
// index column would freeze them.
type Relations struct {
	Spans     []ActionSpan  `json:"spans"`
	Tasks     []Task        `json:"tasks"`
	Handbacks []Handback    `json:"handbacks"`
	Retries   []Retry       `json:"retries"`
	Files     []FileTouched `json:"files"`
	Outside   []Outside     `json:"outside"`
	Events    []Event       `json:"events"`
}

// ActionSpan is the wall time of one action: the model wrote until GenEnd (its
// first tool call, or the end when it called none), its tools ran until
// ToolsEnd, and the next action of the turn started at End. The gap between
// ToolsEnd and End is waiting: on a subagent, a background task, or the human.
type ActionSpan struct {
	Action   int       `json:"action"`
	Turn     int       `json:"turn"`
	At       time.Time `json:"at"`
	GenEnd   time.Time `json:"gen_end"`
	ToolsEnd time.Time `json:"tools_end"`
	End      time.Time `json:"end"`
	// Said is true when the action ended the model's side with text for the human.
	Said bool `json:"said,omitempty"`
}

// CallRef points at a tool call.
type CallRef struct {
	ToolID string    `json:"tool_id"`
	Action int       `json:"action"`
	Turn   int       `json:"turn"`
	At     time.Time `json:"at"`
}

// Task is a command the agent started in the background: where it was
// launched, every later call that read its output, and the call that stopped it.
type Task struct {
	ID      string    `json:"id"`
	Label   string    `json:"label,omitempty"`
	Launch  CallRef   `json:"launch"`
	Pickups []CallRef `json:"pickups"`
	Stop    *CallRef  `json:"stop,omitempty"`
	// Output is what the agent saw when it last read the task's output.
	Output string `json:"output,omitempty"`
}

// Handback says which action of the parent first ran after a subagent finished:
// the action its result shaped. Action is -1 when the turn ended first.
type Handback struct {
	AgentID string    `json:"agent_id"`
	Spawn   CallRef   `json:"spawn"`
	EndedAt time.Time `json:"ended_at"`
	Action  int       `json:"action"`
	Message string    `json:"message,omitempty"` // the subagent's hand-back message, when it sent one
}

// Retry pairs a failed tool call with the next call of the same tool in its turn.
type Retry struct {
	Failed CallRef `json:"failed"`
	Retry  CallRef `json:"retry"`
}

// FileTouch is one tool call that read or wrote a file.
type FileTouch struct {
	CallRef
	Mode string `json:"mode"` // "read" or "write"
	Tool string `json:"tool"`
}

// FileTouched is a file with every touch, in order.
type FileTouched struct {
	Path    string      `json:"path"`
	Writes  int         `json:"writes"`
	Turns   int         `json:"turns"`
	Touches []FileTouch `json:"touches"`
}

// Outside is a service beyond the machine: a web host, the web search, a skill
// or an MCP connector.
type Outside struct {
	Kind  string    `json:"kind"` // "web", "search", "skill", "connector"
	Name  string    `json:"name"`
	Calls []CallRef `json:"calls"`
}

// Event is something that happened to the session rather than in it: an API
// error Claude Code retried, or a message it wrote itself.
type Event struct {
	Kind    string    `json:"kind"` // "api_error", "synthetic_api_error", "synthetic"
	At      time.Time `json:"at"`
	Turn    int       `json:"turn"`
	Action  *int      `json:"action,omitempty"`
	Message string    `json:"message,omitempty"`
}

var (
	backgroundID = regexp.MustCompile(`(?i)running in background with ID:\s*([A-Za-z0-9_-]+)`)
	// DECISION: paths in shell commands are found by extension, not by parsing
	// the shell. It misses extensionless files and can match a URL path; both
	// are acceptable for "which files did this session work on".
	pathInCommand = regexp.MustCompile(`(?:~/|\.{0,2}/)?(?:[\w.@-]+/)+[\w.@-]+\.(?:md|py|go|js|mjs|css|html|json|jsonl|toml|swift|sh|txt|yaml|yml|png|sql|ts|tsx|rs|c|h|plist|mod|sum|cfg)\b`)
	noisePath     = regexp.MustCompile(`/tmp/|/\.claude/|node_modules|/scratchpad/`)
)

type toolInput struct {
	Command         string `json:"command"`
	Description     string `json:"description"`
	RunInBackground bool   `json:"run_in_background"`
	FilePath        string `json:"file_path"`
	NotebookPath    string `json:"notebook_path"`
	Path            string `json:"path"`
	URL             string `json:"url"`
	Query           string `json:"query"`
	Skill           string `json:"skill"`
	TaskID          string `json:"task_id"`
	Message         string `json:"message"`
}

func (c *ToolCall) ref() CallRef {
	return CallRef{ToolID: c.ID, Action: c.Action, Turn: c.Turn, At: c.At}
}

func firstLine(s string, max int) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	if len(s) > max {
		s = s[:max-1] + "…"
	}
	return s
}

// Relations derives the session's relations. Subagents must be loaded (Load or
// the archive) for hand-backs to appear.
func (s *Session) Relations() *Relations {
	rel := &Relations{Spans: []ActionSpan{}, Tasks: []Task{}, Handbacks: []Handback{}, Retries: []Retry{}, Files: []FileTouched{}, Outside: []Outside{}, Events: []Event{}}

	// spans
	for _, t := range s.Turns {
		for i, a := range t.Actions {
			sp := ActionSpan{Action: a.Index, Turn: t.Index, At: a.At, GenEnd: a.At, ToolsEnd: a.At, End: t.EndAt,
				Said: a.StopReason == "end_turn" && a.Text() != ""}
			if i+1 < len(t.Actions) {
				sp.End = t.Actions[i+1].At
			}
			if sp.End.Before(sp.At) {
				sp.End = sp.At
			}
			if len(a.ToolCalls) == 0 {
				sp.GenEnd, sp.ToolsEnd = sp.End, sp.End
			} else {
				sp.GenEnd = a.ToolCalls[0].At
				for _, c := range a.ToolCalls {
					if c.At.Before(sp.GenEnd) {
						sp.GenEnd = c.At
					}
					if c.EndedAt.After(sp.ToolsEnd) {
						sp.ToolsEnd = c.EndedAt
					}
				}
				if sp.ToolsEnd.Before(sp.GenEnd) {
					sp.ToolsEnd = sp.GenEnd
				}
			}
			rel.Spans = append(rel.Spans, sp)
		}
	}

	inputs := make([]toolInput, len(s.ToolCalls))
	for i, c := range s.ToolCalls {
		_ = json.Unmarshal(c.Input, &inputs[i]) // unknown shapes leave the zero value
	}

	// background tasks: launch, then every later call that names the task
	taskAt := map[string]int{}
	for i, c := range s.ToolCalls {
		res := c.ResultText()
		m := backgroundID.FindStringSubmatch(res)
		if m == nil && !inputs[i].RunInBackground {
			continue
		}
		id := fmt.Sprintf("task-%d", c.Action)
		if m != nil {
			id = m[1]
		}
		label := inputs[i].Description
		if label == "" {
			label = firstLine(inputs[i].Command, 60)
		}
		taskAt[id] = len(rel.Tasks)
		rel.Tasks = append(rel.Tasks, Task{ID: id, Label: label, Launch: c.ref(), Pickups: []CallRef{}})
	}
	for i, c := range s.ToolCalls {
		raw := string(c.Input)
		for id, ti := range taskAt {
			t := &rel.Tasks[ti]
			if c.ID == t.Launch.ToolID || c.At.Before(t.Launch.At) {
				continue
			}
			switch {
			case c.Name == "TaskStop" && inputs[i].TaskID == id:
				r := c.ref()
				t.Stop = &r
			case (c.Name == "TaskOutput" && inputs[i].TaskID == id) || strings.Contains(raw, "/"+id+".") || strings.Contains(raw, id+".output"):
				t.Pickups = append(t.Pickups, c.ref())
				t.Output = c.ResultText()
			}
		}
	}

	// hand-backs
	for _, sa := range s.Subagents {
		var spawn *ToolCall
		for _, c := range s.ToolCalls {
			if c.Subagent == sa {
				spawn = c
				break
			}
		}
		if spawn == nil || sa.Session == nil {
			continue
		}
		hb := Handback{AgentID: sa.AgentID, Spawn: spawn.ref(), EndedAt: sa.Session.LastAt, Action: -1}
		if spawn.Turn < len(s.Turns) {
			for _, a := range s.Turns[spawn.Turn].Actions {
				if a.Index > spawn.Action && !a.At.Before(hb.EndedAt) {
					hb.Action = a.Index
					break
				}
			}
		}
		for _, c := range sa.Session.ToolCalls {
			if c.Name == "SubagentHandback" {
				var in toolInput
				if json.Unmarshal(c.Input, &in) == nil {
					hb.Message = in.Message
				}
			}
		}
		rel.Handbacks = append(rel.Handbacks, hb)
	}

	// retries
	for i, c := range s.ToolCalls {
		if !c.IsError {
			continue
		}
		for _, d := range s.ToolCalls[i+1:] {
			if d.Turn != c.Turn {
				break
			}
			if d.Name == c.Name && d.Action > c.Action { // the same action's parallel calls are siblings, not retries
				rel.Retries = append(rel.Retries, Retry{Failed: c.ref(), Retry: d.ref()})
				break
			}
		}
	}

	// files and outside services
	files := map[string]*FileTouched{}
	turnsOf := map[string]map[int]bool{}
	touch := func(c *ToolCall, path, mode string) {
		path = strings.TrimPrefix(path, "./")
		if path == "" || noisePath.MatchString(path) {
			return
		}
		f := files[path]
		if f == nil {
			f = &FileTouched{Path: path}
			files[path] = f
			turnsOf[path] = map[int]bool{}
		}
		for _, t := range f.Touches {
			if t.ToolID == c.ID {
				return
			}
		}
		f.Touches = append(f.Touches, FileTouch{CallRef: c.ref(), Mode: mode, Tool: c.Name})
		turnsOf[path][c.Turn] = true
		if mode == "write" {
			f.Writes++
		}
	}
	outside := map[string]*Outside{}
	reach := func(kind, name string, c *ToolCall) {
		k := kind + "\x00" + name
		o := outside[k]
		if o == nil {
			o = &Outside{Kind: kind, Name: name}
			outside[k] = o
		}
		o.Calls = append(o.Calls, c.ref())
	}
	for i, c := range s.ToolCalls {
		in := inputs[i]
		switch {
		case c.Name == "Read" || c.Name == "Glob" || c.Name == "Grep" || c.Name == "LS":
			touch(c, firstNonEmpty(in.FilePath, in.Path), "read")
		case c.Name == "Write" || c.Name == "Edit" || c.Name == "MultiEdit" || c.Name == "NotebookEdit":
			touch(c, firstNonEmpty(in.FilePath, in.NotebookPath), "write")
		case c.Name == "Bash" && in.Command != "":
			seen := map[string]bool{}
			for _, p := range pathInCommand.FindAllString(in.Command, -1) {
				if seen[p] {
					continue
				}
				seen[p] = true
				mode := "read"
				if writesTo(in.Command, p) {
					mode = "write"
				}
				touch(c, p, mode)
			}
		case c.Name == "WebFetch" && in.URL != "":
			host := in.URL
			if u, err := url.Parse(in.URL); err == nil && u.Host != "" {
				host = u.Host
			}
			reach("web", host, c)
		case c.Name == "WebSearch":
			reach("search", "web search", c)
		case c.Name == "Skill" && in.Skill != "":
			reach("skill", in.Skill, c)
		case strings.HasPrefix(c.Name, "mcp__"):
			parts := strings.SplitN(c.Name, "__", 3)
			if len(parts) >= 2 {
				reach("connector", parts[1], c)
			}
		}
	}
	for p, f := range files {
		f.Turns = len(turnsOf[p])
		rel.Files = append(rel.Files, *f)
	}
	sort.Slice(rel.Files, func(i, j int) bool {
		a, b := rel.Files[i], rel.Files[j]
		if a.Writes != b.Writes {
			return a.Writes > b.Writes
		}
		if len(a.Touches) != len(b.Touches) {
			return len(a.Touches) > len(b.Touches)
		}
		return a.Path < b.Path
	})
	for _, o := range outside {
		rel.Outside = append(rel.Outside, *o)
	}
	sort.Slice(rel.Outside, func(i, j int) bool {
		if rel.Outside[i].Kind != rel.Outside[j].Kind {
			return rel.Outside[i].Kind < rel.Outside[j].Kind
		}
		return rel.Outside[i].Name < rel.Outside[j].Name
	})

	// events
	turnAt := func(at time.Time) int {
		n := 0
		for _, t := range s.Turns {
			if !t.StartAt.After(at) {
				n = t.Index
			}
		}
		return n
	}
	for _, r := range s.Records {
		if r.Type == "system" && r.Subtype == "api_error" {
			rel.Events = append(rel.Events, Event{Kind: "api_error", At: r.Timestamp, Turn: turnAt(r.Timestamp), Message: errorText(r.Error)})
		}
	}
	for _, a := range s.Actions {
		if !a.Synthetic {
			continue
		}
		kind := "synthetic"
		if a.SyntheticKind == "api_error" {
			kind = "synthetic_api_error"
		}
		idx := a.Index
		rel.Events = append(rel.Events, Event{Kind: kind, At: a.At, Turn: a.Turn, Action: &idx, Message: firstLine(a.Text(), 200)})
	}
	sort.SliceStable(rel.Events, func(i, j int) bool { return rel.Events[i].At.Before(rel.Events[j].At) })
	return rel
}

func firstNonEmpty(a ...string) string {
	for _, s := range a {
		if s != "" {
			return s
		}
	}
	return ""
}

// writesTo says whether a shell command writes the path: a redirect, tee, an
// in-place edit, or the destination of cp, mv or touch.
func writesTo(cmd, path string) bool {
	q := regexp.QuoteMeta(path)
	re, err := regexp.Compile(`(?:>{1,2}\s*|tee\s+(?:-a\s+)?|sed\s+-i[^|;&\n]*\s|cp\s+\S+\s+|mv\s+\S+\s+|touch\s+)` + q)
	return err == nil && re.MatchString(cmd)
}

// errorText renders a record's error field: a string, or an object's message.
func errorText(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return firstLine(s, 200)
	}
	var o struct {
		Message string `json:"message"`
		Error   struct {
			Message string `json:"message"`
			Type    string `json:"type"`
		} `json:"error"`
		Status int `json:"status"`
	}
	if json.Unmarshal(raw, &o) == nil {
		msg := firstNonEmpty(o.Message, o.Error.Message, o.Error.Type)
		if o.Status != 0 {
			msg = strings.TrimSpace(fmt.Sprintf("%d %s", o.Status, msg))
		}
		return firstLine(msg, 200)
	}
	return ""
}

// ImageRef describes one image in the session without its bytes.
type ImageRef struct {
	Index     int       `json:"index"`
	Turn      int       `json:"turn"`
	At        time.Time `json:"at"`
	Where     string    `json:"where"` // "prompt" or "tool_result"
	ToolID    string    `json:"tool_id,omitempty"`
	MediaType string    `json:"media_type"`
	Size      int       `json:"size"` // decoded bytes
}

// Images lists every inline image in file order, without payloads.
func (s *Session) Images() []ImageRef {
	refs, _ := s.images(-1)
	return refs
}

// ImageData returns image n's media type and base64 payload. It fails after
// StripImages, which removes payloads.
func (s *Session) ImageData(n int) (mediaType, b64 string, err error) {
	refs, data := s.images(n)
	if n < 0 || n >= len(refs) {
		return "", "", fmt.Errorf("image %d out of range (session has %d images)", n, len(refs))
	}
	if data == "" {
		return "", "", fmt.Errorf("image %d has no payload in this transcript", n)
	}
	return refs[n].MediaType, data, nil
}

func (s *Session) images(want int) ([]ImageRef, string) {
	refs := []ImageRef{}
	data := ""
	turn := 0
	promptTurn := map[string]int{}
	for _, t := range s.Turns {
		if t.Prompt != nil {
			promptTurn[t.Prompt.UUID] = t.Index
		}
	}
	add := func(r *Record, b Block, where, toolID string) {
		if b.Type != "image" || b.Source == nil {
			return
		}
		size := b.Source.Size
		if b.Source.Data != "" {
			size = len(b.Source.Data) * 3 / 4
		}
		if len(refs) == want {
			data = b.Source.Data
		}
		refs = append(refs, ImageRef{Index: len(refs), Turn: turn, At: r.Timestamp, Where: where, ToolID: toolID, MediaType: b.Source.MediaType, Size: size})
	}
	for _, r := range s.Records {
		if r.Type != "user" || r.Message == nil {
			continue
		}
		if t, ok := promptTurn[r.UUID]; ok {
			turn = t
		}
		for _, b := range r.Message.Content {
			add(r, b, "prompt", "")
			if b.Type == "tool_result" {
				for _, inner := range b.Content {
					add(r, inner, "tool_result", b.ToolUseID)
				}
			}
		}
	}
	return refs, data
}
