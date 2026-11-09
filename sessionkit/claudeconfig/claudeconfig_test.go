package claudeconfig

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReadLayersExperimentsAndRedaction(t *testing.T) {
	home := t.TempDir()
	claude := filepath.Join(home, ".claude")
	root := filepath.Join(home, "work")
	os.MkdirAll(filepath.Join(root, ".claude", "skills", "demo"), 0o755)
	os.MkdirAll(claude, 0o755)
	os.WriteFile(filepath.Join(claude, "settings.json"), []byte(`{"model":"a","permissions":{"allow":["Bash(ls)"]}}`), 0o644)
	os.WriteFile(filepath.Join(root, ".claude", "settings.json"), []byte(`{"model":"b"}`), 0o644)
	os.WriteFile(filepath.Join(root, ".claude", "skills", "demo", "SKILL.md"), []byte("x"), 0o644)
	os.WriteFile(filepath.Join(root, "CLAUDE.md"), []byte("one\ntwo\n"), 0o644)
	os.WriteFile(claude+".json", []byte(`{"userID":"SECRET-USER","oauthAccount":{"emailAddress":"secret@example.com","accessToken":"SECRET-TOKEN"},
		"cachedExperimentData":{"flag_a":{"experimentId":"exp_other_name","variationId":1,"value":true}},
		"cachedExperimentFeatures":["flag_a"],"cachedGrowthBookFeatures":{"flag_a":true,"flag_b":{"n":2}},"cachedGrowthBookFeaturesAt":1794266586516,
		"projects":{"/p":{"allowedTools":["x"],"mcpServers":{"srv":{"env":{"KEY":"SECRET-ENV"}}},"hasTrustDialogAccepted":true}},
		"skillUsage":{"demo":{"usageCount":3},"gone":{"usageCount":1}},"numStartups":7}`), 0o600)

	s, err := Read(claude, []string{root})
	if err != nil {
		t.Fatal(err)
	}
	var model Setting
	for _, e := range s.Effective {
		if e.Key == "model" {
			model = e
		}
	}
	if model.Value != "b" || !strings.HasPrefix(model.From, "project") || len(model.Also) != 1 || model.Also[0] != "user" {
		t.Fatalf("the project layer overrides the user layer: %+v", model)
	}
	if len(s.Experiments) != 1 || s.Experiments[0].ExperimentID != "exp_other_name" || s.Experiments[0].VariationID != 1 {
		t.Fatalf("experiments: %+v", s.Experiments)
	}
	if len(s.Flags) != 2 || !s.Flags[0].InExperiment || s.Flags[1].InExperiment || s.FlagsAt == nil {
		t.Fatalf("flags: %+v", s.Flags)
	}
	if len(s.Projects) != 1 || s.Projects[0].MCPServers[0] != "srv" || !s.Projects[0].Trusted || s.Projects[0].AllowedTools != 1 {
		t.Fatalf("projects: %+v", s.Projects)
	}
	if len(s.Memory) != 1 || s.Memory[0].Lines != 2 || len(s.Skills) != 2 || s.Skills[0].Uses != 3 || !s.Skills[0].OnDisk || s.Skills[1].OnDisk {
		t.Fatalf("memory %+v skills %+v", s.Memory, s.Skills)
	}
	if s.Identity["userID"] != "set" || s.Identity["machineID"] != "not set" || s.State["numStartups"] != float64(7) {
		t.Fatalf("identity %v state %v", s.Identity, s.State)
	}
	b, _ := json.Marshal(s)
	for _, secret := range []string{"SECRET-USER", "SECRET-TOKEN", "SECRET-ENV", "secret@example.com"} {
		if strings.Contains(string(b), secret) {
			t.Fatalf("snapshot leaks %s", secret)
		}
	}
	if s2, err := Read(filepath.Join(home, "nowhere"), nil); err != nil || len(s2.Flags) != 0 || len(s2.Layers) != 2 {
		t.Fatalf("a machine without Claude Code reads as empty: %v %+v", err, s2)
	}
}
