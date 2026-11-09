package catalog

import (
	"strings"
	"testing"
)

func TestFind(t *testing.T) {
	r, err := InspectDir(seed(t))
	if err != nil {
		t.Fatal(err)
	}
	if l, err := r.Find("11111111"); err != nil || l.File.Kind != "main" {
		t.Fatalf("prefix lookup: %v %+v", err, l)
	}
	if _, err := r.Find("ffff"); err == nil || !strings.Contains(err.Error(), "no session") {
		t.Fatalf("miss should error: %v", err)
	}
	if l, err := r.Find(r.Projects[0].Sessions[0].Path); err != nil || l.File.ID == "" {
		t.Fatalf("path lookup: %v", err)
	}
}
