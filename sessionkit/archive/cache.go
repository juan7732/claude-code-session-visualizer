package archive

import (
	"fmt"
	"sync"
	"time"
)

// DefaultCacheBytes is the cache budget `skit serve` uses, in source bytes.
//
// DECISION: the budget counts transcript bytes on disk, not memory, because that
// is what is known before parsing. A parsed session takes about 2.6 times its
// transcript (measured: 166 MB on disk, 431 MB resident), so a full cache is
// around 700 MB: room for the largest session seen so far with a few others
// beside it. TrimCache gives the memory back when nobody reads.
const DefaultCacheBytes = 256 << 20

// cache keeps parsed sessions between requests in a long-lived process. An
// entry is valid while the stamp of its source (size, modification time,
// subagent files) is unchanged. Cached sessions are shared between requests:
// callers must treat them as read-only.
type cache struct {
	mu      sync.Mutex
	budget  int64
	entries []*cacheEntry // most recently used first
}

type cacheEntry struct {
	key, stamp string
	cost       int64
	used       time.Time
	ready      chan struct{} // closed when res and err are set
	res        Resolved
	err        error
}

// EnableCache makes Resolve keep parsed sessions, up to budget source bytes
// (the most recent one is always kept, whatever its size). One-shot commands
// do not need it; `skit serve` does.
func (a *Archive) EnableCache(budget int64) { a.cache = &cache{budget: budget} }

// TrimCache drops cached sessions nobody asked for in maxIdle, so an idle
// server gives the memory back. It returns how many it dropped.
func (a *Archive) TrimCache(maxIdle time.Duration) int {
	if a.cache == nil {
		return 0
	}
	c := a.cache
	c.mu.Lock()
	defer c.mu.Unlock()
	kept := c.entries[:0]
	for _, e := range c.entries {
		if time.Since(e.used) < maxIdle {
			kept = append(kept, e)
		}
	}
	dropped := len(c.entries) - len(kept)
	clear(c.entries[len(kept):])
	c.entries = kept
	return dropped
}

// CachedSessions reports how many parsed sessions are held (for status).
func (a *Archive) CachedSessions() int {
	if a.cache == nil {
		return 0
	}
	a.cache.mu.Lock()
	defer a.cache.mu.Unlock()
	return len(a.cache.entries)
}

// holds reports whether key is cached, whatever its stamp: somebody is
// reading that session.
func (c *cache) holds(key string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, e := range c.entries {
		if e.key == key {
			return true
		}
	}
	return false
}

// get returns the cached value for key when its stamp matches, else runs load
// once (concurrent callers for the same key and stamp wait for that one run).
func (c *cache) get(key, stamp string, cost int64, load func() (Resolved, error)) (Resolved, error) {
	c.mu.Lock()
	for i, e := range c.entries {
		if e.key != key {
			continue
		}
		c.entries = append(c.entries[:i], c.entries[i+1:]...)
		if e.stamp == stamp {
			e.used = time.Now()
			c.entries = append([]*cacheEntry{e}, c.entries...)
			c.mu.Unlock()
			<-e.ready
			return e.res, e.err
		}
		break // the source changed: the old parse is dropped
	}
	e := &cacheEntry{key: key, stamp: stamp, cost: cost, used: time.Now(), ready: make(chan struct{})}
	c.entries = append([]*cacheEntry{e}, c.entries...)
	total := int64(0)
	for i, old := range c.entries {
		total += old.cost
		if i > 0 && total > c.budget {
			clear(c.entries[i:])
			c.entries = c.entries[:i]
			break
		}
	}
	c.mu.Unlock()

	func() {
		// A load that panics still has to end: everyone waiting on this entry
		// would otherwise wait for good, and each new request for the session
		// would join them.
		defer close(e.ready)
		defer func() {
			if p := recover(); p != nil {
				e.err = fmt.Errorf("reading the session failed: %v", p)
			}
		}()
		e.res, e.err = load()
		if e.err == nil && e.res.memo == nil {
			e.res.memo = &memo{}
		}
	}()
	if e.err != nil {
		c.mu.Lock()
		for i, x := range c.entries {
			if x == e {
				c.entries = append(c.entries[:i], c.entries[i+1:]...)
				break
			}
		}
		c.mu.Unlock()
	}
	return e.res, e.err
}
