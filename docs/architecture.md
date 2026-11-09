# Architecture

skit follows the tool-first pattern (`engineering/practices/tool-first-ai-development.md`): a CLI an agent can use on
day one, over an engine library, with more faces added as they earn their place.

```
cmd/skit          binary entry: version wiring, exit code
internal/cli      Cobra commands. Parse flags → call sessionkit → print. --json on every read command.
sessionkit/       the engine (import path …/sessionkit/<pkg>). No printing, no flags, no env reads.
  catalog         find Claude Code's data: dir, projects, session files, subagents, live sessions, retention
  transcript      (M1) JSONL → records → tree → turns, tool calls, compactions, subagents
  stats           (M2) usage once per request, pricing, reconciliation with Claude Code's cost-state
  store           (M3) SQLite archive + index, ~/.sessionkit/, schema versioned
  search          (M3/v0.5) FTS5 keyword, then hybrid meaning + words
  embed           (v0.5) Embedder interface + JSON-lines worker client
  serve           (M4) HTTP over a Unix socket; same operations as the CLI
client/SessionVisualizer   (M6) Swift app; talks only to `skit serve`
runtime/LlamaRuntime       (v0.5) Swift embedding worker over llama.cpp
```

## Boundaries
- **Claude Code's files are read-only input.** skit never writes under `~/.claude` or `$CLAUDE_CONFIG_DIR`.
- **The engine is a process.** The Swift client and any future web renderer talk to `skit serve` over a Unix socket.
  The process boundary is the future network boundary; the sync service reuses the same operations.
- **The archive lives in `~/.sessionkit/`.** Never under `~/Library`.
- **The embedding model runs in a sidecar worker** speaking JSON lines (DigUp's protocol), never linked into the engine.

## Data flow (v0)
```
~/.claude/projects/**.jsonl ──catalog──▶ transcript.Session ──stats──▶ CLI list/show/stats (--json)
                                             │
                                             └──store.Archive──▶ ~/.sessionkit/skit.sqlite ──search──▶ CLI search
                                                                             └──serve──▶ SessionVisualizer
```

## Testing
- Unit tests next to each package (`go test ./...`).
- Parser eval: `internal/testdata/sessions/*` with `expected.json`; drift fails `go test`.
- Hermetic end-to-end suite in `test/integration/`: the real binary runs in a temp HOME with a seeded `~/.claude`,
  inside Docker (`just integration`) or locally against a fresh build (`just integration-local`). Pattern from ergo.

## Conventions
- Judgment calls are marked in code: `// DECISION:` (chosen among alternatives, with reason), `// REVIEW:` (unsure),
  `// SPEC:` (cites the doc that forced it), `// TODO:` (known gap). `rg "// (DECISION|REVIEW):"` maps every one.
- Docs in this directory are the source of truth for skit. Early designs may start in the engineering repo and move here.
