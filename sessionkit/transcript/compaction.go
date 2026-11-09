package transcript

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"
)

// CompactionDetail explains one compaction: the context before it, the
// summary that replaced the history (with its sections), the messages Claude
// Code kept verbatim, what it re-injected afterwards, and the context the
// first action after it actually received.
type CompactionDetail struct {
	Index      int       `json:"index"`
	Turn       int       `json:"turn"`
	At         time.Time `json:"at"`
	Trigger    string    `json:"trigger,omitempty"`
	DurationMs int       `json:"duration_ms,omitempty"`

	PreTokens         int `json:"pre_tokens"`         // Claude Code's count before
	PostTokens        int `json:"post_tokens"`        // Claude Code's count after (the summary and preserved messages)
	CumulativeDropped int `json:"cumulative_dropped"` // across the session so far

	LastActionBefore  *int `json:"last_action_before,omitempty"`
	ContextBefore     int  `json:"context_before"` // reported context of the last action before
	FirstActionAfter  *int `json:"first_action_after,omitempty"`
	ContextAfter      int  `json:"context_after"` // reported context of the first action after
	ReinjectedChars   int  `json:"reinjected_chars"`
	SummarisedPrompts int  `json:"summarised_prompts"` // prompts folded into the summary (from summarizedTurnPromptUuids)

	Summary    SummaryPart      `json:"summary"`
	Preserved  []PreservedPart  `json:"preserved"`
	Reinjected []AttachmentPart `json:"reinjected"`
	FileRefs   []string         `json:"file_refs,omitempty"` // files Claude Code re-read after compacting
}

// SummaryPart is the compaction summary.
type SummaryPart struct {
	Chars    int           `json:"chars"`
	Sections []SectionPart `json:"sections"`
	Text     string        `json:"text,omitempty"`
}

// SectionPart is one numbered section of the summary.
type SectionPart struct {
	Title string `json:"title"`
	Chars int    `json:"chars"`
}

// PreservedPart is a message kept verbatim across the compaction.
type PreservedPart struct {
	UUID   string `json:"uuid"`
	Type   string `json:"type"`           // user | assistant | attachment
	Kind   string `json:"kind,omitempty"` // prompt, tool_result, text…, or the attachment type
	Turn   int    `json:"turn"`
	Action int    `json:"action"` // -1 when not an action
	Chars  int    `json:"chars"`
	Head   string `json:"head"`
	Text   string `json:"text,omitempty"`
}

type compactMeta struct {
	Trigger           string `json:"trigger"`
	PreTokens         int    `json:"preTokens"`
	PostTokens        int    `json:"postTokens"`
	Cumulative        int    `json:"cumulativeDroppedTokens"`
	DurationMs        int    `json:"durationMs"`
	PreservedMessages struct {
		UUIDs    []string `json:"uuids"`
		AllUUIDs []string `json:"allUuids"`
	} `json:"preservedMessages"`
}

var sectionRe = regexp.MustCompile(`(?m)^\s*(\d+)\.\s+([^\n:]+):?\s*$`)

