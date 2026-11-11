package cli

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/embed"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/embed/embedtest"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/search"
)

// The test binary doubles as llama-server (see embed's tests): started with
// SKIT_FAKE_LLAMA set, it serves the stand-in instead of running tests.
func TestMain(m *testing.M) {
	if os.Getenv("SKIT_FAKE_LLAMA") == "1" {
		embedtest.Main(os.Args[1:])
		return
	}
	os.Exit(m.Run())
}

// run executes skit in this process and returns what it printed.
func run(t *testing.T, args ...string) (stdout string, err error) {
	t.Helper()
	root := NewRoot("test")
	var out, errOut bytes.Buffer
	root.SetOut(&out)
	root.SetErr(&errOut)
	root.SetArgs(args)
	err = root.Execute()
	return out.String(), err
}

func runJSON(t *testing.T, v any, args ...string) {
	t.Helper()
	out, err := run(t, append(args, "--json")...)
	if err != nil {
		t.Fatalf("skit %s: %v", strings.Join(args, " "), err)
	}
	if err := json.Unmarshal([]byte(out), v); err != nil {
		t.Fatalf("skit %s --json is not JSON: %v\n%s", strings.Join(args, " "), err, out)
	}
}

// TestMeaningSearchFromNothing follows a new user: archive, find out meaning
// search is not set up, run `skit embed` (which downloads the model, here from
// a local server standing in for Hugging Face), then search and eval. The
// commands, the engine, the download and the sidecar's process handling are
// all real; only llama-server's arithmetic and the model file are stand-ins.
func TestMeaningSearchFromNothing(t *testing.T) {
	// A tiny "model" at a pinned checksum, served like Hugging Face serves it.
	body := []byte(strings.Repeat("not really a gguf ", 256))
	var downloads atomic.Int64
	hf := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		downloads.Add(1)
		w.Write(body)
	}))
	defer hf.Close()
	sum := sha256.Sum256(body)
	real := embed.TextModel
	embed.TextModel = embed.ModelFile{Repo: "org/tiny-GGUF", Revision: "0123456789abcdef", Name: "tiny.gguf", Bytes: int64(len(body)), SHA256: hex.EncodeToString(sum[:]), BaseURL: hf.URL}
	defer func() { embed.TextModel = real }()

	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	home, claude := t.TempDir(), t.TempDir()
	t.Setenv("SKIT_HOME", home)
	t.Setenv("CLAUDE_CONFIG_DIR", claude)
	t.Setenv("SKIT_LLAMA_SERVER", exe)
	t.Setenv("SKIT_FAKE_LLAMA", "1")
	const id = "bbbbbbbb-0000-0000-0000-000000000002"
	src, err := os.ReadFile(filepath.Join("..", "testdata", "sessions", "prose-search", id+".jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	proj := filepath.Join(claude, "projects", "-Users-xxxx-work")
	if err := os.MkdirAll(proj, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(proj, id+".jsonl"), src, 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := run(t, "archive"); err != nil {
		t.Fatal(err)
	}

	// Not set up yet: status says so, and a meaning query says what to run
	// without downloading or starting anything.
	var st meaningReport
	runJSON(t, &st, "embed", "--status")
	if st.Ready || st.ModelFile.Present || st.LlamaServer != exe || st.Vectors.Vectors != 0 {
		t.Fatalf("status before embed = %+v", st)
	}
	if _, err := run(t, "search", "--mode", "meaning", "retention"); err == nil || !strings.Contains(err.Error(), "skit embed") {
		t.Fatalf("meaning search before embed should point at `skit embed`, got %v", err)
	}
	if downloads.Load() != 0 {
		t.Fatal("something other than `skit embed` reached for the network")
	}

	// A missing llama-server stops embed before the download.
	t.Setenv("SKIT_LLAMA_SERVER", filepath.Join(home, "no-such-binary"))
	if _, err := run(t, "embed"); err == nil || !strings.Contains(err.Error(), "llama-server not found") || downloads.Load() != 0 {
		t.Fatalf("embed without llama-server: err=%v downloads=%d", err, downloads.Load())
	}
	t.Setenv("SKIT_LLAMA_SERVER", exe)

	var res struct {
		Embedded int    `json:"embedded"`
		Texts    int    `json:"texts"`
		Vectors  int    `json:"vectors"`
		Source   string `json:"source"`
	}
	runJSON(t, &res, "embed")
	if res.Embedded != 11 || res.Vectors != 11 || res.Texts != 11 || !strings.Contains(res.Source, "org/tiny-GGUF@0123456789ab/tiny.gguf") {
		t.Fatalf("embed = %+v", res)
	}
	if got, _ := os.ReadFile(filepath.Join(home, "models", "tiny.gguf")); !bytes.Equal(got, body) || downloads.Load() != 1 {
		t.Fatalf("the model should be downloaded once into the home: %d bytes, %d downloads", len(got), downloads.Load())
	}
	runJSON(t, &res, "embed")
	if res.Embedded != 0 || res.Vectors != 11 || downloads.Load() != 1 {
		t.Fatalf("second embed = %+v, downloads %d", res, downloads.Load())
	}

	// The stand-in's cosines are word overlaps, under the gate a real model is
	// held to, so by default the answer is that nothing is close enough.
	var hits []search.Hit
	runJSON(t, &hits, "search", "--mode", "meaning", "a retention sweep deletes the session files")
	if len(hits) != 0 {
		t.Fatalf("gated meaning search = %+v", hits)
	}
	if out, err := run(t, "search", "--mode", "meaning", "a retention sweep deletes the session files"); err != nil || !strings.Contains(out, "nothing in the archive is close") || !strings.Contains(out, "--all") {
		t.Fatalf("gated meaning search for people: %q %v", out, err)
	}
	runJSON(t, &hits, "search", "--mode", "meaning", "--all", "a retention sweep deletes the session files")
	if len(hits) == 0 || hits[0].Turn != 0 || hits[0].Match != "meaning" || hits[0].Cosine <= 0 {
		t.Fatalf("meaning search = %+v", hits)
	}
	// Narrowed to a session by a prefix of its id, to two kinds, with a gate
	// low enough for the stand-in.
	runJSON(t, &hits, "search", "--mode", "meaning", "--session", "bbbbbbbb", "--kind", "prompt,thinking", "--min-cosine", "0.01", "a retention sweep deletes the session files")
	if len(hits) == 0 {
		t.Fatal("narrowed meaning search found nothing")
	}
	for _, h := range hits {
		if h.Kind != "prompt" && h.Kind != "thinking" {
			t.Fatalf("--kind prompt,thinking returned a %s", h.Kind)
		}
	}
	if _, err := run(t, "search", "--session", "cccccccc", "retention"); err == nil || !strings.Contains(err.Error(), "no archived session starts with") {
		t.Fatalf("--session with an unknown prefix: %v", err)
	}
	runJSON(t, &hits, "search", "--no-tools", "Zstandard", "version")
	for _, h := range hits {
		if h.Kind == "tool_use" || h.Kind == "tool_result" {
			t.Fatalf("--no-tools returned a %s", h.Kind)
		}
	}
	if len(hits) == 0 {
		t.Fatal("--no-tools should still find the reply about Zstandard")
	}
	out, err := run(t, "search", "--mode", "meaning", "--all", "-n", "2", "a retention sweep deletes the session files")
	if err != nil || !strings.Contains(out, "turn 0") || !strings.Contains(out, "cos 0.") || strings.Count(out, "\n  turn") != 2 {
		t.Fatalf("meaning search for people:\n%s\n%v", out, err)
	}
	runJSON(t, &hits, "search", "retention", "sweep")
	if len(hits) == 0 || hits[0].Match != "keyword" {
		t.Fatalf("keyword search = %+v", hits)
	}

	evalFile := filepath.Join(home, "queries.json")
	os.WriteFile(evalFile, []byte(`{"queries": [
	  {"q": "retention sweep deletes session files", "expect": ["bbbbbbbb@0"], "tag": "words"},
	  {"q": "Zstandard", "expect": ["bbbbbbbb@4"], "tag": "wrong-on-purpose"},
	  {"q": "quantum chromodynamics lattice", "expect": []}]}`), 0o644)
	var rep search.EvalReport
	runJSON(t, &rep, "eval", evalFile, "--all")
	if len(rep.Modes) != 3 || rep.Modes[0].Overall.N != 2 || rep.Modes[0].Overall.R1 != 0.5 || rep.Modes[1].Outcomes[0].Rank != 1 || rep.Modes[1].Nothing.Answered != 1 ||
		rep.Modes[2].Mode != "hybrid" || rep.Modes[2].Outcomes[0].Rank != 1 {
		t.Fatalf("eval = %+v", rep)
	}
	// Hybrid from the command line: with the real gate the stand-in passes
	// nothing, so what comes back is keyword's hits, each saying so.
	runJSON(t, &hits, "search", "--mode", "hybrid", "retention", "sweep")
	if len(hits) == 0 || hits[0].Match != "keyword" {
		t.Fatalf("hybrid search = %+v", hits)
	}
	runJSON(t, &hits, "search", "--mode", "hybrid", "--min-cosine", "0.1", "retention", "sweep")
	if len(hits) == 0 || (hits[0].Match != "both" && hits[0].Match != "meaning") || hits[0].Cosine == 0 {
		t.Fatalf("hybrid search with a gate the stand-in can pass = %+v", hits[0])
	}
	out, err = run(t, "eval", evalFile, "--mode", "keyword", "--misses")
	if err != nil || !strings.Contains(out, "keyword   all") || strings.Contains(out, "meaning") || !strings.Contains(out, "not in top 10") || !strings.Contains(out, "want bbbbbbbb@4") {
		t.Fatalf("eval for people:\n%s\n%v", out, err)
	}
	if _, err := run(t, "eval", evalFile, "--mode", "telepathy"); err == nil {
		t.Fatal("eval accepted a mode that does not exist")
	}

	// Ready now. (`skit doctor` prints this same report; it is not run here
	// because it also asks launchd about the background agent.)
	runJSON(t, &st, "embed", "--status")
	if !st.Ready || st.Vectors.Vectors != 11 || st.Stale || !st.ModelFile.Present {
		t.Fatalf("status after embed = %+v", st)
	}

	// Every command stopped the sidecar it started.
	if left, _ := filepath.Glob(filepath.Join(home, "run", "*")); len(left) != 0 {
		t.Fatalf("sidecars left running: %v", left)
	}

	var m Manifest
	runJSON(t, &m, "describe")
	paths := map[string]bool{}
	for _, c := range m.Commands {
		paths[c.Path] = true
	}
	if !paths["skit embed"] || !paths["skit eval"] {
		t.Fatalf("describe must list embed and eval: %v", paths)
	}
}
