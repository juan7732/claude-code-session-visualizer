package store

import (
	"fmt"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// Two skit processes share one index: `skit serve` archiving beside a CLI
// command, or the app's agent beside a terminal. Each is its own connection.

// A transaction that reads before it writes must wait for the other writer,
// not fail at once with "database is locked". One writer holds the lock, the
// other asks for it, and nothing here depends on how fast the machine is.
func TestAWriterWaitsForTheOther(t *testing.T) {
	one, two := openTwo(t)
	held, err := one.db.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer held.Rollback()
	// A change the other connection has not seen: a transaction that had
	// already read would be refused when it turned to writing.
	if _, err := held.Exec(`UPDATE sessions SET project = 'q' WHERE id = 's1'`); err != nil {
		t.Fatal(err)
	}
	started := make(chan struct{})
	done := make(chan error, 1)
	go func() {
		close(started)
		done <- two.ReplaceSegments("s2", someSegments("s2", 0))
	}()
	<-started
	select {
	case err := <-done:
		t.Fatalf("the second writer did not wait for the lock: %v", err)
	case <-time.After(200 * time.Millisecond):
	}
	if err := held.Commit(); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatalf("the second writer, once the first was done: %v", err)
	}
	var n int
	if err := two.db.QueryRow(`SELECT count(*) FROM segments WHERE session = 's2'`).Scan(&n); err != nil || n != 40 {
		t.Fatalf("segments written = %d, %v; want 40", n, err)
	}
}

// Two writers taking turns as fast as they can, and neither loses a write.
//
// DECISION: each writes for a second at most. SQLite's wait for the lock is a
// poll, not a queue: a writer that commits and begins again without a pause
// can keep the other out for as long as it goes on, and past busy_timeout the
// other gives up. Sixty rounds took longer than that under the race detector
// on the CI runner, so the test failed there for being slow, not for a fault.
// A real ingest reads and parses a transcript between its transactions.
func TestTwoWritersTakeTurns(t *testing.T) {
	one, two := openTwo(t)
	const rounds = 60
	const budget = time.Second
	errs := make(chan error, 2*rounds)
	var wg sync.WaitGroup
	for _, w := range []struct {
		st *Store
		id string
	}{{one, "s1"}, {two, "s2"}} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			start := time.Now()
			for n := 0; n < rounds && (n == 0 || time.Since(start) < budget); n++ {
				if err := w.st.ReplaceSegments(w.id, someSegments(w.id, n)); err != nil {
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
	for _, id := range []string{"s1", "s2"} {
		var n int
		if err := one.db.QueryRow(`SELECT count(*) FROM segments WHERE session = ?`, id).Scan(&n); err != nil || n != 40 {
			t.Errorf("%s: segments = %d, %v; want 40", id, n, err)
		}
	}
}

// openTwo opens one index twice, as two processes would, with two sessions in it.
func openTwo(t *testing.T) (one, two *Store) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "skit.sqlite")
	var err error
	if one, err = Open(path); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { one.Close() })
	if two, err = Open(path); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { two.Close() })
	for _, id := range []string{"s1", "s2"} {
		if err := one.UpsertSummary(SessionRow{ID: id, Project: "p", SourcePath: "/x/" + id, Summary: []byte(`{}`)}); err != nil {
			t.Fatal(err)
		}
	}
	return one, two
}

func someSegments(id string, round int) []Segment {
	out := make([]Segment, 40)
	for i := range out {
		out[i] = Segment{Session: id, Kind: "assistant", Text: fmt.Sprintf("round %d segment %d of %s with some words to index", round, i, id)}
	}
	return out
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
