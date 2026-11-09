// Package serve exposes the engine over HTTP on a Unix domain socket. It is a
// thin face: every route calls the same functions the CLI calls and returns
// the same JSON shapes (`--json`). Routes live under /v0/ and only gain fields
// before 1.0 (docs/decisions/0004-json-shapes.md).
//
//	GET  /v0                          route list
//	GET  /v0/status                   version, Claude Code data dir, index counts, live sessions
//	GET  /v0/sessions?project=&limit= list rows (archive.ListRow)
//	GET  /v0/sessions/{id}            session document (archive.SessionDoc)
//	GET  /v0/sessions/{id}/stats      stats.Summary with the context curve
//	GET  /v0/sessions/{id}/turns/{n}  one agent turn: its actions, each with tool calls and results
//	GET  /v0/sessions/{id}/actions/{n} one action with its tool calls and results
//	GET  /v0/sessions/{id}/actions/{n}/context  what the model received: system prompt, tools, messages, attachments (?full=1 for texts)
//	GET  /v0/sessions/{id}/compactions/{n}      before/after a compaction: summary sections, preserved messages, re-injected context
//	GET  /v0/sessions/{id}/relations            action spans, background tasks, hand-backs, retries, files, outside services, events
//	GET  /v0/sessions/{id}/images               the session's images (no bytes); /images/{n} returns one image
//	GET  /v0/sessions/{id}/annotations          pin, tags and notes; PATCH the same path to change them
//	GET  /v0/annotations                        every annotated session
//	GET  /v0/claude?root=                       how Claude Code is configured: settings layers, experiments, flags (redacted)
//	GET  /v0/search?q=&limit=&project=&session=&kind=&prefix=
//	POST /v0/archive                  {"ids": [...], "project": "", "strip_requests": false} → archive results
package serve

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/annotate"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/archive"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/claudeconfig"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/search"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/stats"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/transcript"
)

// Server holds the engine handles. One Archive means one SQLite writer; the
// mutex serialises requests that touch it.
type Server struct {
	Version string
	Archive *archive.Archive
	// Inspect finds Claude Code's data; defaults to catalog.Inspect.
	Inspect func() (*catalog.Report, error)
	Logf    func(format string, args ...any)

	mu      sync.Mutex
	started time.Time
}

// New makes a server over an open archive.
func New(version string, a *archive.Archive) *Server {
	return &Server{Version: version, Archive: a, Inspect: catalog.Inspect, Logf: func(string, ...any) {}, started: time.Now()}
}

// Handler returns the HTTP handler (for a socket listener or for tests).
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v0", s.routes)
	mux.HandleFunc("GET /v0/{$}", s.routes)
	mux.HandleFunc("GET /v0/status", s.status)
	mux.HandleFunc("GET /v0/sessions", s.sessions)
	mux.HandleFunc("GET /v0/sessions/{id}", s.session)
	mux.HandleFunc("GET /v0/sessions/{id}/stats", s.sessionStats)
	mux.HandleFunc("GET /v0/sessions/{id}/turns/{n}", s.turn)
	mux.HandleFunc("GET /v0/sessions/{id}/actions/{n}", s.action)
	mux.HandleFunc("GET /v0/sessions/{id}/actions/{n}/context", s.actionContext)
	mux.HandleFunc("GET /v0/sessions/{id}/compactions/{n}", s.compaction)
	mux.HandleFunc("GET /v0/sessions/{id}/relations", s.relations)
	mux.HandleFunc("GET /v0/sessions/{id}/images", s.images)
	mux.HandleFunc("GET /v0/sessions/{id}/images/{n}", s.image)
	mux.HandleFunc("GET /v0/sessions/{id}/annotations", s.annotation)
	mux.HandleFunc("PATCH /v0/sessions/{id}/annotations", s.annotate)
	mux.HandleFunc("GET /v0/annotations", s.annotations)
	mux.HandleFunc("GET /v0/claude", s.claude)
	mux.HandleFunc("GET /v0/search", s.search)
	mux.HandleFunc("POST /v0/archive", s.archive)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeError(w, http.StatusNotFound, fmt.Sprintf("no route %s %s (see GET /v0)", r.Method, r.URL.Path))
	})
	return logging(s.Logf, mux)
}

