# v0 plan

Copied from the workspace session log on 2026-11-08; this file is the source of truth from here on.

# Visualizer v0 plan

Decisions already taken: Go engine runs as a process (not linked into Swift). IDL deferred until a second face needs it;
the contract for v0 is "one CLI subcommand = one engine function = one service endpoint, same names, JSON shapes". Not
for the App Store. Embedding via a sidecar worker, no Ollama. Naming: SessionKit, LlamaRuntime, SessionVisualizer.
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
4. `skit search <words>` finds turns across all archived sessions by keyword (FTS5). Meaning search is v0.5.
5. `skit serve` exposes the same operations over HTTP on a Unix socket.
6. SessionVisualizer (Swift, SwiftPM, one window) lists sessions and shows one timeline with stats, fed by `serve`.

## Repo layout (`claude-code-session-visualizer/`)

```
go.mod                          module github.com/juan7732/claude-code-session-visualizer   (Go 1.25)
cmd/skit/                       CLI entry (binary `skit`); internal/cli/ holds the Cobra commands. Subcommands: list, show, stats, archive, search, serve, doctor, describe
sessionkit/                     the engine, importable. No I/O opinions.
  transcript/                   JSONL reader → Record, Session, Turn, ToolCall, Compaction, Subagent. The parser.
  catalog/                      discovers sessions on disk (~/.claude/projects, companion dirs, sessions/<pid>.json, history.jsonl)
  stats/                        usage summation, pricing table, cost reconciliation against cost-state
  store/                        SQLite archive + index (modernc.org/sqlite, pure Go, FTS5 on). Schema versioned.
  search/                       keyword now; hybrid scorer (DigUp's z-scaled meaning + coverage) when vectors arrive
  embed/                        Embedder interface + JSON-lines worker client (DigUp's protocol). No implementation in v0.
  serve/                        HTTP handlers over a Unix socket, thin wrappers over the packages above
internal/testdata/sessions/     fixtures + expected.json (parser eval); tools/redact makes the redacted real one
test/integration/               hermetic dockerized end-to-end suite (ergo's harness pattern): real binary, temp HOME, seeded ~/.claude
justfile                        build, test, integration, fmt, vet, check, run (ergo's shape)
docs/                           source of truth: tenets.md, architecture.md, plan-v0.md, the promoted sessions-study notes,
                                roadmap.md (from ideas.md), decisions/0001-go-engine-as-a-process.md, 0002-idl-deferred.md
client/SessionVisualizer/       SwiftPM app (M6)
runtime/LlamaRuntime/           Swift embedding worker (v0.5)
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

**M3 Archive + keyword search (DONE).** `store`: `sessions`, `turns`, `segments` (one per content block, with `kind`,
`modality`, `loc`), `fts` over segment text, `meta` with schema version + fingerprint. `archive` ingests new or changed
sessions incrementally by byte offset, keeps the raw JSONL lines (lossless, zstd-compressed) per session minus
`api-request*` unless debug mode is on, records `session-owner`, and respects the debug-mode setting for `api-request*`.
`search` = FTS5 + bm25 with DigUp's term rules (stopwords, prefix on the last word, lookup detection for ids). Index
location `~/.sessionkit/` (never under ~/Library).

**M4 Serve.** `serve --socket <path>`: `GET /sessions`, `GET /sessions/{id}`, `GET /sessions/{id}/stats`,
`GET /search?q=`, `GET /status`, `POST /archive`. Same JSON as the CLI's `--json`. Hand-written, versioned under `/v0/`.
Watches `~/.claude/projects` with fsnotify so the archive stays current; a hooks installer lands later.

**M5 Embedding spike.** Build llama.cpp with Metal, run `embeddinggemma-2-Q8_0.gguf` text-only through `llama-embedding`
on a few hundred real turns. Measure load time and vectors/sec. Decide the worker implementation (Swift `LlamaRuntime`
lifted from DigUp's design vs a C++ worker) and write `docs/decisions/0003-embedding-worker.md`. No product code.

**M6 Swift client.** SwiftPM executable `SessionVisualizer`, macOS 14+. Starts `skit serve`, talks over the socket. Two
views: session list (grouped by project, sortable by last activity/cost) and session timeline (turns as rows, tool calls
inline, compaction cuts, subagent lanes collapsed, context-window curve as a header chart, images shown inline).
`build.sh` modelled on DigUp's for a signed `.app` with `skit` in `Contents/Helpers/`.

v0.5 after that: hybrid meaning search with the worker, image tiers B and C, hooks installer, export.

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

## Inputs

- `sessions-study/02-record-anatomy.md`, `03-stats-and-cost.md`, `04-working-with-sessions.md`, `06-subagents.md`,
  `07-archive-sizing.md`, `ideas.md`, `tools/inspect.py`
- `digup-study/03-index-and-search.md`, `07-what-transfers.md`
- `engineering/designs/claude-code-session-visualizer/vision.md`, `engineering/practices/tool-first-ai-development.md`

## Progress

- M0 executed 2026-11-08: repo scaffolded, `skit doctor` and `skit describe` working, justfile, dockerized integration
  harness, CI, docs promoted, tenets written. First commit made, not pushed.
- Next: M1 parser.
