package store

import (
	"context"
	"database/sql"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestMigrateFromV1 builds a schema-1 index by hand and checks it reaches the
// current schema with the columns v2 added and stale segments cleared.
func TestMigrateFromV1(t *testing.T) {
	path := filepath.Join(t.TempDir(), "skit.sqlite")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	v1 := `CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE sessions(id TEXT PRIMARY KEY, project TEXT NOT NULL, source_path TEXT NOT NULL, source_size INTEGER NOT NULL,
 source_mtime INTEGER NOT NULL, source_sub TEXT NOT NULL DEFAULT '', records INTEGER NOT NULL DEFAULT 0, first_at TEXT, last_at TEXT,
 title TEXT NOT NULL DEFAULT '', owner_account TEXT NOT NULL DEFAULT '', owner_org TEXT NOT NULL DEFAULT '', summary TEXT NOT NULL,
 indexed_at TEXT NOT NULL, archive_path TEXT NOT NULL DEFAULT '', archived_bytes INTEGER NOT NULL DEFAULT 0, debug INTEGER NOT NULL DEFAULT 0, archived_at TEXT);
CREATE TABLE segments(id INTEGER PRIMARY KEY, session TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, agent TEXT NOT NULL DEFAULT '',
 turn INTEGER NOT NULL DEFAULT -1, uuid TEXT NOT NULL DEFAULT '', kind TEXT NOT NULL, tool TEXT NOT NULL DEFAULT '', at TEXT, text TEXT NOT NULL);
CREATE VIRTUAL TABLE fts USING fts5(text, content='segments', content_rowid='id');
INSERT INTO sessions(id, project, source_path, source_size, source_mtime, summary, indexed_at) VALUES('s1','p','/x',1,1,'{}','now');
INSERT INTO segments(session, turn, kind, text) VALUES('s1', 3, 'assistant', 'old row');
PRAGMA user_version = 1;`
	if _, err := db.Exec(v1); err != nil {
		t.Fatal(err)
	}
	db.Close()
	st, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	var version, segs, schema int
	st.db.QueryRow(`PRAGMA user_version`).Scan(&version)
	st.db.QueryRow(`SELECT count(*) FROM segments`).Scan(&segs)
	st.db.QueryRow(`SELECT schema FROM sessions WHERE id='s1'`).Scan(&schema)
	if version != SchemaVersion || segs != 0 || schema != 1 {
		t.Fatalf("after migration: version=%d segments=%d row schema=%d", version, segs, schema)
	}
	row, err := st.Session("s1")
	if err != nil || row == nil || row.Schema != 1 {
		t.Fatalf("row = %+v %v (schema 1 rows must be re-indexed by archive)", row, err)
	}
}

// columns returns a table's columns as "name type notnull default", sorted.
func columns(t *testing.T, st *Store, table string) []string {
	t.Helper()
	rows, err := st.db.Query(`SELECT name || ' ' || type || ' ' || "notnull" || ' ' || coalesce(dflt_value, '') FROM pragma_table_info(?) ORDER BY name`, table)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var c string
		rows.Scan(&c)
		out = append(out, c)
	}
	return out
}

