package store

import (
	"fmt"
	"path/filepath"
	"sync"
	"testing"
)

// Two skit processes share one index: `skit serve` archiving beside a CLI
// command, or the app's agent beside a terminal. Each is its own connection.

// A transaction that reads before it writes must wait for the other writer,
// not fail at once with "database is locked".
func TestTwoWritersWaitForEachOther(t *testing.T) {
	path := filepath.Join(t.TempDir(), "skit.sqlite")
	one, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer one.Close()
	two, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer two.Close()
	for _, id := range []string{"s1", "s2"} {
		if err := one.UpsertSummary(SessionRow{ID: id, Project: "p", SourcePath: "/x/" + id, Summary: []byte(`{}`)}); err != nil {
			t.Fatal(err)
		}
	}
	segs := func(id string, n int) []Segment {
		out := make([]Segment, 40)
		for i := range out {
			out[i] = Segment{Session: id, Kind: "assistant", Text: fmt.Sprintf("round %d segment %d of %s with some words to index", n, i, id)}
		}
		return out
	}
	const rounds = 60
	errs := make(chan error, 2*rounds)
	var wg sync.WaitGroup
	for _, w := range []struct {
		st *Store
		id string
	}{{one, "s1"}, {two, "s2"}} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for n := 0; n < rounds; n++ {
				if err := w.st.ReplaceSegments(w.id, segs(w.id, n)); err != nil {
					errs <- fmt.Errorf("%s round %d: %w", w.id, n, err)
				}
			}
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Error(err)
	}
}

// Several processes opening an index that needs creating or migrating: one
// does the work, the others find it done.
func TestOpeningTogetherMigratesOnce(t *testing.T) {
	for trial := 0; trial < 5; trial++ {
		path := filepath.Join(t.TempDir(), "skit.sqlite")
		const openers = 6
		errs := make(chan error, openers)
		var wg sync.WaitGroup
		for i := 0; i < openers; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				st, err := Open(path)
				if err != nil {
					errs <- err
					return
				}
				st.Close()
			}()
		}
		wg.Wait()
		close(errs)
		for err := range errs {
			t.Errorf("trial %d: %v", trial, err)
		}
	}
}
