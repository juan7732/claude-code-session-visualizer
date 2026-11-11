package archive

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/klauspost/compress/zstd"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
)

// The cases of ADR 0008: whatever happens to the source or to a write, the
// archive never ends up holding fewer lines than it did.

func firstLines(b []byte, n int) []byte {
	i := 0
	for ; n > 0; n-- {
		j := bytes.IndexByte(b[i:], '\n')
		if j < 0 {
			return b
		}
		i += j + 1
	}
	return b[:i]
}

func locate(t *testing.T, claude string) catalog.Located {
	t.Helper()
	rep, err := catalog.InspectDir(claude)
	if err != nil {
		t.Fatal(err)
	}
	l, err := rep.Find(fixtureID)
	if err != nil {
		t.Fatal(err)
	}
	return l
}

func lines(t *testing.T, path string) int {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	_, n, err := decodedLen(f)
	if err != nil {
		t.Fatalf("%s does not decode: %v", filepath.Base(path), err)
	}
	return n
}

// setup seeds the fixture with only its first n lines on disk and returns the
// archive, the fake Claude dir, the source path and the full transcript.
func setup(t *testing.T, n int) (a *Archive, claude, src string, full []byte) {
	t.Helper()
	claude, l := seed(t)
	src = l.File.Path
	full, err := os.ReadFile(src)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(src, firstLines(full, n), 0o644); err != nil {
		t.Fatal(err)
	}
	a, err = OpenAt(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { a.Close() })
	return a, claude, src, full
}

func mustIngest(t *testing.T, a *Archive, claude string, opt Options) Result {
	t.Helper()
	res, err := a.Ingest(locate(t, claude), opt)
	if err != nil {
		t.Fatal(err)
	}
	return res
}

func TestSourceShrinkKeepsThePreviousCopy(t *testing.T) {
	a, claude, src, full := setup(t, 31)
	first := mustIngest(t, a, claude, Options{})
	if lines(t, first.Path) != 31 {
		t.Fatalf("first copy has %d lines", lines(t, first.Path))
	}
	os.WriteFile(src, firstLines(full, 5), 0o644)

	res := mustIngest(t, a, claude, Options{})
	if res.Action != "updated" || len(res.Kept) != 1 {
		t.Fatalf("a shrunk source must keep the earlier copy aside: %+v", res)
	}
	if got := lines(t, res.Kept[0]); got != 31 {
		t.Fatalf("kept copy has %d lines, want the 31 archived before the source shrank", got)
	}
	if got := lines(t, res.Path); got != 5 {
		t.Fatalf("current copy has %d lines, want 5", got)
	}
	checks, err := a.Verify(nil)
	if err != nil || len(checks) != 1 || checks[0].Status != "ok" || len(checks[0].Previous) != 1 {
		t.Fatalf("verify = %+v %v", checks, err)
	}
	// The same source again is unchanged and keeps nothing new.
	if again := mustIngest(t, a, claude, Options{}); again.Action != "unchanged" || len(again.Kept) != 0 {
		t.Fatalf("second ingest = %+v", again)
	}
}

func TestTornAppendIsCutOff(t *testing.T) {
	a, claude, src, full := setup(t, 10)
	first := mustIngest(t, a, claude, Options{})

	// A write that died half way: bytes after the length the index recorded.
	f, _ := os.OpenFile(first.Path, os.O_APPEND|os.O_WRONLY, 0o600)
	f.Write([]byte("\x28\xb5\x2f\xfd\x04\x58torn"))
	f.Close()
	if c, _ := a.Verify(nil); len(c) != 1 || c[0].Status != "corrupt" || c[0].Records != 10 {
		t.Fatalf("verify should report the torn copy as corrupt with 10 readable lines: %+v", c)
	}

	os.WriteFile(src, full, 0o644)
	res := mustIngest(t, a, claude, Options{})
	if res.Action != "updated" || len(res.Kept) != 0 {
		t.Fatalf("append after a torn write = %+v", res)
	}
	if got := lines(t, res.Path); got != 31 {
		t.Fatalf("copy has %d lines after recovery, want 31", got)
	}
	if s, _, err := a.Load(fixtureID); err != nil || s.Totals.Records != 31 {
		t.Fatalf("the archived session must load after recovery: %v", err)
	}
	if c, _ := a.Verify(nil); c[0].Status != "ok" {
		t.Fatalf("verify after recovery = %+v", c[0])
	}
}

