package embed

import (
	"context"
	"sync"
	"time"
)

// Embedder gives vectors for documents and queries. It starts its backend on
// first use and, when IdleStop is set, stops it after that long without a
// request, so a long-lived process (skit serve) holds the model in memory only
// while someone is searching or indexing.
type Embedder struct {
	// IdleStop is how long the backend may sit unused before it is stopped.
	// Zero keeps it until Close.
	IdleStop time.Duration

	source string
	start  func(ctx context.Context) (*Client, func() error, error)
	// sidecar is the process behind client when this embedder started one.
	sidecar *Sidecar

	mu       sync.Mutex
	client   *Client
	stop     func() error
	inflight int
	timer    *time.Timer
	starts   int
}

// NewEmbedder embeds through a llama-server sidecar started with opt. source
// names the model and settings (ModelFile.Source).
func NewEmbedder(opt SidecarOptions, source string) *Embedder {
	return NewEmbedderFunc(func() (SidecarOptions, error) { return opt, nil }, source)
}

// NewEmbedderFunc is NewEmbedder with the options worked out each time a
// sidecar is about to start, not when the embedder is made. A process that
// lives for days (skit serve) can then be handed its embedder before the model
// has been downloaded: the first request after it arrives just works, and one
// before it gets resolve's error.
func NewEmbedderFunc(resolve func() (SidecarOptions, error), source string) *Embedder {
	e := &Embedder{source: source}
	e.start = func(ctx context.Context) (*Client, func() error, error) {
		opt, err := resolve()
		if err != nil {
			return nil, nil, err
		}
		sc, err := StartSidecar(ctx, opt)
		if err != nil {
			return nil, nil, err
		}
		e.sidecar = sc // under e.mu: start is only called from acquire
		return &sc.Client, sc.Stop, nil
	}
	return e
}

// NewClientEmbedder embeds through a server that is already running and that
// someone else owns.
func NewClientEmbedder(c *Client, source string) *Embedder {
	return &Embedder{source: source, start: func(context.Context) (*Client, func() error, error) {
		return c, func() error { return nil }, nil
	}}
}

// Source names what makes the vectors.
func (e *Embedder) Source() string { return e.source }

// Documents embeds pieces of transcripts.
func (e *Embedder) Documents(ctx context.Context, texts []string) ([][]float32, error) {
	framed := make([]string, len(texts))
	for i, t := range texts {
		framed[i] = Document(t)
	}
	return e.embed(ctx, framed)
}

// Query embeds what the user typed.
func (e *Embedder) Query(ctx context.Context, text string) ([]float32, error) {
	vecs, err := e.embed(ctx, []string{Query(text)})
	if err != nil {
		return nil, err
	}
	return vecs[0], nil
}

func (e *Embedder) embed(ctx context.Context, framed []string) ([][]float32, error) {
	c, err := e.acquire(ctx)
	if err != nil {
		return nil, err
	}
	defer e.release()
	return c.Embed(ctx, framed)
}

func (e *Embedder) acquire(ctx context.Context) (*Client, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.timer != nil {
		e.timer.Stop()
		e.timer = nil
	}
	if e.client != nil && e.sidecar != nil && e.sidecar.Exited() {
		// It died on its own (killed, crashed). Forget it and start another
		// rather than fail every request from here on.
		_ = e.stop()
		e.client, e.stop, e.sidecar = nil, nil, nil
	}
	if e.client == nil {
		c, stop, err := e.start(ctx)
		if err != nil {
			return nil, err
		}
		e.client, e.stop = c, stop
		e.starts++
	}
	e.inflight++
	return e.client, nil
}

func (e *Embedder) release() {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.inflight--
	if e.inflight == 0 && e.IdleStop > 0 && e.client != nil {
		e.timer = time.AfterFunc(e.IdleStop, e.stopIfIdle)
	}
}

func (e *Embedder) stopIfIdle() {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.inflight > 0 || e.client == nil {
		return
	}
	_ = e.stop()
	e.client, e.stop, e.timer, e.sidecar = nil, nil, nil, nil
}

// Running reports whether the backend is up right now.
func (e *Embedder) Running() bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.client != nil
}

// Close stops the backend. The embedder can be used again; it starts anew.
func (e *Embedder) Close() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.timer != nil {
		e.timer.Stop()
		e.timer = nil
	}
	if e.client == nil {
		return nil
	}
	err := e.stop()
	e.client, e.stop, e.sidecar = nil, nil, nil
	return err
}
