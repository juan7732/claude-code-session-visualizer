// Package serve exposes the engine over HTTP on a Unix domain socket. It is a
// thin face: every route calls the same functions the CLI calls and returns
// the same JSON shapes (`--json`). Routes live under /v0/ and only gain fields
// before 1.0 (docs/decisions/0004-json-shapes.md).
//
//	GET  /v0                          route list
//	GET  /v0/status                   version, Claude Code data dir, index counts, live sessions
//	GET  /v0/sessions?project=&limit= list rows (archive.ListRow)
//	GET  /v0/now?minutes=             sessions at work: what each is doing at this moment, and its prompt cache (now.Report)
//	GET  /v0/overview?project=&slug=  every session added up: totals, by project, by day, tools, models, time (stats.Overview)
//	GET  /v0/sessions/{id}            session document (archive.SessionDoc)
//	GET  /v0/sessions/{id}/stats      stats.Summary with the context curve
//	GET  /v0/sessions/{id}/turns/{n}  one agent turn: its actions, each with tool calls and results
//	GET  /v0/sessions/{id}/actions/{n} one action with its tool calls and results (?agent=<id>: of that subagent)
//	GET  /v0/sessions/{id}/actions/{n}/context  what the model received: system prompt, tools, messages, attachments (?full=1 for texts)
//	GET  /v0/sessions/{id}/compactions/{n}      before/after a compaction: summary sections, preserved messages, re-injected context
//	GET  /v0/sessions/{id}/relations            action spans, background tasks, hand-backs, retries, files, outside services, commits, events
//	GET  /v0/sessions/{id}/time?top=            where the wall time went: waiting, the model, tools, subagents; slowest calls, longest waits
//	GET  /v0/sessions/{id}/export?format=markdown&turn=&thinking=   the session or one turn as Markdown (text/markdown)
//	GET  /v0/file?path=&session=&text=0         a file some session touched, as it is now, and the sessions that touched it
//	GET  /v0/sessions/{id}/images               the session's images (no bytes); /images/{n} returns one image
//	GET  /v0/sessions/{id}/annotations          pin, tags and notes; PATCH the same path to change them
//	GET  /v0/annotations                        every annotated session
//	GET  /v0/claude?root=                       how Claude Code is configured: settings layers, experiments, flags (redacted)
//	GET  /v0/primitives?kind=&name=&days=&unused=1&root=  skills, agents, commands, connectors, hooks, plugins, memory: where each is defined and how much it is used
//	GET  /v0/search?q=&mode=&limit=&project=&session=&kind=&tools=&prefix=&all=&min_cosine=&min_z=
//	                                  mode: keyword (default) | meaning; kind: one or several, comma-separated;
//	                                  tools=0 leaves out tool calls and results; all=1 turns the meaning gate off
//	POST /v0/archive                  {"ids": [...], "project": "", "strip_requests": false} → archive results
//	GET  /v0/archive/verify?id=       every archived copy (or those ids) checked against the index
package serve

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime/debug"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/juan7732/claude-code-session-visualizer/sessionkit/annotate"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/archive"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/catalog"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/claudeconfig"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/export"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/home"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/now"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/primitives"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/search"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/stats"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/store"
	"github.com/juan7732/claude-code-session-visualizer/sessionkit/transcript"
)

// Server holds the engine handles. Requests run concurrently: the index is
// safe for that (database/sql over one connection), parsed sessions come from
// the archive's cache and are read-only, and an ingest takes the archive's own
// lock. Only annotation writes need a mutex here (read, change, write back).
type Server struct {
	Version string
	Archive *archive.Archive
	// Inspect finds Claude Code's data; defaults to catalog.Inspect.
	Inspect func() (*catalog.Report, error)
	Logf    func(format string, args ...any)
	// LogRequests logs one line per request. Off for the launchd agent, whose
	// log would otherwise grow with every click in the client.
	LogRequests bool
	// Embedder embeds queries for /v0/search?mode=meaning and hybrid, and the
	// archive's new text in the background (EmbedEvery). Nil means this server
	// cannot search by meaning.
	Embedder Embedder
	// Now reads what the sessions at work are doing; it keeps what it read of
	// each transcript's tail between requests.
	Now now.Reader
	// ManagedDir is the managed settings directory /v0/primitives also looks
	// in; "" for none.
	ManagedDir string

	vectors      search.Vectors // the index's vectors, held between meaning queries
	embedding    atomic.Bool    // a background pass is running
	swept        chan struct{}  // closed when the first sweep has finished
	sweptOnce    sync.Once
	lastEmbedErr string // the last background failure logged, so it is logged once

	annMu   sync.Mutex
	started time.Time
}