func TestListDoesNotHideGrowth(t *testing.T) {
	a, claude, src, full := setup(t, 10)
	mustIngest(t, a, claude, Options{})
	os.WriteFile(src, full, 0o644)

	// `skit list` refreshes the row's source fingerprint from the grown file.
	if _, fresh, err := a.Summary(locate(t, claude)); err != nil || fresh {
		t.Fatalf("summary of a grown source should re-parse: fresh=%v err=%v", fresh, err)
	}
	res := mustIngest(t, a, claude, Options{})
	if res.Action != "updated" || lines(t, res.Path) != 31 {
		t.Fatalf("the lines added before `list` ran must still be archived: %+v, %d lines", res, lines(t, res.Path))
	}
}

func TestCopyNewerThanTheIndexIsNotTruncated(t *testing.T) {
	// A crash after the rename and before the index update leaves a complete
	// copy that is longer than the row says.
	a, claude, src, full := setup(t, 10)
	first := mustIngest(t, a, claude, Options{})
	os.WriteFile(src, full, 0o644)
	_, _, tmp, err := compressTo(src, first.Path, true)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(tmp, first.Path); err != nil {
		t.Fatal(err)
	}

	res := mustIngest(t, a, claude, Options{})
	if len(res.Kept) != 0 || lines(t, res.Path) != 31 {
		t.Fatalf("a complete newer copy must survive: %+v, %d lines", res, lines(t, res.Path))
	}
	if c, _ := a.Verify(nil); c[0].Status != "ok" {
		t.Fatalf("verify = %+v", c[0])
	}
}

func TestRowsFromSchema2(t *testing.T) {
	// Rows migrated from schema 2 know neither the copy's size nor the source
	// tail. They are rewritten with the length check, growing or shrinking.
	forget := func(a *Archive) {
		if _, err := a.Store.DB().Exec(`UPDATE sessions SET archive_size=0, archive_tail='', archived_fp=''`); err != nil {
			t.Fatal(err)
		}
	}
	a, claude, src, full := setup(t, 10)
	mustIngest(t, a, claude, Options{})
	forget(a)
	os.WriteFile(src, full, 0o644)
	res := mustIngest(t, a, claude, Options{})
	if res.Action != "updated" || len(res.Kept) != 0 || lines(t, res.Path) != 31 {
		t.Fatalf("grown source on a migrated row = %+v, %d lines", res, lines(t, res.Path))
	}
	forget(a)
	os.WriteFile(src, firstLines(full, 5), 0o644)
	res = mustIngest(t, a, claude, Options{})
	if len(res.Kept) != 1 || lines(t, res.Kept[0]) != 31 {
		t.Fatalf("shrunk source on a migrated row must keep the earlier copy: %+v", res)
	}
}

func TestStripRequestsReplacesWithoutKeeping(t *testing.T) {
	a, claude, _, _ := setup(t, 31)
	mustIngest(t, a, claude, Options{})
	res := mustIngest(t, a, claude, Options{StripRequests: true})
	if res.Action != "updated" || len(res.Kept) != 0 || lines(t, res.Path) != 28 {
		t.Fatalf("stripping is asked for, so nothing is kept aside: %+v, %d lines", res, lines(t, res.Path))
	}
	// Going back to lossless grows the copy again.
	res = mustIngest(t, a, claude, Options{})
	if len(res.Kept) != 0 || lines(t, res.Path) != 31 {
		t.Fatalf("back to lossless = %+v, %d lines", res, lines(t, res.Path))
	}
}

func TestTouchedSourceAddsNoBytes(t *testing.T) {
	a, claude, src, _ := setup(t, 31)
	first := mustIngest(t, a, claude, Options{})
	before, _ := os.Stat(first.Path)
	later := time.Now().Add(time.Minute)
	os.Chtimes(src, later, later)

	res := mustIngest(t, a, claude, Options{})
	after, _ := os.Stat(res.Path)
	if res.Action != "updated" || after.Size() != before.Size() {
		t.Fatalf("an append with nothing new must not grow the copy: %+v, %d → %d bytes", res, before.Size(), after.Size())
	}
	if again := mustIngest(t, a, claude, Options{}); again.Action != "unchanged" {
		t.Fatalf("then unchanged: %+v", again)
	}
}

