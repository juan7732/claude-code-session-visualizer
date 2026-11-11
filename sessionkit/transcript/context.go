package transcript

import (
	"encoding/json"
	"fmt"
	"strings"
	"unicode/utf8"
)

// Context visibility: what the model actually received for one action.
//
// Claude Code records every request it sends: `api-request` (parameters,
// cache breakpoints, hashes of the message bodies), `api-request-blob` (one
// message body per hash) and `api-request-shape` (the system prompt and tool
// definitions shared by requests of the same shape). Together with the
// `attachment` records injected around the prompt, they explain the context
// size reported in usage. These records are bulky. The archive keeps them
// unless a session was archived with --strip-requests (ADR 0007), in which
// case its breakdown is unavailable.

// ContextBreakdown explains one action's context.
type ContextBreakdown struct {
	Action    int    `json:"action"`
	Turn      int    `json:"turn"`
	Available bool   `json:"available"`
	Reason    string `json:"reason,omitempty"` // why not, when Available is false

	Usage           Usage `json:"usage"`
	ReportedTokens  int   `json:"reported_tokens"`  // input + cache creation + cache read
	EstimatedTokens int   `json:"estimated_tokens"` // chars/4 over everything below; runs low for JSON schemas

	System      []TextPart       `json:"system"`
	Tools       []ToolDef        `json:"tools"`
	ToolsChars  int              `json:"tools_chars"`
	Messages    []MessagePart    `json:"messages"`
	Keep        int              `json:"keep"` // messages reused from the previous request (not in Messages)
	Attachments []AttachmentPart `json:"attachments"`
	CacheBreaks []string         `json:"cache_breakpoints"`
	Params      json.RawMessage  `json:"params,omitempty"`
}

// TextPart is one system prompt block.
type TextPart struct {
	Chars int    `json:"chars"`
	Head  string `json:"head"`
	Text  string `json:"text,omitempty"`
}

// ToolDef is one tool definition sent with the request.
type ToolDef struct {
	Name  string `json:"name"`
	Chars int    `json:"chars"`
	Text  string `json:"text,omitempty"` // the definition JSON, when full
}

// MessagePart is one message body in the request.
type MessagePart struct {
	Role   string      `json:"role"`
	Chars  int         `json:"chars"`
	Blocks []BlockPart `json:"blocks"`
}

// BlockPart is one content block of a request message.
type BlockPart struct {
	Type  string `json:"type"`
	Label string `json:"label,omitempty"` // e.g. "CLAUDE.md (instructions)" when recognised
	Chars int    `json:"chars"`
	Head  string `json:"head"`
	Text  string `json:"text,omitempty"`
}

// AttachmentPart is one thing Claude Code injected between the previous
// action and this one.
type AttachmentPart struct {
	Type  string `json:"type"`
	Role  string `json:"role"`
	Chars int    `json:"chars"`
	Head  string `json:"head"`
	Text  string `json:"text,omitempty"`
}

// EstimateTokens is the rough rule used throughout: four characters per token.
func EstimateTokens(chars int) int { return chars / 4 }

func head(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	if len(s) > 100 {
		return clip(s, 100) + "…"
	}
	return s
}

// clip is at most the first n bytes of s, never ending inside a character.
func clip(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	return s[:n]
}

type apiRequest struct {
	ID        string          `json:"id"`
	ShapeHash string          `json:"shapeHash"`
	Keep      int             `json:"keep"`
	Tail      []string        `json:"tail"`
	Params    json.RawMessage `json:"params"`
	Cache     []struct {
		Path []any `json:"path"`
	} `json:"cacheControl"`
}

type apiShape struct {
	ShapeHash string `json:"shapeHash"`
	Shape     struct {
		System json.RawMessage   `json:"system"`
		Tools  []json.RawMessage `json:"tools"`
	} `json:"shape"`
}

type apiBlob struct {
	Hash    string `json:"hash"`
	Message struct {
		Role    string `json:"role"`
		Content Blocks `json:"content"`
	} `json:"message"`
}

