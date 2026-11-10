package cli

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/transcript"
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
	return transcript.ToolSummary(name, input)
}

func money(v *float64) string {
	if v == nil {
		return "-"
	}
	return fmt.Sprintf("$%.2f", *v)
}
