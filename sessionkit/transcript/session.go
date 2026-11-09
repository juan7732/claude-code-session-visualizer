package transcript

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// Session is a parsed transcript: the records, the uuid tree, and the
// structures assembled from them.
type Session struct {
	ID   string `json:"id"`
	Path string `json:"path,omitempty"`

	Title       string    `json:"title,omitempty"`
	Slug        string    `json:"slug,omitempty"`
	Cwd         string    `json:"cwd,omitempty"`  // first working directory
	Cwds        []string  `json:"cwds,omitempty"` // every distinct working directory, in order of first appearance
	GitBranch   string    `json:"git_branch,omitempty"`
	Versions    []string  `json:"versions,omitempty"`
	Entrypoints []string  `json:"entrypoints,omitempty"`
	FirstAt     time.Time `json:"first_at"`
	LastAt      time.Time `json:"last_at"`

	Records     []*Record     `json:"-"`
	Prompts     []*Prompt     `json:"prompts"`
	Turns       []*Turn       `json:"turns"`
	ToolCalls   []*ToolCall   `json:"tool_calls"`
	Compactions []*Compaction `json:"compactions"`
	Subagents   []*Subagent   `json:"subagents,omitempty"`
	PRLinks     []PRLink      `json:"pr_links,omitempty"`
	Cost        *CostState    `json:"cost,omitempty"`
	// OwnerAccount and OwnerOrg come from the session-owner record.
	OwnerAccount string `json:"owner_account,omitempty"`
	OwnerOrg     string `json:"owner_org,omitempty"`

	// Chain is the main line of the conversation, root to tip, as uuids.
	Chain []string `json:"-"`
	// Branches counts parents with more than one child (rewinds, forks).
	Branches int `json:"branches"`
	// UnknownTypes counts record types this parser does not model.
	UnknownTypes map[string]int `json:"unknown_types,omitempty"`
	// Partial is true when the file ended mid-line (still being written).
	Partial bool `json:"partial,omitempty"`

	Totals Totals `json:"totals"`

	byUUID map[string]*Record
}

// Prompt is one human message.
type Prompt struct {
	Index  int       `json:"index"`
	UUID   string    `json:"uuid"`
	At     time.Time `json:"at"`
	Text   string    `json:"text"`
	Images int       `json:"images"`
	// Context holds the text blocks the IDE or Claude Code injected into the
	// prompt (<ide_opened_file>, <ide_selection>, <system-reminder>…). They are
	// not the human's words, but they shaped what the model saw.
	Context []Block `json:"context,omitempty"`
	Record  *Record `json:"-"`
}

// Turn is one API request: the assistant records sharing a requestId, with
// their blocks in order and usage counted once.
type Turn struct {
	Index      int       `json:"index"`
	RequestID  string    `json:"request_id"`
	MessageID  string    `json:"message_id,omitempty"`
	Model      string    `json:"model"`
	At         time.Time `json:"at"`
	StopReason string    `json:"stop_reason,omitempty"`
	// Synthetic is true for messages Claude Code wrote itself (model "<synthetic>"):
	// shown on the timeline, not counted as requests. SyntheticKind says which:
	// "api_error" (the API could not be reached), "no_response" (a turn that
	// needed no model reply), or "other".
	Synthetic     bool        `json:"synthetic,omitempty"`
	SyntheticKind string      `json:"synthetic_kind,omitempty"`
	Usage         Usage       `json:"usage"`
	Blocks        []Block     `json:"blocks"`
	Records       []*Record   `json:"-"`
	ToolCalls     []*ToolCall `json:"-"`
}

// Text returns the turn's visible text blocks joined.
func (t *Turn) Text() string {
	var sb strings.Builder
	for _, b := range t.Blocks {
		if b.Type == "text" {
			if sb.Len() > 0 {
				sb.WriteString("\n")
			}
			sb.WriteString(b.Text)
		}
	}
	return sb.String()
}

