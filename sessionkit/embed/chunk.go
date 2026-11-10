package embed

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

// MaxChunkRunes is the longest piece of text given one vector. The model reads
// 2,048 tokens; prose runs near four characters a token and code near three,
// so 1,500 characters stays inside the window with room to spare, and a vector
// for one or two paragraphs points at a place a reader can find.
const MaxChunkRunes = 1500

// minChunkLetters is the least a piece must say to get a vector. "ok",
// "continue" and a lone path have a vector too, but it sits close to every
// short query and finds nothing anyone meant.
const minChunkLetters = 16

// Piece is a byte range of a text.
type Piece struct {
	Start, Len int
}

// Chunks cuts text into pieces of at most max runes, breaking at a paragraph
// when there is one in the second half of the window, else at a line, a
// sentence, a space, and only then mid-word. Pieces do not overlap and cover
// the text in order; pieces with almost no letters are left out.
func Chunks(text string, max int) []Piece {
	if max <= 0 {
		max = MaxChunkRunes
	}
	var out []Piece
	pos := 0
	for pos < len(text) {
		end := pos + windowBytes(text[pos:], max)
		if end < len(text) {
			end = pos + breakPoint(text[pos:end])
		}
		if hasProse(text[pos:end]) {
			out = append(out, Piece{Start: pos, Len: end - pos})
		}
		pos = end
	}
	return out
}

// windowBytes is the byte length of the first max runes of s.
func windowBytes(s string, max int) int {
	n := 0
	for i := range s {
		if n == max {
			return i
		}
		n++
	}
	return len(s)
}

// breakPoint picks where to cut a full window: after the last separator found
// in its second half, trying the strongest separator first.
func breakPoint(w string) int {
	half := len(w) / 2
	for _, sep := range []string{"\n\n", "\n", ". ", " "} {
		if i := strings.LastIndex(w, sep); i >= half {
			return i + len(sep)
		}
	}
	// No separator: cut at the window, which windowBytes placed on a rune boundary.
	return len(w)
}

func hasProse(s string) bool {
	letters := 0
	for len(s) > 0 {
		r, size := utf8.DecodeRuneInString(s)
		if unicode.IsLetter(r) {
			letters++
			if letters >= minChunkLetters {
				return true
			}
		}
		s = s[size:]
	}
	return false
}

// EmbeddingGemma's prompt framing, from the model card. A document and a query
// are framed differently on purpose; the same text embeds to different vectors.

// Document frames a piece of a transcript for indexing.
func Document(text string) string { return "title: none | text: " + text }

// Query frames what the user typed.
func Query(text string) string { return "task: search result | query: " + text }
