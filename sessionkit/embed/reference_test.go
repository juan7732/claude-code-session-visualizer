package embed

import (
	"context"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"testing"
)

// referenceFile pins what the real model answers for a few fixed texts.
//
// SPEC: docs/decisions/0005-embedding-worker.md: "a llama.cpp upgrade that
// reproduces the reference vectors keeps the index. A reference-vectors test
// pins that." When this test fails after an upgrade, the vectors changed:
// bump vectorVersion (the index then re-embeds) and record new references
// with SKIT_TEST_MODEL_UPDATE=1.
const referenceFile = "../../internal/testdata/embed/reference-vectors.json"

type reference struct {
	Source string          `json:"source"`
	Items  []referenceItem `json:"items"`
}

type referenceItem struct {
	Kind   string    `json:"kind"` // document | query
	Text   string    `json:"text"`
	Vector []float32 `json:"vector"`
}

var referenceTexts = []referenceItem{
	{Kind: "document", Text: "The retention sweep deletes transcripts older than cleanupPeriodDays when Claude Code starts, so the archive copies each session before that can happen."},
	{Kind: "document", Text: "func (s *Store) ReplaceSegments(session string, segs []Segment) error {\n\ttx, err := s.db.Begin()\n\tif err != nil {\n\t\treturn err\n\t}\n\tdefer tx.Rollback()"},
	{Kind: "document", Text: "Brown the onions slowly in butter, add the rice and stir until it turns translucent, then pour in the stock a ladle at a time."},
	{Kind: "query", Text: "when are old sessions removed from disk"},
}

// TestReferenceVectors runs the real llama-server with the real model. It
// needs both, so it runs only when SKIT_TEST_MODEL names the GGUF file
// (`just test-model`); CI has neither.
func TestReferenceVectors(t *testing.T) {
	model := os.Getenv("SKIT_TEST_MODEL")
	if model == "" {
		t.Skip("SKIT_TEST_MODEL is not set (run `just test-model`)")
	}
	bin, err := FindBinary(os.Getenv("SKIT_LLAMA_SERVER"))
	if err != nil {
		t.Skip(err)
	}
	e := NewEmbedder(SidecarOptions{Binary: bin, Model: model, RunDir: t.TempDir()}, TextModel.Source())
	defer e.Close()

	got := make([][]float32, len(referenceTexts))
	for i, it := range referenceTexts {
		var err error
		if it.Kind == "query" {
			got[i], err = e.Query(context.Background(), it.Text)
		} else {
			var vs [][]float32
			vs, err = e.Documents(context.Background(), []string{it.Text})
			if err == nil {
				got[i] = vs[0]
			}
		}
		if err != nil {
			t.Fatal(err)
		}
		var norm float64
		for _, x := range got[i] {
			norm += float64(x) * float64(x)
		}
		if len(got[i]) != Dimensions || math.Abs(norm-1) > 1e-4 {
			t.Fatalf("text %d: %d dimensions, squared length %g", i, len(got[i]), norm)
		}
	}
	// The model does what it is for: the question about deleting old sessions
	// is nearest the retention paragraph, and the recipe is farthest.
	q := got[3]
	if !(Dot(q, got[0]) > Dot(q, got[1]) && Dot(q, got[1]) > Dot(q, got[2])) {
		t.Fatalf("ranking is off: retention %.3f, code %.3f, recipe %.3f", Dot(q, got[0]), Dot(q, got[1]), Dot(q, got[2]))
	}

	if os.Getenv("SKIT_TEST_MODEL_UPDATE") == "1" {
		ref := reference{Source: TextModel.Source()}
		for i, it := range referenceTexts {
			it.Vector = make([]float32, Dimensions)
			// Stored as the index stores them: through half floats.
			if err := Unpack(it.Vector, Pack(got[i])); err != nil {
				t.Fatal(err)
			}
			ref.Items = append(ref.Items, it)
		}
		b, _ := json.Marshal(ref)
		if err := os.MkdirAll(filepath.Dir(referenceFile), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(referenceFile, append(b, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
		t.Logf("wrote %s", referenceFile)
		return
	}

	b, err := os.ReadFile(referenceFile)
	if err != nil {
		t.Fatalf("%v (record references with SKIT_TEST_MODEL_UPDATE=1)", err)
	}
	var ref reference
	if err := json.Unmarshal(b, &ref); err != nil {
		t.Fatal(err)
	}
	if ref.Source != TextModel.Source() {
		t.Fatalf("references were recorded for %q, the code now names %q: record them again", ref.Source, TextModel.Source())
	}
	if len(ref.Items) != len(referenceTexts) {
		t.Fatalf("%d references for %d texts", len(ref.Items), len(referenceTexts))
	}
	for i, it := range ref.Items {
		if it.Text != referenceTexts[i].Text || it.Kind != referenceTexts[i].Kind {
			t.Fatalf("reference %d is for another text: record them again", i)
		}
		if cos := Dot(got[i], it.Vector); cos < 0.999 {
			t.Errorf("text %d (%s): cosine %.5f against its reference; the vectors changed", i, it.Kind, cos)
		}
	}
}