// TestMigratedSchemaEqualsFresh guards the two ways an index reaches the
// current schema: created at it, or migrated to it. A column added to one and
// forgotten in the other fails here.
func TestMigratedSchemaEqualsFresh(t *testing.T) {
	fresh, err := Open(filepath.Join(t.TempDir(), "fresh.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer fresh.Close()

	path := filepath.Join(t.TempDir(), "old.sqlite")
	db, _ := sql.Open("sqlite", path)
	if _, err := db.Exec(`CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE sessions(id TEXT PRIMARY KEY, project TEXT NOT NULL, source_path TEXT NOT NULL, source_size INTEGER NOT NULL,
 source_mtime INTEGER NOT NULL, source_sub TEXT NOT NULL DEFAULT '', records INTEGER NOT NULL DEFAULT 0, first_at TEXT, last_at TEXT,
 title TEXT NOT NULL DEFAULT '', owner_account TEXT NOT NULL DEFAULT '', owner_org TEXT NOT NULL DEFAULT '', summary TEXT NOT NULL,
 indexed_at TEXT NOT NULL, archive_path TEXT NOT NULL DEFAULT '', archived_bytes INTEGER NOT NULL DEFAULT 0, debug INTEGER NOT NULL DEFAULT 0, archived_at TEXT);
CREATE TABLE segments(id INTEGER PRIMARY KEY, session TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, agent TEXT NOT NULL DEFAULT '',
 turn INTEGER NOT NULL DEFAULT -1, uuid TEXT NOT NULL DEFAULT '', kind TEXT NOT NULL, tool TEXT NOT NULL DEFAULT '', at TEXT, text TEXT NOT NULL);
PRAGMA user_version = 1;`); err != nil {
		t.Fatal(err)
	}
	db.Close()
	old, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer old.Close()

	for _, table := range []string{"sessions", "segments", "chunks", "vectors"} {
		f, m := columns(t, fresh, table), columns(t, old, table)
		if len(f) == 0 || strings.Join(f, "\n") != strings.Join(m, "\n") {
			t.Fatalf("%s differs.\nfresh:\n  %s\nmigrated:\n  %s", table, strings.Join(f, "\n  "), strings.Join(m, "\n  "))
		}
	}
	// The archive state round-trips through the columns schema 3 added.
	if err := old.UpsertSummary(SessionRow{ID: "s1", Project: "p", SourcePath: "/x", Summary: []byte(`{}`)}); err != nil {
		t.Fatal(err)
	}
	want := ArchiveState{Path: "/a/s1.jsonl.zst", Bytes: 10, Size: 7, Tail: "abc", Fingerprint: "10:1:0:0", KeepsRequests: true}
	if err := old.SetArchive("s1", want); err != nil {
		t.Fatal(err)
	}
	row, err := old.Session("s1")
	if err != nil || row.ArchivePath != want.Path || row.ArchivedBytes != 10 || row.ArchiveSize != 7 || row.ArchiveTail != "abc" || row.ArchivedFP != want.Fingerprint || !row.KeepsRequests {
		t.Fatalf("archive state = %+v %v", row, err)
	}
}

// TestMigrateFromV4KeepsEverything: schemas 5 to 7 only add, so segments stay, rows
// keep the version they were indexed at (no session is parsed again), and the
// new tables work on the migrated index.
func TestMigrateFromV4KeepsEverything(t *testing.T) {
	path := filepath.Join(t.TempDir(), "skit.sqlite")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	// Schema 4 is the latest schema without what v5 added.
	v4 := strings.Replace(strings.TrimSuffix(schemaLatest, schemaVectors+schemaFiles), "text    TEXT NOT NULL,\n  chunked INTEGER NOT NULL DEFAULT 0  -- 1 once its chunks are written (possibly none: nothing worth a vector)\n", "text    TEXT NOT NULL\n", 1)
	if strings.Contains(v4, "chunked") || strings.Contains(v4, "vectors") || strings.Contains(v4, "files(") {
		t.Fatal("the test's schema 4 still has schema 5 in it")
	}
	if _, err := db.Exec(v4 + `
INSERT INTO sessions(id, project, source_path, source_size, source_mtime, summary, indexed_at, schema) VALUES('s1','p','/x',1,1,'{}','now',4);
INSERT INTO segments(session, turn, kind, text) VALUES('s1', 3, 'assistant', 'a row that must survive');
PRAGMA user_version = 4;`); err != nil {
		t.Fatal(err)
	}
	db.Close()
	st, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	var version, segs int
	st.db.QueryRow(`PRAGMA user_version`).Scan(&version)
	st.db.QueryRow(`SELECT count(*) FROM segments`).Scan(&segs)
	row, err := st.Session("s1")
	// The row keeps the version it was indexed at. Schema 5 left it current;
	// schema 6 changed what a summary holds, so it is now due to be indexed again.
	if err != nil || version != SchemaVersion || segs != 1 || row.Schema != 4 || row.Schema >= IndexedVersion {
		t.Fatalf("version=%d segments=%d row schema=%d err=%v (a v4 row keeps its version and is due for re-indexing)", version, segs, row.Schema, err)
	}
	todo, err := st.UnchunkedSegments([]string{"assistant"}, 10)
	if err != nil || len(todo) != 1 || todo[0].Text != "a row that must survive" {
		t.Fatalf("segments from before the migration should be waiting to be cut: %+v %v", todo, err)
	}
	var hits int
	st.db.QueryRow(`SELECT count(*) FROM fts WHERE fts MATCH 'survive'`).Scan(&hits)
	if hits != 1 {
		t.Fatalf("keyword search lost the row: %d hits", hits)
	}
}

func TestChunksAndVectors(t *testing.T) {
	st, err := Open(filepath.Join(t.TempDir(), "skit.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	if err := st.UpsertSummary(SessionRow{ID: "s1", Project: "p", SourcePath: "/x", Summary: []byte(`{}`)}); err != nil {
		t.Fatal(err)
	}
	// Multi-byte text: chunk offsets are bytes, and must come back as the same text.
	long := "héllo wörld, première partie. " + "日本語の二番目の部分です。"
	cut := len("héllo wörld, première partie. ")
	segs := []Segment{
		{Session: "s1", Kind: "prompt", Text: long},
		{Session: "s1", Kind: "assistant", Text: "the same words twice"},
		{Session: "s1", Kind: "assistant", Text: "the same words twice"},
		{Session: "s1", Kind: "tool_result", Text: "not for vectors"},
		{Session: "s1", Kind: "prompt", Text: "ok"},
	}
	if err := st.ReplaceSegments("s1", segs); err != nil {
		t.Fatal(err)
	}
	todo, err := st.UnchunkedSegments([]string{"prompt", "assistant"}, 100)
	if err != nil || len(todo) != 4 {
		t.Fatalf("unchunked = %d %v, want the four prompt and assistant rows", len(todo), err)
	}
	var ids []int64
	var chunks []Chunk
	for _, g := range todo {
		ids = append(ids, g.ID)
		switch g.Text {
		case long:
			chunks = append(chunks, Chunk{Segment: g.ID, Ord: 0, Start: 0, Len: cut, Hash: ChunkHash(long[:cut])},
				Chunk{Segment: g.ID, Ord: 1, Start: cut, Len: len(long) - cut, Hash: ChunkHash(long[cut:])})
		case "ok": // cut, and nothing worth a vector
		default:
			chunks = append(chunks, Chunk{Segment: g.ID, Ord: 0, Start: 0, Len: len(g.Text), Hash: ChunkHash(g.Text)})
		}
	}
	ids = append(ids, 9999) // a segment that vanished meanwhile
	chunks = append(chunks, Chunk{Segment: 9999, Ord: 0, Start: 0, Len: 1, Hash: ChunkHash("gone")})
	if err := st.PutChunks(ids, chunks); err != nil {
		t.Fatal(err)
	}
	if again, _ := st.UnchunkedSegments([]string{"prompt", "assistant"}, 100); len(again) != 0 {
		t.Fatalf("%d segments still waiting, the one with no chunk included", len(again))
	}
	c, err := st.VectorCounts()
	if err != nil || c.Chunks != 4 || c.Texts != 3 || c.Vectors != 0 || c.Source != "" {
		t.Fatalf("counts = %+v %v, want 4 chunks of 3 distinct texts", c, err)
	}

	missing, err := st.ChunksWithoutVector(100)
	if err != nil || len(missing) != 3 {
		t.Fatalf("missing = %d %v", len(missing), err)
	}
	if missing[0].Text != long[:cut] || missing[1].Text != long[cut:] || missing[2].Text != "the same words twice" {
		t.Fatalf("chunk texts came back wrong: %q", missing)
	}
	if dropped, err := st.UseVectorSource("model A"); err != nil || dropped != 0 {
		t.Fatalf("first source: %d %v", dropped, err)
	}
	var hashes, vecs [][]byte
	for i, m := range missing {
		hashes = append(hashes, m.Hash)
		vecs = append(vecs, []byte{byte(i), 0})
	}
	if err := st.PutVectors(hashes[:2], vecs[:2]); err != nil {
		t.Fatal(err)
	}
	if left, _ := st.ChunksWithoutVector(100); len(left) != 1 || left[0].Text != "the same words twice" {
		t.Fatalf("after two vectors, missing = %q", left)
	}
	if err := st.PutVectors(hashes, vecs); err != nil { // the first two again: kept, not an error
		t.Fatal(err)
	}
	c, _ = st.VectorCounts()
	if c.Vectors != 3 || c.Bytes != 6 || c.Source != "model A" {
		t.Fatalf("counts = %+v", c)
	}

	// The same source again changes nothing; another drops every vector.
	if dropped, _ := st.UseVectorSource("model A"); dropped != 0 {
		t.Fatalf("same source dropped %d", dropped)
	}
	if dropped, _ := st.UseVectorSource("model B"); dropped != 3 {
		t.Fatalf("new source dropped %d, want 3", dropped)
	}
	if err := st.PutVectors(hashes, vecs); err != nil {
		t.Fatal(err)
	}

	// Replacing the session's segments takes the chunks; the vectors stay
	// until pruned, and are pruned only when nothing uses them.
	if err := st.ReplaceSegments("s1", segs[1:2]); err != nil {
		t.Fatal(err)
	}
	if c, _ = st.VectorCounts(); c.Chunks != 0 || c.Vectors != 0 {
		t.Fatalf("after replacing segments: %+v", c)
	}
	todo, _ = st.UnchunkedSegments([]string{"assistant"}, 100)
	if len(todo) != 1 {
		t.Fatalf("the new row should be waiting: %d", len(todo))
	}
	if err := st.PutChunks([]int64{todo[0].ID}, []Chunk{{Segment: todo[0].ID, Start: 0, Len: len(todo[0].Text), Hash: ChunkHash(todo[0].Text)}}); err != nil {
		t.Fatal(err)
	}
	if left, _ := st.ChunksWithoutVector(100); len(left) != 0 {
		t.Fatalf("the text kept its vector by hash, yet %d are missing", len(left))
	}
	if n, err := st.PruneVectors(); err != nil || n != 2 {
		t.Fatalf("pruned %d %v, want the 2 no chunk uses", n, err)
	}
	if c, _ = st.VectorCounts(); c.Chunks != 1 || c.Vectors != 1 {
		t.Fatalf("at the end: %+v", c)
	}
}

// TestVectorGenerationMovesWhenTheVectorsDo: a process that holds the vectors
// in memory trusts this counter to say when to read the index again.
func TestVectorGenerationMovesWhenTheVectorsDo(t *testing.T) {
	st, err := Open(filepath.Join(t.TempDir(), "skit.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	gen := func() int64 {
		t.Helper()
		g, err := st.VectorGeneration()
		if err != nil {
			t.Fatal(err)
		}
		return g
	}
	moved := func(what string, before int64) int64 {
		t.Helper()
		now := gen()
		if now == before {
			t.Fatalf("%s did not move the generation (%d)", what, before)
		}
		return now
	}
	still := func(what string, before int64) {
		t.Helper()
		if now := gen(); now != before {
			t.Fatalf("%s moved the generation %d → %d", what, before, now)
		}
	}
	if gen() != 0 {
		t.Fatal("a new index starts at generation 0")
	}
	st.UpsertSummary(SessionRow{ID: "s1", Project: "proj", SourcePath: "/x", Summary: []byte(`{}`)})
	text := "words enough to be worth a vector"
	st.ReplaceSegments("s1", []Segment{{Session: "s1", Kind: "assistant", Text: text}})
	still("indexing a session nobody has cut yet", 0)

	todo, _ := st.UnchunkedSegments([]string{"assistant"}, 10)
	hash := ChunkHash(text)
	st.PutChunks([]int64{todo[0].ID}, []Chunk{{Segment: todo[0].ID, Len: len(text), Hash: hash}})
	g := moved("writing chunks", 0)
	if _, err := st.UseVectorSource("model A"); err != nil {
		t.Fatal(err)
	}
	g = moved("naming a source for the first time", g)
	st.UseVectorSource("model A")
	still("naming the same source again", g)
	st.PutVectors([][]byte{hash}, [][]byte{{1, 2}})
	g = moved("storing a vector", g)

	// What a search reads back: the piece with its vector and what it may be narrowed by.
	var pieces []Piece
	if err := st.EachPiece(context.Background(), func(p Piece) error {
		p.Vec = append([]byte(nil), p.Vec...)
		pieces = append(pieces, p)
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if len(pieces) != 1 || pieces[0].Session != "s1" || pieces[0].Project != "proj" || pieces[0].Kind != "assistant" || pieces[0].Len != len(text) || string(pieces[0].Vec) != "\x01\x02" {
		t.Fatalf("pieces = %+v", pieces)
	}

	st.PruneVectors()
	still("pruning when nothing is orphaned", g)
	st.ReplaceSegments("s1", []Segment{{Session: "s1", Kind: "assistant", Text: text}})
	g = moved("re-indexing a session that had chunks", g)
	st.UseVectorSource("model B")
	moved("changing the source", g)

	// The last pass is remembered and reported.
	if c, _ := st.VectorCounts(); c.EmbeddedAt != "" {
		t.Fatalf("no pass has run, yet embedded_at = %q", c.EmbeddedAt)
	}
	when := time.Date(2026, 11, 10, 17, 30, 0, 0, time.UTC)
	if err := st.MarkEmbedded(when); err != nil {
		t.Fatal(err)
	}
	if c, _ := st.VectorCounts(); c.EmbeddedAt != "2026-11-10T17:30:00Z" {
		t.Fatalf("embedded_at = %q", c.EmbeddedAt)
	}
}

// TestFilesByPath: which sessions touched a file, the latest first; two paths a
// session wrote that are the same file on disk are one row.
func TestFilesByPath(t *testing.T) {
	st, err := Open(filepath.Join(t.TempDir(), "skit.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	at := func(h int) time.Time { return time.Date(2026, 11, 8, h, 0, 0, 0, time.UTC) }
	for _, id := range []string{"s1", "s2"} {
		if err := st.UpsertSummary(SessionRow{ID: id, Project: "p", SourcePath: "/x/" + id, Title: "title " + id, Summary: []byte("{}")}); err != nil {
			t.Fatal(err)
		}
	}
	if err := st.ReplaceFiles("s1", []FileRow{
		{Path: "/w/a.go", Raw: "a.go", Reads: 2, Writes: 1, FirstAt: at(1), LastAt: at(3)},
		{Path: "/w/a.go", Raw: "./a.go", Reads: 1, FirstAt: at(4), LastAt: at(5)},
		{Path: "/w/b.go", Raw: "b.go", Writes: 1, FirstAt: at(2), LastAt: at(2)},
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.ReplaceFiles("s2", []FileRow{{Path: "/w/a.go", Raw: "/w/a.go", Writes: 4, FirstAt: at(9), LastAt: at(9)}}); err != nil {
		t.Fatal(err)
	}
	got, err := st.FileSessions("/w/a.go")
	if err != nil || len(got) != 2 || got[0].Session != "s2" || got[0].Writes != 4 || got[0].Title != "title s2" {
		t.Fatalf("sessions of a.go: %+v %v", got, err)
	}
	if got[1].Session != "s1" || got[1].Reads != 3 || got[1].Writes != 1 || !got[1].FirstAt.Equal(at(1)) || !got[1].LastAt.Equal(at(5)) || got[1].Raw != "a.go" {
		t.Fatalf("two spellings of one file are one row: %+v", got[1])
	}
	// Replacing a session's files forgets the old ones; nobody touched c.go.
	if err := st.ReplaceFiles("s1", nil); err != nil {
		t.Fatal(err)
	}
	if got, _ := st.FileSessions("/w/b.go"); len(got) != 0 {
		t.Fatalf("b.go after s1 was replaced: %+v", got)
	}
	if got, _ := st.FileSessions("/w/c.go"); len(got) != 0 {
		t.Fatalf("c.go: %+v", got)
	}
}
