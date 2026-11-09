//go:build integration

package integration

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/juan7732/claude-code-session-visualizer/test/integration/harness"
)

func unixClient(socket string) *http.Client {
	return &http.Client{Transport: &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, "unix", socket)
	}}, Timeout: 10 * time.Second}
}

func TestServe_OverUnixSocket(t *testing.T) {
	t.Parallel()
	h := harness.New(t)
	id := h.SeedFixture("synthetic-basics", "-Users-me-work")
	socket := filepath.Join(h.Home, "skit.sock")

	p := h.Start("serve", "--socket", socket, "--settle", "300ms")
	if !h.WaitForFile(socket, 10*time.Second) {
		t.Fatalf("socket never appeared:\n%s", p.Output())
	}
	c := unixClient(socket)
	getJSON := func(path string, v any) int {
		t.Helper()
		resp, err := c.Get("http://skit" + path)
		if err != nil {
			t.Fatalf("GET %s: %v\n%s", path, err, p.Output())
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		if v != nil {
			if err := json.Unmarshal(b, v); err != nil {
				t.Fatalf("GET %s: not JSON: %v\n%s", path, err, b)
			}
		}
		return resp.StatusCode
	}

	var st struct {
		Version  string `json:"version"`
		Sessions int    `json:"sessions_on_disk"`
	}
	if code := getJSON("/v0/status", &st); code != 200 || st.Sessions != 1 {
		t.Fatalf("status %d %+v", code, st)
	}
	var rows []struct {
		ID string `json:"id"`
	}
	if code := getJSON("/v0/sessions", &rows); code != 200 || len(rows) != 1 || rows[0].ID != id {
		t.Fatalf("sessions %d %+v", code, rows)
	}

	// The watcher archives the session once its transcript changes and settles.
	src := filepath.Join(h.ClaudeDir, "projects", "-Users-me-work", id+".jsonl")
	f, _ := os.OpenFile(src, os.O_APPEND|os.O_WRONLY, 0o644)
	f.WriteString(`{"type":"user","uuid":"u9","parentUuid":"a8","turnOrigin":"human","sessionId":"` + id + `","timestamp":"2026-11-08T10:03:00.000Z","message":{"role":"user","content":[{"type":"text","text":"watched giraffe prompt"}]}}` + "\n")
	f.Close()
	deadline := time.Now().Add(15 * time.Second)
	var hits []struct {
		Kind string `json:"kind"`
	}
	for time.Now().Before(deadline) {
		if getJSON("/v0/search?q=giraffe", &hits) == 200 && len(hits) == 1 {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}
	if len(hits) != 1 || hits[0].Kind != "prompt" {
		t.Fatalf("watcher did not archive the change:\n%s", p.Output())
	}

	// The CLI sees the same archive the server wrote.
	res := h.Run("search", "giraffe")
	res.AssertOK(t)
	if !strings.Contains(res.Stdout, "giraffe") {
		t.Fatalf("CLI search should see the server's archive:\n%s", res.Stdout)
	}

	p.Stop()
	if _, err := os.Stat(socket); err == nil {
		t.Fatal("socket file should be removed on shutdown")
	}
}
