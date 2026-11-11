package transcript

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// FuzzParse feeds the parser, and everything built on a parsed session, lines
// it has never seen. The format is undocumented and changes with each Claude
// Code release (docs/record-anatomy.md), so the one promise is that no line
// makes skit fall over.
//
//	go test -run '^$' -fuzz FuzzParse -fuzztime 1m ./sessionkit/transcript/
func FuzzParse(f *testing.F) {
	for _, name := range []string{
		filepath.Join("synthetic-basics", "aaaaaaaa-0000-0000-0000-000000000001.jsonl"),
		filepath.Join("prose-search", "bbbbbbbb-0000-0000-0000-000000000002.jsonl"),
	} {
		if b, err := os.ReadFile(filepath.Join("..", "..", "internal", "testdata", "sessions", name)); err == nil {
			f.Add(b)
		}
	}
	// A request whose tail names a blob that is not there, by a hash shorter than a hash.
	f.Add([]byte(`{"type":"api-request","id":"q1","shapeHash":"s","tail":["ab","é"]}
{"type":"user","uuid":"u1","turnOrigin":"human","message":{"role":"user","content":"go"}}
{"type":"assistant","uuid":"a1","parentUuid":"u1","requestId":"r1","requestRef":"q1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"Bash","input":{"command":"git commit -m x"}}]}}
{"type":"user","uuid":"r1","parentUuid":"a1","toolUseResult":{"persistedOutputPath":"/dev/zero"},"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":[{"type":"image","source":"x"},7,null]}]}}
{"type":"system","subtype":"compact_boundary","uuid":"c1","compactMetadata":{"trigger":1}}
`))
	f.Fuzz(func(t *testing.T, data []byte) {
		s, err := Parse(bytes.NewReader(data))
		if s == nil {
			if err == nil {
				t.Fatal("no session and no error")
			}
			return
		}
		for i := range s.Actions {
			_, _ = s.ContextOf(i, true)
		}
		for i := range s.Compactions {
			_, _ = s.CompactionOf(i, true)
		}
		_ = s.Relations()
		_ = PrimitivesOf(s)
		_ = s.DisplayTitle()
		for i := range s.Images() {
			_, _, _ = s.ImageData(i)
		}
		for _, c := range s.ToolCalls {
			_, _ = s.SpilledPath(c)
			_ = ToolSummary(c.Name, c.Input)
		}
		if _, err := json.Marshal(s); err != nil {
			t.Fatalf("a parsed session must encode: %v", err)
		}
	})
}
