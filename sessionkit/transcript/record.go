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
	"errors"
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
	RequestID         string          `json:"requestId"`
	RequestRef        string          `json:"requestRef"` // id of the api-request record that produced this response
	APIBlockIndex     int             `json:"apiBlockIndex"`
	IsAPIErrorMessage bool            `json:"isApiErrorMessage"`
	Error             json.RawMessage `json:"error"` // a string on synthetic error messages, an object on system api_error records

	// user
	TurnOrigin         string              `json:"turnOrigin"`
	Origin             Origin              `json:"origin"` // what Claude Code 2.1.26x wrote where turnOrigin is now
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
	// Mismatch is set when the line was JSON but a field had a type this
	// parser does not expect. The record is kept with every field that did
	// decode; that one field is absent.
	Mismatch error `json:"-"`
}

// Origin is who or what a user record came from. It is an object with a kind
// in the transcripts seen; a bare string is read as the kind.
type Origin struct {
	Kind string `json:"kind"`
}

func (o *Origin) UnmarshalJSON(data []byte) error {
	data = trimSpace(data)
	if len(data) > 0 && data[0] == '"' {
		return lenient(json.Unmarshal(data, &o.Kind))
	}
	type plain Origin
	return lenient(json.Unmarshal(data, (*plain)(o)))
}

// TurnStarter is what started the turn this user record opens, "" when the
// record does not say: "human", or what Claude Code names a message of its
// own ("task_notification", "peer").
//
// DECISION: turnOrigin first, then origin.kind. Claude Code 2.1.263 and 2.1.267
// wrote prompts with origin {"kind":"human"} and no turnOrigin (13 of the 36
// prompts of one session on the machine this was found on, 2026-11-11); read
// by turnOrigin alone they were not prompts, opened no turn and were not
// indexed for search. origin spells a kind with a hyphen where turnOrigin has
// an underscore ("task-notification"); the underscore is the one kept.
func (r *Record) TurnStarter() string {
	if r.TurnOrigin != "" {
		return r.TurnOrigin
	}
	return strings.ReplaceAll(r.Origin.Kind, "-", "_")
}

// lenient lets a decoder keep what it could read. encoding/json fills every
// field it can and reports the first whose type did not fit; for a format that
// changes with each Claude Code release, one such field is not a reason to
// lose the record. The mismatch is remembered by Record.UnmarshalJSON.
func lenient(err error) error {
	var te *json.UnmarshalTypeError
	if errors.As(err, &te) {
		return nil
	}
	return err
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
	// DECISION: a field of an unexpected type costs that field, not the record.
	// It used to make the whole line <malformed>: a user record whose
	// imagePasteIds were strings lost its prompt, an assistant record with an
	// unfamiliar block lost its request and its tokens, and nothing said so.
	err := json.Unmarshal(b, &aux)
	if lenient(err) != nil {
		return err
	}
	raw, offset, line := r.Raw, r.Offset, r.Line // set by Reader before decoding; keep them
	*r = Record(aux.plain)
	r.Raw, r.Offset, r.Line = raw, offset, line
	r.Mismatch = err
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
// the model (api-request, api-request-blob, api-request-shape): bulky, kept by
// the archive unless it was made with --strip-requests (ADR 0007).
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
// becomes one text block. A single object (the error a server tool returns in
// place of its list) is kept as one block; anything else is no blocks.
type Blocks []Block

func (b *Blocks) UnmarshalJSON(data []byte) error {
	data = trimSpace(data)
	if len(data) == 0 {
		return nil
	}
	switch data[0] {
	case '"':
		var s string
		if err := json.Unmarshal(data, &s); err != nil {
			return err
		}
		*b = Blocks{{Type: "text", Text: s}}
	case '[':
		var items []json.RawMessage
		if err := json.Unmarshal(data, &items); err != nil {
			return err
		}
		list := make(Blocks, 0, len(items))
		for _, item := range items {
			item = trimSpace(item)
			var blk Block
			if len(item) > 0 && item[0] == '"' { // a string among the blocks is text
				blk.Type = "text"
				if err := json.Unmarshal(item, &blk.Text); err != nil {
					return err
				}
			} else if err := json.Unmarshal(item, &blk); err != nil {
				return err
			}
			list = append(list, blk)
		}
		*b = list
	case '{':
		var blk Block
		if err := json.Unmarshal(data, &blk); err != nil {
			return err
		}
		*b = Blocks{blk}
	default: // null, a number, a boolean: nothing to show
		*b = nil
	}
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

// UnmarshalJSON keeps the fields that fit when one does not (a search result
// whose source is a string, where an image's is an object).
func (b *Block) UnmarshalJSON(data []byte) error {
	type plain Block
	err := lenient(json.Unmarshal(data, (*plain)(b)))
	if b.Source != nil && *b.Source == (ImageSource{}) {
		b.Source = nil // a source that was not an object leaves an empty one behind
	}
	return err
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

// ImageSource is an inline image. Data is the base64 payload as read from the
// transcript; it never leaves through JSON (see MarshalJSON). Session.ImageData
// is the way to an image's bytes.
type ImageSource struct {
	Type      string `json:"type"`
	MediaType string `json:"media_type"`
	Data      string `json:"data,omitempty"`
	Size      int    `json:"size,omitempty"`
}

// MarshalJSON writes the image's size in place of its payload, so a JSON
// document never carries megabytes of base64 and no caller has to strip a
// session (which may be shared) before printing it.
func (s ImageSource) MarshalJSON() ([]byte, error) {
	size := s.Size
	if s.Data != "" {
		size = len(s.Data) * 3 / 4
	}
	return json.Marshal(struct {
		Type      string `json:"type"`
		MediaType string `json:"media_type"`
		Size      int    `json:"size,omitempty"`
	}{s.Type, s.MediaType, size})
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
	if err := lenient(json.Unmarshal(b, &aux)); err != nil {
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
