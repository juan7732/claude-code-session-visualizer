// Package cache keeps per-session summaries on disk so that commands which
// look at every session (list) do not re-parse unchanged transcripts. An entry
// is valid while its Key matches the transcript's size, modification time and
// subagent directory state. The M3 store will absorb this.
//
// Location: $SKIT_HOME/cache/summaries/<session-id>.json, default ~/.sessionkit.
package cache

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Schema changes whenever the cached shape changes; bumping it invalidates
// every entry.
const Schema = 1

// Dir is skit's home: $SKIT_HOME, else ~/.sessionkit.
func Dir() (string, error) {
	if d := os.Getenv("SKIT_HOME"); d != "" {
		return d, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("cannot find home directory: %w", err)
	}
	return filepath.Join(home, ".sessionkit"), nil
}

// Key identifies the state of a transcript on disk.
type Key struct {
	Path          string `json:"path"`
	Size          int64  `json:"size"`
	ModTimeNanos  int64  `json:"mod_time"`
	SubagentFiles int    `json:"subagent_files"`
	SubagentBytes int64  `json:"subagent_bytes"`
	Schema        int    `json:"schema"`
}

// KeyFor builds a Key from what catalog already knows about a session file.
func KeyFor(path string, size int64, mod time.Time, subagentFiles int, subagentBytes int64) Key {
	return Key{Path: path, Size: size, ModTimeNanos: mod.UnixNano(), SubagentFiles: subagentFiles, SubagentBytes: subagentBytes, Schema: Schema}
}

func (k Key) digest() string {
	b, _ := json.Marshal(k)
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// Store is one cache directory.
type Store struct {
	dir string
}

// Open opens the summary cache under Dir(), creating it.
func Open() (*Store, error) {
	d, err := Dir()
	if err != nil {
		return nil, err
	}
	return OpenAt(filepath.Join(d, "cache", "summaries"))
}

// OpenAt opens a cache at an explicit directory.
func OpenAt(dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	return &Store{dir: dir}, nil
}

type entry struct {
	Digest string          `json:"digest"`
	Key    Key             `json:"key"`
	Value  json.RawMessage `json:"value"`
}

func (s *Store) file(id string) string {
	id = strings.Map(func(r rune) rune {
		if r == '/' || r == '\\' || r == '.' {
			return '_'
		}
		return r
	}, id)
	return filepath.Join(s.dir, id+".json")
}

// Get loads the cached value for id into v when its key still matches.
func (s *Store) Get(id string, key Key, v any) bool {
	b, err := os.ReadFile(s.file(id))
	if err != nil {
		return false
	}
	var e entry
	if json.Unmarshal(b, &e) != nil || e.Digest != key.digest() {
		return false
	}
	return json.Unmarshal(e.Value, v) == nil
}

// Put stores v for id under key, replacing any older entry atomically.
func (s *Store) Put(id string, key Key, v any) error {
	val, err := json.Marshal(v)
	if err != nil {
		return err
	}
	b, err := json.Marshal(entry{Digest: key.digest(), Key: key, Value: val})
	if err != nil {
		return err
	}
	tmp := s.file(id) + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.file(id))
}

// Size reports how many entries the cache holds and their bytes.
func (s *Store) Size() (files int, bytes int64) { return sizeOfDir(s.dir) }

// SizeAt reports the summary cache size under a skit home directory.
func SizeAt(home string) (files int, bytes int64) {
	return sizeOfDir(filepath.Join(home, "cache", "summaries"))
}

func sizeOfDir(dir string) (files int, bytes int64) {
	_ = filepath.WalkDir(dir, func(_ string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		if info, err := d.Info(); err == nil && strings.HasSuffix(d.Name(), ".json") {
			files++
			bytes += info.Size()
		}
		return nil
	})
	return files, bytes
}

// Clear removes every entry.
func (s *Store) Clear() error {
	entries, err := os.ReadDir(s.dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	for _, e := range entries {
		if err := os.Remove(filepath.Join(s.dir, e.Name())); err != nil {
			return err
		}
	}
	return nil
}
