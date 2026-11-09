package transcript

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

// ErrPartialLine is returned by Reader.Next when the input ends without a
// newline: Claude Code is probably still writing the line. Offset() then
// points at the start of the partial line, where a later read should resume.
var ErrPartialLine = errors.New("transcript: partial last line")

// Reader streams records from a transcript. Lines can be megabytes long
// (images, big tool results), so nothing is buffered beyond one line.
type Reader struct {
	br     *bufio.Reader
	offset int64
	line   int
}

// NewReader wraps r. Pass a *os.File positioned at a saved Offset to resume.
func NewReader(r io.Reader) *Reader {
	return &Reader{br: bufio.NewReaderSize(r, 1<<16)}
}

// NewReaderAt is NewReader for a stream known to start at byte offset `start`
// of the file, so Record.Offset values stay file-absolute.
func NewReaderAt(r io.Reader, start int64, line int) *Reader {
	rd := NewReader(r)
	rd.offset = start
	rd.line = line
	return rd
}

// Offset is the byte offset of the next unread line.
func (r *Reader) Offset() int64 { return r.offset }

// Line is the number of complete lines read so far.
func (r *Reader) Line() int { return r.line }

// Next returns the next record. At the end it returns io.EOF; a trailing line
// with no newline returns ErrPartialLine without consuming it. A line that is
// not valid JSON is returned as a Record with Type MalformedType and the error
// in Malformed, so callers can keep the line and keep going.
func (r *Reader) Next() (*Record, error) {
	raw, err := r.br.ReadBytes('\n')
	if err != nil {
		if err == io.EOF {
			if len(raw) == 0 {
				return nil, io.EOF
			}
			return nil, ErrPartialLine
		}
		return nil, err
	}
	start := r.offset
	r.offset += int64(len(raw))
	r.line++
	line := bytes.TrimRight(raw, "\r\n")
	if len(bytes.TrimSpace(line)) == 0 {
		return r.Next()
	}
	rec := &Record{Offset: start, Line: r.line}
	rec.Raw = append(json.RawMessage(nil), line...)
	if err := json.Unmarshal(line, rec); err != nil {
		rec.Type = MalformedType
		rec.Malformed = fmt.Errorf("line %d: %w", r.line, err)
	}
	return rec, nil
}

// ReadAll reads every complete record. It returns ErrPartialLine alongside the
// records read so far when the file ends mid-line.
func ReadAll(r io.Reader) ([]*Record, error) {
	rd := NewReader(r)
	var out []*Record
	for {
		rec, err := rd.Next()
		if err == io.EOF {
			return out, nil
		}
		if err != nil {
			return out, err
		}
		out = append(out, rec)
	}
}
