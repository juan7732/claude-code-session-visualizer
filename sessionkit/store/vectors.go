package store

import (
	"crypto/sha256"
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// Meaning search keeps three things in the index (schema 5):
//
//	chunks   a segment's text cut into pieces short enough for the model,
//	         each naming its text by hash; removed with the segment
//	vectors  one vector per hash, so the same text is embedded once however
//	         often it appears and however often its session is re-indexed
//	meta     vector_source: what made the vectors
//
// DECISION: vectors hang off a content hash, not off the segment row (ADR 0005
// said "on the segment row"). ReplaceSegments swaps every row of a session on
// each ingest, so a vector on the row would be recomputed every time a live
// session grows; and one vector per segment covers only the start of a
// segment longer than the model reads.

// HashLen is the length of a chunk hash in bytes.
const HashLen = 16

// ChunkHash names a chunk's text.
func ChunkHash(text string) []byte {
	sum := sha256.Sum256([]byte(text))
	return sum[:HashLen]
}

// Chunk is one piece of a segment.
type Chunk struct {
	Segment int64
	Ord     int
	Start   int // byte offset into the segment's text
	Len     int
	Hash    []byte
}

// SegmentText is a segment waiting to be cut into chunks.
type SegmentText struct {
	ID   int64
	Text string
}

// UnchunkedSegments returns up to limit segments of the given kinds whose
// chunks have not been written yet.
func (s *Store) UnchunkedSegments(kinds []string, limit int) ([]SegmentText, error) {
	if len(kinds) == 0 {
		return nil, nil
	}
	args := make([]any, 0, len(kinds)+1)
	for _, k := range kinds {
		args = append(args, k)
	}
	args = append(args, limit)
	rows, err := s.db.Query(`SELECT id, text FROM segments WHERE chunked = 0 AND kind IN (?`+strings.Repeat(",?", len(kinds)-1)+`) ORDER BY id LIMIT ?`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []SegmentText
	for rows.Next() {
		var g SegmentText
		if err := rows.Scan(&g.ID, &g.Text); err != nil {
			return nil, err
		}
		out = append(out, g)
	}
	return out, rows.Err()
}

// PutChunks writes the chunks of the given segments and marks every one of
// them as cut, including those that produced no chunk. A segment that was
// deleted in the meantime (its session was re-indexed) is skipped.
func (s *Store) PutChunks(segments []int64, chunks []Chunk) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	mark, err := tx.Prepare(`UPDATE segments SET chunked = 1 WHERE id = ? AND chunked = 0`)
	if err != nil {
		return err
	}
	defer mark.Close()
	live := make(map[int64]bool, len(segments))
	for _, id := range segments {
		res, err := mark.Exec(id)
		if err != nil {
			return err
		}
		if n, _ := res.RowsAffected(); n == 1 {
			live[id] = true
		}
	}
	ins, err := tx.Prepare(`INSERT INTO chunks(segment, ord, start, len, hash) VALUES(?,?,?,?,?)`)
	if err != nil {
		return err
	}
	defer ins.Close()
	for _, c := range chunks {
		if !live[c.Segment] {
			continue
		}
		if len(c.Hash) != HashLen {
			return fmt.Errorf("chunk hash is %d bytes, expected %d", len(c.Hash), HashLen)
		}
		if _, err := ins.Exec(c.Segment, c.Ord, c.Start, c.Len, c.Hash); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// ChunkText is a chunk's text, waiting for a vector.
type ChunkText struct {
	Hash []byte
	Text string
}

// ChunksWithoutVector returns up to limit distinct chunk texts that have no
// vector yet.
func (s *Store) ChunksWithoutVector(limit int) ([]ChunkText, error) {
	rows, err := s.db.Query(`
SELECT c.hash, substr(CAST(g.text AS BLOB), c.start + 1, c.len)
FROM chunks c JOIN segments g ON g.id = c.segment
WHERE NOT EXISTS (SELECT 1 FROM vectors v WHERE v.hash = c.hash)
GROUP BY c.hash ORDER BY min(c.segment), min(c.ord) LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ChunkText
	for rows.Next() {
		var c ChunkText
		var text []byte
		if err := rows.Scan(&c.Hash, &text); err != nil {
			return nil, err
		}
		c.Text = string(text)
		out = append(out, c)
	}
	return out, rows.Err()
}

// PutVectors stores one packed vector per hash. A hash that already has one
// keeps it.
func (s *Store) PutVectors(hashes [][]byte, vecs [][]byte) error {
	if len(hashes) != len(vecs) {
		return errors.New("PutVectors: hashes and vectors differ in number")
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	ins, err := tx.Prepare(`INSERT INTO vectors(hash, vec) VALUES(?,?) ON CONFLICT(hash) DO NOTHING`)
	if err != nil {
		return err
	}
	defer ins.Close()
	for i := range hashes {
		if _, err := ins.Exec(hashes[i], vecs[i]); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// VectorSource is what made the stored vectors, "" when there are none yet.
func (s *Store) VectorSource() (string, error) {
	var v string
	err := s.db.QueryRow(`SELECT value FROM meta WHERE key = 'vector_source'`).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	return v, err
}

// UseVectorSource declares what is about to make vectors. Vectors made by
// anything else are dropped first (and counted): two sources are never mixed
// in one index, because their vectors cannot be compared.
func (s *Store) UseVectorSource(source string) (dropped int, err error) {
	if source == "" {
		return 0, errors.New("vector source is empty")
	}
	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	var have string
	err = tx.QueryRow(`SELECT value FROM meta WHERE key = 'vector_source'`).Scan(&have)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return 0, err
	}
	if have == source {
		return 0, nil
	}
	res, err := tx.Exec(`DELETE FROM vectors`)
	if err != nil {
		return 0, err
	}
	n, _ := res.RowsAffected()
	if _, err := tx.Exec(`INSERT INTO meta(key, value) VALUES('vector_source', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`, source); err != nil {
		return 0, err
	}
	return int(n), tx.Commit()
}

// PruneVectors deletes vectors no chunk points at any more and returns how
// many went.
func (s *Store) PruneVectors() (int, error) {
	res, err := s.db.Exec(`DELETE FROM vectors WHERE NOT EXISTS (SELECT 1 FROM chunks c WHERE c.hash = vectors.hash)`)
	if err != nil {
		return 0, err
	}
	n, _ := res.RowsAffected()
	return int(n), nil
}

// VectorCounts says how much of the index has vectors.
type VectorCounts struct {
	Source  string `json:"source"`  // what made the vectors; "" before the first embed
	Chunks  int    `json:"chunks"`  // pieces of text across all segments
	Texts   int    `json:"texts"`   // distinct pieces (the same text appears once)
	Vectors int    `json:"vectors"` // distinct pieces that have a vector
	Bytes   int64  `json:"bytes"`   // size of the stored vectors
}

// VectorCounts reports vector coverage.
func (s *Store) VectorCounts() (VectorCounts, error) {
	var c VectorCounts
	var err error
	if c.Source, err = s.VectorSource(); err != nil {
		return c, err
	}
	if err := s.db.QueryRow(`SELECT count(*), count(DISTINCT hash) FROM chunks`).Scan(&c.Chunks, &c.Texts); err != nil {
		return c, err
	}
	if err := s.db.QueryRow(`SELECT count(*), coalesce(sum(length(vec)), 0) FROM vectors v WHERE EXISTS (SELECT 1 FROM chunks c WHERE c.hash = v.hash)`).Scan(&c.Vectors, &c.Bytes); err != nil {
		return c, err
	}
	return c, nil
}
