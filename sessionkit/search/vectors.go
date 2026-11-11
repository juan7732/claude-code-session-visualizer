package search

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/embed"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/store"
)

// pieces is every chunk that has a vector, read from the index in one pass:
// the packed vectors side by side in one slice, and for each what a hit needs
// (its segment and byte range) and what a search may narrow by (session,
// project, kind, kept once per segment).
type pieces struct {
	gen   int64
	rows  []pieceRow
	segs  []segmentInfo
	data  []byte // len(rows) × width bytes
	width int
}

type pieceRow struct {
	segment    int64
	start, len int32
	info       int32 // index into segs
}

type segmentInfo struct {
	session, project, kind string
}

func (p *pieces) vec(i int) []byte { return p.data[i*p.width : (i+1)*p.width] }

func loadPieces(ctx context.Context, st *store.Store) (*pieces, error) {
	// The generation is read first: if the index changes while it is being
	// read, the next query sees a newer generation and reads again.
	gen, err := st.VectorGeneration()
	if err != nil {
		return nil, err
	}
	p := &pieces{gen: gen, width: 2 * embed.Dimensions}
	last := int64(-1)
	err = st.EachPiece(ctx, func(c store.Piece) error {
		if len(c.Vec) != p.width {
			return fmt.Errorf("a stored vector is %d bytes, expected %d: run `skit embed`", len(c.Vec), p.width)
		}
		if c.Segment != last {
			p.segs = append(p.segs, segmentInfo{session: c.Session, project: c.Project, kind: c.Kind})
			last = c.Segment
		}
		p.rows = append(p.rows, pieceRow{segment: c.Segment, start: int32(c.Start), len: int32(c.Len), info: int32(len(p.segs) - 1)})
		p.data = append(p.data, c.Vec...)
		return nil
	})
	if err != nil {
		return nil, err
	}
	return p, nil
}

// Vectors keeps the index's vectors in memory between queries, for a process
// that answers many (skit serve). Without it every meaning query reads and
// copies every vector out of SQLite; with it a query is one pass over a slice.
// It reads the index again when the index says the vectors changed
// (store.VectorGeneration), and lets go of the memory after Idle without a
// query. 1,536 bytes a piece: 2 MB for this archive, about 350 MB for a heavy
// year. The zero value is ready to use.
type Vectors struct {
	// Idle is how long the vectors stay in memory with nobody searching. Zero
	// keeps them.
	Idle time.Duration

	mu     sync.Mutex
	held   *pieces
	timer  *time.Timer
	loaded int // how many times the index was read, for tests
}

// get returns the current pieces, reading the index when it has changed. The
// result is never modified, so callers scan it without holding the lock.
func (v *Vectors) get(ctx context.Context, st *store.Store) (*pieces, error) {
	v.mu.Lock()
	defer v.mu.Unlock()
	gen, err := st.VectorGeneration()
	if err != nil {
		return nil, err
	}
	if v.held == nil || v.held.gen != gen {
		p, err := loadPieces(ctx, st)
		if err != nil {
			return nil, err
		}
		v.held = p
		v.loaded++
	}
	if v.Idle > 0 {
		if v.timer != nil {
			v.timer.Stop()
		}
		v.timer = time.AfterFunc(v.Idle, v.Drop)
	}
	return v.held, nil
}

// Drop lets go of the vectors; the next query reads them again.
func (v *Vectors) Drop() {
	v.mu.Lock()
	defer v.mu.Unlock()
	v.held = nil
	if v.timer != nil {
		v.timer.Stop()
		v.timer = nil
	}
}

// Held reports how many pieces are in memory right now.
func (v *Vectors) Held() int {
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.held == nil {
		return 0
	}
	return len(v.held.rows)
}

// keeps is the narrowing options applied to one segment in memory. It must
// agree with filter, which says the same thing in SQL for keyword search.
func (opt Options) keeps(s segmentInfo) bool {
	if opt.Session != "" && s.session != opt.Session {
		return false
	}
	if opt.Project != "" && !strings.Contains(strings.ToLower(s.project), strings.ToLower(opt.Project)) {
		return false
	}
	if opt.NoTools && (s.kind == "tool_use" || s.kind == "tool_result") {
		return false
	}
	if len(opt.Kinds) > 0 || opt.Kind != "" {
		if s.kind != opt.Kind && !slices.Contains(opt.Kinds, s.kind) {
			return false
		}
	}
	return true
}
