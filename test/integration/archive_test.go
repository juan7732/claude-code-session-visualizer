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
