// Package transcript parses Claude Code session transcripts: the JSONL files
// under <claude>/projects/<slug>/<session>.jsonl and their subagent files.
//
// It parses generously and counts precisely: every line becomes a Record with
// its raw bytes kept, unknown record types are preserved as opaque events, and
// Session assembles the uuid tree, turns (one per API request), tool call
// pairs, compactions and subagents. See docs/record-anatomy.md.
package transcript

import (
	"encoding/json"
	"strings"
	"time"
)

// Record is one JSONL line. Fields shared by most record types are decoded;
// everything else stays in Raw. Zero values mean "absent".
type Record struct {
	Type              string `json:"type"`
	UUID              string `json:"uuid"`
	ParentUUID        string `json:"parentUuid"`
	LogicalParentUUID string `json:"logicalParentUuid"`
	IsSidechain       bool   `json:"isSidechain"`
	SessionID         string `json:"sessionId"`
	AgentID           string `json:"agentId"`
	Cwd               string `json:"cwd"`
	GitBranch         string `json:"gitBranch"`
	Version           string `json:"version"`
	Entrypoint        string `json:"entrypoint"`
	Slug              string `json:"slug"`

	// assistant
	RequestID     string `json:"requestId"`
	APIBlockIndex int    `json:"apiBlockIndex"`

	// user
	TurnOrigin         string              `json:"turnOrigin"`
	IsMeta             bool                `json:"isMeta"`
	IsCompactSummary   bool                `json:"isCompactSummary"`
	ToolUseResult      json.RawMessage     `json:"toolUseResult"`
	PermissionDecision *PermissionDecision `json:"permissionDecision"`
	ImagePasteIDs      []int               `json:"imagePasteIds"`

	// system
	Subtype         string           `json:"subtype"`
	Level           string           `json:"level"`
	CompactMetadata *CompactMetadata `json:"compactMetadata"`

	// attachment
	Attachment   *AttachmentInfo `json:"attachment"`
	RenderedRole string          `json:"renderedRole"`

	// metadata records
	AITitle    string `json:"aiTitle"`
	LastPrompt string `json:"lastPrompt"`
	LeafUUID   string `json:"leafUuid"`

	Message *Message `json:"message"`

	// Not from JSON.
	Timestamp time.Time       `json:"-"`
	Raw       json.RawMessage `json:"-"` // the line as read, without the newline
	Offset    int64           `json:"-"` // byte offset of the line in the file
	Line      int             `json:"-"` // 1-based line number
	Malformed error           `json:"-"` // set when the line was not valid JSON; Type is then MalformedType
}

// MalformedType is the Type of a Record whose line could not be parsed.
const MalformedType = "<malformed>"

// UnmarshalJSON decodes the envelope and parses the timestamp.
func (r *Record) UnmarshalJSON(b []byte) error {
	type plain Record
	var aux struct {
		plain
		Timestamp string `json:"timestamp"`
	}
	if err := json.Unmarshal(b, &aux); err != nil {
		return err
	}
	raw, offset, line := r.Raw, r.Offset, r.Line // set by Reader before decoding; keep them
	*r = Record(aux.plain)
	r.Raw, r.Offset, r.Line = raw, offset, line
	if aux.Timestamp != "" {
		if t, err := time.Parse(time.RFC3339Nano, aux.Timestamp); err == nil {
			r.Timestamp = t
		}
	}
	return nil
}

// Decode unmarshals the raw line into v, for record types whose extra fields
// are not on Record (cost-state, pr-link, file-history-*).
func (r *Record) Decode(v any) error { return json.Unmarshal(r.Raw, v) }

// IsTimeline reports whether the record belongs on the session timeline.
func (r *Record) IsTimeline() bool {
	switch r.Type {
	case "user", "assistant", "system", "attachment":
		return true
	}
	return false
}

// IsAPIRequest reports whether the record is a copy of a request body sent to
// the model (api-request, api-request-blob, api-request-shape): bulky, and
// only kept in debug mode.
func (r *Record) IsAPIRequest() bool { return strings.HasPrefix(r.Type, "api-request") }

// PermissionDecision is how a tool call was allowed.
type PermissionDecision struct {
	Decision string `json:"decision"`
	Source   string `json:"source"`
}

// CompactMetadata describes a compaction boundary.
type CompactMetadata struct {
	Trigger                 string `json:"trigger"`
	PreTokens               int    `json:"preTokens"`
	PostTokens              int    `json:"postTokens"`
	CumulativeDroppedTokens int    `json:"cumulativeDroppedTokens"`
	DurationMs              int    `json:"durationMs"`
}

// AttachmentInfo is the kind of context Claude Code injected.
type AttachmentInfo struct {
	Type string `json:"type"`
}

// Message is the API message carried by user and assistant records.
type Message struct {
	Role       string `json:"role"`
	Model      string `json:"model"`
	ID         string `json:"id"`
	StopReason string `json:"stop_reason"`
	Content    Blocks `json:"content"`
	Usage      *Usage `json:"usage"`
}

// Blocks is message content: a list of blocks, or a bare string, which
// becomes one text block.
type Blocks []Block

func (b *Blocks) UnmarshalJSON(data []byte) error {
	data = trimSpace(data)
	if len(data) > 0 && data[0] == '"' {
		var s string
		if err := json.Unmarshal(data, &s); err != nil {
			return err
		}
		*b = Blocks{{Type: "text", Text: s}}
		return nil
	}
	var list []Block
	if err := json.Unmarshal(data, &list); err != nil {
		return err
	}
	*b = list
	return nil
}

