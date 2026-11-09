package search

import (
	"reflect"
	"testing"
)

func TestTermsAndQuery(t *testing.T) {
	got := Terms("Where did we talk about the ENOTFOUND error, in session 36086585?")
	want := []string{"talk", "enotfound", "error", "36086585"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Terms = %v, want %v", got, want)
	}
	if FTSQuery(got, true) != `"talk" OR "enotfound" OR "error" OR "36086585"*` {
		t.Fatalf("FTSQuery = %s", FTSQuery(got, true))
	}
	if !IsLookup([]string{"e1234", "toolu_01abc"}) || IsLookup([]string{"error", "e1234"}) || IsLookup(nil) {
		t.Fatal("IsLookup wrong")
	}
	if coverage([]string{"grok", "zebra"}, "Grokking the zebras") != 1 || coverage([]string{"grok", "lion"}, "zebras") != 0 {
		t.Fatal("coverage wrong")
	}
}