func TestVerifyMissing(t *testing.T) {
	a, claude, _, _ := setup(t, 31)
	res := mustIngest(t, a, claude, Options{})
	os.Remove(res.Path)
	if c, _ := a.Verify([]string{"aaaaaaaa"}); len(c) != 1 || c[0].Status != "missing" {
		t.Fatalf("verify = %+v", c)
	}
	if c, _ := a.Verify([]string{"bbbb"}); len(c) != 0 {
		t.Fatalf("a prefix that matches nothing checks nothing: %+v", c)
	}
	// A missing copy is rebuilt from the source.
	if again := mustIngest(t, a, claude, Options{}); again.Action != "updated" || lines(t, again.Path) != 31 {
		t.Fatalf("ingest after the copy vanished = %+v", again)
	}
}

func TestCacheBudgetAndTrim(t *testing.T) {
	c := &cache{budget: 100}
	loads := 0
	load := func() (Resolved, error) { loads++; return Resolved{Project: "p"}, nil }
	c.get("a", "1", 60, load)
	c.get("a", "1", 60, load)
	if loads != 1 || len(c.entries) != 1 {
		t.Fatalf("same key and stamp must load once: loads=%d entries=%d", loads, len(c.entries))
	}
	c.get("a", "2", 60, load) // the source changed
	if loads != 2 || len(c.entries) != 1 {
		t.Fatalf("a new stamp replaces the entry: loads=%d entries=%d", loads, len(c.entries))
	}
	c.get("b", "1", 60, load) // over budget: the older one goes
	if len(c.entries) != 1 || c.entries[0].key != "b" || c.holds("a") {
		t.Fatalf("budget should evict the least recent: %d entries", len(c.entries))
	}
	c.get("big", "1", 1000, load) // larger than the budget: still kept, alone
	if len(c.entries) != 1 || !c.holds("big") {
		t.Fatalf("the most recent session is always kept: %d entries", len(c.entries))
	}
	a := &Archive{cache: c}
	a.TrimCache(time.Hour)
	if a.CachedSessions() != 1 {
		t.Fatal("a recently used entry survives a trim")
	}
	a.TrimCache(0)
	if a.CachedSessions() != 0 {
		t.Fatal("an idle entry is dropped")
	}
}

func TestIngestDoesNotFillTheCache(t *testing.T) {
	a, claude, src, full := setup(t, 10)
	a.EnableCache(DefaultCacheBytes)
	mustIngest(t, a, claude, Options{})
	if a.CachedSessions() != 0 {
		t.Fatal("archiving a session nobody reads must not cache it")
	}
	rep, _ := catalog.InspectDir(claude)
	if _, err := a.Resolve(rep, fixtureID); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(src, full, 0o644)
	mustIngest(t, a, claude, Options{}) // a reader holds it: the ingest's parse replaces the stale one
	rep, _ = catalog.InspectDir(claude)
	r, err := a.Resolve(rep, fixtureID)
	if err != nil || r.Session.Totals.Records != 31 || a.CachedSessions() != 1 {
		t.Fatalf("after growth the cached session must be the grown one: %v, %d cached", err, a.CachedSessions())
	}
}

