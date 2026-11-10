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
	// Versions, dates and numbered names stay whole and are searched as a
	// phrase; hyphenated words and ids with letters in every part do not.
	got = Terms("Does v0.6.0 merit a 0.5.1? See 2026-11-10, issue-3, gemma-embedding-2, co-authored-by toolu_01abc 3.5.")
	want = []string{"v0 6 0", "merit", "0 5 1", "see", "2026 11 10", "issue 3", "gemma embedding 2", "co", "authored", "toolu", "01abc", "3 5"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("Terms with numbered words =\n  %q\nwant\n  %q", got, want)
	}
	if q := FTSQuery([]string{"merit", "0 5 1"}, true); q != `"merit" OR "0 5 1"*` {
		t.Fatalf("FTSQuery with a phrase = %s", q)
	}
	if !IsLookup([]string{"0 5 1"}) || !IsLookup([]string{"v0 6 0"}) {
		t.Fatal("a version is a lookup")
	}
	if coverage([]string{"0 5 1", "merit"}, "does it merit a 0.5.1 instead") != 1 || coverage([]string{"0 5 1"}, "0.5 and 1.5.0") != 0 || coverage([]string{"0 5 1"}, "port 5 of 10.5.12") != 0 {
		t.Fatal("coverage of a phrase term wrong")
	}
	if !IsLookup([]string{"e1234", "toolu_01abc"}) || IsLookup([]string{"error", "e1234"}) || IsLookup(nil) {
		t.Fatal("IsLookup wrong")
	}
	if coverage([]string{"grok", "zebra"}, "Grokking the zebras") != 1 || coverage([]string{"grok", "lion"}, "zebras") != 0 {
		t.Fatal("coverage wrong")
	}
}
