package annotate

import "testing"

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
