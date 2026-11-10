package service

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCapLog(t *testing.T) {
	path := filepath.Join(t.TempDir(), LogName)
	if cut, err := CapLog(path, 100, 10); cut || err != nil {
		t.Fatalf("no log yet is nothing to do: cut=%v err=%v", cut, err)
	}

	// launchd's descriptor: opened once, in append mode, held for the agent's life.
	agent, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	defer agent.Close()
	for i := 0; i < 100; i++ {
		fmt.Fprintf(agent, "line %03d of the log\n", i) // 20 bytes each
	}

	if cut, err := CapLog(path, 4000, 500); cut || err != nil {
		t.Fatalf("under the cap nothing is cut: cut=%v err=%v", cut, err)
	}
	cut, err := CapLog(path, 1000, 500)
	if !cut || err != nil {
		t.Fatalf("over the cap: cut=%v err=%v", cut, err)
	}
	b, _ := os.ReadFile(path)
	lines := strings.Split(strings.TrimSuffix(string(b), "\n"), "\n")
	if len(b) > 500 || len(b) < 400 || lines[0] != "line 076 of the log" || lines[len(lines)-1] != "line 099 of the log" {
		t.Fatalf("kept %d bytes, from %q to %q; want the newest whole lines within 500 bytes", len(b), lines[0], lines[len(lines)-1])
	}

	// The agent keeps writing through the descriptor it already had, and its
	// next line lands right after what was kept.
	fmt.Fprintf(agent, "line 100 of the log\n")
	b, _ = os.ReadFile(path)
	if !strings.HasSuffix(string(b), "line 099 of the log\nline 100 of the log\n") || strings.Contains(string(b), "\x00") {
		t.Fatalf("a write after the cut must follow the kept lines with no gap: %q", string(b[len(b)-60:]))
	}
}
