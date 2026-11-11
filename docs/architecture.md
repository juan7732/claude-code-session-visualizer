# Architecture

skit follows the tool-first pattern (`engineering/practices/tool-first-ai-development.md`): a CLI an agent can use on
day one, over an engine library, with more faces added as they earn their place.

```
cmd/skit          binary entry: version wiring, exit code
internal/cli      Cobra commands. Parse flags → call sessionkit → print. --json on every read command.
sessionkit/       the engine (import path …/sessionkit/<pkg>). No printing, no flags, no env reads.
  catalog         find Claude Code's data: dir, projects, session files, subagents, live sessions, retention
  home            skit's own directory: $SKIT_HOME, else ~/.sessionkit
  transcript      JSONL → records → uuid tree → turns and their actions (one per request), tool call pairs,
                  compactions, subagents, relations; prompts and actions on rewound branches flagged
  stats           per-session summary: usage once per request with subagents rolled in, models, tools, compactions,
                  context-window curve, rewound turns and actions, Claude Code's cost figure (a pricing table is
                  decided but not built: decisions/0003, issue #1)
  store           the index: ~/.sessionkit/skit.sqlite (pure-Go SQLite). sessions (summary JSON + source fingerprint +
                  archive state), segments (one per content block), fts (FTS5, porter), chunks (a segment's prose cut
                  into pieces, each named by a hash of its text) and vectors (one per hash, 768 × float16). Schema
                  versioned. Also the summary cache: list reads a session's summary from here while its source
                  fingerprint matches.
  archive         the durable copy: ~/.sessionkit/archive/<project>/<id>.jsonl.zst, raw lines appended by byte offset
                  as a session grows, every record kept (--strip-requests drops api-request*, ADR 0007), subagents and
                  spilled tool results mirrored. It never ends up holding less than it did: checked appends, atomic
                  rewrites, a fuller earlier copy kept as <copy>.prev-<time>, `archive --verify` (ADR 0008).
                  Load() rebuilds a Session from the copy when Claude Code has deleted the source. Resolve() keeps
                  parsed sessions in a cache for long-lived processes; cached sessions are read-only. Chunk() and
                  Embed() cut prose segments and give every distinct piece a vector (meaning-search.md).
  search          by words: FTS5 + bm25 candidates, coverage of the query's words, lookup queries weigh words more.
                  By meaning: cosine of the query's vector against every stored vector, best piece per segment
                  that passes the gate. Hybrid: the meaning hits that pass the gate, then keyword's. Eval: queries
                  with known answers → R@1, R@5, R@10, MRR per mode.
  embed           the pinned model file and its one download into ~/.sessionkit/models/, the llama-server sidecar
                  (start on a loopback port with a random key, health, stop, reap one whose owner died), the client
                  for /v1/embeddings, prompt framing, the chunker, float16 vectors
                  (decisions/0005-embedding-worker.md). embed/embedtest stands in for llama-server in tests.
  export          a session, or one turn, as Markdown for a reader without skit: prompts, what was said, one line per
                  tool call, compactions marked
  service         the launchd agent that runs `skit serve` from login on: install, uninstall, status
                  (decisions/0009-background-agent.md)
  serve           HTTP on a Unix socket ($SKIT_HOME/skit.sock), routes under /v0/, same JSON as --json; the same engine
                  functions the CLI calls (archive.List/Resolve/Document, stats, search, Ingest). Requests run
                  concurrently over cached sessions (256 MiB of transcripts, dropped after ten idle minutes). Watches
                  ~/.claude/projects with fsnotify and archives a session once its transcript settles; sweeps
                  every session at start and hourly for what changed while nothing was running.
client/SessionVisualizer   (M7 onwards) the native macOS app, a Swift package: SkitKit (HTTP/1.0 over the Unix socket,
                           typed /v0 client, models) and the SwiftUI app. Talks only to `skit serve`
                           (decisions/0010-client-transport.md). build.sh makes the signed bundle with skit in
                           Contents/Helpers (decisions/0011-the-app-bundle-and-its-links.md; its README has the rest)
```

## Boundaries

- **Claude Code's files are read-only input.** skit never writes under `~/.claude` or `$CLAUDE_CONFIG_DIR`.
- **The engine is a process.** The Swift client and any future web renderer talk to `skit serve` over a Unix socket. The
  process boundary is the future network boundary; the sync service reuses the same operations.
- **The archive lives in `~/.sessionkit/`.** Never under `~/Library`.
- **The embedding model runs in a sidecar**, `llama-server` over its OpenAI-style HTTP API (ADR 0005), never linked into
  the engine.
- **One file outside skit's home:** the launchd agent's plist in `~/Library/LaunchAgents`, written only by
  `skit service install`.

## Data flow (v0)

```
~/.claude/projects/**.jsonl ──catalog──▶ transcript.Session ──stats──▶ CLI list/show/stats (--json)
                                             │                              ▲
                                             └──archive.Ingest──▶ ~/.sessionkit/archive/**.jsonl.zst ──archive.Load──┘ (source gone)
                                                       └──▶ ~/.sessionkit/skit.sqlite (summaries, segments, fts) ──search──▶ CLI search
                                                                 │   ▲                              └──serve──▶ SessionVisualizer
                                                                 └──archive.Embed──▶ llama-server (127.0.0.1) ──▶ chunks, vectors
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
