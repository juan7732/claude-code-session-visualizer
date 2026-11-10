// Package store is skit's index: one SQLite file holding every session's
// summary and source fingerprint, one segment per content block, and an FTS5
// table over segment text. Vectors join it later. The raw transcripts live
// beside it as files (see package archive); the index can always be rebuilt
// from them.
package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite" // pure-Go SQLite with FTS5
)

// SchemaVersion is bumped with every migration.
const SchemaVersion = 4

// Store is an open index.
type Store struct {
	db   *sql.DB
	Path string
}

// Open opens (and creates or migrates) the index at path.
func Open(path string) (*Store, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite", path+"?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=foreign_keys(ON)&_pragma=synchronous(NORMAL)")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1) // one writer, no lock dance
	s := &Store{db: db, Path: path}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, fmt.Errorf("index %s: %w", path, err)
	}
	return s, nil
}

// Close closes the database.
func (s *Store) Close() error { return s.db.Close() }

// DB exposes the connection for read-only queries (search).
func (s *Store) DB() *sql.DB { return s.db }

func (s *Store) migrate() error {
	var version int
	if err := s.db.QueryRow(`PRAGMA user_version`).Scan(&version); err != nil {
		return err
	}
	if version > SchemaVersion {
		return fmt.Errorf("made by a newer skit (schema %d, this skit knows %d)", version, SchemaVersion)
	}
	if version == SchemaVersion {
		return nil
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if version == 0 {
		// A new index is created at the latest schema directly.
		if _, err := tx.Exec(schemaLatest); err != nil {
			return err
		}
		version = SchemaVersion
	}
	if version == 1 {
		// v2: segments carry the agent turn and the action; sessions record the
		// schema that indexed them so stale rows are re-indexed by `archive`.
		// Old segment rows had the action index in `turn`; drop them, the
		// archive re-creates them.
		if _, err := tx.Exec(`ALTER TABLE segments ADD COLUMN action INTEGER NOT NULL DEFAULT -1;
			ALTER TABLE sessions ADD COLUMN schema INTEGER NOT NULL DEFAULT 1;
			DELETE FROM segments;`); err != nil {
			return err
		}
		version = 2
	}
	if version == 2 {
		// v3: what the archive needs to never lose lines (ADR 0008): the raw
		// copy's size on disk, a hash of the source bytes just before the append
		// offset, and the source fingerprint the copy was made from. Rows from v2
		// have none of them, so their next ingest rewrites the copy with checks.
		if _, err := tx.Exec(`ALTER TABLE sessions ADD COLUMN archive_size INTEGER NOT NULL DEFAULT 0;
			ALTER TABLE sessions ADD COLUMN archive_tail TEXT NOT NULL DEFAULT '';
			ALTER TABLE sessions ADD COLUMN archived_fp TEXT NOT NULL DEFAULT '';`); err != nil {
			return err
		}
		version = 3
	}
	if version == 3 {
		// v4: no new columns. Summaries gained the rewound counts, and a row's
		// `schema` says which version wrote its summary, so rows from v3 are
		// re-indexed by the next `archive` or `list` instead of reporting zeros.
		version = 4
	}
	if _, err := tx.Exec(fmt.Sprintf(`PRAGMA user_version = %d`, SchemaVersion)); err != nil {
		return err
	}
	return tx.Commit()
}

// schemaLatest is the DDL for a brand-new index (schema SchemaVersion).
// Existing indexes reach it through the migrations in migrate().
const schemaLatest = `
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE sessions(
  id             TEXT PRIMARY KEY,
  project        TEXT NOT NULL,
  source_path    TEXT NOT NULL,
  source_size    INTEGER NOT NULL,
  source_mtime   INTEGER NOT NULL,          -- unix nanoseconds
  source_sub     TEXT NOT NULL DEFAULT '',  -- "<subagent files>:<subagent bytes>"
  records        INTEGER NOT NULL DEFAULT 0,
  first_at       TEXT,
  last_at        TEXT,
  title          TEXT NOT NULL DEFAULT '',
  owner_account  TEXT NOT NULL DEFAULT '',
  owner_org      TEXT NOT NULL DEFAULT '',
  summary        TEXT NOT NULL,             -- stats.Summary JSON
  indexed_at     TEXT NOT NULL,
  archive_path   TEXT NOT NULL DEFAULT '',  -- raw copy; '' when only the summary is indexed
  archived_bytes INTEGER NOT NULL DEFAULT 0, -- source bytes copied so far (append offset)
  debug          INTEGER NOT NULL DEFAULT 0, -- api-request* records kept in the raw copy (name is historical)
  archived_at    TEXT,
  schema         INTEGER NOT NULL DEFAULT 1, -- SchemaVersion that produced the summary and segments
  archive_size   INTEGER NOT NULL DEFAULT 0, -- size of the raw copy on disk after the last write (0: unknown)
  archive_tail   TEXT NOT NULL DEFAULT '',   -- sha256 of the source bytes just before archived_bytes
  archived_fp    TEXT NOT NULL DEFAULT ''    -- source fingerprint the raw copy was made from
);
CREATE INDEX sessions_last_at ON sessions(last_at);
CREATE TABLE segments(
  id      INTEGER PRIMARY KEY,
  session TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  agent   TEXT NOT NULL DEFAULT '',   -- '' for the main transcript, else the subagent id
  turn    INTEGER NOT NULL DEFAULT -1,
  uuid    TEXT NOT NULL DEFAULT '',
  action  INTEGER NOT NULL DEFAULT -1,
  kind    TEXT NOT NULL,              -- prompt | context | assistant | thinking | tool_use | tool_result | summary
  tool    TEXT NOT NULL DEFAULT '',
  at      TEXT,
  text    TEXT NOT NULL
);
CREATE INDEX segments_session ON segments(session);
CREATE VIRTUAL TABLE fts USING fts5(text, content='segments', content_rowid='id', tokenize="porter unicode61 remove_diacritics 2");
CREATE TRIGGER segments_ai AFTER INSERT ON segments BEGIN
  INSERT INTO fts(rowid, text) VALUES (new.id, new.text);
END;
CREATE TRIGGER segments_ad AFTER DELETE ON segments BEGIN
  INSERT INTO fts(fts, rowid, text) VALUES ('delete', old.id, old.text);
END;
`

// SessionRow is one indexed session.
type SessionRow struct {
	ID            string
	Project       string
	SourcePath    string
	SourceSize    int64
	SourceMtime   int64
	SourceSub     string
	Records       int
	FirstAt       time.Time
	LastAt        time.Time
	Title         string
	OwnerAccount  string
	OwnerOrg      string
	Summary       json.RawMessage
	IndexedAt     time.Time
	ArchivePath   string
	ArchivedBytes int64
	KeepsRequests bool // api-request* records are in the raw copy (column `debug`, kept for schema stability)
	ArchivedAt    time.Time
	Schema        int
	// ArchiveSize is the raw copy's size on disk after the last successful
	// write: an append truncates to it first, so a torn write never stays.
	ArchiveSize int64
	// ArchiveTail is a hash of the source bytes just before ArchivedBytes; an
	// append is only safe while the source still has them.
	ArchiveTail string
	// ArchivedFP is the source fingerprint the raw copy was made from. The
	// source_* columns are refreshed by list's cache too, so they cannot say
	// whether the copy is current; this can.
	ArchivedFP string
}

// Archived reports whether a raw copy exists for the row.
func (r SessionRow) Archived() bool { return r.ArchivePath != "" }

// Fingerprint identifies the state of a transcript's subagent files.
func Fingerprint(subFiles int, subBytes int64) string {
	return fmt.Sprintf("%d:%d", subFiles, subBytes)
}

// SourceFingerprint identifies a source transcript's whole state: its size,
// its modification time and its subagent files.
func SourceFingerprint(size, mtimeNanos int64, subFiles int, subBytes int64) string {
	return fmt.Sprintf("%d:%d:%s", size, mtimeNanos, Fingerprint(subFiles, subBytes))
}

// UpsertSummary writes the indexed summary and source fingerprint, leaving the
// archive columns alone. Used by list as its cache and by archive before it
// copies the raw lines.
func (s *Store) UpsertSummary(r SessionRow) error {
	_, err := s.db.Exec(`
INSERT INTO sessions(id, project, source_path, source_size, source_mtime, source_sub, records, first_at, last_at, title,
                     owner_account, owner_org, summary, indexed_at, schema)
VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
ON CONFLICT(id) DO UPDATE SET project=excluded.project, source_path=excluded.source_path, source_size=excluded.source_size,
  source_mtime=excluded.source_mtime, source_sub=excluded.source_sub, records=excluded.records, first_at=excluded.first_at,
  last_at=excluded.last_at, title=excluded.title, owner_account=excluded.owner_account, owner_org=excluded.owner_org,
  summary=excluded.summary, indexed_at=excluded.indexed_at, schema=excluded.schema`,
		r.ID, r.Project, r.SourcePath, r.SourceSize, r.SourceMtime, r.SourceSub, r.Records, timeText(r.FirstAt), timeText(r.LastAt),
		r.Title, r.OwnerAccount, r.OwnerOrg, string(r.Summary), time.Now().UTC().Format(time.RFC3339Nano), SchemaVersion)
	return err
}

// ArchiveState is what the index records about a session's raw copy.
type ArchiveState struct {
	Path          string // the raw copy
	Bytes         int64  // source bytes covered (the append offset)
	Size          int64  // the copy's size on disk
	Tail          string // hash of the source bytes just before Bytes
	Fingerprint   string // source fingerprint the copy was made from
	KeepsRequests bool
}

// SetArchive records the raw copy's state for a session.
func (s *Store) SetArchive(id string, a ArchiveState) error {
	res, err := s.db.Exec(`UPDATE sessions SET archive_path=?, archived_bytes=?, debug=?, archived_at=?, archive_size=?, archive_tail=?, archived_fp=? WHERE id=?`,
		a.Path, a.Bytes, boolInt(a.KeepsRequests), time.Now().UTC().Format(time.RFC3339Nano), a.Size, a.Tail, a.Fingerprint, id)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("session %s is not indexed", id)
	}
	return nil
}

