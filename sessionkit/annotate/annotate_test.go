package annotate

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func TestApplyRoundTrip(t *testing.T) {
	home := t.TempDir()
	yes, no := true, false
	a, err := Apply(home, "s1", Patch{Pinned: &yes, AddTags: []string{" Review ", "m6"}, Notes: map[string]string{"action:60": "the hand-back"}})
	if err != nil || !a.Pinned || len(a.Tags) != 2 || a.Tags[0] != "m6" || a.Tags[1] != "review" || a.Notes["action:60"] == "" {
		t.Fatalf("apply: %v %+v", err, a)
	}
	a, _ = Apply(home, "s1", Patch{RemoveTags: []string{"M6"}, Notes: map[string]string{"action:60": ""}})
	if len(a.Tags) != 1 || len(a.Notes) != 0 || !a.Pinned {
		t.Fatalf("patch should remove a tag and a note, keep the pin: %+v", a)
	}
	if got, _ := Get(home, "other"); got.Tags == nil || got.Notes == nil || got.Pinned {
		t.Fatalf("a session without annotations reads as empty, not null: %+v", got)
	}
	Apply(home, "s1", Patch{Pinned: &no, RemoveTags: []string{"review"}})
	if all, _ := All(home); len(all) != 0 {
		t.Fatalf("an emptied annotation is dropped from the file: %+v", all)
	}
}

// The CLI and the agent both write the file. Each writer here stands for a
// process: none of them shares anything with the others but the file.
func TestConcurrentWritersLoseNothing(t *testing.T) {
	home := t.TempDir()
	const writers, notes = 8, 12
	var wg sync.WaitGroup
	errs := make(chan error, writers*notes)
	for w := 0; w < writers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for n := 0; n < notes; n++ {
				if _, err := Apply(home, "s1", Patch{Notes: map[string]string{fmt.Sprintf("action:%d", w*100+n): "kept"}}); err != nil {
					errs <- err
				}
			}
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
	a, err := Get(home, "s1")
	if err != nil || len(a.Notes) != writers*notes {
		t.Fatalf("%d notes written, %d kept (%v)", writers*notes, len(a.Notes), err)
	}
	left, _ := filepath.Glob(filepath.Join(home, "*.tmp"))
	if st, err := os.Stat(Path(home)); err != nil || st.Mode().Perm() != 0o600 || len(left) != 0 {
		t.Fatalf("the file is the owner's alone and no temporary file is left: %v %v %v", err, st.Mode().Perm(), left)
	}
}