// Status is GET /v0/status.
type Status struct {
	Version   string                `json:"version"`
	Uptime    string                `json:"uptime"`
	ClaudeDir string                `json:"claude_dir"`
	SkitHome  string                `json:"skit_home"`
	Index     IndexCounts           `json:"index"`
	Live      []catalog.LiveSession `json:"live"`
	Sessions  int                   `json:"sessions_on_disk"`
}

// IndexCounts mirrors store.Counts for JSON.
type IndexCounts struct {
	Sessions int   `json:"sessions"`
	Archived int   `json:"archived"`
	Segments int   `json:"segments"`
	Bytes    int64 `json:"bytes"`
}

func (s *Server) routes(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"version": s.Version,
		"routes": []string{
			"GET /v0/status", "GET /v0/sessions?project=&limit=", "GET /v0/sessions/{id}", "GET /v0/sessions/{id}/stats",
			"GET /v0/sessions/{id}/turns/{n}", "GET /v0/sessions/{id}/actions/{n}", "GET /v0/sessions/{id}/actions/{n}/context?full=1", "GET /v0/sessions/{id}/compactions/{n}?full=1",
			"GET /v0/sessions/{id}/relations", "GET /v0/sessions/{id}/images", "GET /v0/sessions/{id}/images/{n}",
			"GET /v0/sessions/{id}/annotations", "PATCH /v0/sessions/{id}/annotations", "GET /v0/annotations", "GET /v0/claude?root=",
			"GET /v0/search?q=&limit=&project=&session=&kind=&prefix=", "POST /v0/archive",
		},
	})
}

func (s *Server) status(w http.ResponseWriter, _ *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rep, err := s.Inspect()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	c, err := s.Archive.Store.Counts()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	live := rep.Live
	if live == nil {
		live = []catalog.LiveSession{}
	}
	writeJSON(w, http.StatusOK, Status{Version: s.Version, Uptime: stats.FormatDuration(time.Since(s.started)), ClaudeDir: rep.ClaudeDir,
		SkitHome: s.Archive.Home, Index: IndexCounts(c), Live: live, Sessions: rep.Totals.Sessions})
}

func (s *Server) sessions(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rep, err := s.Inspect()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	rows, err := s.Archive.List(rep, r.URL.Query().Get("project"), true, limit, func(err error) { s.Logf("list: %v", err) })
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, rows)
}

func (s *Server) resolve(w http.ResponseWriter, id string) (archive.Resolved, bool) {
	rep, err := s.Inspect()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return archive.Resolved{}, false
	}
	res, err := s.Archive.Resolve(rep, id)
	if err != nil {
		var nf *archive.NotFoundError
		if errors.As(err, &nf) {
			writeError(w, http.StatusNotFound, err.Error())
		} else {
			writeError(w, http.StatusBadRequest, err.Error())
		}
		return archive.Resolved{}, false
	}
	return res, true
}

func (s *Server) session(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	res, ok := s.resolve(w, r.PathValue("id"))
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, archive.Document(res))
}

func (s *Server) sessionStats(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	res, ok := s.resolve(w, r.PathValue("id"))
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, stats.Compute(res.Session, res.Project, stats.Options{Context: true}))
}

// ActionDoc is one action with its tool calls and their results.
type ActionDoc struct {
	*transcript.Action
	Thinking  string           `json:"thinking,omitempty"`
	ToolCalls []ActionToolCall `json:"tool_calls"`
}

// ActionToolCall is a tool call with its result text.
type ActionToolCall struct {
	*transcript.ToolCall
	Result       string `json:"result,omitempty"`
	ResultSource string `json:"result_source,omitempty"` // "transcript" or the spilled file path
}

// TurnDoc is GET /v0/sessions/{id}/turns/{n}: one agent turn with every action.
type TurnDoc struct {
	*transcript.Turn
	Actions []ActionDoc `json:"actions"`
}