// CompactionOf explains compaction n. With full, the summary, preserved and
// re-injected texts are included.
func (s *Session) CompactionOf(n int, full bool) (CompactionDetail, error) {
	if n < 0 || n >= len(s.Compactions) {
		return CompactionDetail{}, fmt.Errorf("compaction %d out of range (session has %d compactions)", n, len(s.Compactions))
	}
	c := s.Compactions[n]
	d := CompactionDetail{Index: n, Turn: -1, At: c.At, Preserved: []PreservedPart{}, Reinjected: []AttachmentPart{}, FileRefs: []string{}}
	for _, t := range s.Turns {
		for _, tc := range t.Compactions {
			if tc == c {
				d.Turn = t.Index
			}
		}
	}
	var meta compactMeta
	if c.Boundary != nil {
		var wrap struct {
			M compactMeta `json:"compactMetadata"`
		}
		if c.Boundary.Decode(&wrap) == nil {
			meta = wrap.M
		}
	}
	d.Trigger, d.DurationMs, d.PreTokens, d.PostTokens, d.CumulativeDropped = meta.Trigger, meta.DurationMs, meta.PreTokens, meta.PostTokens, meta.Cumulative

	// Actions around the boundary.
	bIdx := recordIndex(s, c.Boundary)
	actionByReq := map[string]*Action{}
	for _, a := range s.Actions {
		if a.RequestID != "" {
			actionByReq[a.RequestID] = a
		}
	}
	for _, a := range s.Actions {
		if a.Synthetic || len(a.Records) == 0 {
			continue
		}
		ri := recordIndex(s, a.Records[0])
		if ri < bIdx {
			idx := a.Index
			d.LastActionBefore, d.ContextBefore = &idx, a.Usage.ContextTokens()
		} else if d.FirstActionAfter == nil {
			idx := a.Index
			d.FirstActionAfter, d.ContextAfter = &idx, a.Usage.ContextTokens()
		}
	}

	// The summary.
	if c.Summary != nil {
		var sum struct {
			Prompts []string `json:"summarizedTurnPromptUuids"`
		}
		_ = c.Summary.Decode(&sum)
		d.SummarisedPrompts = len(sum.Prompts)
		txt := c.SummaryTxt
		d.Summary = SummaryPart{Chars: len(txt), Sections: []SectionPart{}}
		if full {
			d.Summary.Text = txt
		}
		locs := sectionRe.FindAllStringSubmatchIndex(txt, -1)
		for i, loc := range locs {
			end := len(txt)
			if i+1 < len(locs) {
				end = locs[i+1][0]
			}
			d.Summary.Sections = append(d.Summary.Sections, SectionPart{Title: strings.TrimSpace(txt[loc[4]:loc[5]]), Chars: end - loc[0]})
		}
	}

	// Preserved messages.
	promptTurn := map[string]int{}
	for _, t := range s.Turns {
		if t.Prompt != nil {
			promptTurn[t.Prompt.UUID] = t.Index
		}
	}
	uuids := meta.PreservedMessages.AllUUIDs
	if len(uuids) == 0 {
		uuids = meta.PreservedMessages.UUIDs
	}
	for _, u := range uuids {
		r := s.byUUID[u]
		if r == nil {
			d.Preserved = append(d.Preserved, PreservedPart{UUID: u, Type: "missing", Turn: -1, Action: -1})
			continue
		}
		p := PreservedPart{UUID: u, Type: r.Type, Turn: -1, Action: -1}
		switch r.Type {
		case "assistant":
			if a := actionByReq[r.RequestID]; a != nil {
				p.Action, p.Turn = a.Index, a.Turn
			}
			p.Kind = blockKinds(r)
		case "user":
			if t, ok := promptTurn[u]; ok {
				p.Kind, p.Turn = "prompt", t
			} else {
				p.Kind = blockKinds(r)
			}
		case "attachment":
			if r.Attachment != nil {
				p.Kind = r.Attachment.Type
			}
		}
		txt := recordText(r)
		p.Chars, p.Head = len(txt), head(txt)
		if full {
			p.Text = txt
		}
		d.Preserved = append(d.Preserved, p)
	}

	// Re-injected context: attachments between the boundary and the first action after it.
	end := len(s.Records)
	if d.FirstActionAfter != nil {
		end = recordIndex(s, s.Actions[*d.FirstActionAfter].Records[0])
	}
	for i := bIdx + 1; i < end; i++ {
		r := s.Records[i]
		if r.Type != "attachment" || r.Attachment == nil {
			continue
		}
		txt := recordText(r)
		p := AttachmentPart{Type: r.Attachment.Type, Role: r.RenderedRole, Chars: len(txt), Head: head(txt)}
		if full {
			p.Text = txt
		}
		d.Reinjected = append(d.Reinjected, p)
		d.ReinjectedChars += len(txt)
		if r.Attachment.Type == "compact_file_reference" || r.Attachment.Type == "file" {
			if f := fileRef(r); f != "" {
				d.FileRefs = append(d.FileRefs, f)
			}
		}
	}
	return d, nil
}

func blockKinds(r *Record) string {
	if r.Message == nil {
		return ""
	}
	seen := map[string]bool{}
	var kinds []string
	for _, b := range r.Message.Content {
		if !seen[b.Type] {
			seen[b.Type] = true
			kinds = append(kinds, b.Type)
		}
	}
	return strings.Join(kinds, "+")
}

// recordText is the human-readable text of a record: message text, or an
// attachment's rendered content.
func recordText(r *Record) string {
	if r.Type == "attachment" {
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
		return sb.String()
	}
	if r.Message == nil {
		return ""
	}
	var sb strings.Builder
	for _, b := range r.Message.Content {
		if t := b.PlainText(); t != "" {
			if sb.Len() > 0 {
				sb.WriteString("\n")
			}
			sb.WriteString(t)
		}
	}
	return sb.String()
}

// fileRef pulls a file path out of a compact_file_reference or file attachment.
func fileRef(r *Record) string {
	var a struct {
		Attachment map[string]json.RawMessage `json:"attachment"`
	}
	if r.Decode(&a) == nil {
		for _, k := range []string{"filename", "path", "file_path", "filePath"} {
			if v, ok := a.Attachment[k]; ok {
				var s string
				if json.Unmarshal(v, &s) == nil && s != "" {
					return s
				}
			}
		}
	}
	txt := recordText(r)
	if m := regexp.MustCompile(`(/[^\s"'<>]+)`).FindString(txt); m != "" {
		return m
	}
	return ""
}