// decoded returns the raw copy, decompressed.
func decoded(t *testing.T, path string) []byte {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	dec, err := zstd.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	defer dec.Close()
	b, err := io.ReadAll(dec)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// TestUnfinishedLastLineIsArchived: the copy is the source byte for byte at
// every step, whether or not the last line has its newline yet.
func TestUnfinishedLastLineIsArchived(t *testing.T) {
	a, claude, src, _ := setup(t, 31)
	whole := `{"type":"user","uuid":"u9","parentUuid":"a8","turnOrigin":"human","sessionId":"` + fixtureID + `","timestamp":"2026-11-08T10:02:00.000Z","message":{"role":"user","content":"a prompt cut in two"}}`
	half := len(whole) / 2
	appendTo := func(s string) {
		f, _ := os.OpenFile(src, os.O_APPEND|os.O_WRONLY, 0o644)
		f.WriteString(s)
		f.Close()
	}
	same := func(step string, res Result) {
		t.Helper()
		want, _ := os.ReadFile(src)
		if got := decoded(t, res.Path); !bytes.Equal(got, want) {
			t.Fatalf("%s: the copy (%d bytes) is not the source (%d bytes)", step, len(got), len(want))
		}
		if res.Bytes != int64(len(want)) {
			t.Fatalf("%s: covered %d of %d bytes", step, res.Bytes, len(want))
		}
	}

	// Half a line, as a crash mid-write would leave it. It is kept, not parsed.
	appendTo(whole[:half])
	res := mustIngest(t, a, claude, Options{})
	same("half a line", res)
	s, _, err := a.Load(fixtureID)
	if err != nil || !s.Partial || s.Totals.Prompts != 2 {
		t.Fatalf("an unfinished line is evidence, not a record: partial=%v prompts=%d err=%v", s.Partial, s.Totals.Prompts, err)
	}

	// The rest arrives without a newline: a whole record, and the copy continues the same line.
	appendTo(whole[half:])
	res = mustIngest(t, a, claude, Options{})
	same("whole line, no newline", res)
	if len(res.Kept) != 0 {
		t.Fatalf("growth mid-line is an append, nothing to keep aside: %+v", res)
	}
	s, _, err = a.Load(fixtureID)
	if err != nil || s.Partial || s.Totals.Prompts != 3 {
		t.Fatalf("a last line that is whole JSON counts without its newline: partial=%v prompts=%d err=%v", s.Partial, s.Totals.Prompts, err)
	}

	// The newline and one more line.
	appendTo("\n" + strings.Replace(whole, `"u9"`, `"u10"`, 1) + "\n")
	res = mustIngest(t, a, claude, Options{})
	same("newline and another line", res)
	if c, _ := a.Verify(nil); c[0].Status != "ok" || c[0].Records != 33 {
		t.Fatalf("verify = %+v", c[0])
	}
}

// TestMemoisedPerParsedSession: a cached session derives its relations and
// encodes its document once; a session that changed is derived again.
func TestMemoisedPerParsedSession(t *testing.T) {
	a, claude, src, _ := setup(t, 31)
	resolve := func() Resolved {
		t.Helper()
		rep, err := catalog.InspectDir(claude)
		if err != nil {
			t.Fatal(err)
		}
		r, err := a.Resolve(rep, fixtureID)
		if err != nil {
			t.Fatal(err)
		}
		return r
	}

	// Without a cache nothing is kept: every call derives afresh.
	one := resolve()
	if first, again := one.Relations(), one.Relations(); first == again {
		t.Fatal("a one-shot Resolved has nowhere to keep its relations")
	}

	a.EnableCache(DefaultCacheBytes)
	first, again := resolve(), resolve()
	if first.Relations() != again.Relations() {
		t.Fatal("two requests for the same parsed session must share one Relations")
	}
	doc1, err := first.DocumentJSON()
	doc2, _ := again.DocumentJSON()
	if err != nil || len(doc1) == 0 || &doc1[0] != &doc2[0] {
		t.Fatalf("the document must be encoded once and shared: err=%v", err)
	}
	want, _ := json.Marshal(Document(first))
	if !bytes.Equal(doc1, want) {
		t.Fatal("the memoised document must be exactly Document(), encoded")
	}

	// The transcript grows: a new parse, new answers.
	f, _ := os.OpenFile(src, os.O_APPEND|os.O_WRONLY, 0o644)
	f.WriteString(`{"type":"user","uuid":"u9","parentUuid":"a8","turnOrigin":"human","sessionId":"` + fixtureID + `","timestamp":"2026-11-08T10:02:00.000Z","message":{"role":"user","content":"later"}}` + "\n")
	f.Close()
	grown := resolve()
	if grown.Relations() == first.Relations() {
		t.Fatal("a session that changed must be derived again")
	}
	doc3, _ := grown.DocumentJSON()
	if bytes.Equal(doc3, doc1) {
		t.Fatal("the grown session's document must differ")
	}
}
