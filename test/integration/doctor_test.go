//go:build integration

package integration

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/juan7732/claude-code-session-visualizer/test/integration/harness"
)

func TestDoctor_EmptyHome(t *testing.T) {
	t.Parallel()
	h := harness.New(t)
	res := h.Run("doctor")
	res.AssertOK(t)
	if !strings.Contains(res.Stdout, "cleanupPeriodDays = 30 (default)") {
		t.Fatalf("doctor should report the default retention:\n%s", res.Stdout)
	}
}

func TestDoctor_JSONSeesSeededData(t *testing.T) {
	t.Parallel()
	h := harness.New(t)
	h.WriteFile("settings.json", `{"cleanupPeriodDays": 365}`)
	h.SeedSession("-Users-me-work", "11111111-2222-3333-4444-555555555555", `{"type":"user","uuid":"a"}`, `{"type":"assistant","uuid":"b","parentUuid":"a"}`)
	h.WriteFile("sessions/7.json", `{"pid":7,"sessionId":"11111111-2222-3333-4444-555555555555","cwd":"/Users/me/work","name":"work-1","status":"idle","version":"2.1.319"}`)

	res := h.Run("doctor", "--json")
	res.AssertOK(t)
	var rep struct {
		Exists    bool `json:"exists"`
		Retention struct {
			Days int `json:"cleanup_period_days"`
		} `json:"retention"`
		Totals struct {
			Sessions int `json:"sessions"`
		} `json:"totals"`
		Live []struct {
			PID int `json:"pid"`
		} `json:"live"`
	}
	if err := json.Unmarshal([]byte(res.Stdout), &rep); err != nil {
		t.Fatalf("not JSON: %v\n%s", err, res.Stdout)
	}
	if !rep.Exists || rep.Retention.Days != 365 || rep.Totals.Sessions != 1 || len(rep.Live) != 1 || rep.Live[0].PID != 7 {
		t.Fatalf("unexpected report: %+v", rep)
	}
}

func TestDescribe_IsJSON(t *testing.T) {
	t.Parallel()
	h := harness.New(t)
	res := h.Run("describe")
	res.AssertOK(t)
	var m map[string]any
	if err := json.Unmarshal([]byte(res.Stdout), &m); err != nil {
		t.Fatalf("describe is not JSON: %v", err)
	}
	if m["name"] != "skit" {
		t.Fatalf("manifest name = %v", m["name"])
	}
}

func TestUnknownCommand_JSONError(t *testing.T) {
	t.Parallel()
	h := harness.New(t)
	res := h.Run("nope", "--json")
	if res.ExitCode == 0 {
		t.Fatal("expected failure")
	}
	var e map[string]string
	if err := json.Unmarshal([]byte(res.Stderr), &e); err != nil || e["error"] == "" {
		t.Fatalf("stderr should be a JSON error with --json:\n%s", res.Stderr)
	}
}