const sessionCols = `id, project, source_path, source_size, source_mtime, source_sub, records, first_at, last_at, title,
 owner_account, owner_org, summary, indexed_at, archive_path, archived_bytes, debug, archived_at, schema,
 archive_size, archive_tail, archived_fp`

func scanSession(sc interface{ Scan(...any) error }) (SessionRow, error) {
	var r SessionRow
	var first, last, indexed, archived sql.NullString
	var summary string
	var debug int
	err := sc.Scan(&r.ID, &r.Project, &r.SourcePath, &r.SourceSize, &r.SourceMtime, &r.SourceSub, &r.Records, &first, &last, &r.Title,
		&r.OwnerAccount, &r.OwnerOrg, &summary, &indexed, &r.ArchivePath, &r.ArchivedBytes, &debug, &archived, &r.Schema,
		&r.ArchiveSize, &r.ArchiveTail, &r.ArchivedFP)
	if err != nil {
		return r, err
	}
	r.Summary = json.RawMessage(summary)
	r.FirstAt, r.LastAt, r.IndexedAt, r.ArchivedAt = parseTime(first), parseTime(last), parseTime(indexed), parseTime(archived)
	r.KeepsRequests = debug != 0
	return r, nil
}

// Session returns one row, or nil when the id is unknown.
func (s *Store) Session(id string) (*SessionRow, error) {
	r, err := scanSession(s.db.QueryRow(`SELECT `+sessionCols+` FROM sessions WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &r, nil
}

// Sessions returns every indexed session, most recent activity first.
func (s *Store) Sessions() ([]SessionRow, error) {
	rows, err := s.db.Query(`SELECT ` + sessionCols + ` FROM sessions ORDER BY last_at DESC, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SessionRow
	for rows.Next() {
		r, err := scanSession(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// SessionsByPrefix returns rows whose id starts with prefix.
func (s *Store) SessionsByPrefix(prefix string) ([]SessionRow, error) {
	rows, err := s.db.Query(`SELECT `+sessionCols+` FROM sessions WHERE id LIKE ? ORDER BY id`, escapeLike(prefix)+"%")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SessionRow
	for rows.Next() {
		r, err := scanSession(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

// Segment is one searchable piece of a session.
type Segment struct {
	Session string
	Agent   string
	Turn    int // agent turn index, -1 for session-level pieces
	Action  int // action index within the session, -1 for prompts and summaries
	UUID    string
	Kind    string
	Tool    string
	At      time.Time
	Text    string
}

// ReplaceSegments swaps a session's segments in one transaction.
func (s *Store) ReplaceSegments(session string, segs []Segment) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM segments WHERE session = ?`, session); err != nil {
		return err
	}
	stmt, err := tx.Prepare(`INSERT INTO segments(session, agent, turn, action, uuid, kind, tool, at, text) VALUES(?,?,?,?,?,?,?,?,?)`)
	if err != nil {
		return err
	}
	defer stmt.Close()
	for _, g := range segs {
		if _, err := stmt.Exec(g.Session, g.Agent, g.Turn, g.Action, g.UUID, g.Kind, g.Tool, timeText(g.At), g.Text); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// Counts summarises the index.
type Counts struct {
	Sessions int
	Archived int
	Segments int
	Bytes    int64
}

// Counts reports index size.
func (s *Store) Counts() (Counts, error) {
	var c Counts
	if err := s.db.QueryRow(`SELECT count(*), coalesce(sum(archive_path <> ''),0) FROM sessions`).Scan(&c.Sessions, &c.Archived); err != nil {
		return c, err
	}
	if err := s.db.QueryRow(`SELECT count(*) FROM segments`).Scan(&c.Segments); err != nil {
		return c, err
	}
	for _, suffix := range []string{"", "-wal"} {
		if st, err := os.Stat(s.Path + suffix); err == nil {
			c.Bytes += st.Size()
		}
	}
	return c, nil
}

func timeText(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t.UTC().Format(time.RFC3339Nano)
}

func parseTime(ns sql.NullString) time.Time {
	if !ns.Valid || ns.String == "" {
		return time.Time{}
	}
	t, _ := time.Parse(time.RFC3339Nano, ns.String)
	return t
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

func escapeLike(s string) string {
	return strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(s)
}