// Embedder is what the server needs from package embed: vectors for queries
// and for the archive's text.
type Embedder interface {
	Source() string
	Query(ctx context.Context, text string) ([]float32, error)
	Documents(ctx context.Context, texts []string) ([][]float32, error)
}

// New makes a server over an open archive.
func New(version string, a *archive.Archive) *Server {
	a.EnableCache(archive.DefaultCacheBytes)
	return &Server{Version: version, Archive: a, Inspect: catalog.Inspect, Logf: func(string, ...any) {}, LogRequests: true, started: time.Now(), swept: make(chan struct{}), vectors: search.Vectors{Idle: cacheIdle}}
}

// Handler returns the HTTP handler (for a socket listener or for tests).
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v0", s.routes)
	mux.HandleFunc("GET /v0/{$}", s.routes)
	mux.HandleFunc("GET /v0/status", s.status)
	mux.HandleFunc("GET /v0/sessions", s.sessions)
	mux.HandleFunc("GET /v0/overview", s.overview)
	mux.HandleFunc("GET /v0/now", s.now)
	mux.HandleFunc("GET /v0/file", s.file)
	mux.HandleFunc("GET /v0/sessions/{id}", s.session)
	mux.HandleFunc("GET /v0/sessions/{id}/stats", s.sessionStats)
	mux.HandleFunc("GET /v0/sessions/{id}/turns/{n}", s.turn)
	mux.HandleFunc("GET /v0/sessions/{id}/actions/{n}", s.action)
	mux.HandleFunc("GET /v0/sessions/{id}/actions/{n}/context", s.actionContext)
	mux.HandleFunc("GET /v0/sessions/{id}/compactions/{n}", s.compaction)
	mux.HandleFunc("GET /v0/sessions/{id}/relations", s.relations)
	mux.HandleFunc("GET /v0/sessions/{id}/time", s.timeSplit)
	mux.HandleFunc("GET /v0/sessions/{id}/export", s.export)
	mux.HandleFunc("GET /v0/sessions/{id}/images", s.images)
	mux.HandleFunc("GET /v0/sessions/{id}/images/{n}", s.image)
	mux.HandleFunc("GET /v0/sessions/{id}/annotations", s.annotation)
	mux.HandleFunc("PATCH /v0/sessions/{id}/annotations", s.annotate)
	mux.HandleFunc("GET /v0/annotations", s.annotations)
	mux.HandleFunc("GET /v0/claude", s.claude)
	mux.HandleFunc("GET /v0/primitives", s.primitives)
	mux.HandleFunc("GET /v0/search", s.search)
	mux.HandleFunc("POST /v0/archive", s.archive)
	mux.HandleFunc("GET /v0/archive/verify", s.verify)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeError(w, http.StatusNotFound, fmt.Sprintf("no route %s %s (see GET /v0)", r.Method, r.URL.Path))
	})
	if !s.LogRequests {
		return mux
	}
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
	Cached    int                   `json:"cached_sessions"` // parsed sessions held in memory
	// Vectors says how much of the indexed text can be searched by meaning
	// and when it was last brought up to date.
	Vectors store.VectorCounts `json:"vectors"`
	// VectorsHeld is how many vectors are in memory right now.
	VectorsHeld int `json:"vectors_held"`
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
			"GET /v0/status", "GET /v0/sessions?project=&limit=", "GET /v0/now?minutes=", "GET /v0/overview?project=&slug=", "GET /v0/file?path=&session=&text=0", "GET /v0/sessions/{id}", "GET /v0/sessions/{id}/stats",
			"GET /v0/sessions/{id}/turns/{n}", "GET /v0/sessions/{id}/actions/{n}?agent=", "GET /v0/sessions/{id}/actions/{n}/context?full=1", "GET /v0/sessions/{id}/compactions/{n}?full=1",
			"GET /v0/sessions/{id}/relations", "GET /v0/sessions/{id}/time?top=", "GET /v0/sessions/{id}/export?format=markdown&turn=&thinking=", "GET /v0/sessions/{id}/images", "GET /v0/sessions/{id}/images/{n}",
			"GET /v0/sessions/{id}/annotations", "PATCH /v0/sessions/{id}/annotations", "GET /v0/annotations", "GET /v0/claude?root=", "GET /v0/primitives?kind=&name=&days=&unused=1&root=",
			"GET /v0/search?q=&mode=&limit=&project=&session=&kind=&tools=&prefix=&all=&min_cosine=&min_z=", "POST /v0/archive", "GET /v0/archive/verify?id=",
		},
	})
}