// ToolCall pairs a tool_use block with the tool_result that answered it.
type ToolCall struct {
	ID      string          `json:"id"`
	Name    string          `json:"name"`
	Input   json.RawMessage `json:"input,omitempty"`
	At      time.Time       `json:"at"`
	EndedAt time.Time       `json:"ended_at,omitempty"`
	IsError bool            `json:"is_error,omitempty"`
	Paired  bool            `json:"paired"`
	// Spilled is the path Claude Code recorded for a tool output too large for
	// the transcript (<session>/tool-results/<id>.txt). Resolve it with
	// Session.SpilledPath, since the recorded path is from the original machine.
	Spilled   string    `json:"spilled,omitempty"`
	Use       *Record   `json:"-"`
	Result    *Record   `json:"-"`
	ResultIdx int       `json:"-"` // index of the tool_result block in Result.Message.Content
	Subagent  *Subagent `json:"-"`
}

// Result text, when paired.
func (c *ToolCall) ResultText() string {
	if c.Result == nil || c.Result.Message == nil || c.ResultIdx >= len(c.Result.Message.Content) {
		return ""
	}
	return c.Result.Message.Content[c.ResultIdx].PlainText()
}

// Compaction is a compact_boundary system record with the summary that followed it.
type Compaction struct {
	At         time.Time        `json:"at"`
	Metadata   *CompactMetadata `json:"metadata,omitempty"`
	Boundary   *Record          `json:"-"`
	Summary    *Record          `json:"-"`
	SummaryTxt string           `json:"summary,omitempty"`
}

// Subagent is a transcript under <session>/subagents/.
type Subagent struct {
	AgentID   string        `json:"agent_id"`
	Path      string        `json:"path"`
	ToolUseID string        `json:"tool_use_id,omitempty"`
	Meta      *SubagentMeta `json:"meta,omitempty"`
	Session   *Session      `json:"session"`
}

// SubagentMeta is agent-<id>.meta.json.
type SubagentMeta struct {
	AgentType   string `json:"agentType"`
	Description string `json:"description"`
	ToolUseID   string `json:"toolUseId"`
	SpawnDepth  int    `json:"spawnDepth"`
	Model       string `json:"model"`
	Finished    bool   `json:"finished"`
}

// Totals are the exact counts the parser eval pins.
type Totals struct {
	Records          int            `json:"records"`
	Malformed        int            `json:"malformed"`
	Prompts          int            `json:"prompts"`
	Requests         int            `json:"requests"`
	AssistantRecords int            `json:"assistant_records"`
	UserRecords      int            `json:"user_records"`
	Attachments      int            `json:"attachments"`
	ToolCalls        int            `json:"tool_calls"`
	ToolResults      int            `json:"tool_results"`
	UnpairedToolUses int            `json:"unpaired_tool_uses"`
	ToolErrors       int            `json:"tool_errors"`
	Images           int            `json:"images"`
	Compactions      int            `json:"compactions"`
	APIErrors        int            `json:"api_errors"`
	Synthetic        int            `json:"synthetic_messages"`
	SyntheticErrors  int            `json:"synthetic_api_errors"`
	InjectedBlocks   int            `json:"injected_blocks"`
	APIRequests      int            `json:"api_request_records"`
	Subagents        int            `json:"subagents"`
	Usage            Usage          `json:"usage"`
	Models           map[string]int `json:"models"`
	Tools            map[string]int `json:"tools"`
	Types            map[string]int `json:"types"`
}

// Parse reads a transcript stream and builds the session. Subagents are not
// loaded; use Load for a file on disk.
func Parse(r io.Reader) (*Session, error) {
	recs, err := ReadAll(r)
	partial := errors.Is(err, ErrPartialLine)
	if err != nil && !partial {
		return nil, err
	}
	s := Build(recs)
	s.Partial = partial
	return s, nil
}

