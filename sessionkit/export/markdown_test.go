package export

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/transcript"
)

func load(t *testing.T) *transcript.Session {
	t.Helper()
	s, err := transcript.Load(filepath.Join("..", "..", "internal", "testdata", "sessions", "synthetic-basics", "aaaaaaaa-0000-0000-0000-000000000001.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestMarkdownOfTheWholeSession(t *testing.T) {
	var out bytes.Buffer
	if err := Markdown(&out, load(t), Options{Location: time.UTC}); err != nil {
		t.Fatal(err)
	}
	const want = "# Synthetic basics\n\n" +
		"2026-11-08 10:00 → 2026-11-08 10:01 · 1m 04s · `/Users/xxxx/work`\n\n" +
		"Session `aaaaaaaa-0000-0000-0000-000000000001`\n\n" +
		"## Turn 0 · 2026-11-08 10:00\n\n" +
		"**You**\n\nXxxx xx xxx xxxxx.\n\n_1 image attached_\n\n" +
		"**Claude**\n\nXxxxxxx xxx xxxx.\n\n" +
		// Four actions that only called tools: one list.
		"- `Bash` xx -xx → xxx\n- `Read` /xxx/x.png\n- `Agent` xxxx → Xxxxx xxxxx xxxxxxxx\n- `Edit` /xxx/y.go → <persisted-output>\n\n" +
		"> Context compacted (auto): 6.4k → 900 tokens. The model continued from a summary.\n\n" +
		"## Turn 1 · 2026-11-08 10:01\n\n" +
		"**You**\n\nXxxxxxxx.\n\n**Claude**\n\nXxxx.\n\n_Claude Code: Xxxxxxx xxxxxxx._\n"
	if got := out.String(); got != want {
		t.Fatalf("markdown:\n%s\nwant:\n%s", got, want)
	}
}

func TestMarkdownOfOneTurn(t *testing.T) {
	s := load(t)
	turn := 1
	var out bytes.Buffer
	if err := Markdown(&out, s, Options{Turn: &turn, Location: time.UTC}); err != nil {
		t.Fatal(err)
	}
	if got := out.String(); !strings.HasPrefix(got, "## Turn 1 · ") || strings.Contains(got, "Turn 0") || strings.Contains(got, "# Synthetic") {
		t.Fatalf("one turn, no title:\n%s", got)
	}
	out.Reset()
	turn = 0
	if err := Markdown(&out, s, Options{Turn: &turn, Thinking: true, Location: time.UTC}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "> **Thinking**\n>\n> xxxx\n") {
		t.Fatalf("thinking is quoted when asked for:\n%s", out.String())
	}
	turn = 2
	if err := Markdown(&out, s, Options{Turn: &turn}); err == nil {
		t.Fatal("a turn that is not there is an error")
	}
}
