# Plan

The milestones, done and to come, and the choices behind them. v0 ends at M9. v1 is M0 to M16 complete, M16 being the
release itself, and v1 is what gets shared (Juan, 2026-11-10). M17 to M19 come after it; M20 to M22 were added on
2026-11-10 and may be taken up before the release, while its signing waits on Apple. This file is the source of truth
for what is in scope; the workspace session log only records what happened.

Decisions already taken: Go engine runs as a process (not linked into Swift). IDL deferred until a second face needs it;
the contract for v0 is "one CLI subcommand = one engine function = one service endpoint, same names, JSON shapes". Not
for the App Store. Embedding via a `llama-server` sidecar (ADR 0005), no Ollama. Naming: SessionKit, SessionVisualizer.
Pattern: the engineering repo's `practices/tool-first-ai-development.md`. Tenets: `tenets.md`.

## Pace

No time estimates anywhere in this plan. A milestone ends when it feels right, then the next one starts.

## v0 definition of done

1. `skit list` enumerates every session on this Mac (all projects, orphaned/superseded files, subagents) with title,
   project, cwd, span, prompts, requests, tokens, cost.
2. `skit show <id>` renders one session as a timeline (human and JSON), with turns reassembled, tool calls paired,
   compactions and subagent lanes marked.
3. `skit archive` copies the kept records of every session into a durable store that survives Claude Code's sweep, and
   `list`/`show` work from the archive when the original is gone.
4. `skit search <words>` finds turns across all archived sessions by keyword (FTS5). Meaning search is M14.
5. `skit serve` exposes the same operations over HTTP on a Unix socket.
6. SessionVisualizer (Swift, SwiftPM, one window) lists sessions and shows one session with its stats, fed by `serve`.
   As built, that is M7 to M9: Sessions, Transcript, Summary and Search.

## Repo layout (`claude-code-session-visualizer/`)

```
go.mod                          module github.com/juan7732/claude-code-session-visualizer   (Go 1.26)
cmd/skit/                       CLI entry (binary `skit`); internal/cli/ holds the Cobra commands (`skit describe` lists them)
sessionkit/                     the engine, importable. No I/O opinions.
  transcript/                   JSONL reader → Record, Session, Turn, ToolCall, Compaction, Subagent. The parser.
  catalog/                      discovers sessions on disk (~/.claude/projects, companion dirs, sessions/<pid>.json, history.jsonl)
  stats/                        usage summation, pricing table, cost reconciliation against cost-state
  store/                        SQLite archive + index (modernc.org/sqlite, pure Go, FTS5 on). Schema versioned.
  search/                       keyword now; hybrid scorer (DigUp's z-scaled meaning + coverage) when vectors arrive
  export/                       a session or one turn as Markdown
  embed/                        (M14) client for the llama-server sidecar, process management, model download
  service/                      the launchd agent that keeps `skit serve` running
  serve/                        HTTP handlers over a Unix socket, thin wrappers over the packages above
internal/testdata/sessions/     fixtures + expected.json (parser eval); tools/redact makes the redacted real one
test/integration/               hermetic dockerized end-to-end suite (ergo's harness pattern): real binary, temp HOME, seeded ~/.claude
justfile                        build, test, integration, fmt, vet, check, run (ergo's shape)
docs/                           source of truth: tenets.md, architecture.md, plan-v0.md, the promoted sessions-study notes,
                                roadmap.md (from ideas.md), decisions/
client/SessionVisualizer/       SwiftPM app (M7 onwards)
```

## Milestones

A milestone is marked **(DONE)** in its heading when delivered.

**M0 Scaffold (DONE).** go.mod, Cobra skeleton with `--json` on every read command, `doctor` (reports `~/.claude`
location, `cleanupPeriodDays`, live sessions, session count, disk use), `describe --json` (the agent manifest: every
subcommand, flags, output schema, examples), MIT license, CI with `go test ./...` and `go vet`. Promote the
sessions-study notes into `docs/`.

**M1 Parser (DONE).** `transcript.Reader` streams lines, tolerant of a partial last line, tracks byte offset for resume.
`Record` keeps `json.RawMessage` plus typed views for the record types we know; unknown types become `OpaqueEvent`.
`Session.Build` makes the uuid tree, finds the tip via `last-prompt`, walks the main chain, groups assistant records
into `Turn` by requestId (usage once), pairs tool calls, marks `Compaction`s, attaches `Subagent`s from the companion
dir by `meta.toolUseId`, resolves spilled tool results. **Parser eval**: `internal/testdata` fixtures: this bootstrap
session (`36086585…`) redacted by `tools/redact` (keeps structure, replaces prose with same-length placeholder text,
strips images to 1×1 PNGs), plus synthetic sessions built for specific cases (compaction, subagents, images, orphaned
files). `expected.json` counts cross-checked against `sessions-study/tools/inspect.py`. `go test` fails on any drift.