func (s *Server) status(w http.ResponseWriter, _ *http.Request) {
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
	vc, _ := s.Archive.Store.VectorCounts()
	writeJSON(w, http.StatusOK, Status{Version: s.Version, Uptime: stats.FormatDuration(time.Since(s.started)), ClaudeDir: rep.ClaudeDir,
		SkitHome: s.Archive.Home, Index: IndexCounts(c), Live: live, Sessions: rep.Totals.Sessions, Cached: s.Archive.CachedSessions(),
		Vectors: vc, VectorsHeld: s.vectors.Held()})
}

func (s *Server) sessions(w http.ResponseWriter, r *http.Request) {
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

// now says what the sessions at work are doing: `skit now`. It is asked every
// few seconds while a client shows it, and reads only what changed.
func (s *Server) now(w http.ResponseWriter, r *http.Request) {
	opt := now.Options{Known: s.Archive.Known}
	if m := r.URL.Query().Get("minutes"); m != "" {
		minutes, err := strconv.Atoi(m)
		if err != nil || minutes <= 0 {
			writeError(w, http.StatusBadRequest, "minutes is a number of minutes")
			return
		}
		opt.Window = time.Duration(minutes) * time.Minute
	}
	rep, err := s.Inspect()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	out, err := s.Now.Read(rep, opt)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// overview adds every session up: `skit overview`.
func (s *Server) overview(w http.ResponseWriter, r *http.Request) {
	rep, err := s.Inspect()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	rows, err := s.Archive.List(rep, r.URL.Query().Get("project"), true, 0, func(err error) { s.Logf("overview: %v", err) })
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	// slug narrows to one project exactly, where project= matches any slug that contains the text.
	slug := r.URL.Query().Get("slug")
	sums := make([]stats.Summary, 0, len(rows))
	for _, row := range rows {
		if slug == "" || row.Project == slug {
			sums = append(sums, row.Summary)
		}
	}
	writeJSON(w, http.StatusOK, stats.Overall(sums, home.LocalZone()))
}

// file says what a touched file is now and who touched it: `skit file`.
func (s *Server) file(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	path := q.Get("path")
	if path == "" {
		writeError(w, http.StatusBadRequest, "path is required")
		return
	}
	id := ""
	if q.Get("session") != "" {
		res, ok := s.resolve(w, q.Get("session"))
		if !ok {
			return
		}
		id = res.Session.ID
	}
	v, err := s.Archive.FileNow(path, id, q.Get("text") != "0")
	if errors.Is(err, archive.ErrUntouched) {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, v)
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
	res, ok := s.resolve(w, r.PathValue("id"))
	if !ok {
		return
	}
	// The document is megabytes: encoded once per parsed session, then served from memory.
	body, err := res.DocumentJSON()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

func (s *Server) sessionStats(w http.ResponseWriter, r *http.Request) {
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
	res, ok := s.resolve(w, r.PathValue("id"))
	if !ok {
		return
	}
	n, err := strconv.Atoi(r.PathValue("n"))
	if err != nil || n < 0 || n >= len(res.Session.Turns) {
		writeError(w, http.StatusNotFound, fmt.Sprintf("turn %q out of range (session has %d turns)", r.PathValue("n"), len(res.Session.Turns)))
		return
	}
	t := res.Session.Turns[n]
	doc := TurnDoc{Turn: t, Actions: []ActionDoc{}}
	for _, a := range t.Actions {
		doc.Actions = append(doc.Actions, actionDoc(res.Session, a))
	}
	writeJSON(w, http.StatusOK, doc)
}

func (s *Server) action(w http.ResponseWriter, r *http.Request) {
	res, ok := s.resolve(w, r.PathValue("id"))
	if !ok {
		return
	}
	// ?agent=<id>: action n of that subagent's own transcript.
	sess := res.Session
	if agent := r.URL.Query().Get("agent"); agent != "" {
		if sess = res.Session.SubagentSession(agent); sess == nil {
			writeError(w, http.StatusNotFound, fmt.Sprintf("no subagent %q in this session", agent))
			return
		}
	}
	n, err := strconv.Atoi(r.PathValue("n"))
	if err != nil || n < 0 || n >= len(sess.Actions) {
		writeError(w, http.StatusNotFound, fmt.Sprintf("action %q out of range (%d actions)", r.PathValue("n"), len(sess.Actions)))
		return
	}
	writeJSON(w, http.StatusOK, actionDoc(sess, sess.Actions[n]))
}

// export writes the session, or one turn of it, as Markdown: `skit export`.
func (s *Server) export(w http.ResponseWriter, r *http.Request) {
	res, ok := s.resolve(w, r.PathValue("id"))
	if !ok {
		return
	}
	q := r.URL.Query()
	if f := q.Get("format"); f != "" && f != "markdown" {
		writeError(w, http.StatusBadRequest, fmt.Sprintf("unknown format %q: markdown is the one there is", f))
		return
	}
	opt := export.Options{Thinking: q.Get("thinking") == "1" || q.Get("thinking") == "true"}
	if t := q.Get("turn"); t != "" {
		n, err := strconv.Atoi(t)
		if err != nil {
			writeError(w, http.StatusBadRequest, "turn must be a number")
			return
		}
		opt.Turn = &n
	}
	var text bytes.Buffer
	if err := export.Markdown(&text, res.Session, opt); err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	w.Header().Set("Content-Type", "text/markdown; charset=utf-8")
	_, _ = w.Write(text.Bytes())
}

func (s *Server) actionContext(w http.ResponseWriter, r *http.Request) {
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
	res, ok := s.resolve(w, r.PathValue("id"))
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, res.Relations())
}

// timeSplit says where the session's wall time went: `skit time`.
func (s *Server) timeSplit(w http.ResponseWriter, r *http.Request) {
	res, ok := s.resolve(w, r.PathValue("id"))
	if !ok {
		return
	}
	top := 0
	if v := r.URL.Query().Get("top"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 1 {
			writeError(w, http.StatusBadRequest, "top must be a positive number")
			return
		}
		top = n
	}
	writeJSON(w, http.StatusOK, stats.TimeOf(res.Session, res.Relations(), top))
}

func (s *Server) images(w http.ResponseWriter, r *http.Request) {
	res, ok := s.resolve(w, r.PathValue("id"))
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, res.Session.Images())
}

// image returns one image's bytes with its media type. The only /v0 route
// that is not JSON.
func (s *Server) image(w http.ResponseWriter, r *http.Request) {
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
	s.annMu.Lock()
	defer s.annMu.Unlock()
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
	all, err := annotate.All(s.Archive.Home)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, all)
}