func actionDoc(sess *transcript.Session, a *transcript.Action) ActionDoc {
	doc := ActionDoc{Action: a, Thinking: a.Thinking(), ToolCalls: []ActionToolCall{}}
	for _, c := range a.ToolCalls {
		tc := ActionToolCall{ToolCall: c}
		if c.Paired {
			tc.Result, tc.ResultSource = c.ResultText(), "transcript"
			if p, ok := sess.SpilledPath(c); ok {
				if b, err := os.ReadFile(p); err == nil {
					tc.Result, tc.ResultSource = string(b), p
				}
			}
		}
		doc.ToolCalls = append(doc.ToolCalls, tc)
	}
	return doc
}

func (s *Server) turn(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	res, ok := s.resolve(w, r.PathValue("id"))
	if !ok {
		return
	}
	n, err := strconv.Atoi(r.PathValue("n"))
	if err != nil || n < 0 || n >= len(res.Session.Turns) {
		writeError(w, http.StatusNotFound, fmt.Sprintf("turn %q out of range (session has %d turns)", r.PathValue("n"), len(res.Session.Turns)))
		return
	}
	res.Session.StripImages()
	t := res.Session.Turns[n]
	doc := TurnDoc{Turn: t, Actions: []ActionDoc{}}
	for _, a := range t.Actions {
		doc.Actions = append(doc.Actions, actionDoc(res.Session, a))
	}
	writeJSON(w, http.StatusOK, doc)
}

func (s *Server) action(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	res, ok := s.resolve(w, r.PathValue("id"))
	if !ok {
		return
	}
	n, err := strconv.Atoi(r.PathValue("n"))
	if err != nil || n < 0 || n >= len(res.Session.Actions) {
		writeError(w, http.StatusNotFound, fmt.Sprintf("action %q out of range (session has %d actions)", r.PathValue("n"), len(res.Session.Actions)))
		return
	}
	res.Session.StripImages()
	writeJSON(w, http.StatusOK, actionDoc(res.Session, res.Session.Actions[n]))
}

func (s *Server) actionContext(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	res, ok := s.resolve(w, r.PathValue("id"))
	if !ok {
		return
	}
	n, err := strconv.Atoi(r.PathValue("n"))
	if err != nil {
		writeError(w, http.StatusNotFound, "action must be a number")
		return
	}
	full := r.URL.Query().Get("full") == "1" || r.URL.Query().Get("full") == "true"
	cb, err := res.Session.ContextOf(n, full)
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, cb)
}

func (s *Server) compaction(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	res, ok := s.resolve(w, r.PathValue("id"))
	if !ok {
		return
	}
	n, err := strconv.Atoi(r.PathValue("n"))
	if err != nil {
		writeError(w, http.StatusNotFound, "compaction must be a number")
		return
	}
	full := r.URL.Query().Get("full") == "1" || r.URL.Query().Get("full") == "true"
	d, err := res.Session.CompactionOf(n, full)
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, d)
}

func (s *Server) relations(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	res, ok := s.resolve(w, r.PathValue("id"))
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, res.Session.Relations())
}

func (s *Server) images(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	res, ok := s.resolve(w, r.PathValue("id"))
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, res.Session.Images())
}

// image returns one image's bytes with its media type. The only /v0 route
// that is not JSON.
func (s *Server) image(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	res, ok := s.resolve(w, r.PathValue("id"))
	if !ok {
		return
	}
	n, err := strconv.Atoi(r.PathValue("n"))
	if err != nil {
		writeError(w, http.StatusNotFound, "image must be a number")
		return
	}
	mt, b64, err := res.Session.ImageData(n)
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "image payload is not base64: "+err.Error())
		return
	}
	w.Header().Set("Content-Type", mt)
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(raw)
}

func (s *Server) annotation(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	res, ok := s.resolve(w, r.PathValue("id"))
	if !ok {
		return
	}
	a, err := annotate.Get(s.Archive.Home, res.Session.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, a)
}

func (s *Server) annotate(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	res, ok := s.resolve(w, r.PathValue("id"))
	if !ok {
		return
	}
	var p annotate.Patch
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		writeError(w, http.StatusBadRequest, "body must be JSON: "+err.Error())
		return
	}
	a, err := annotate.Apply(s.Archive.Home, res.Session.ID, p)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, a)
}

func (s *Server) annotations(w http.ResponseWriter, _ *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	all, err := annotate.All(s.Archive.Home)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, all)
}