// Load parses the file at path and its subagents directory
// (<dir>/<session-id>/subagents/agent-*.jsonl).
func Load(path string) (*Session, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	s, err := Parse(f)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	s.Path = path
	if s.ID == "" {
		s.ID = strings.TrimSuffix(filepath.Base(path), ".jsonl")
	}
	if err := s.loadSubagents(filepath.Join(filepath.Dir(path), s.ID, "subagents")); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Session) loadSubagents(dir string) error {
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".jsonl") {
			continue
		}
		p := filepath.Join(dir, name)
		f, err := os.Open(p)
		if err != nil {
			return err
		}
		sub, err := Parse(f)
		f.Close()
		if err != nil {
			return fmt.Errorf("%s: %w", p, err)
		}
		sub.Path = p
		sa := &Subagent{Path: p, Session: sub, AgentID: strings.TrimSuffix(strings.TrimPrefix(name, "agent-"), ".jsonl")}
		if len(sub.Records) > 0 && sub.Records[0].AgentID != "" {
			sa.AgentID = sub.Records[0].AgentID
		}
		if b, err := os.ReadFile(strings.TrimSuffix(p, ".jsonl") + ".meta.json"); err == nil {
			var m SubagentMeta
			if json.Unmarshal(b, &m) == nil {
				sa.Meta = &m
				sa.ToolUseID = m.ToolUseID
			}
		}
		s.AttachSubagent(sa)
	}
	return nil
}

// AttachSubagent links a subagent to the tool call that spawned it (by
// ToolUseID) and adds it to the session. Used by Load and by the archive.
func (s *Session) AttachSubagent(sa *Subagent) {
	for _, c := range s.ToolCalls {
		if sa.ToolUseID != "" && c.ID == sa.ToolUseID {
			c.Subagent = sa
			break
		}
	}
	s.Subagents = append(s.Subagents, sa)
	sort.Slice(s.Subagents, func(i, j int) bool { return s.Subagents[i].AgentID < s.Subagents[j].AgentID })
	s.Totals.Subagents = len(s.Subagents)
}

// SyntheticModel is the model name Claude Code uses for messages it generates
// itself (no API request behind them).
const SyntheticModel = "<synthetic>"