func (s *Server) claude(w http.ResponseWriter, r *http.Request) {
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

// primitives lists what Claude Code is extended with and its use: `skit primitives`.
func (s *Server) primitives(w http.ResponseWriter, r *http.Request) {
	rep, err := s.Inspect()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	q := r.URL.Query()
	opt := primitives.Options{Kind: q.Get("kind"), Name: q.Get("name"), Unused: q.Get("unused") == "1" || q.Get("unused") == "true"}
	if opt.Kind != "" && !slices.Contains(primitives.Kinds, opt.Kind) {
		writeError(w, http.StatusBadRequest, "unknown kind "+strconv.Quote(opt.Kind)+": one of "+strings.Join(primitives.Kinds, ", "))
		return
	}
	if opt.Name != "" && opt.Kind == "" {
		writeError(w, http.StatusBadRequest, "name needs a kind")
		return
	}
	if d := q.Get("days"); d != "" {
		days, err := strconv.Atoi(d)
		if err != nil || days < 0 {
			writeError(w, http.StatusBadRequest, "days is a number of days")
			return
		}
		if days > 0 {
			opt.Since = time.Now().AddDate(0, 0, -days)
		}
	}
	out, err := primitives.Read(s.Archive.Store, primitives.Places{ClaudeDir: rep.ClaudeDir, Managed: s.ManagedDir, Dirs: q["root"]}, opt)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	if opt.Name != "" && len(out.Items) == 0 {
		writeError(w, http.StatusNotFound, "no "+opt.Kind+" named "+strconv.Quote(opt.Name)+" is installed, on offer or used in an archived session")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) search(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	on := func(name string) bool { return q.Get(name) == "1" || q.Get(name) == "true" }
	opt := search.Options{Mode: q.Get("mode"), Limit: limit, Project: q.Get("project"), Session: q.Get("session"),
		PrefixLast: on("prefix"), NoGate: on("all"), NoTools: q.Get("tools") == "0" || q.Get("tools") == "false"}
	if k := q.Get("kind"); k != "" {
		opt.Kinds = strings.Split(k, ",")
	}
	opt.MinCosine, _ = strconv.ParseFloat(q.Get("min_cosine"), 64)
	opt.MinZ, _ = strconv.ParseFloat(q.Get("min_z"), 64)
	opt.Vectors = &s.vectors
	hits, err := search.Search(r.Context(), s.Archive.Store, s.queryEmbedder(), q.Get("q"), opt)
	switch {
	case err == nil:
	case errors.Is(err, search.ErrNoEmbedder), errors.Is(err, search.ErrNoVectors), errors.Is(err, search.ErrStaleVectors):
		// The request is fine; the index is not ready for it. `skit embed` is.
		writeError(w, http.StatusConflict, err.Error()+": run `skit embed`")
		return
	case errors.Is(err, search.ErrEmptyQuery), errors.Is(err, search.ErrUnknownMode), errors.Is(err, search.ErrUnknownKind):
		writeError(w, http.StatusBadRequest, err.Error())
		return
	default:
		// Meaning search can fail for reasons that are not the caller's: the
		// model is missing, llama-server did not start.
		if m := q.Get("mode"); m == search.ModeMeaning || m == search.ModeHybrid {
			writeError(w, http.StatusServiceUnavailable, err.Error())
			return
		}
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

// verify is GET /v0/archive/verify: what `skit archive --verify --json` prints.
func (s *Server) verify(w http.ResponseWriter, r *http.Request) {
	checks, err := s.Archive.Verify(r.URL.Query()["id"])
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, checks)
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
	rep, err := s.Inspect()
	if err != nil {
		return archive.Result{}, err
	}
	l, err := rep.Find(path)
	if err != nil {
		return archive.Result{}, err
	}
	return s.ingestKeepingMode(l)
}

// ingestKeepingMode archives a session the way its copy was made: one archived
// with --strip-requests is not turned lossless behind the user's back.
func (s *Server) ingestKeepingMode(l catalog.Located) (archive.Result, error) {
	opt := archive.Options{}
	if row, err := s.Archive.Store.Session(l.File.ID); err == nil && row != nil && row.Archived() {
		opt.StripRequests = !row.KeepsRequests
	}
	return s.Archive.Ingest(l, opt)
}

// Sweep archives every session on disk whose copy is missing or behind. The
// watcher only hears about changes made while it runs; the sweep catches what
// changed while no skit was running, and anything a file event missed. Cheap
// when nothing changed: one stat and one index row per session.
func (s *Server) Sweep() (changed, failed int) {
	defer s.sweptOnce.Do(func() { close(s.swept) })
	rep, err := s.Inspect()
	if err != nil {
		s.Logf("sweep: %v", err)
		return 0, 1
	}
	for _, l := range rep.Sessions() {
		if l.File.Kind != "main" {
			continue
		}
		res, err := s.ingestKeepingMode(l)
		switch {
		case err != nil:
			failed++
			s.Logf("sweep: %s: %v", l.File.ID, err)
		case res.Action != "unchanged":
			changed++
			s.Logf("sweep: %s %s (%d records)", res.Action, short(res.ID), res.Records)
		}
	}
	return changed, failed
}

func short(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

// SweepEvery runs Sweep now and then at every interval until ctx is done.
func (s *Server) SweepEvery(ctx context.Context, interval time.Duration) {
	tick := time.NewTicker(interval)
	defer tick.Stop()
	for {
		s.Sweep()
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}

// queryEmbedder hands the embedder to search, keeping "none" a nil interface.
func (s *Server) queryEmbedder() search.QueryEmbedder {
	if s.Embedder == nil {
		return nil
	}
	return s.Embedder
}

// EmbedEvery keeps meaning search level with the archive: once the first
// sweep has finished (or after two minutes, if nothing sweeps), and then at
// every interval, it gives vectors to whatever text has none.
//
// SPEC: issue #3 and docs/decisions/0009-background-agent.md: background work
// is the tool's to manage. It runs on a period and not on every change, so the
// model is not loaded again each time a live transcript grows.
func (s *Server) EmbedEvery(ctx context.Context, interval time.Duration) {
	select {
	case <-ctx.Done():
		return
	case <-s.swept:
	case <-time.After(2 * time.Minute):
	}
	tick := time.NewTicker(interval)
	defer tick.Stop()
	for {
		s.EmbedPass(ctx)
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}

// EmbedPass embeds what has no vector yet and returns how many texts it
// embedded. It asks the index first, so the model is started only when there
// is work, and it stops a sidecar it started once the work is done. It never
// downloads anything: without the model or llama-server it does nothing and
// says why in the log, once.
func (s *Server) EmbedPass(ctx context.Context) int {
	if s.Embedder == nil || !s.embedding.CompareAndSwap(false, true) {
		return 0
	}
	defer s.embedding.Store(false)
	pending, err := s.Archive.EmbedPending(ctx, s.Embedder.Source())
	if err != nil {
		s.logEmbedFailure(err)
		return 0
	}
	if pending == 0 {
		return 0
	}
	// A sidecar that was already up is serving someone's searches; leave it.
	type lifecycle interface {
		Running() bool
		StopIfIdle()
	}
	if lc, ok := s.Embedder.(lifecycle); ok && !lc.Running() {
		defer lc.StopIfIdle()
	}
	res, err := s.Archive.Embed(ctx, s.Embedder, nil)
	if err != nil {
		if ctx.Err() == nil {
			s.logEmbedFailure(err)
		}
		return res.Embedded
	}
	s.lastEmbedErr = ""
	s.Logf("embed: %d texts in %.1fs; %d of %d have vectors", res.Embedded, res.Seconds, res.Vectors, res.Texts)
	return res.Embedded
}

// logEmbedFailure logs a background failure when it is new. A missing model
// would otherwise be reported at every interval for as long as it is missing.
func (s *Server) logEmbedFailure(err error) {
	if msg := err.Error(); msg != s.lastEmbedErr {
		s.lastEmbedErr = msg
		s.Logf("embed: %v", err)
	}
}

// cacheIdle is how long a parsed session stays in memory with nobody asking for it.
const cacheIdle = 10 * time.Minute

// maxSocketPath is the longest Unix socket path the kernel accepts (sun_path
// is 104 bytes on macOS, 108 on Linux; the NUL terminator takes one).
const maxSocketPath = 103

// Listen binds the Unix socket. A stale socket file from a crashed server is
// replaced; a live one is an error, so a second skit never starts watching or
// archiving beside the first.
func Listen(socket string) (net.Listener, error) {
	if len(socket) > maxSocketPath {
		return nil, fmt.Errorf("socket path is %d bytes; Unix sockets allow at most %d on this platform. Use a shorter --socket path", len(socket), maxSocketPath)
	}
	if err := os.MkdirAll(filepath.Dir(socket), 0o700); err != nil {
		return nil, err
	}
	if _, err := os.Stat(socket); err == nil {
		if conn, err := net.DialTimeout("unix", socket, 200*time.Millisecond); err == nil {
			conn.Close()
			return nil, fmt.Errorf("another skit is already serving on %s", socket)
		}
		os.Remove(socket)
	}
	ln, err := net.Listen("unix", socket)
	if err != nil {
		return nil, err
	}
	os.Chmod(socket, 0o600)
	return ln, nil
}

// ListenAndServe is Listen followed by Serve.
func (s *Server) ListenAndServe(ctx context.Context, socket string) error {
	ln, err := Listen(socket)
	if err != nil {
		return err
	}
	return s.Serve(ctx, ln, socket)
}

// Serve answers requests on ln until ctx is done, then removes the socket file.
func (s *Server) Serve(ctx context.Context, ln net.Listener, socket string) error {
	srv := &http.Server{Handler: s.Handler(), ReadHeaderTimeout: 10 * time.Second}
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ln) }()
	go func() { // give memory back when nobody is reading
		tick := time.NewTicker(time.Minute)
		defer tick.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-tick.C:
				if s.Archive.TrimCache(cacheIdle) > 0 {
					debug.FreeOSMemory() // a parsed session is hundreds of megabytes; hand them back now
				}
			}
		}
	}()
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
	// Compact: the reader is a program. `skit <command> --json` prints the same
	// shapes indented for people.
	_ = json.NewEncoder(w).Encode(v)
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