func (s *Server) claude(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rep, err := s.Inspect()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	snap, err := claudeconfig.Read(rep.ClaudeDir, r.URL.Query()["root"])
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, snap)
}

func (s *Server) search(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	hits, err := search.Run(s.Archive.Store, q.Get("q"), search.Options{Limit: limit, Project: q.Get("project"), Session: q.Get("session"),
		Kind: q.Get("kind"), PrefixLast: q.Get("prefix") == "1" || q.Get("prefix") == "true"})
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	if hits == nil {
		hits = []search.Hit{}
	}
	writeJSON(w, http.StatusOK, hits)
}

// ArchiveRequest is the body of POST /v0/archive.
type ArchiveRequest struct {
	IDs           []string `json:"ids"`
	Project       string   `json:"project"`
	StripRequests bool     `json:"strip_requests"` // drop api-request* from the copy (smaller, loses `context`)
}

func (s *Server) archive(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var req ArchiveRequest
	if r.Body != nil && r.ContentLength != 0 {
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "body must be JSON: "+err.Error())
			return
		}
	}
	rep, err := s.Inspect()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	results, err := s.ingest(rep, req)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, results)
}

// ingest archives the requested sessions (all matching when IDs is empty).
func (s *Server) ingest(rep *catalog.Report, req ArchiveRequest) ([]archive.Result, error) {
	var targets []catalog.Located
	if len(req.IDs) > 0 {
		for _, id := range req.IDs {
			l, err := rep.Find(id)
			if err != nil {
				return nil, err
			}
			targets = append(targets, l)
		}
	} else {
		for _, l := range rep.Sessions() {
			if l.File.Kind == "main" && (req.Project == "" || strings.Contains(strings.ToLower(l.Project.Slug), strings.ToLower(req.Project))) {
				targets = append(targets, l)
			}
		}
	}
	results := []archive.Result{}
	for _, l := range targets {
		res, err := s.Archive.Ingest(l, archive.Options{StripRequests: req.StripRequests})
		if err != nil {
			s.Logf("archive %s: %v", l.File.ID, err)
			res.Action = "failed"
		}
		results = append(results, res)
	}
	return results, nil
}

// IngestPath archives the session whose transcript is at path (used by the watcher).
func (s *Server) IngestPath(path string) (archive.Result, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rep, err := s.Inspect()
	if err != nil {
		return archive.Result{}, err
	}
	l, err := rep.Find(path)
	if err != nil {
		return archive.Result{}, err
	}
	return s.Archive.Ingest(l, archive.Options{})
}

// maxSocketPath is the longest Unix socket path the kernel accepts (sun_path
// is 104 bytes on macOS, 108 on Linux; the NUL terminator takes one).
const maxSocketPath = 103

// ListenAndServe serves on a Unix socket until ctx is done, then removes the
// socket file. A stale socket file from a crashed server is replaced.
func (s *Server) ListenAndServe(ctx context.Context, socket string) error {
	if len(socket) > maxSocketPath {
		return fmt.Errorf("socket path is %d bytes; Unix sockets allow at most %d on this platform. Use a shorter --socket path", len(socket), maxSocketPath)
	}
	if err := os.MkdirAll(filepath.Dir(socket), 0o700); err != nil {
		return err
	}
	if _, err := os.Stat(socket); err == nil {
		if conn, err := net.DialTimeout("unix", socket, 200*time.Millisecond); err == nil {
			conn.Close()
			return fmt.Errorf("another skit is already serving on %s", socket)
		}
		os.Remove(socket)
	}
	ln, err := net.Listen("unix", socket)
	if err != nil {
		return err
	}
	os.Chmod(socket, 0o600)
	srv := &http.Server{Handler: s.Handler(), ReadHeaderTimeout: 10 * time.Second}
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ln) }()
	select {
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		err := srv.Shutdown(shutdown)
		os.Remove(socket)
		return err
	case err := <-errc:
		os.Remove(socket)
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(v)
}

func writeError(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

func logging(logf func(string, ...any), next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		logf("%s %s %s", r.Method, r.URL.RequestURI(), time.Since(start).Round(time.Millisecond))
	})
}
