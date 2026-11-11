package now

import (
	"bytes"
	"errors"
	"io"
	"os"
	"strings"
	"time"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/transcript"
)

// tailBytes is how much of a transcript's end is read at first, and maxTail
// how much at most when that does not hold what is needed.
//
// DECISION: the tail, never the file. A running session's transcript grows
// every few seconds and can be over a hundred megabytes; what it is doing now
// lies in its last records (measured 2026-11-11: within 32 kB on five
// transcripts). One long line (a request's copy, an image) can push it
// further back, so the read grows once before giving up.
const (
	tailBytes = 1 << 20
	maxTail   = 16 << 20
)

// tail is what the end of a transcript says.
type tail struct {
	title      string
	lastPrompt string
	cwd        string
	model      string
	// lastAt is the time of the last record of the conversation.
	lastAt time.Time
	// pending are tool calls with no result yet, oldest first; lastTool is the
	// call whose result came back last.
	pending  []Tool
	lastTool *Tool
	// ended is true when the last word is the agent's and it stopped: the turn
	// is over. said is that word's text, endedAt its time.
	ended   bool
	endedAt time.Time
	said    string
	// usage is the last request's; requestAt when it was sent (or answered,
	// when the transcript keeps no copy of requests).
	usage     *transcript.Usage
	requestAt time.Time
	// ttl is the lifetime of the last cache write seen: 300 or 3600 seconds, 0 when none was.
	ttl int
	// complete is false when the read ran out before a request was found.
	complete bool
}

// readTail reads the end of the transcript at path.
func readTail(path string, size int64) (*tail, error) {
	for budget := int64(tailBytes); ; budget *= 4 {
		recs, whole, err := lastRecords(path, size, budget)
		if err != nil {
			return nil, err
		}
		t := summarise(recs)
		if t.complete || whole || budget >= maxTail {
			return t, nil
		}
	}
}

// lastRecords parses the records in the last budget bytes of the file. whole
// is true when that is the whole file.
func lastRecords(path string, size, budget int64) (recs []*transcript.Record, whole bool, err error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, false, err
	}
	defer f.Close()
	start := size - budget
	if start <= 0 {
		start, whole = 0, true
	}
	buf := make([]byte, size-start)
	n, err := io.ReadFull(io.NewSectionReader(f, start, size-start), buf)
	if err != nil && !errors.Is(err, io.ErrUnexpectedEOF) && !errors.Is(err, io.EOF) {
		return nil, whole, err
	}
	buf = buf[:n]
	if !whole {
		// The read starts in the middle of a line: drop what is left of it.
		if i := bytes.IndexByte(buf, '\n'); i >= 0 {
			buf = buf[i+1:]
		} else {
			buf = nil
		}
	}
	// A line still being written at the end is left out by the reader.
	recs, err = transcript.ReadAll(bytes.NewReader(buf))
	if errors.Is(err, transcript.ErrPartialLine) {
		err = nil
	}
	return recs, whole, err
}

// summarise reads records in file order into what they say about now.
func summarise(recs []*transcript.Record) *tail {
	t := &tail{}
	// sent is when the last copy of a request was written, answered when the
	// last answer with usage was.
	var sent, answered time.Time
	pending := map[string]int{} // tool_use id → index in t.pending
	for _, r := range recs {
		if r.Malformed != nil || r.IsSidechain {
			continue
		}
		if r.Cwd != "" {
			t.cwd = r.Cwd
		}
		switch r.Type {
		case "ai-title":
			if r.AITitle != "" {
				t.title = r.AITitle
			}
		case "last-prompt":
			if r.LastPrompt != "" {
				t.lastPrompt = r.LastPrompt
			}
		case "api-request":
			if !r.Timestamp.IsZero() {
				sent = r.Timestamp
			}
		case "user":
			if r.Message == nil {
				continue
			}
			t.lastAt = later(t.lastAt, r.Timestamp)
			// Something was handed to the model: a prompt, or a tool's result.
			t.ended, t.said = false, ""
			for _, b := range r.Message.Content {
				if b.Type != "tool_result" {
					continue
				}
				if i, ok := pending[b.ToolUseID]; ok {
					t.pending[i].done = true
					delete(pending, b.ToolUseID)
					done, ended := t.pending[i], r.Timestamp
					done.EndedAt, done.Failed = &ended, b.IsError
					t.lastTool = &done
				}
			}
		case "assistant":
			if r.Message == nil {
				continue
			}
			t.lastAt = later(t.lastAt, r.Timestamp)
			synthetic := r.Message.Model == transcript.SyntheticModel
			if u := r.Message.Usage; u != nil && !synthetic {
				t.usage, t.model, t.complete = u, r.Message.Model, true
				answered = r.Timestamp
				switch {
				case u.Ephemeral5mInputTokens > 0:
					// Where a request wrote both, the conversation is what the short one holds.
					t.ttl = 300
				case u.Ephemeral1hInputTokens > 0:
					t.ttl = 3600
				}
			}
			text := ""
			for _, b := range r.Message.Content {
				switch b.Type {
				case "tool_use":
					pending[b.ID] = len(t.pending)
					t.pending = append(t.pending, Tool{ID: b.ID, Name: b.Name, Summary: head(transcript.ToolSummary(b.Name, b.Input), 160), Since: r.Timestamp})
				case "text":
					if s := strings.TrimSpace(b.Text); s != "" {
						text = s
					}
				}
			}
			// DECISION: the turn is over when the agent stopped without asking for
			// a tool: Claude Code's own messages ("No response requested.") and an
			// answer that ran out of room included. A record whose stop reason is
			// not written yet is a block of an answer still arriving.
			switch r.Message.StopReason {
			case "end_turn", "stop_sequence", "max_tokens", "refusal":
				t.ended, t.endedAt = true, r.Timestamp
			default:
				t.ended = synthetic
				if synthetic {
					t.endedAt = r.Timestamp
				}
			}
			if text != "" {
				t.said = head(text, 280)
			}
		}
	}
	// A transcript keeps a copy of each request, or it does not (Claude Code's
	// choice). Where it does, the last copy says when the cache was last used,
	// an answer still on its way included; where the last copy is long before
	// the last answer, copies are not being kept, and the answer's time stands in.
	t.requestAt = sent
	if sent.IsZero() || answered.Sub(sent) > 10*time.Minute {
		t.requestAt = answered
	}
	var open []Tool
	for _, p := range t.pending {
		if !p.done {
			open = append(open, p)
		}
	}
	t.pending = open
	return t
}

func later(a, b time.Time) time.Time {
	if b.After(a) {
		return b
	}
	return a
}

// head is the first line of text that has any, cut to max bytes on a rune.
func head(text string, max int) string {
	text = transcript.FirstLine(text)
	if len(text) <= max {
		return text
	}
	cut := max
	for cut > 0 && text[cut]&0xC0 == 0x80 {
		cut--
	}
	return text[:cut] + "…"
}
