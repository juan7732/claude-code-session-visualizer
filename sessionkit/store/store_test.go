package store

import (
	"database/sql"
	"path/filepath"
	"testing"
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
