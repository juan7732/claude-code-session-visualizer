package cli

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestDescribeListsDoctor(t *testing.T) {
	root := NewRoot("test")
	var out bytes.Buffer
	root.SetOut(&out)
	root.SetArgs([]string{"describe"})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
	var m Manifest
	if err := json.Unmarshal(out.Bytes(), &m); err != nil {
		t.Fatalf("describe is not JSON: %v\n%s", err, out.String())
	}
	if m.Name != "skit" || m.Version != "test" {
		t.Fatalf("manifest header = %+v", m)
	}
	found := false
	for _, c := range m.Commands {
		if c.Path == "skit doctor" {
			found = true
			hasJSON := false
			for _, f := range c.Flags {
				if f.Name == "json" && f.Global {
					hasJSON = true
				}
			}
			if !hasJSON {
				t.Fatalf("doctor is missing the inherited --json flag: %+v", c.Flags)
			}
		}
	}
	if !found {
		t.Fatalf("manifest lacks doctor: %+v", m.Commands)
	}
}

func TestHumanBytes(t *testing.T) {
	cases := map[int64]string{0: "0 B", 999: "999 B", 1500: "1.5 kB", 47_500_000: "47.5 MB", 3_000_000_000: "3.0 GB"}
	for in, want := range cases {
		if got := humanBytes(in); got != want {
			t.Errorf("humanBytes(%d) = %q, want %q", in, got, want)
		}
	}
}
