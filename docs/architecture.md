# Architecture

skit follows the tool-first pattern (`engineering/practices/tool-first-ai-development.md`): a CLI an agent can use on
day one, over an engine library, with more faces added as they earn their place.

```
cmd/skit          binary entry: version wiring, exit code
internal/cli      Cobra commands. Parse flags → call sessionkit → print. --json on every read command.
sessionkit/       the engine (import path …/sessionkit/<pkg>). No printing, no flags, no env reads.
  catalog         find Claude Code's data: dir, projects, session files, subagents, live sessions, retention
  home            skit's own directory: $SKIT_HOME, else ~/.sessionkit
  transcript      JSONL → records → uuid tree → turns (one per request), tool call pairs, compactions, subagents
  stats           per-session summary: usage once per request with subagents rolled in, models, tools, compactions,
                  context-window curve, Claude Code's cost figure (pricing table: M3)
  store           the index: ~/.sessionkit/skit.sqlite (pure-Go SQLite). sessions (summary JSON + source fingerprint +
                  archive state), segments (one per content block), fts (FTS5, porter). Schema versioned. Also the
                  summary cache: list reads a session's summary from here while its source fingerprint matches.
  archive         the durable copy: ~/.sessionkit/archive/<project>/<id>.jsonl.zst, raw lines appended by byte offset
                  as a session grows, every record kept (--strip-requests drops api-request*, ADR 0007), subagents and
                  spilled tool results mirrored. It never ends up holding less than it did: checked appends, atomic
                  rewrites, a fuller earlier copy kept as <copy>.prev-<time>, `archive --verify` (ADR 0008).
                  Load() rebuilds a Session from the copy when Claude Code has deleted the source. Resolve() keeps
                  parsed sessions in a cache for long-lived processes; cached sessions are read-only.
  search          FTS5 + bm25 candidates, coverage of the query's words, lookup queries weigh words more; v0.5 adds
                  vectors with DigUp's z-scaled fusion
  embed           (v0.5) client for the llama-server sidecar (OpenAI /v1/embeddings), process management, model
                  download into ~/.sessionkit/models/ (decisions/0005-embedding-worker.md)
  serve           HTTP on a Unix socket ($SKIT_HOME/skit.sock), routes under /v0/, same JSON as --json; the same engine
                  functions the CLI calls (archive.List/Resolve/Document, stats, search, Ingest). Requests run
                  concurrently over cached sessions (256 MiB of transcripts, dropped after ten idle minutes). Watches
                  ~/.claude/projects with fsnotify and archives a session once its transcript settles.
client/SessionVisualizer   (M6) Swift app; talks only to `skit serve`
runtime/LlamaRuntime       (v0.5) Swift embedding worker over llama.cpp
```

## Boundaries

- **Claude Code's files are read-only input.** skit never writes under `~/.claude` or `$CLAUDE_CONFIG_DIR`.
- **The engine is a process.** The Swift client and any future web renderer talk to `skit serve` over a Unix socket. The
  process boundary is the future network boundary; the sync service reuses the same operations.
- **The archive lives in `~/.sessionkit/`.** Never under `~/Library`.
- **The embedding model runs in a sidecar worker** speaking JSON lines (DigUp's protocol), never linked into the engine.

## Data flow (v0)

```
~/.claude/projects/**.jsonl ──catalog──▶ transcript.Session ──stats──▶ CLI list/show/stats (--json)
                                             │                              ▲
                                             └──archive.Ingest──▶ ~/.sessionkit/archive/**.jsonl.zst ──archive.Load──┘ (source gone)
                                                       └──▶ ~/.sessionkit/skit.sqlite (summaries, segments, fts) ──search──▶ CLI search
                                                                                                    └──serve──▶ SessionVisualizer
```

## Testing

- Unit tests next to each package (`go test ./...`).
- Parser eval: `internal/testdata/sessions/<fixture>/` holds one transcript (plus its subagents dir) and an
  `expected.json` written by the independent Python oracle `internal/tools/expected/expected.py`; `go test` fails on
  drift. `bootstrap-session` is this project's own first Claude Code session, redacted by `internal/tools/redact`
  (structure, ids, timestamps and numbers kept; every string masked; images replaced by a 1×1 PNG; `api-request*`
  dropped). `synthetic-basics` covers compaction, subagent, images, an unpaired tool call, an unknown record type and a
  malformed line.
- Hermetic end-to-end suite in `test/integration/`: the real binary runs in a temp HOME with a seeded `~/.claude`,
  inside Docker (`just integration`) or locally against a fresh build (`just integration-local`). Pattern from ergo.

## Conventions

- Judgment calls are marked in code: `// DECISION:` (chosen among alternatives, with reason), `// REVIEW:` (unsure),
  `// SPEC:` (cites the doc that forced it), `// TODO:` (known gap). `rg "// (DECISION|REVIEW):"` maps every one.
- Docs in this directory are the source of truth for skit. Early designs may start in the engineering repo and move
  here.