// Build assembles a Session from records in file order.
func Build(recs []*Record) *Session {
	s := &Session{
		Records:      recs,
		byUUID:       make(map[string]*Record, len(recs)),
		UnknownTypes: map[string]int{},
	}
	s.Totals.Models = map[string]int{}
	s.Totals.Tools = map[string]int{}
	s.Totals.Types = map[string]int{}
	versions, entrypoints, seenCwd := map[string]bool{}, map[string]bool{}, map[string]bool{}
	calls := map[string]*ToolCall{}
	turnsByReq := map[string]*Turn{}
	var leaf string
	var pendingCompaction *Compaction

	for _, r := range recs {
		s.Totals.Records++
		s.Totals.Types[r.Type]++
		if r.UUID != "" {
			s.byUUID[r.UUID] = r
		}
		if s.ID == "" && r.SessionID != "" {
			s.ID = r.SessionID
		}
		if !r.Timestamp.IsZero() {
			if s.FirstAt.IsZero() || r.Timestamp.Before(s.FirstAt) {
				s.FirstAt = r.Timestamp
			}
			if r.Timestamp.After(s.LastAt) {
				s.LastAt = r.Timestamp
			}
		}
		if r.Cwd != "" {
			if s.Cwd == "" {
				s.Cwd = r.Cwd
			}
			if !seenCwd[r.Cwd] {
				seenCwd[r.Cwd] = true
				s.Cwds = append(s.Cwds, r.Cwd)
			}
		}
		if r.GitBranch != "" {
			s.GitBranch = r.GitBranch
		}
		if r.Slug != "" {
			s.Slug = r.Slug
		}
		if r.Version != "" {
			versions[r.Version] = true
		}
		if r.Entrypoint != "" {
			entrypoints[r.Entrypoint] = true
		}

		switch r.Type {
		case MalformedType:
			s.Totals.Malformed++
		case "user":
			s.Totals.UserRecords++
			s.addUser(r, calls, pendingCompaction)
			if pendingCompaction != nil && r.IsCompactSummary {
				pendingCompaction = nil
			}
		case "assistant":
			s.Totals.AssistantRecords++
			s.addAssistant(r, turnsByReq, calls)
		case "system":
			switch r.Subtype {
			case "api_error":
				s.Totals.APIErrors++
			case "compact_boundary":
				c := &Compaction{At: r.Timestamp, Metadata: r.CompactMetadata, Boundary: r}
				s.Compactions = append(s.Compactions, c)
				s.Totals.Compactions++
				pendingCompaction = c
			}
		case "attachment":
			s.Totals.Attachments++
		case "ai-title":
			if r.AITitle != "" {
				s.Title = r.AITitle
			}
		case "last-prompt":
			if r.LeafUUID != "" {
				leaf = r.LeafUUID
			}
		case "cost-state":
			var c CostState
			if r.Decode(&c) == nil {
				s.Cost = &c
			}
		case "pr-link":
			var p PRLink
			if r.Decode(&p) == nil && p.URL != "" {
				s.PRLinks = append(s.PRLinks, p)
			}
		case "api-request", "api-request-blob", "api-request-shape":
			s.Totals.APIRequests++
		case "session-owner":
			var o struct {
				Account string `json:"accountUuid"`
				Org     string `json:"organizationUuid"`
			}
			if r.Decode(&o) == nil {
				s.OwnerAccount, s.OwnerOrg = o.Account, o.Org
			}
		case "queue-operation", "bridge-session", "atis-latch", "mode", "permission-mode",
			"tools-used", "file-history-snapshot", "file-history-delta":
			// known, not modelled yet
		default:
			s.UnknownTypes[r.Type]++
		}
	}

	for _, c := range s.ToolCalls {
		if !c.Paired {
			s.Totals.UnpairedToolUses++
		}
	}
	s.Versions = sortedKeys(versions)
	s.Entrypoints = sortedKeys(entrypoints)
	s.buildChain(leaf)
	return s
}

func (s *Session) addUser(r *Record, calls map[string]*ToolCall, pending *Compaction) {
	if r.Message == nil {
		return
	}
	if r.IsCompactSummary && pending != nil {
		pending.Summary = r
		pending.SummaryTxt = contentText(r.Message.Content)
	}
	images := 0
	hasToolResult := false
	for i, b := range r.Message.Content {
		switch b.Type {
		case "image":
			images++
		case "tool_result":
			hasToolResult = true
			s.Totals.ToolResults++
			for _, inner := range b.Content {
				if inner.Type == "image" {
					images++
				}
			}
			if c, ok := calls[b.ToolUseID]; ok {
				c.Result, c.ResultIdx, c.Paired, c.EndedAt, c.IsError = r, i, true, r.Timestamp, b.IsError
				c.Spilled = spilledPath(r.ToolUseResult, b.PlainText())
				if b.IsError {
					s.Totals.ToolErrors++
				}
			}
		}
	}
	s.Totals.Images += images
	if r.TurnOrigin == "human" && !hasToolResult && !r.IsCompactSummary && !r.IsMeta {
		text, injected := splitPrompt(r.Message.Content)
		p := &Prompt{Index: len(s.Prompts), UUID: r.UUID, At: r.Timestamp, Text: text, Images: images, Context: injected, Record: r}
		s.Prompts = append(s.Prompts, p)
		s.Totals.Prompts++
		s.Totals.InjectedBlocks += len(injected)
	}
}

