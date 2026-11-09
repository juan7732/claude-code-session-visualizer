package catalog

import (
	"os"
	"path/filepath"
	"testing"
)

func seed(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	must := func(err error) {
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.WriteFile(filepath.Join(dir, "settings.json"), []byte(`{"cleanupPeriodDays": 90}`), 0o644))
	proj := filepath.Join(dir, "projects", "-Users-me-work")
	must(os.MkdirAll(filepath.Join(proj, "11111111-2222-3333-4444-555555555555", "subagents"), 0o755))
	must(os.WriteFile(filepath.Join(proj, "11111111-2222-3333-4444-555555555555.jsonl"), []byte("{\"type\":\"user\"}\n"), 0o644))
	must(os.WriteFile(filepath.Join(proj, "11111111-2222-3333-4444-555555555555", "subagents", "agent-abc.jsonl"), []byte("{}\n{}\n"), 0o644))
	must(os.WriteFile(filepath.Join(proj, "11111111-2222-3333-4444-555555555555.orphaned-123-x.jsonl"), []byte("{}\n"), 0o644))
	must(os.WriteFile(filepath.Join(proj, "notes.txt"), []byte("ignored"), 0o644))
	must(os.MkdirAll(filepath.Join(dir, "projects", "-Users-me-empty", "memory"), 0o755))
	must(os.MkdirAll(filepath.Join(dir, "sessions"), 0o755))
	must(os.WriteFile(filepath.Join(dir, "sessions", "42.json"), []byte(`{"pid":42,"sessionId":"11111111-2222-3333-4444-555555555555","cwd":"/Users/me/work","name":"work-a1","status":"busy","version":"2.1.319"}`), 0o644))
	must(os.WriteFile(filepath.Join(dir, "sessions", "42.abc.key"), []byte(`{}`), 0o600))
	return dir
}

func TestInspectDir(t *testing.T) {
	r, err := InspectDir(seed(t))
	if err != nil {
		t.Fatal(err)
	}
	if !r.Exists {
		t.Fatal("expected Exists")
	}
	if r.Retention.CleanupPeriodDays != 90 || r.Retention.Source == "default" {
		t.Fatalf("retention = %+v", r.Retention)
	}
	if len(r.Projects) != 1 {
		t.Fatalf("projects with sessions = %d, want 1 (empty project skipped)", len(r.Projects))
	}
	p := r.Projects[0]
	if p.Slug != "-Users-me-work" || len(p.Sessions) != 2 {
		t.Fatalf("project = %+v", p)
	}
	if r.Totals.Sessions != 1 || r.Totals.Orphaned != 1 || r.Totals.Subagents != 1 {
		t.Fatalf("totals = %+v", r.Totals)
	}
	if len(r.Live) != 1 || r.Live[0].PID != 42 || r.Live[0].Status != "busy" {
		t.Fatalf("live = %+v", r.Live)
	}
}

func TestInspectMissingDir(t *testing.T) {
	r, err := InspectDir(filepath.Join(t.TempDir(), "nope"))
	if err != nil {
		t.Fatal(err)
	}
	if r.Exists || len(r.Warnings) != 1 || r.Retention.CleanupPeriodDays != DefaultCleanupPeriodDays {
		t.Fatalf("report = %+v", r)
	}
}

func TestDirHonoursConfigDir(t *testing.T) {
	t.Setenv("CLAUDE_CONFIG_DIR", "/tmp/elsewhere")
	d, err := Dir()
	if err != nil || d != "/tmp/elsewhere" {
		t.Fatalf("Dir() = %q, %v", d, err)
	}
}
