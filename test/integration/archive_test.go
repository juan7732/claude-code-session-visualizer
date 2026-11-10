//go:build integration

package integration

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/juan7732/claude-code-session-visualizer/test/integration/harness"
)

func TestArchive_SurvivesSourceDeletion(t *testing.T) {
	t.Parallel()
	h := harness.New(t)
	id := h.SeedFixture("synthetic-basics", "-Users-me-work")

	res := h.Run("archive")
	res.AssertOK(t)
	if !strings.Contains(res.Stdout, "archived  "+id[:8]) || !strings.Contains(res.Stdout, "1 archived, 0 updated, 0 unchanged") {
		t.Fatalf("archive output:\n%s", res.Stdout)
	}
	zst := filepath.Join(h.Home, ".sessionkit", "archive", "-Users-me-work", id+".jsonl.zst")
	if _, err := os.Stat(zst); err != nil {
		t.Fatalf("raw copy missing: %v", err)
	}
	if _, err := os.Stat(filepath.Join(h.Home, ".sessionkit", "archive", "-Users-me-work", id, "tool-results", "toolu_04.txt")); err != nil {
		t.Fatalf("spilled output not archived: %v", err)
	}

	res = h.Run("archive")
	res.AssertOK(t)
	if !strings.Contains(res.Stdout, "unchanged") {
		t.Fatalf("second archive should be a no-op:\n%s", res.Stdout)
	}

	// Simulate Claude Code's sweep.
	if err := os.RemoveAll(filepath.Join(h.ClaudeDir, "projects", "-Users-me-work")); err != nil {
		t.Fatal(err)
	}
	res = h.Run("list")
	res.AssertOK(t)
	if !strings.Contains(res.Stdout, id[:8]) || !strings.Contains(res.Stdout, "(archived; source gone)") {
		t.Fatalf("list should still show the archived session:\n%s", res.Stdout)
	}
	res = h.Run("show", id[:8])
	res.AssertOK(t)
	if !strings.Contains(res.Stdout, "showing the archived copy") || !strings.Contains(res.Stdout, "→ subagent a1b2c3d4e5f607182") {
		t.Fatalf("show from archive:\n%s", res.Stdout)
	}
	res = h.Run("show", id, "--action", "3")
	res.AssertOK(t)
	if !strings.Contains(res.Stdout, "full output line 1") {
		t.Fatalf("spilled output should resolve from the archive:\n%s", res.Stdout)
	}
	res = h.Run("context", id)
	res.AssertOK(t)
	if !strings.Contains(res.Stdout, "Tool definitions      2 tools") {
		t.Fatalf("context should work from the archive after the source is gone:\n%s", res.Stdout)
	}
	res = h.Run("stats", id, "--json")
	res.AssertOK(t)
	var sum struct {
		Requests int `json:"requests"`
	}
	if err := json.Unmarshal([]byte(res.Stdout), &sum); err != nil || sum.Requests != 7 {
		t.Fatalf("stats from archive: %v %+v", err, sum)
	}
}

func TestSearch_FindsAcrossKinds(t *testing.T) {
	t.Parallel()
	h := harness.New(t)
	id := h.SeedFixture("synthetic-basics", "-Users-me-work")
	h.Run("archive").AssertOK(t)

	res := h.Run("search", "Bash")
	res.AssertOK(t)
	if !strings.Contains(res.Stdout, id[:8]) || !strings.Contains(res.Stdout, "tool_use:Bash") {
		t.Fatalf("search output:\n%s", res.Stdout)
	}
	res = h.Run("search", "Bash", "--kind", "tool_use", "--json")
	res.AssertOK(t)
	var hits []struct {
		Kind string `json:"kind"`
		Turn int    `json:"turn"`
	}
	if err := json.Unmarshal([]byte(res.Stdout), &hits); err != nil || len(hits) == 0 {
		t.Fatalf("search --json: %v\n%s", err, res.Stdout)
	}
	for _, h := range hits {
		if h.Kind != "tool_use" {
			t.Fatalf("--kind filter leaked %+v", h)
		}
	}
	res = h.Run("search", "nosuchwordanywhere")
	res.AssertOK(t)
	if !strings.Contains(res.Stdout, "no matches") {
		t.Fatalf("miss should say so:\n%s", res.Stdout)
	}
}

// The archive never ends up holding fewer lines than it did (ADR 0008), seen
// from the command line: growth after a `list`, a shrunk source, a torn copy.
func TestArchive_NeverShrinks(t *testing.T) {
	t.Parallel()
	h := harness.New(t)
	id := h.SeedFixture("synthetic-basics", "-Users-me-work")
	src := filepath.Join(h.ClaudeDir, "projects", "-Users-me-work", id+".jsonl")
	zst := filepath.Join(h.Home, ".sessionkit", "archive", "-Users-me-work", id+".jsonl.zst")
	full, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	cut := func(n int) []byte {
		lines := strings.SplitAfter(string(full), "\n")
		return []byte(strings.Join(lines[:n], ""))
	}
	type check struct {
		Status   string   `json:"status"`
		Records  int      `json:"records"`
		Previous []string `json:"previous"`
	}
	verify := func() (check, harness.Result) {
		res := h.Run("archive", "--verify", "--json")
		var cs []check
		if err := json.Unmarshal([]byte(res.Stdout), &cs); err != nil || len(cs) != 1 {
			t.Fatalf("verify output: %v\n%s", err, res.Stdout)
		}
		return cs[0], res
	}

	// Ten lines archived, then the session grows and `list` runs first.
	os.WriteFile(src, cut(10), 0o644)
	h.Run("archive").AssertOK(t)
	os.WriteFile(src, full, 0o644)
	h.Run("list").AssertOK(t)
	res := h.Run("archive")
	res.AssertOK(t)
	if !strings.Contains(res.Stdout, "updated") {
		t.Fatalf("growth seen by `list` first must still be archived:\n%s", res.Stdout)
	}
	if c, r := verify(); c.Status != "ok" || c.Records != 31 || r.ExitCode != 0 {
		t.Fatalf("after growth: %+v exit %d", c, r.ExitCode)
	}

	// The source shrinks: the fuller copy is kept beside the new one.
	os.WriteFile(src, cut(5), 0o644)
	res = h.Run("archive")
	res.AssertOK(t)
	if !strings.Contains(res.Stdout, "kept the earlier copy") {
		t.Fatalf("a shrunk source should report the kept copy:\n%s", res.Stdout)
	}
	c, _ := verify()
	if c.Status != "ok" || c.Records != 5 || len(c.Previous) != 1 {
		t.Fatalf("after shrink: %+v", c)
	}

	// A torn write: verify fails loudly, the next archive repairs it.
	f, _ := os.OpenFile(zst, os.O_APPEND|os.O_WRONLY, 0o600)
	f.WriteString("\x28\xb5\x2f\xfd\x04\x58torn")
	f.Close()
	if c, r := verify(); c.Status != "corrupt" || r.ExitCode == 0 {
		t.Fatalf("a torn copy must fail verify: %+v exit %d", c, r.ExitCode)
	}
	os.WriteFile(src, full, 0o644)
	h.Run("archive").AssertOK(t)
	if c, r := verify(); c.Status != "ok" || c.Records != 31 || r.ExitCode != 0 {
		t.Fatalf("after repair: %+v exit %d", c, r.ExitCode)
	}
	os.Remove(src)
	h.Run("show", id).AssertOK(t)
}