func (s *Session) addAssistant(r *Record, turns map[string]*Turn, calls map[string]*ToolCall) {
	if r.Message == nil {
		return
	}
	key := r.RequestID
	if key == "" {
		key = "uuid:" + r.UUID // synthetic records have no requestId; each is its own turn
	}
	t, ok := turns[key]
	if !ok {
		t = &Turn{Index: len(s.Turns), RequestID: r.RequestID, MessageID: r.Message.ID, Model: r.Message.Model, At: r.Timestamp,
			Synthetic: r.Message.Model == SyntheticModel}
		if r.Message.Usage != nil {
			t.Usage = *r.Message.Usage
			s.Totals.Usage.Add(t.Usage)
		}
		turns[key] = t
		s.Turns = append(s.Turns, t)
		if t.Synthetic {
			t.SyntheticKind = syntheticKind(r)
			s.Totals.Synthetic++
			if t.SyntheticKind == "api_error" {
				s.Totals.SyntheticErrors++
			}
		} else {
			s.Totals.Requests++
			s.Totals.Models[r.Message.Model]++
		}
	}
	if r.Message.StopReason != "" {
		t.StopReason = r.Message.StopReason
	}
	t.Records = append(t.Records, r)
	for _, b := range r.Message.Content {
		if b.Type == "tool_use" {
			c := &ToolCall{ID: b.ID, Name: b.Name, Input: b.Input, At: r.Timestamp, Use: r}
			calls[b.ID] = c
			s.ToolCalls = append(s.ToolCalls, c)
			t.ToolCalls = append(t.ToolCalls, c)
			s.Totals.ToolCalls++
			s.Totals.Tools[b.Name]++
		}
	}
	// Blocks arrive one record per block, in apiBlockIndex order; keep file order
	// but sort by index when it is present and disagrees.
	t.Blocks = append(t.Blocks, r.Message.Content...)
	if len(t.Records) > 1 && r.APIBlockIndex < t.Records[len(t.Records)-2].APIBlockIndex {
		sort.SliceStable(t.Records, func(i, j int) bool { return t.Records[i].APIBlockIndex < t.Records[j].APIBlockIndex })
		t.Blocks = t.Blocks[:0]
		for _, rec := range t.Records {
			t.Blocks = append(t.Blocks, rec.Message.Content...)
		}
	}
}

// buildChain walks from the tip to the root, following logicalParentUuid
// across compaction boundaries, and counts branch points.
func (s *Session) buildChain(leaf string) {
	children := map[string]int{}
	var latest *Record
	for _, r := range s.Records {
		if r.UUID == "" {
			continue
		}
		if r.ParentUUID != "" && s.isContinuation(r) {
			children[r.ParentUUID]++
		}
		if latest == nil || r.Timestamp.After(latest.Timestamp) {
			latest = r
		}
	}
	for _, n := range children {
		if n > 1 {
			s.Branches++
		}
	}
	tip := leaf
	if _, ok := s.byUUID[tip]; !ok && latest != nil {
		tip = latest.UUID
	}
	seen := map[string]bool{}
	var chain []string
	for id := tip; id != "" && !seen[id]; {
		seen[id] = true
		r, ok := s.byUUID[id]
		if !ok {
			break
		}
		chain = append(chain, id)
		next := r.ParentUUID
		if next == "" {
			next = r.LogicalParentUUID
		}
		id = next
	}
	for i, j := 0, len(chain)-1; i < j; i, j = i+1, j-1 {
		chain[i], chain[j] = chain[j], chain[i]
	}
	s.Chain = chain
}

var spilledMarker = regexp.MustCompile(`Full output saved to: (\S+)`)

// spilledPath finds the persisted-output path of a large tool result: the
// toolUseResult's persistedOutputPath, else the marker line in the text.
func spilledPath(toolUseResult json.RawMessage, text string) string {
	if len(toolUseResult) > 0 {
		var t struct {
			Path string `json:"persistedOutputPath"`
		}
		if json.Unmarshal(toolUseResult, &t) == nil && t.Path != "" {
			return t.Path
		}
	}
	if m := spilledMarker.FindStringSubmatch(text); m != nil {
		return m[1]
	}
	return ""
}

