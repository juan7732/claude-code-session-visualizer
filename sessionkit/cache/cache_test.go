package cache

import (
	"testing"
	"time"
)

func TestGetPutStale(t *testing.T) {
	s, err := OpenAt(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	type v struct{ N int }
	now := time.Now()
	k := KeyFor("/x/a.jsonl", 10, now, 0, 0)
	var got v
	if s.Get("a", k, &got) {
		t.Fatal("miss expected on empty cache")
	}
	if err := s.Put("a", k, v{7}); err != nil {
		t.Fatal(err)
	}
	if !s.Get("a", k, &got) || got.N != 7 {
		t.Fatalf("hit expected, got %+v", got)
	}
	if s.Get("a", KeyFor("/x/a.jsonl", 11, now, 0, 0), &got) {
		t.Fatal("a size change must miss")
	}
	if s.Get("a", KeyFor("/x/a.jsonl", 10, now, 1, 100), &got) {
		t.Fatal("a new subagent must miss")
	}
	files, _ := s.Size()
	if files != 1 {
		t.Fatalf("size = %d entries", files)
	}
	if err := s.Clear(); err != nil {
		t.Fatal(err)
	}
	if s.Get("a", k, &got) {
		t.Fatal("cleared cache must miss")
	}
}
