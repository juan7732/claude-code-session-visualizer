package transcript

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"runtime"
	"sync"
	"sync/atomic"
)

// ErrPartialLine is returned by Reader.Next when the input ends in the middle
// of a line: bytes with no newline that are not yet a whole JSON value. Claude
// Code is probably still writing it. Offset() then points at the start of the
// partial line, where a later read should resume.
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

// Next returns the next record. At the end it returns io.EOF. A last line with
// no newline is a record like any other when it is a whole JSON value (a file
// that simply lacks its final newline loses nothing); when it is not, Next
// returns ErrPartialLine without consuming it. A complete line that is not
// valid JSON is returned as a Record with Type MalformedType and the error in
// Malformed, so callers can keep the line and keep going.
func (r *Reader) Next() (*Record, error) {
	rec, err := r.nextRaw()
	if err != nil {
		return nil, err
	}
	rec.decode()
	return rec, nil
}

// nextRaw reads the next line into a Record that has its bytes, its offset and
// its line number, and nothing decoded yet.
func (r *Reader) nextRaw() (*Record, error) {
	for {
		raw, err := r.br.ReadBytes('\n')
		if err != nil {
			if err == io.EOF {
				if len(bytes.TrimSpace(raw)) == 0 {
					return nil, io.EOF
				}
				if !json.Valid(raw) {
					return nil, ErrPartialLine
				}
				// Whole value, missing only its newline: fall through and return it.
			} else {
				return nil, err
			}
		}
		start := r.offset
		r.offset += int64(len(raw))
		r.line++
		line := bytes.TrimRight(raw, "\r\n")
		if len(bytes.TrimSpace(line)) == 0 {
			continue
		}
		// ReadBytes returns a fresh slice each call, so the line is the record's to keep.
		return &Record{Offset: start, Line: r.line, Raw: json.RawMessage(line)}, nil
	}
}

// decode fills the record's fields from its raw line; a line that is not valid
// JSON becomes a MalformedType record that still carries the line.
func (rec *Record) decode() {
	line := rec.Line
	if err := json.Unmarshal(rec.Raw, rec); err != nil {
		rec.Type = MalformedType
		rec.Malformed = fmt.Errorf("line %d: %w", line, err)
	}
}

// ReadAll reads every complete record. It returns ErrPartialLine alongside the
// records read so far when the file ends mid-line.
//
// Lines are read in order and decoded in parallel: decoding is where the time
// goes (a transcript line can be megabytes of base64), and each line stands
// alone. Measured on a 166 MB transcript, 16 cores, 2026-11-10: 1.93 s → 0.38 s.
func ReadAll(r io.Reader) ([]*Record, error) {
	rd := NewReader(r)
	var out []*Record
	var readErr error
	for {
		rec, err := rd.nextRaw()
		if err == io.EOF {
			break
		}
		if err != nil {
			readErr = err
			break
		}
		out = append(out, rec)
	}
	workers := min(runtime.GOMAXPROCS(0), len(out))
	if workers <= 1 {
		for _, rec := range out {
			rec.decode()
		}
		return out, readErr
	}
	var next atomic.Int64
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				i := int(next.Add(1)) - 1
				if i >= len(out) {
					return
				}
				out[i].decode()
			}
		}()
	}
	wg.Wait()
	return out, readErr
}