// SpilledPath resolves a tool call's spilled output to a readable file: first
// under this session's own companion directory (so archives and fixtures
// work), then at the path Claude Code recorded. ok is false when neither exists.
func (s *Session) SpilledPath(c *ToolCall) (path string, ok bool) {
	if c == nil || c.Spilled == "" {
		return "", false
	}
	if s.Path != "" {
		local := filepath.Join(filepath.Dir(s.Path), s.ID, "tool-results", filepath.Base(c.Spilled))
		if _, err := os.Stat(local); err == nil {
			return local, true
		}
	}
	if _, err := os.Stat(c.Spilled); err == nil {
		return c.Spilled, true
	}
	return "", false
}

// isContinuation reports whether r is a conversation step that could start a
// branch under its parent. Three kinds of sibling are not branches: attachments
// and system notes (they hang off the same parent as the next message), the
// next block of the same split request (same requestId as the parent), and a
// tool_result answering a tool_use held by the parent (parallel tool calls make
// several of these point at the same record).
func (s *Session) isContinuation(r *Record) bool {
	switch r.Type {
	case "assistant":
		if p := s.byUUID[r.ParentUUID]; p != nil && p.Type == "assistant" && p.RequestID != "" && p.RequestID == r.RequestID {
			return false
		}
		return true
	case "user":
		if r.Message != nil {
			for _, b := range r.Message.Content {
				if b.Type == "tool_result" {
					return false
				}
			}
		}
		return true
	}
	return false
}

// Record returns the record with the given uuid.
func (s *Session) Record(uuid string) *Record { return s.byUUID[uuid] }

// Duration is wall time from first to last record.
func (s *Session) Duration() time.Duration { return s.LastAt.Sub(s.FirstAt) }

// injectedPrefixes mark text blocks the IDE or Claude Code added to a human
// prompt (open file, selection, system reminders). They stay in the record but
// are left out of the prompt's display text.
var injectedPrefixes = []string{"<ide_opened_file>", "<ide_selection>", "<system-reminder>", "<ide_diagnostics>"}

func isInjected(text string) bool {
	t := strings.TrimSpace(text)
	for _, p := range injectedPrefixes {
		if strings.HasPrefix(t, p) {
			return true
		}
	}
	return false
}

// syntheticKind classifies a synthetic assistant message.
func syntheticKind(r *Record) string {
	if r.IsAPIErrorMessage {
		return "api_error"
	}
	text := strings.TrimSpace(contentText(r.Message.Content))
	switch {
	case strings.HasPrefix(text, "API Error"):
		return "api_error"
	case text == "No response requested.":
		return "no_response"
	}
	return "other"
}

// InjectedKind names an injected block by its leading tag: "ide_opened_file",
// "ide_selection", "system-reminder"…; "" when the block is not injected.
func InjectedKind(text string) string {
	t := strings.TrimSpace(text)
	for _, p := range injectedPrefixes {
		if strings.HasPrefix(t, p) {
			return strings.Trim(p, "<>")
		}
	}
	return ""
}

// splitPrompt separates a human prompt into its own text and the blocks that
// were injected around it.
func splitPrompt(blocks Blocks) (string, []Block) {
	var sb strings.Builder
	var injected []Block
	for _, b := range blocks {
		if b.Type != "text" {
			continue
		}
		if isInjected(b.Text) {
			injected = append(injected, b)
			continue
		}
		if sb.Len() > 0 {
			sb.WriteString("\n")
		}
		sb.WriteString(b.Text)
	}
	return sb.String(), injected
}

func contentText(blocks Blocks) string {
	var sb strings.Builder
	for _, b := range blocks {
		if b.Type == "text" && !isInjected(b.Text) {
			if sb.Len() > 0 {
				sb.WriteString("\n")
			}
			sb.WriteString(b.Text)
		}
	}
	return sb.String()
}

func sortedKeys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
