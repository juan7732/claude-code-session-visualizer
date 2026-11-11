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
	// What Claude Code keeps for itself: a folder of notes per project.
	os.MkdirAll(filepath.Join(claude, "projects", "-p-work", "memory"), 0o755)
	os.WriteFile(filepath.Join(claude, "projects", "-p-work", "memory", "MEMORY.md"), []byte("- a pointer\n"), 0o644)
	os.WriteFile(filepath.Join(claude, "projects", "-p-work", "memory", "a-fact.md"), []byte("SECRET-NOTE\nline\nline\n"), 0o644)
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
	// The project's instructions first, then the notes, each with its kind and whose it is.
	if len(s.Memory) != 3 || s.Memory[0].Kind != "instructions" || s.Memory[0].Project != root ||
		s.Memory[1].Kind != "memory" || s.Memory[1].Project != "-p-work" || filepath.Base(s.Memory[2].Path) != "a-fact.md" || s.Memory[2].Lines != 3 {
		t.Fatalf("memory files: %+v", s.Memory)
	}
	if s.Memory[0].Lines != 2 || len(s.Skills) != 2 || s.Skills[0].Uses != 3 || !s.Skills[0].OnDisk || s.Skills[1].OnDisk {
		t.Fatalf("memory %+v skills %+v", s.Memory, s.Skills)
	}
	if s.Identity["userID"] != "set" || s.Identity["machineID"] != "not set" || s.State["numStartups"] != float64(7) {
		t.Fatalf("identity %v state %v", s.Identity, s.State)
	}
	b, _ := json.Marshal(s)
	for _, secret := range []string{"SECRET-USER", "SECRET-TOKEN", "SECRET-ENV", "secret@example.com", "SECRET-NOTE"} {
		if strings.Contains(string(b), secret) {
			t.Fatalf("snapshot leaks %s", secret)
		}
	}
	if s2, err := Read(filepath.Join(home, "nowhere"), nil); err != nil || len(s2.Flags) != 0 || len(s2.Layers) != 2 {
		t.Fatalf("a machine without Claude Code reads as empty: %v %+v", err, s2)
	}
}

func TestSettingsLayersNeverCarryCredentials(t *testing.T) {
	home := t.TempDir()
	claude := filepath.Join(home, ".claude")
	os.MkdirAll(claude, 0o755)
	os.WriteFile(filepath.Join(claude, "settings.json"), []byte(`{
		"model": "claude-fable-5-1",
		"apiKeyHelper": "security find-generic-password -s SECRET-HELPER -w",
		"awsCredentialExport": "SECRET-EXPORT",
		"env": {
			"ANTHROPIC_API_KEY": "sk-ant-SECRET-APIKEY",
			"ANTHROPIC_AUTH_TOKEN": "SECRET-AUTHTOKEN",
			"DB_PASS": "SECRET-DBPASS",
			"HTTPS_PROXY": "http://user:SECRET-PROXYPASS@proxy.example.com:8080",
			"SOMETHING_ELSE": "ghp_SECRETGITHUB0123456789",
			"OPAQUE": "0123456789abcdefSECRETOPAQUE0123456789",
			"MAX_THINKING_TOKENS": "32000",
			"ANTHROPIC_MODEL": "claude-fable-5-1"
		},
		"permissions": {"allow": ["Bash(ls)", "Bash(curl -H 'Authorization: Bearer SECRET-BEARERTOKEN' https://example.com)"], "defaultMode": "bypassPermissions"},
		"disableBypassPermissionsMode": "disable",
		"mcpServers": {"srv": {"url": "https://example.com/mcp", "headers": {"X-Api": "SECRET-HEADER", "Accept": "SECRET-ACCEPT"}}},
		"hooks": {"PostToolUse": [{"matcher": "Edit", "hooks": [{"type": "command", "command": "gofmt -l ."}]}]}
	}`), 0o644)
	s, err := Read(claude, nil)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(s)
	if strings.Contains(string(b), "SECRET") {
		t.Fatalf("a settings layer leaks a credential:\n%s", b)
	}
	got := map[string]any{}
	for _, e := range s.Effective {
		got[e.Key] = e.Value
	}
	// What is hidden says so; what is harmless is still there to read.
	for _, k := range []string{"apiKeyHelper", "env.ANTHROPIC_API_KEY", "env.DB_PASS", "env.HTTPS_PROXY", "env.OPAQUE", "mcpServers.srv.headers.Accept"} {
		if got[k] != NotShown {
			t.Errorf("%s = %v, want %q", k, got[k], NotShown)
		}
	}
	for k, want := range map[string]any{"model": "claude-fable-5-1", "env.MAX_THINKING_TOKENS": "32000", "env.ANTHROPIC_MODEL": "claude-fable-5-1",
		"permissions.defaultMode": "bypassPermissions", "disableBypassPermissionsMode": "disable", "mcpServers.srv.url": "https://example.com/mcp"} {
		if got[k] != want {
			t.Errorf("%s = %v, want %v", k, got[k], want)
		}
	}
	allow, _ := got["permissions.allow"].([]any)
	if len(allow) != 2 || allow[0] != "Bash(ls)" || allow[1] != NotShown {
		t.Errorf("permissions.allow = %v: the rule with a bearer token is hidden, the other is not", allow)
	}
	// The file on disk is read, never rewritten.
	if raw, _ := os.ReadFile(filepath.Join(claude, "settings.json")); !strings.Contains(string(raw), "sk-ant-SECRET-APIKEY") {
		t.Fatal("settings.json was changed")
	}
}

func TestSecretNames(t *testing.T) {
	for name, want := range map[string]bool{"apiKeyHelper": true, "ANTHROPIC_API_KEY": true, "ANTHROPIC_AUTH_TOKEN": true, "awsAuthRefresh": true,
		"otelHeadersHelper": true, "APIKey": true, "github-token": true, "MAX_THINKING_TOKENS": false, "disableBypassPermissionsMode": false,
		"includeCoAuthoredBy": false, "model": false, "keybindings": false} {
		if got := secretName(name); got != want {
			t.Errorf("secretName(%q) = %v, want %v (words %v)", name, got, want, words(name))
		}
	}
}