func trimSpace(b []byte) []byte {
	for len(b) > 0 && (b[0] == ' ' || b[0] == '\n' || b[0] == '\t' || b[0] == '\r') {
		b = b[1:]
	}
	return b
}

// Block is one content block: text, thinking, tool_use, tool_result, image, or
// something newer we keep by Type only.
type Block struct {
	Type string `json:"type"`

	Text     string `json:"text,omitempty"`
	Thinking string `json:"thinking,omitempty"`

	// tool_use
	ID    string          `json:"id,omitempty"`
	Name  string          `json:"name,omitempty"`
	Input json.RawMessage `json:"input,omitempty"`

	// tool_result
	ToolUseID string `json:"tool_use_id,omitempty"`
	Content   Blocks `json:"content,omitempty"`
	IsError   bool   `json:"is_error,omitempty"`

	// image
	Source *ImageSource `json:"source,omitempty"`
}

// PlainText returns the block's text, or the concatenated text of a
// tool_result's blocks.
func (b Block) PlainText() string {
	switch b.Type {
	case "text":
		return b.Text
	case "thinking":
		return b.Thinking
	case "tool_result":
		var sb strings.Builder
		for _, c := range b.Content {
			sb.WriteString(c.PlainText())
		}
		return sb.String()
	}
	return ""
}

// ImageSource is an inline image. Size is set by Session.StripImages when the
// base64 payload is removed for output.
type ImageSource struct {
	Type      string `json:"type"`
	MediaType string `json:"media_type"`
	Data      string `json:"data,omitempty"`
	Size      int    `json:"size,omitempty"`
}

// Usage is the token accounting of one API request. Claude Code repeats it on
// every split record of the request; Session counts it once.
type Usage struct {
	InputTokens              int `json:"input_tokens"`
	OutputTokens             int `json:"output_tokens"`
	CacheCreationInputTokens int `json:"cache_creation_input_tokens"`
	CacheReadInputTokens     int `json:"cache_read_input_tokens"`
	ThinkingTokens           int `json:"-"`
	Ephemeral5mInputTokens   int `json:"-"`
	Ephemeral1hInputTokens   int `json:"-"`
	WebSearchRequests        int `json:"-"`
	WebFetchRequests         int `json:"-"`
}

func (u *Usage) UnmarshalJSON(b []byte) error {
	type plain Usage
	var aux struct {
		plain
		Details struct {
			Thinking int `json:"thinking_tokens"`
		} `json:"output_tokens_details"`
		CacheCreation struct {
			E5m int `json:"ephemeral_5m_input_tokens"`
			E1h int `json:"ephemeral_1h_input_tokens"`
		} `json:"cache_creation"`
		ServerToolUse struct {
			Search int `json:"web_search_requests"`
			Fetch  int `json:"web_fetch_requests"`
		} `json:"server_tool_use"`
	}
	if err := json.Unmarshal(b, &aux); err != nil {
		return err
	}
	*u = Usage(aux.plain)
	u.ThinkingTokens = aux.Details.Thinking
	u.Ephemeral5mInputTokens = aux.CacheCreation.E5m
	u.Ephemeral1hInputTokens = aux.CacheCreation.E1h
	u.WebSearchRequests = aux.ServerToolUse.Search
	u.WebFetchRequests = aux.ServerToolUse.Fetch
	return nil
}

// Add accumulates another usage into u.
func (u *Usage) Add(o Usage) {
	u.InputTokens += o.InputTokens
	u.OutputTokens += o.OutputTokens
	u.CacheCreationInputTokens += o.CacheCreationInputTokens
	u.CacheReadInputTokens += o.CacheReadInputTokens
	u.ThinkingTokens += o.ThinkingTokens
	u.Ephemeral5mInputTokens += o.Ephemeral5mInputTokens
	u.Ephemeral1hInputTokens += o.Ephemeral1hInputTokens
	u.WebSearchRequests += o.WebSearchRequests
	u.WebFetchRequests += o.WebFetchRequests
}

// ContextTokens approximates the context size at this request: everything the
// model read, cached or not.
func (u Usage) ContextTokens() int {
	return u.InputTokens + u.CacheCreationInputTokens + u.CacheReadInputTokens
}

// CostState is Claude Code's own running total for the session.
type CostState struct {
	TotalCostUSD                   float64               `json:"totalCostUSD"`
	TotalDurationMs                int64                 `json:"totalDuration"`
	TotalAPIDurationMs             int64                 `json:"totalAPIDuration"`
	TotalAPIDurationWithoutRetries int64                 `json:"totalAPIDurationWithoutRetries"`
	TotalToolDurationMs            int64                 `json:"totalToolDuration"`
	TotalLinesAdded                int                   `json:"totalLinesAdded"`
	TotalLinesRemoved              int                   `json:"totalLinesRemoved"`
	HasUnknownModelCost            bool                  `json:"hasUnknownModelCost"`
	ModelUsage                     map[string]ModelUsage `json:"modelUsage"`
}

// ModelUsage is Claude Code's per-model total inside CostState.
type ModelUsage struct {
	InputTokens              int     `json:"inputTokens"`
	OutputTokens             int     `json:"outputTokens"`
	ThinkingTokens           int     `json:"thinkingTokens"`
	CacheReadInputTokens     int     `json:"cacheReadInputTokens"`
	CacheCreationInputTokens int     `json:"cacheCreationInputTokens"`
	WebSearchRequests        int     `json:"webSearchRequests"`
	CostUSD                  float64 `json:"costUSD"`
}

// PRLink is a pull request Claude Code associated with the session.
type PRLink struct {
	Number     int    `json:"prNumber"`
	URL        string `json:"prUrl"`
	Repository string `json:"prRepository"`
}