// ContextOf explains what the model received for action n. With full, the
// texts of every component are included (system blocks, tool definitions,
// message blocks, attachments); otherwise only sizes and heads.
func (s *Session) ContextOf(n int, full bool) (ContextBreakdown, error) {
	if n < 0 || n >= len(s.Actions) {
		return ContextBreakdown{}, fmt.Errorf("action %d out of range (session has %d actions)", n, len(s.Actions))
	}
	a := s.Actions[n]
	cb := ContextBreakdown{Action: a.Index, Turn: a.Turn, Usage: a.Usage, ReportedTokens: a.Usage.ContextTokens(),
		System: []TextPart{}, Tools: []ToolDef{}, Messages: []MessagePart{}, Attachments: []AttachmentPart{}, CacheBreaks: []string{}}
	if a.Synthetic || len(a.Records) == 0 {
		cb.Reason = "synthetic message: Claude Code wrote it without a request"
		return cb, nil
	}

	// Attachments injected since the previous action (file order).
	firstIdx := recordIndex(s, a.Records[0])
	prevIdx := -1
	if n > 0 && len(s.Actions[n-1].Records) > 0 {
		prevIdx = recordIndex(s, s.Actions[n-1].Records[len(s.Actions[n-1].Records)-1])
	}
	chars := 0
	for i := prevIdx + 1; i < firstIdx && i < len(s.Records); i++ {
		r := s.Records[i]
		if r.Type != "attachment" || r.Attachment == nil {
			continue
		}
		var rendered struct {
			Rendered []struct {
				Content string `json:"content"`
			} `json:"rendered"`
		}
		_ = r.Decode(&rendered)
		var sb strings.Builder
		for _, x := range rendered.Rendered {
			sb.WriteString(x.Content)
		}
		txt := sb.String()
		p := AttachmentPart{Type: r.Attachment.Type, Role: r.RenderedRole, Chars: len(txt), Head: head(txt)}
		if full {
			p.Text = txt
		}
		cb.Attachments = append(cb.Attachments, p)
		chars += len(txt)
	}

	// The request itself: its record, its shape and the blobs of its tail,
	// each decoded now from where the index says it is.
	ref := a.Records[0].RequestRef
	where := s.requestRecords()
	var req *apiRequest
	if r := where.requests[ref]; r != nil && ref != "" {
		var x apiRequest
		if r.Decode(&x) == nil {
			req = &x
		}
	}
	if req == nil {
		cb.Reason = "no api-request record for this action (archived with --strip-requests, or an older Claude Code)"
		cb.EstimatedTokens = EstimateTokens(chars)
		return cb, nil
	}
	cb.Available = true
	cb.Keep = req.Keep
	cb.Params = req.Params
	for _, c := range req.Cache {
		parts := make([]string, 0, len(c.Path))
		for _, p := range c.Path {
			parts = append(parts, fmt.Sprint(p))
		}
		cb.CacheBreaks = append(cb.CacheBreaks, strings.Join(parts, "."))
	}
	if sh := where.shape(req.ShapeHash); sh != nil {
		var blocks []struct {
			Text string `json:"text"`
		}
		if json.Unmarshal(sh.Shape.System, &blocks) != nil {
			var one string
			if json.Unmarshal(sh.Shape.System, &one) == nil {
				blocks = append(blocks, struct {
					Text string `json:"text"`
				}{one})
			}
		}
		for _, b := range blocks {
			p := TextPart{Chars: len(b.Text), Head: head(b.Text)}
			if full {
				p.Text = b.Text
			}
			cb.System = append(cb.System, p)
			chars += len(b.Text)
		}
		for _, t := range sh.Shape.Tools {
			var nm struct {
				Name string `json:"name"`
			}
			_ = json.Unmarshal(t, &nm)
			d := ToolDef{Name: nm.Name, Chars: len(t)}
			if full {
				d.Text = string(t)
			}
			cb.Tools = append(cb.Tools, d)
			cb.ToolsChars += len(t)
		}
		chars += cb.ToolsChars
	}
	for _, h := range req.Tail {
		b := where.blob(h)
		if b == nil {
			cb.Messages = append(cb.Messages, MessagePart{Role: "?", Blocks: []BlockPart{{Type: "missing", Head: "blob " + clip(h, 8) + " not in transcript"}}})
			continue
		}
		mp := MessagePart{Role: b.Message.Role, Blocks: []BlockPart{}}
		for _, blk := range b.Message.Content {
			txt := blk.PlainText()
			if blk.Type == "tool_use" {
				txt = blk.Name + " " + string(blk.Input)
			}
			if blk.Type == "image" && blk.Source != nil {
				txt = fmt.Sprintf("[image %s, %d bytes]", blk.Source.MediaType, len(blk.Source.Data)*3/4)
			}
			bp := BlockPart{Type: blk.Type, Chars: len(txt), Head: head(txt), Label: labelFor(txt)}
			if full {
				bp.Text = txt
			}
			mp.Blocks = append(mp.Blocks, bp)
			mp.Chars += len(txt)
		}
		cb.Messages = append(cb.Messages, mp)
		chars += mp.Chars
	}
	cb.EstimatedTokens = EstimateTokens(chars)
	return cb, nil
}

