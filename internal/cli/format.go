package cli

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"
)

// truncate cuts s to width runes, adding an ellipsis, and flattens newlines.
func truncate(s string, width int) string {
	s = strings.Join(strings.Fields(s), " ")
	if utf8.RuneCountInString(s) <= width {
		return s
	}
	if width <= 1 {
		return "…"
	}
	runes := []rune(s)
	return string(runes[:width-1]) + "…"
}

func localTime(t time.Time) string {
	if t.IsZero() {
		return "-"
	}
	return t.Local().Format("2006-01-02 15:04")
}

func localClock(t time.Time) string {
	if t.IsZero() {
		return "--:--:--"
	}
	return t.Local().Format("15:04:05")
}

// offset renders the time since start as +h:mm:ss.
func offset(start, t time.Time) string {
	if start.IsZero() || t.IsZero() {
		return "        "
	}
	d := t.Sub(start)
	if d < 0 {
		d = 0
	}
	h := int(d.Hours())
	m := int(d.Minutes()) % 60
	s := int(d.Seconds()) % 60
	return fmt.Sprintf("+%d:%02d:%02d", h, m, s)
}

func shortDuration(d time.Duration) string {
	switch {
	case d <= 0:
		return ""
	case d < time.Second:
		return fmt.Sprintf("%dms", d.Milliseconds())
	case d < time.Minute:
		return fmt.Sprintf("%.1fs", d.Seconds())
	default:
		return fmt.Sprintf("%dm%02ds", int(d.Minutes()), int(d.Seconds())%60)
	}
}

// toolSummary is a one-line description of a tool call from its input.
func toolSummary(name string, input json.RawMessage) string {
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
	// First string field, in key order.
	best := ""
	for _, v := range m {
		if s, ok := v.(string); ok && (best == "" || len(s) > len(best)) {
			best = s
		}
	}
	return best
}

func money(v *float64) string {
	if v == nil {
		return "-"
	}
	return fmt.Sprintf("$%.2f", *v)
}