**M2 CLI read path (DONE).** `list`, `show` (timeline: one line per turn with time offset, role, model, tokens, tool
names, durations; `--turn N` for detail; `--json` full structure), `stats` (tokens by category, cost ours vs Claude
Code's, tools by name, compactions, context curve as a table), `projects`. Human output designed for a terminal, JSON
for agents. This is the point where Claude Code itself can start using the tool.

**M3 Archive + keyword search (DONE).** `store`: `sessions` (summary, source fingerprint, archive state), `segments`
(one per content block, with its kind, turn and action), `fts` over segment text, a versioned schema. `archive` ingests
new or changed sessions incrementally by byte offset and keeps the raw JSONL lines, zstd-compressed and lossless,
request records included (`--strip-requests` drops them, ADR 0007); records `session-owner`. `search` = FTS5 + bm25 with
DigUp's term rules (stopwords, prefix on the last word, lookup detection for ids). Index location `~/.sessionkit/`
(never under ~/Library).

**M4 Serve (DONE).** `serve --socket <path>`: `GET /sessions`, `GET /sessions/{id}`, `GET /sessions/{id}/stats`,
`GET /search?q=`, `GET /status`, `POST /archive`. Same JSON as the CLI's `--json`. Hand-written, versioned under `/v0/`.
Watches `~/.claude/projects` with fsnotify so the archive stays current; a hooks installer lands later.

**M5 Embedding spike (DONE).** Build llama.cpp with Metal, run `embeddinggemma-2-Q8_0.gguf` text-only through
`llama-embedding` on a few hundred real turns. Measure load time and vectors/sec. Decide the worker implementation
(Swift `LlamaRuntime` lifted from DigUp's design vs a C++ worker). No product code. Outcome: `llama-server` as the
sidecar for text, images and audio (`decisions/0005-embedding-worker.md`, `embedding-spike.md`).

**M6 Engine hardening (DONE).** From the review of 2026-11-09. The archive never ends up holding less than it did:
checked appends, atomic rewrites, a fuller earlier copy kept as `<copy>.prev-<time>`, `skit archive --verify`
(`decisions/0008-the-archive-never-shrinks.md`). The archiver runs without being asked: `skit service install` puts
`skit serve` under launchd, `serve` sweeps at start and hourly, `doctor` reports the agent and the sessions still
waiting (`decisions/0009-background-agent.md`). `serve` caches parsed sessions and answers requests concurrently (a warm
turn fetch on a 166 MB session went from 1.9 s to under a millisecond). Turns and actions on rewound branches are
flagged and counted. Cost stays Claude Code's own figure; the pricing table is deferred (issue #1).

### The native client

The old M6 ("two views") became seven milestones once the mocks grew into a whole app. Reference for all of them:
`ux-mocks/app.html` at iteration 13 for layout and behaviour, `ux-mocks/NOTES.md` for intent; where they disagree,
`NOTES.md` wins. The mocks live in the workspace beside this repo.

| #   | Milestone                           | Ends with                                                              |
| --- | ----------------------------------- | ---------------------------------------------------------------------- |
| M7  | App skeleton and Sessions           | The app launches, lists every session from `skit serve`, opens one     |
| M8  | Transcript and the drawer           | A session can be read end to end, inspected and annotated              |
| M9  | Summary, Search and the bundled app | The three questions are answered from an app in /Applications. **v0**  |
| M10 | Canvas: Braid                       | The centrepiece canvas, read-order layout                              |
| M11 | Timeline                            | Strip with playhead, ledger, where the time went                       |
| M12 | Canvas: Score                       | Time-true staves, built from M10's camera and M11's time axis          |
| M13 | Files, Stats, Compare, Claude       | The remaining pages, each shippable on its own                         |
| M14 | Semantic search                     | A question in your own words finds the turn; engine first, then Finder |

Why this order: M7 to M9 answer the three questions a session must answer (what is it about, what did I do and when, did
I discuss X and where) with standard SwiftUI, so the data path, the selection model and the engine contract are proven
before any custom drawing. Braid comes first among the drawn views because it is the primary view and the largest risk.
Score waits for the Timeline because it is the Timeline's warped time axis on the Braid's camera. M14's engine half
depends on none of the client work and can run beside it from now on.

Rules for every client milestone:

- **The client never parses or derives.** If a view needs something `/v0` does not serve, it becomes a `--json` shape
  and a route in the engine first. No mining of tool inputs in Swift.
- **Contract tests.** The Swift models decode recorded `/v0` responses for the `synthetic-basics` fixture. An engine
  change that breaks decoding fails the client's tests.
- **One selection, one node language, one vocabulary** (turn, action, tool call, subagent; ADR 0006) across every view.
- **Every command is in the menu bar** with its shortcut; toolbar and context menus are subsets.
- **A view brings its own settings.** The Settings window exists from M7; each milestone adds its tab and its ⚙.
- **Judged against the mock.** Done includes a side-by-side screenshot of the Swift view and the same route in
  `app.html`, on the same real session, light and dark.
- **Look** (confirmed 2026-11-10): Bento is the one style, as design tokens in one file. Light and dark follow the
  system; OLED is a setting. The other six styles in the mock are not ported.
- **Code layout:** `client/SessionVisualizer/` (SwiftPM, SwiftUI, macOS 14+). The engine stays untouched by client work.

**M7 App skeleton and Sessions (DONE).** Mock: the shell and `#/sessions`.

- SwiftPM app, one window. On first launch it runs `skit service install` for its own `skit`, so archiving and the
  socket are there from then on; it shows a clear state when the engine is missing or the version does not match.
- Typed `/v0` client, hand-written `Codable` (ADR 0004). **First risk to retire:** `URLSession` does not speak HTTP over
  a Unix socket. Either a small HTTP/1.1 client on Network.framework, or an opt-in loopback listener in `serve`. Decide
  by a spike at the start of the milestone; record the choice as an ADR.
- Shell: icon rail with hover flyout (projects, recent), toolbar, menu bar with every command (disabled until its view
  exists), Settings window skeleton, design tokens.
- Sessions home: rows with title, project, last activity, turns, actions, tokens, cost; project chips; pin and tags;
  pinned first; sort.
- Opening a session lands on a minimal Summary: title and the facts from `/stats`.

Engine: `/status`, `/sessions`, `/sessions/{id}`, `/stats`, `/annotations`. Done when: launch, see every session on this
Mac, filter by project, pin one, open one.

**M8 Transcript and the drawer (DONE).** Mock: `?view=transcript` (Chat+) and the bottom drawer.

- Chat+ flow: prompt cards, prose rendered block by block (paragraphs, headings, lists, code, tables), compact tool rows
  with the result excerpt, the parallel group, subagent strands, background-task links, thinking folded, "21m later"
  rules, compaction markers, API-error rows, rewound turns marked.
- **Folding**, added after Juan's first use: a turn's tool calls fold into one line per run ("63 tool calls · Bash 58 ·
  Write 5 · 2 failed · 29m 1s") and what was said stays. ← on a call or an action with nothing open folds its turn; → or
  a click on the line shows the calls again; ⌥⌘← and ⌥⌘→ for the whole session; a setting opens sessions folded.
- One selection per window, shared by the session's views, and the bottom drawer on it: Details, Input and result, Note;
  breadcrumb turn › action › tool; previous and next; resizable.
- Keyboard: j/k (an action with one tool call is one stop), J/K turns, Return or i inspects in the drawer, → opens, ←
  closes then folds, e/c every call of the turn, g/G, / find, ? the list. The scroll map. Find in session (⌘F) through
  the engine's search, after a pause in typing.
- Notes on a session, turn, action, tool call, subagent or compaction, kept by the engine.

Engine, for it: `result_head` and `result_bytes` on tool calls; lists never `null`; parallel line decoding; relations
and the encoded document kept per parsed session; the agent as an interactive process
(`relations-and-client-routes.md`). Largest session through the agent: 2.7 s → 0.41 s not in memory, 8 ms in memory.

Carried to M9: Copy Link (needs the app's URL scheme, so the bundle), the drawer on the Summary, selecting a single
subagent step, the `/compactions/{n}` detail in the drawer, a ⚙ popover per view (the options are a Settings tab).

**M9 Summary, Search and the bundled app (DONE, v0).** Mock: `?view=summary` (Dashboard), `#/search` (Finder), ⌘K.

- Summary dashboard: about, ended, size, outcome (files written, commits, lines), problems, context with the gauge,
  parallel work, outside, where it worked, how it ran; a search box for this session that answers yes or no and offers
  every session when the answer is no; the digest (one row per turn) and the hours grid beneath. The Arcs map waits for
  M10.
- **The context gauge** measures the peak against a window the human sets (Settings › Summary: 1M by default, or 200k).
  A transcript does not record the window, and the card says the number is the setting (decided 2026-11-10).
- Every row that names a node selects it, and the drawer is under the Summary too. New nodes: a file, an outside
  service, one step of a subagent. The drawer on a compaction shows what the cut did: the actions on both sides, the
  summary's sections, what was kept word for word, what was put back.
- Search: the simplified Finder (hits grouped by session with a strip of where they fall, the text of the selected hit
  beside them, Open in Transcript or Session Summary), kinds with their counts as a scope bar, live after a pause,
  recent searches. A hit opens its session with find-in-session already on that hit.
- After Juan's first use: a search that finds several sessions lists them folded, one line each, to choose from; a click
  or Return shows a session's hits, "Show All Hits" and "Fold to Sessions" (⌥⌘→, ⌥⌘←) do it for all and the choice is
  kept. A **Keyword / Meaning** switch beside the field (M14's client half, in its plain form: the engine's
  `mode=meaning`, each hit with how close it is). **Back and Forward** (⌘[, ⌘]) follow where the window has been: Back
  from a Transcript is the Summary it was opened from, Back from a hit is the Search page. A session opened from a list
  starts on its Summary.
- ⌘K palette: sessions, mentions (the engine's search), commands; ⌘O opens it too.
- Export Session as Markdown (⇧⌘E), Copy Turn as Markdown. The text is the engine's (`skit export`).
- `client/SessionVisualizer/build.sh` (`just client-app`, `just client-app-install`): a signed `.app` with `skit` in
  `Contents/Helpers/`, ad hoc unless `SIGN_IDENTITY` is set. The app registers `skit-visualizer://`; Copy Link (⇧⌘C)
  writes a link to the selected node and the app opens such links (`decisions/0011-the-app-bundle-and-its-links.md`).

Engine, for it: `commits` in `/relations`, `in_turns` in stats, `skit export` and `/export`, `/actions/{n}?agent=`
(`relations-and-client-routes.md`). Still missing: the model's context-window limit (a setting stands in), fork parent
and child ids ("How it ran" shows the number of branch points). Open after M9: an app icon (it came on 2026-11-10:
Juan's logo, on the Dock's grid); a Developer ID, without which the app runs only on the Mac that built it; a ⚙ popover
per view (the options are Settings tabs). Done when: for any session, what it was about, what happened when, and whether
X was discussed can be answered from the app in /Applications. This closes v0's definition of done, item 6.

**M10 Canvas: Braid (DONE).** Mock: `?view=canvas`, layout Braid; lab in `ux-mocks/canvas/`.

- **The spike came first and settled the approach** (`decisions/0012-the-canvas-is-drawn.md`): one AppKit view draws the
  canvas with Core Graphics and Core Text; every text is broken into lines once, so the layout is computed and the same
  every time; three levels of detail by zoom. Measured on the three largest sessions at full-screen Retina size: 5 to 8
  ms a frame near, 2 to 3 ms far, against the 16.7 ms a frame has at 60 a second.
- The node language, drawn: prompt card, system-turn card, step card (what it did, what it wrote, a chip per tool call
  when there are several, badges for failed, hand-back and task output), subagent strand with its steps, what came back
  on the arrows, the edges (chain, spawn, hand-back, background launch, thread and read-back).
- Turns stacked with separators and "21m later" pills, compactions as pills, a collapsed turn as one pill (double-click
  or Return; Collapse All). The chain waits for a hand-back: the step that received it sits below the strand.
- Camera: scroll to move, pinch or ⌘-scroll to zoom where the pointer is, drag, Fit Width, All, Focus, ⌘+ ⌘− ⌘0 ⇧⌘0;
  kept per session. A minimap that moves the camera while dragged. Keys: ↑ ↓ steps, ← → turns, i, f, ?. Find on the
  Canvas rings the matches, dims the rest and steps through them. The drawer is under the Canvas too.
- The Summary's map (Arcs): turns down a spine, the files that kept coming back and the outside services as hubs tied to
  the turns that touched them, subagents as pills, background commands as dashed loops.

Engine: nothing new was needed (`/relations` is memoised since M8; a subagent's steps come from its nested document).
Not built: the keyboard inside a strand, dragging a strand aside. Done when: the five questions in `ux-mocks/README.md`
can be answered on the Braid without leaving it.

**M11 Timeline (DONE).** Mock: `?view=timeline` (strip and ledger).

- **The data came first and changed the split.** The mock read the gap after an action's tools as "waiting on subagents,
  tasks, you reading". Measured on real sessions it is the model: a transcript stamps a block when it is complete, so
  the wait for a response, the thinking and most of a long write sit before an action's timestamp
  (`relations-and-client-routes.md`, "Where the time went"). Spans gained `start`, and the split is the engine's.
- The session strip that always fits the width, idle gaps over 90 s cut to hatched bands (the bands narrow when there
  are many); rows for You, Agent (the model working, tools running, waiting to be brought back), Subagents, Background;
  the context curve with compaction marks; the output of every request.
- Playhead: drag anywhere on the strip, play and pause (space), previous and next turn; playing moves along the strip,
  so an idle night is one band. Speed and "the ledger follows" are settings, behind the gear and in Settings. The "now"
  line says the turn, the action, which stretch it is in, what runs beside it and the context size.
- The ledger beneath: a row per action with its clock time, what it did, what came back, and a bar of the model's time
  and the tools'; a turn's row carries the engine's split of that turn. Scrubbing lights the row, a row moves the
  playhead. Idle gaps, compactions, waits for a hand-back and API errors have rows of their own.
- "Where the time went" (W): waiting for you and for background work against in turns; in turns the model, tools,
  subagents, waiting for a hand-back; slowest tool calls; longest waits. Each line goes to its place in the session.
- Selection, find, the drawer and links work as on the other views; `TimeAxis` is the piece M12's Score reuses.

Engine, for it: `start` on spans, `skit time` and `/v0/sessions/{id}/time` (`relations-and-client-routes.md`). Not
built: the ledger's row height as a true time scale (it grows a little with duration, as in the mock); a per-session
memory of where the playhead was. Done when: "where did the time go" and "what was happening at this moment" are
answered for the largest session.

**M12 Canvas: Score (DONE).** Mock: Canvas layout Score.

- Canvas › Layout is Braid or Score, a switch at the left of the Canvas's bar (and behind the gear, and in Settings).
  Each layout keeps its own camera per session.
- Time runs left to right on M11's `TimeAxis` at a scale, warped twice: idle gaps over 90 s are hatched bands labelled
  with how long, and no two moments are closer than 14 points. Both warps are the same for every row, so what stands
  above what happened at the same time.
- Rows: You (a chip where each turn began), Agent (a bar per action: solid while the model worked, light while its tools
  ran, empty while it waited after speaking; under it the tool calls, one lane for each that ran at once, red outline
  when one failed, dashed when it started something that outlived it), one row per subagent running at once (its steps
  along the bottom, an arrow from the call that spawned it and a dashed one into the action that used it), Background (a
  dashed pill from launch to where it was last read, tied to both), and a row for each of up to eight files touched
  three times or more (a square per touch, filled when written).
- Over the canvas, fixed: a ruler with a pill per turn and how far into the session the view is, and the rows' names.
  From far away a turn is one bar; closer its actions; closer still their words. The pointer says what any bar is.
- Fit Rows (the default view: every row, from the start), All, Focus, the minimap, find (matches ringed, the rest
  faded), selection, the drawer, the context menu and links as on the Braid. Time scale (Tight, Normal, Wide) and the
  file rows are options.

Engine: nothing new. The action bars follow M11's reading of a span: the model's part starts when the action before it
finished, so the bars of a turn tile it. `decisions/0012-the-canvas-is-drawn.md` has the frame times (8 to 10 ms up
close at full-screen Retina size). Not built: collapsing turns on the Score; compactions on the ruler. Done when: who
was working at the same time reads at 80 to 160 % zoom.

**M13 Files, Stats, Compare, Claude (DONE).** Four pages of lists, tables and cards. Marked done by Juan on 2026-11-10,
with the file viewer below.

- **Files** (⌘5): every file touched, most written first, with a filter; for one file a strip of the turns that touched
  it and a card per touch with the command or edit around the file's name and what came back. Context: the blocks Claude
  Code injected into the prompts, by kind. Images: the pictures pasted in or returned by a tool, as a grid and large (←
  → esc, Show in Transcript, Copy). Not built: a file's content at a turn and a diff per write (the engine does not read
  file-history snapshots), a session-wide list of attachments, a `file` search kind.
- **Stats**: figures; a year of days (click one for its numbers and sessions); by project (click narrows every board);
  tools and failures; where the time went; models and the prompt cache; actions per prompt; one sortable row per
  session. The boards needed per-day activity and a time split across sessions, which a session row did not have and the
  client does not derive: session summaries gained them and `skit overview` adds them up from the index.
- **Compare** (File › Compare Sessions…): two sessions on the same measures, each with its turns as a strip, actions per
  prompt and where its time went. Both sessions are read once for files written, commits and background commands.
- **Claude**: experiments with the flag each drives and "copy as id=variation", settings in effect by layer, the cached
  flags with a filter, projects, memory files and skills, what Claude Code remembers about itself. Read-only.

After Juan's pass (2026-11-10): **a file viewer in the Files view.** A file opens on "The file": its text as it is on
disk now, coloured by a small highlighter for the usual languages, or the plain fact that nothing is at that path any
more; Open in the application chosen in Settings › General (Visual Studio Code when it is installed and nothing was
chosen), Reveal in Finder, Copy Path; and beside it every session that touched the same file, each a click away.
"Touches" is the list that was there before. The inspector's file panel has "View File". Memory files on the Claude page
open in the chosen application (double-click); the app does not show their text, because the engine does not send it.
The file at a turn and a diff per write are still issue #5.

Engine, for it (`relations-and-client-routes.md`): `activity`, `shape` and `time` in summaries (index schema 6);
`skit file` and `/v0/file`, with a table of which session touched which file (index schema 7); `skit overview` and
`/v0/overview`; and a second correction to the time split, which the overview exposed: a wait after the agent spoke is a
hand-back wait only when a hand-back arrived, otherwise it is waiting for you.

**M14 Semantic search (DONE).** Find a turn by meaning, not only by its words. Engine first; the engine half can run
beside M7 to M13.

- `embed` package: client for the `llama-server` sidecar (ADR 0005), started on demand and stopped when idle; the model
  downloaded once from a pinned revision with a checksum into `~/.sessionkit/models/`.
- Vectors on segments (768 dimensions, fp16), written at ingest and by a backfill command with progress; an index schema
  step.
- **An eval before a scorer.** Queries in Juan's own words with the turns they should find, from the real archive. The
  fusion gate is tuned on it: DigUp's z-gate cannot be copied (a junk query reached z ≈ 2.9 on a 300-vector sample,
  `embedding-spike.md`). A scoring change carries the eval delta in its commit message.
- `skit search --mode keyword|meaning|hybrid` and the same parameter on `/v0/search`; a hit says why it matched.
- Client: a Meaning scope in the Finder (needs M9).

Done when: a question that shares no words with the transcript finds the turn, hybrid beats keyword on the eval, and
nothing leaves the machine but the one model download.

State, 2026-11-10 (`meaning-search.md`): built, and marked done by Juan the same day. The `embed` package; index schema
5 (chunks and vectors keyed by a hash of the text, where ADR 0005 said "on the segment row"); `skit embed`; `skit eval`
and an eval of 53 queries; meaning search with a gate that lets it say nothing was found; `hybrid` (meaning matches
first, then keyword hits), which beats keyword on every measure of the eval (R@1 0.62 → 0.69, R@5 0.77 → 0.81, R@10 0.85
→ 0.88, MRR 0.68 → 0.75); narrowing by session, project, kinds and "no tool calls" in every mode; `serve` embedding new
text by itself every thirty minutes and holding the vectors in memory between queries. The Finder offers Keyword, Hybrid
and Meaning beside its field; outside keyword mode the session with the best hit leads the list.

Kept as it is, on purpose (2026-11-10: live with it for now): a near miss gets related hits, because a cosine floor
cannot tell "same subject" from "answers this", and keyword and hybrid still answer a question about an absent subject
from tool output. Both are what M18 is for.

### After the client: the release, and what comes after it

| #   | Milestone                 | Ends with                                                                              |
| --- | ------------------------- | -------------------------------------------------------------------------------------- |
| M15 | (declined)                | "Other people's machines" was proposed and declined on 2026-11-10; see below           |
| M16 | Release 1.0               | A stranger with an Apple silicon Mac can install it, understand it, remove it. **v1**  |
| M17 | Insights from the vectors | Things the archive can say across sessions, with no new model                          |
| M18 | A second small model      | A model that reads a question and a passage together, as an opt-in download            |
| M19 | A small language model    | Text written by a local model (summaries, titles), as a further opt-in download        |
| M20 | Now: sessions at work     | Every session active in the last hour as a card: what it is doing, how warm its cache  |
| M21 | Back to the editor        | From a card, the VS Code window that is running that session comes to the front        |
| M22 | Primitives                | Skills, agents, prompts and the rest: what is installed where, and how much it is used |

**M15, declined.** Hardening for other people's machines (other Claude Code versions, far larger archives, Intel and
CPU-only, strangers' archives) was proposed and declined. The tool supports Apple silicon Macs only and is shared as it
comes, without warranty. Juan's other two Macs, each with its own sessions, are where it gets used beyond this one.

**M16 Release 1.0 (v1).** What makes the tool something to hand to someone else.

- JSON shapes frozen as `v1` and `serve` moved from `/v0/` to `/v1/` (`decisions/0004-json-shapes.md` says this happens
  at 1.0); the client and its contract tests move with it.
- The app signed with a Developer ID and notarised, with `skit` and `llama-server` in `Contents/Helpers/` and their
  licences in the bundle. To settle first: this needs an Apple Developer Program membership; without one the app stays
  ad hoc signed and the README says how to open it.
- A first run that explains, before doing any of them: the archive and where it lives, the background agent, and the one
  download (what it is, its size, its terms, that nothing else uses the network).
- Release binaries of `skit` for people who only want the CLI (Apple silicon).
- A README and docs written for a stranger: what it is, what it reads and never writes, what it keeps and where, that it
  supports Apple silicon Macs only and comes without warranty.
- An uninstall that removes the agent and the app and says where the data is, leaving the archive unless asked.
- A check before a session is exported or a link is copied for what should not leave the machine (keys and tokens by
  pattern).
- The open issues each closed or left open on purpose (#1 the pricing table, #2 `/relations` memoised).

Built ahead of the rest, 2026-11-11: the first run (`Onboarding.swift`). It stands in place of the window until it has
been seen, so nothing connects and no agent is installed before the person presses "Start the Archiver": what the app
reads and keeps, why sessions are lost (with that Mac's own count from `skit doctor`), the archiver, search and the one
download, a tour. Help › Welcome to SessionVisualizer shows it again. Still to do in it for the release: the download
offered from the app once `llama-server` ships with it, and the model's terms shown. Also ahead of the release:
`docs/launch/`, pictures of every page on made-up sessions, and the questions people ask.

Done when: the release, installed from nothing on Juan's other Mac, archives that Mac's sessions and answers a question
about them, and removing it leaves nothing running.

**M17 Insights from the vectors.** After v1. Mining what the sessions say across sessions, with the vectors already
there and no new model (`roadmap.md`, "Models on top of the archive"). A session's own summary vector (the user's name
for a thing against the transcript's); chapters, where the subject changes inside a session; "you have been here
before", the nearest earlier turns to a prompt; a map of subjects across all sessions, which is also what the registry
of projects needs; a ranking that learns from which hits get opened and pinned; a Claude Code skill that answers from
the archive through `skit` with the turns cited. Each is judged on the eval or on a measure written down before it is
built.

**M18 A second small model.** After M17. A reranker or decision model that reads a query and a passage together, as an
explicit, opt-in download with its own line in `doctor`. Answer or near miss (the eval's eight near misses and nineteen
"nothing" queries are its test); what kind of turn this is (a decision, a question, a correction, a dead end), and from
that a register of decisions across sessions and facets in the Finder; the rest of the check before export (names,
grades, health). Starts with a spike on the eval through `llama-server`'s reranking mode, as M5 did for embedding.

**M19 A small language model.** After M18, its own milestone because it is the heaviest thing the app would carry: a
generative model, opt-in, never loaded because another feature was turned on, its work done in the background pass and
not at query time. What a tool call did, embedded with the call (issue #4); titles and abstracts for sessions Claude
Code never titled and a line per turn for the Summary; a query rewritten before it is searched. Starts with a spike that
settles which model, how much memory and how long per call, before any of it is promised.

M20 to M22 were asked for by Juan on 2026-11-10, after M13. They are numbered after M19 because that is when they were
written down. They may be taken up before the release: M16's signing waits on Apple (Juan, 2026-11-10).

**M20 Now: sessions at work (DONE).** A page of its own: every session that did something in the last 60 minutes is a
card, all of them at a glance.

- What it is doing now: the model working, a tool running (which, and for how long), waiting for a permission, waiting
  for a hand-back or a background command, or waiting for you (since when, and what it last said).
- Its prompt cache: how much of the last request was read from the cache, and how long until the cache expires, counted
  from the last request. A timer can be set on a card, and a notification sent when the cache has five minutes left, so
  a session can be picked up again before the next prompt pays for the whole context.
- This takes back a decision: live tailing was declined on 2026-11-09. A card needs the tail of a transcript that is
  still being written.

Engine, to settle first, by a spike on real transcripts: what in a transcript says which cache lifetime a request used
(the usage records split cache writes into five-minute and one-hour ones) and whether expiry can be told from the last
request's time alone; how a waiting permission prompt shows, if it does (`skit time` cannot see it today); and what the
"doing now" of a session costs to keep current (`serve` already watches `~/.claude` and knows the running processes).
Then a `skit` command and a route for it, as for everything else. Notifications are the app's; the engine only says
when. Done when: with three sessions running in three windows, the page says correctly which one is waiting for you, and
a notification arrives five minutes before a cache expires.

State, 2026-11-11 (`now.md`): built, and marked done by Juan the same day. The spike settled the three questions. What a
session is doing: Claude Code keeps a file per running process with its status, and the last records of the transcript
say the rest (which tool, since when, what it last said), within the last 32 kB of a transcript of any size. Cache
lifetime: each request's usage says whether it wrote five-minute or one-hour entries, so expiry is the last request's
time plus that. A waiting permission prompt is not in a transcript at all: it shows only if Claude Code marks the
process as waiting, which is not verified for VS Code. `skit now`, `/v0/now` (about 20 ms with a 115 MB transcript
running), and the Now page on the rail: a card per session with its state and a running clock, what is running or was
last said, and the cache as a bar that empties; a bell per card for a notification when the cache has five minutes left;
the app asks every 3 seconds while the page shows. With it, Refresh (⌘R) by the back and forward arrows on every page,
with a dot when the open session has moved on since it was read. Not built: background shell commands as a state; an
open session's page following a running session by itself; a card's button to the editor window (M21).

**M21 Back to the editor (DONE).** From a card of M20 (and from any live session's page), "Open in VS Code" brings the
window that is running that session to the front, so the work continues where it was left. To settle first: how to tell
which window that is. Claude Code records the process and its entry point for a running session; the editor's window for
a workspace folder can be raised by opening that folder with `code`, which is right when one window has the folder and
not when two do. A session started in a terminal has no editor window: the card says so and offers the folder in Finder
or the terminal instead. Could ship with M20 or after it. Done when: with two VS Code windows on two workspaces, each
running a session, the button on each card raises the right one.

State, 2026-11-11 (`now.md`, "Back to the editor"): built, and marked done by Juan the same day. Which window is told
exactly, not by folder: a window's extension writes a lock file named by the port it listens on, a session is a child of
the process that listens there, and `claude` in the editor's terminal is told the port. An editor asked to open the
workspace a window is already on raises that window, so the engine says what to open (the workspace file for a window on
several folders, found in the editor's own record of its windows) and the app opens it. Tried with the app's own code on
two VS Code windows on two workspaces, each running a session: each card's action raised the right one. A terminal
session brings its terminal application forward; its window or tab cannot be told. On each card, in an open session's
menus (⌥⌘E) and in the palette. Not tried: editors other than VS Code.

**M22 Primitives (DONE).** A section of its own on the rail for what Claude Code is extended with: skills, agents
(subagent definitions), slash commands and prompts, hooks, connectors, plugins, memory and instructions. The Claude page
lists some of these today (skills with a use count, memory files, connectors by name); this is that, grown up.

- Where each is installed: for the user, for a project, from a plugin; and which one wins when a name is defined twice.
- How much each is used, from the sessions themselves and not only from Claude Code's own counter: which sessions
  invoked a skill or spawned an agent of a kind, how often, when last, how it went (failed calls, time spent, tokens).
- What is installed and never used.

Engine: the relations already record skills and connectors a session reached; agents by kind, slash commands and hooks
are to be added, with an aggregate across sessions kept in the index as M13 did for activity. Done when: "which of my
skills did I use this month, in which projects, and which have I never used" is answered from the app and from `skit`.

State, 2026-11-10 (`primitives.md`): built. The engine finds every definition for the user, the account, plugins and
each project (with the folders up to two levels below it), and lists a name defined twice in the order Claude Code
prefers. Use is counted from the transcripts, which turned out to say more than expected: besides tool calls, a session
records the skills, agent types and connectors it had on offer, the folder a skill was loaded from, each memory file
loaded and each hook that spoke; and a skill typed as a slash command leaves no tool call at all, so neither the tool
calls nor Claude Code's own counter see all of the use. The index (schema 8) keeps a row per session, primitive and UTC
day. `skit primitives`, `/v0/primitives` and the Primitives page (rail, between Stats and Claude): a list by kind, most
used first, with a period, "only what was not used" and a filter; the selected item beside it with its definitions
(open, reveal), its figures, its use by day and by project, and the sessions that used it, each opening at the turn of
its first use. There was no mock: the page follows the Files view and the Claude page, and is a first cut. Juan marked
it done "for now" on 2026-11-10; mock-ups and a second pass on the page are issue #8. Not built: plugins on a machine
that has one (written from the documented layout, tested on a made-up one); output styles, the status line and key
bindings; a `primitive` kind in Search.

**Not scheduled.** Continue from here (embedded terminal, fork at a turn; needs the feasibility probe in `NOTES.md`).
Plugins (ergo, git) through the extension points. Image tiers B and C, the hooks installer, HTML export. The pricing
table (issue #1). A web face: possible because the engine is an HTTP JSON process, not built; the no-derivation rule and
a `/v0` free of Swift-specific shapes keep the door open, and HTML export is the smaller answer for a reader without a
Mac. Declined on 2026-11-09: subagents as sessions, retention signals, the accessibility pass. Live tailing was declined
the same day and is back as M20.

## Choices (confirmed 2026-11-08)

| Choice           | Decision                                                                                                |
| ---------------- | ------------------------------------------------------------------------------------------------------- |
| Binary name      | `skit`. `sk` is skim in Homebrew; `skit` and `sessionkit` were free. Engine package stays `sessionkit`. |
| Module path      | `github.com/juan7732/claude-code-session-visualizer`                                                    |
| CLI framework    | Cobra                                                                                                   |
| SQLite driver    | `modernc.org/sqlite`, pure Go, FTS5                                                                     |
| Fixtures         | this bootstrap session, redacted, plus synthetic sessions per use case                                  |
| License          | MIT                                                                                                     |
| Archive location | `~/.sessionkit/`                                                                                        |
| Tests            | hermetic dockerized integration suite modelled on ergo's, plus unit tests; `just` as the task runner    |
| Tenets           | `docs/tenets.md`, written for this project in the style of ergo's                                       |
| Platforms        | Apple silicon Macs only (2026-11-10). Other machines may work and are not supported.                    |
| Warranty         | None. It is shared as it comes (2026-11-10); the MIT licence already says so.                           |

## Inputs

- `sessions-study/02-record-anatomy.md`, `03-stats-and-cost.md`, `04-working-with-sessions.md`, `06-subagents.md`,
  `07-archive-sizing.md`, `ideas.md`, `tools/inspect.py`
- `digup-study/03-index-and-search.md`, `07-what-transfers.md`
- `engineering/designs/claude-code-session-visualizer/vision.md`, `engineering/practices/tool-first-ai-development.md`