// recordIndex is where r is in s.Records, -1 when it is not there.
func recordIndex(s *Session, r *Record) int {
	s.positionsOnce.Do(func() {
		s.positions = make(map[*Record]int, len(s.Records))
		for i, x := range s.Records {
			s.positions[x] = i
		}
	})
	if i, ok := s.positions[r]; ok {
		return i
	}
	return -1
}

// requestRecords says which record holds each request, shape and blob.
//
// DECISION: the records are found once per parsed session and decoded when
// asked for. ContextOf used to decode every api-request* record on each call,
// half a second on a 170 MB session for one click in the client (measured
// 2026-11-11). Keeping them all decoded would double what a cached session
// holds; keeping where they are costs three small maps.
type requestRecords struct {
	requests, shapes, blobs map[string]*Record
}

func (s *Session) requestRecords() *requestRecords {
	s.requestsOnce.Do(func() {
		w := requestRecords{requests: map[string]*Record{}, shapes: map[string]*Record{}, blobs: map[string]*Record{}}
		for _, r := range s.Records {
			if !r.IsAPIRequest() {
				continue
			}
			var key struct {
				ID        string `json:"id"`
				ShapeHash string `json:"shapeHash"`
				Hash      string `json:"hash"`
			}
			if r.Decode(&key) != nil {
				continue
			}
			switch r.Type {
			case "api-request":
				if _, seen := w.requests[key.ID]; !seen { // the first with an id is the request
					w.requests[key.ID] = r
				}
			case "api-request-shape":
				w.shapes[key.ShapeHash] = r
			case "api-request-blob":
				w.blobs[key.Hash] = r
			}
		}
		s.requests = w
	})
	return &s.requests
}

func (w *requestRecords) shape(hash string) *apiShape {
	r := w.shapes[hash]
	if r == nil {
		return nil
	}
	var x apiShape
	if r.Decode(&x) != nil {
		return nil
	}
	return &x
}

func (w *requestRecords) blob(hash string) *apiBlob {
	r := w.blobs[hash]
	if r == nil {
		return nil
	}
	var x apiBlob
	if r.Decode(&x) != nil {
		return nil
	}
	return &x
}

// labelFor names well-known injected blocks so a reader can see what they are.
func labelFor(txt string) string {
	t := strings.TrimSpace(txt)
	// Prefix checks first: a long injected block can quote other kinds of text.
	switch {
	case strings.HasPrefix(t, "<pasted_content"):
		return "pasted content"
	case strings.HasPrefix(t, "<ide_opened_file>") || strings.HasPrefix(t, "<ide_selection>"):
		return "IDE context"
	case strings.HasPrefix(t, "The user's message contains") && strings.Contains(t, "is the name of a skill"):
		return "skill mention and skill content"
	}
	switch {
	case strings.Contains(t, "Codebase and user instructions are shown below"):
		return "CLAUDE.md and user instructions"
	case strings.Contains(t, "You have been invoked in the following environment"):
		return "environment"
	case strings.Contains(t, "The following skills are available"):
		return "skill listing"
	case strings.Contains(t, "The following tools just became available") || strings.Contains(t, "deferred tools"):
		return "deferred tools"
	case strings.Contains(t, "Available agent types"):
		return "agent listing"
	case strings.Contains(t, "MCP Server Instructions"):
		return "MCP instructions"
	}
	return ""
}
