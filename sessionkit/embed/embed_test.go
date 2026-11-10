package embed

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/embed/embedtest"
)

// The test binary doubles as llama-server: started with SKIT_FAKE_LLAMA set,
// it serves the fake instead of running tests. That is the external tool
// stubbed at its own boundary (a process with flags, an environment and a
// port), with skit's code on this side of it all real.
func TestMain(m *testing.M) {
	if os.Getenv("SKIT_FAKE_LLAMA") == "1" {
		embedtest.Main(os.Args[1:])
		return
	}
	os.Exit(m.Run())
}

func fakeBinary(t *testing.T) string {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("SKIT_FAKE_LLAMA", "1")
	return exe
}

func modelFile(t *testing.T) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "model.gguf")
	if err := os.WriteFile(p, []byte("gguf"), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestHalfFloatRoundTrip(t *testing.T) {
	// Every half value survives half → float32 → half.
	for h := 0; h < 1<<16; h++ {
		f := fromHalf(uint16(h))
		if f != f { // NaN payloads are not preserved bit for bit
			continue
		}
		if got := toHalf(f); got != uint16(h) {
			t.Fatalf("half %#04x → %g → %#04x", h, f, got)
		}
	}
	// Rounding: halfway cases go to even, and values in [-1, 1] land within
	// half a unit in the last place (2^-11 relative).
	for _, f := range []float32{0, 1, -1, 0.5, 0.1, -0.33333334, 1e-3, 3.0517578e-05, 1e-7, 0.99999994} {
		back := fromHalf(toHalf(f))
		if diff := math.Abs(float64(back - f)); diff > math.Abs(float64(f))/2048+1e-7 {
			t.Fatalf("%g → %g (off by %g)", f, back, diff)
		}
	}
	if toHalf(1.0+1.0/2048) != 0x3c00 || toHalf(1.0+3.0/2048) != 0x3c02 {
		t.Fatalf("ties must round to even: %#04x %#04x", toHalf(1.0+1.0/2048), toHalf(1.0+3.0/2048))
	}
	if toHalf(float32(math.Inf(1))) != 0x7c00 || toHalf(1e10) != 0x7c00 || toHalf(-1e-10) != 0x8000 {
		t.Fatal("infinity, overflow or underflow wrong")
	}
}

func TestPackKeepsCosine(t *testing.T) {
	a, b := embedtest.Vector("the retention sweep deletes old transcripts"), embedtest.Vector("retention of transcripts and the sweep")
	want := Dot(a, b)
	a2, b2 := make([]float32, Dimensions), make([]float32, Dimensions)
	if err := Unpack(a2, Pack(a)); err != nil {
		t.Fatal(err)
	}
	if err := Unpack(b2, Pack(b)); err != nil {
		t.Fatal(err)
	}
	if got := Dot(a2, b2); math.Abs(float64(got-want)) > 1e-3 {
		t.Fatalf("cosine %g became %g after packing", want, got)
	}
	if Unpack(a2, []byte{1, 2, 3}) == nil {
		t.Fatal("a blob of the wrong length must be refused")
	}
}

func TestChunks(t *testing.T) {
	short := "A short prompt that says enough to be worth a vector."
	if got := Chunks(short, 100); len(got) != 1 || got[0] != (Piece{0, len(short)}) {
		t.Fatalf("short text: %v", got)
	}
	for _, s := range []string{"", "ok", "continue", "/a/b/c", "12345 67890 12345 67890 12345"} {
		if got := Chunks(s, 100); len(got) != 0 {
			t.Fatalf("%q has too little to say for a vector, got %v", s, got)
		}
	}

	para := strings.Repeat("This sentence is here to fill a paragraph with words. ", 6)
	text := para + "\n\n" + para + "\n\n" + para + strings.Repeat("x", 500) + " 日本語のテキストです。" + strings.Repeat("é", 400)
	pieces := Chunks(text, 400)
	pos := 0
	for i, p := range pieces {
		if p.Start < pos {
			t.Fatalf("piece %d overlaps the one before", i)
		}
		chunk := text[p.Start : p.Start+p.Len]
		if !utf8.ValidString(chunk) {
			t.Fatalf("piece %d cuts a character in two", i)
		}
		if n := utf8.RuneCountInString(chunk); n > 400 {
			t.Fatalf("piece %d has %d runes", i, n)
		}
		pos = p.Start + p.Len
	}
	if len(pieces) < 4 {
		t.Fatalf("expected several pieces, got %d", len(pieces))
	}
	// The first cut falls on the paragraph break, not mid-sentence.
	if first := text[:pieces[0].Len]; !strings.HasSuffix(first, "\n\n") {
		t.Fatalf("first piece should end at a paragraph: %q", first[len(first)-20:])
	}
	// Nothing with letters is dropped: the pieces cover the text.
	covered := 0
	for _, p := range pieces {
		covered += p.Len
	}
	if covered != len(text) {
		t.Fatalf("pieces cover %d of %d bytes", covered, len(text))
	}
}

// modelServer serves one file the way Hugging Face does (ranges honoured) and
// counts what was asked of it.
type modelServer struct {
	body      []byte
	gets      atomic.Int64
	ranges    []string
	cutAfter  int // when > 0, the first response stops after this many bytes
	noRanges  bool
	lastPath  string
	failFirst bool
}

func (s *modelServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	n := s.gets.Add(1)
	s.lastPath = r.URL.Path
	s.ranges = append(s.ranges, r.Header.Get("Range"))
	body, status := s.body, http.StatusOK
	if rng := r.Header.Get("Range"); rng != "" && !s.noRanges {
		var from int
		fmt.Sscanf(rng, "bytes=%d-", &from)
		if from >= len(s.body) {
			w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
			return
		}
		body, status = s.body[from:], http.StatusPartialContent
	}
	w.Header().Set("Content-Length", fmt.Sprint(len(body)))
	w.WriteHeader(status)
	if n == 1 && s.cutAfter > 0 {
		w.Write(body[:s.cutAfter])
		w.(http.Flusher).Flush()
		panic(http.ErrAbortHandler) // drop the connection mid-file
	}
	w.Write(body)
}

func testModel(t *testing.T, body []byte) (ModelFile, *modelServer) {
	t.Helper()
	ms := &modelServer{body: body}
	srv := httptest.NewServer(ms)
	t.Cleanup(srv.Close)
	sum := sha256.Sum256(body)
	return ModelFile{Repo: "org/model-GGUF", Revision: "abc123", Name: "m.gguf", Bytes: int64(len(body)), SHA256: hex.EncodeToString(sum[:]), BaseURL: srv.URL}, ms
}

func TestModelDownloadResumesAndVerifies(t *testing.T) {
	body := []byte(strings.Repeat("0123456789abcdef", 4096)) // 64 KiB
	m, ms := testModel(t, body)
	ms.cutAfter = 10_000
	home := t.TempDir()

	if st := m.Check(home); st.Present || st.Detail != "not downloaded" {
		t.Fatalf("before: %+v", st)
	}
	err := m.Ensure(context.Background(), home, nil)
	if err == nil || !strings.Contains(err.Error(), "resume") {
		t.Fatalf("a cut download should say it can be resumed, got %v", err)
	}
	if st := m.Check(home); st.Present || st.Bytes == 0 || st.Detail != "download not finished" {
		t.Fatalf("after the cut: %+v", st)
	}
	var last int64
	if err := m.Ensure(context.Background(), home, func(done, total int64) { last = done }); err != nil {
		t.Fatal(err)
	}
	if last != int64(len(body)) {
		t.Fatalf("progress ended at %d", last)
	}
	if len(ms.ranges) != 2 || !strings.HasPrefix(ms.ranges[1], "bytes=") || ms.ranges[1] == "bytes=0-" {
		t.Fatalf("the second request should continue where the first stopped: %q", ms.ranges)
	}
	if ms.lastPath != "/org/model-GGUF/resolve/abc123/m.gguf" {
		t.Fatalf("path = %s", ms.lastPath)
	}
	got, _ := os.ReadFile(m.Path(home))
	if string(got) != string(body) {
		t.Fatal("the file on disk is not the file served")
	}
	// Present now, and a second Ensure asks the network nothing.
	if st := m.Check(home); !st.Present {
		t.Fatalf("after: %+v", st)
	}
	if err := m.Ensure(context.Background(), home, nil); err != nil || ms.gets.Load() != 2 {
		t.Fatalf("Ensure on a present file: err=%v requests=%d", err, ms.gets.Load())
	}
}

func TestModelChecksumMismatchKeepsNothing(t *testing.T) {
	m, _ := testModel(t, []byte(strings.Repeat("x", 1000)))
	m.SHA256 = strings.Repeat("0", 64)
	home := t.TempDir()
	err := m.Ensure(context.Background(), home, nil)
	if err == nil || !strings.Contains(err.Error(), "checksum") {
		t.Fatalf("err = %v", err)
	}
	if entries, _ := os.ReadDir(ModelsDir(home)); len(entries) != 0 {
		t.Fatalf("a download that fails its checksum must leave nothing: %v", entries)
	}
}

func TestModelCheckCatchesATamperedFile(t *testing.T) {
	body := []byte(strings.Repeat("y", 2000))
	m, ms := testModel(t, body)
	home := t.TempDir()
	if err := m.Ensure(context.Background(), home, nil); err != nil {
		t.Fatal(err)
	}
	// Same size, different bytes, later mtime: the marker no longer vouches for it.
	tampered := []byte(strings.Repeat("z", 2000))
	if err := os.WriteFile(m.Path(home), tampered, 0o644); err != nil {
		t.Fatal(err)
	}
	later := time.Now().Add(2 * time.Second)
	os.Chtimes(m.Path(home), later, later)
	if st := m.Check(home); st.Present || !strings.Contains(st.Detail, "checksum") {
		t.Fatalf("tampered file: %+v", st)
	}
	// Ensure replaces it and keeps the odd file aside rather than deleting it.
	if err := m.Ensure(context.Background(), home, nil); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(m.Path(home)); string(got) != string(body) {
		t.Fatal("the pinned file was not restored")
	}
	if aside, _ := filepath.Glob(m.Path(home) + ".rejected-*"); len(aside) != 1 {
		t.Fatalf("the rejected file should be kept aside, found %v", aside)
	}
	if ms.gets.Load() != 2 {
		t.Fatalf("requests = %d", ms.gets.Load())
	}
}

func TestClientBatchesAndCutsOverlongText(t *testing.T) {
	fake := &embedtest.Server{Key: "k"}
	srv := httptest.NewServer(fake)
	defer srv.Close()
	c := &Client{BaseURL: srv.URL, Key: "k"}

	texts := make([]string, 70)
	for i := range texts {
		texts[i] = fmt.Sprintf("text number %d about archives", i)
	}
	vecs, err := c.Embed(context.Background(), texts)
	if err != nil {
		t.Fatal(err)
	}
	if len(vecs) != 70 || fake.Requests.Load() != 3 {
		t.Fatalf("%d vectors in %d requests, want 70 in 3", len(vecs), fake.Requests.Load())
	}
	for i, v := range vecs {
		if d := Dot(v, embedtest.Vector(texts[i])); d < 0.999 {
			t.Fatalf("vector %d is not the vector of text %d (cosine %g)", i, i, d)
		}
	}

	// One over-long text in a batch: it is cut until it fits, the others are whole.
	long := strings.Repeat("word ", 2*embedtest.TooLongRunes/5)
	vecs, err = c.Embed(context.Background(), []string{"alpha beta gamma", long, "delta epsilon"})
	if err != nil {
		t.Fatal(err)
	}
	if len(vecs) != 3 || Dot(vecs[0], embedtest.Vector("alpha beta gamma")) < 0.999 || Dot(vecs[2], embedtest.Vector("delta epsilon")) < 0.999 {
		t.Fatal("the texts beside the long one lost their vectors")
	}

	bad := &Client{BaseURL: srv.URL, Key: "wrong"}
	if _, err := bad.Embed(context.Background(), []string{"x"}); err == nil || !strings.Contains(err.Error(), "Invalid API Key") {
		t.Fatalf("a refused key should say so, got %v", err)
	}
}

func TestSidecarStartsServesAndStops(t *testing.T) {
	bin, model, run := fakeBinary(t), modelFile(t), t.TempDir()
	sc, err := StartSidecar(context.Background(), SidecarOptions{Binary: bin, Model: model, RunDir: run})
	if err != nil {
		t.Fatal(err)
	}
	defer sc.Stop()
	if files, _ := filepath.Glob(filepath.Join(run, "llama-server-*.json")); len(files) != 1 {
		t.Fatalf("run files while running: %v", files)
	}
	vecs, err := sc.Embed(context.Background(), []string{Document("hello there")})
	if err != nil || len(vecs) != 1 || len(vecs[0]) != Dimensions {
		t.Fatalf("embed through the sidecar: %v", err)
	}
	// The key is required: a client without it is turned away.
	if _, err := (&Client{BaseURL: sc.BaseURL}).Embed(context.Background(), []string{"x"}); err == nil {
		t.Fatal("the sidecar answered a request without its key")
	}
	pid := sc.PID()
	if err := sc.Stop(); err != nil {
		t.Fatal(err)
	}
	if !sc.Exited() || alive(pid) {
		t.Fatal("the server is still running after Stop")
	}
	if files, _ := filepath.Glob(filepath.Join(run, "*")); len(files) != 0 {
		t.Fatalf("run files after Stop: %v", files)
	}
}

func TestSidecarReportsWhyItDidNotStart(t *testing.T) {
	bin := fakeBinary(t)
	_, err := StartSidecar(context.Background(), SidecarOptions{Binary: bin, Model: filepath.Join(t.TempDir(), "missing.gguf")})
	if err == nil || !strings.Contains(err.Error(), "failed to load model") {
		t.Fatalf("err = %v", err)
	}
	if _, err := FindBinary(filepath.Join(t.TempDir(), "nope")); err == nil {
		t.Fatal("FindBinary accepted a path with nothing at it")
	}
}

func TestReapStopsAnOrphanAndSparesTheOwned(t *testing.T) {
	bin, model, run := fakeBinary(t), modelFile(t), t.TempDir()
	orphan, err := StartSidecar(context.Background(), SidecarOptions{Binary: bin, Model: model, RunDir: run})
	if err != nil {
		t.Fatal(err)
	}
	defer orphan.Stop()
	owned, err := StartSidecar(context.Background(), SidecarOptions{Binary: bin, Model: model, RunDir: run})
	if err != nil {
		t.Fatal(err)
	}
	defer owned.Stop()

	// Rewrite the first one's run file as if its owner were a process that is gone.
	dead := deadPID(t)
	writeRunFile(run, runRecord{Owner: dead, PID: orphan.PID(), Binary: bin, Started: time.Now()})
	// And a stale file naming a pid that is now something else entirely: this
	// test process. It must not be signalled.
	writeRunFile(run, runRecord{Owner: dead, PID: os.Getppid(), Binary: "/nowhere/llama-server", Started: time.Now()})

	if n := Reap(run); n != 1 {
		t.Fatalf("Reap stopped %d, want 1", n)
	}
	select {
	case <-orphan.done:
	case <-time.After(5 * time.Second):
		t.Fatal("the orphan is still running")
	}
	if owned.Exited() {
		t.Fatal("Reap stopped a sidecar whose owner is alive")
	}
	if !alive(os.Getppid()) {
		t.Fatal("Reap signalled a process that only shared a pid with a stale file")
	}
	if files, _ := filepath.Glob(filepath.Join(run, "llama-server-*.json")); len(files) != 1 {
		t.Fatalf("only the owned sidecar's file should remain: %v", files)
	}
}

// deadPID returns the id of a process that has just exited.
func deadPID(t *testing.T) int {
	t.Helper()
	p, err := os.StartProcess("/bin/sh", []string{"sh", "-c", "exit 0"}, &os.ProcAttr{})
	if err != nil {
		t.Fatal(err)
	}
	p.Wait()
	return p.Pid
}

func TestEmbedderStartsOnDemandAndStopsWhenIdle(t *testing.T) {
	bin, model := fakeBinary(t), modelFile(t)
	e := NewEmbedder(SidecarOptions{Binary: bin, Model: model}, "fake v1")
	e.IdleStop = 150 * time.Millisecond
	defer e.Close()
	if e.Running() {
		t.Fatal("nothing should run before the first request")
	}
	q, err := e.Query(context.Background(), "retention sweep")
	if err != nil {
		t.Fatal(err)
	}
	docs, err := e.Documents(context.Background(), []string{"the retention sweep deletes transcripts", "a recipe for dinner"})
	if err != nil {
		t.Fatal(err)
	}
	if Dot(q, docs[0]) <= Dot(q, docs[1]) {
		t.Fatal("the matching document should score higher")
	}
	if !e.Running() || e.starts != 1 {
		t.Fatalf("running=%v starts=%d", e.Running(), e.starts)
	}
	deadline := time.Now().Add(5 * time.Second)
	for e.Running() && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if e.Running() {
		t.Fatal("the sidecar should stop after the idle time")
	}
	// The next request starts it again.
	if _, err := e.Query(context.Background(), "again"); err != nil || e.starts != 2 {
		t.Fatalf("after idle stop: err=%v starts=%d", err, e.starts)
	}
	if e.Source() != "fake v1" {
		t.Fatal("source lost")
	}
}

func TestEmbedderRestartsAfterTheSidecarDies(t *testing.T) {
	bin, model := fakeBinary(t), modelFile(t)
	var sc *Sidecar
	e := NewEmbedder(SidecarOptions{Binary: bin, Model: model}, "fake v1")
	defer e.Close()
	if _, err := e.Query(context.Background(), "first"); err != nil {
		t.Fatal(err)
	}
	sc = e.sidecar
	if sc == nil {
		t.Fatal("no sidecar recorded")
	}
	sc.cmd.Process.Kill()
	<-sc.done
	// The request that finds it dead may fail; the one after must not.
	_, _ = e.Query(context.Background(), "finds it dead")
	if _, err := e.Query(context.Background(), "second"); err != nil {
		t.Fatalf("the embedder did not recover from a dead sidecar: %v", err)
	}
	if e.starts != 2 {
		t.Fatalf("starts = %d, want 2", e.starts)
	}
}
