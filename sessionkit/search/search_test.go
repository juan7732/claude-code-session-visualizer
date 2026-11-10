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
	// A question keeps its subject and loses the words every text has.
	if got := Terms("How did we figure out how to get ergo into winget?"); !reflect.DeepEqual(got, []string{"figure", "get", "ergo", "winget"}) {
		t.Fatalf("Terms of a question = %v", got)
	}
	if got := Terms("What is it that they were doing there?"); len(got) != 0 {
		t.Fatalf("a question of nothing but function words has no terms, got %v", got)
	}
	if !IsLookup([]string{"e1234", "toolu_01abc"}) || IsLookup([]string{"error", "e1234"}) || IsLookup(nil) {
		t.Fatal("IsLookup wrong")
	}
	if coverage([]string{"grok", "zebra"}, "Grokking the zebras") != 1 || coverage([]string{"grok", "lion"}, "zebras") != 0 {
		t.Fatal("coverage wrong")
	}
}
