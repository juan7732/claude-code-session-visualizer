# skit

Browse, archive and search your Claude Code sessions. Claude Code keeps transcripts under `~/.claude/projects` and
deletes them after 30 days by default; skit reads them, keeps a durable lossless copy in `~/.sessionkit/`, shows a
session as a timeline with its stats, and searches across all of them. Agents can use every command with `--json`.

Status: M4. Read path, durable archive, keyword search and the service mode work end to end on real sessions; the
embedding spike (M5) and the Swift client (M6) are next. See `docs/plan-v0.md`.

```
skit doctor                    where Claude Code keeps sessions, retention setting, live sessions, disk use, index size
skit projects                  projects (start directories) that have sessions
skit list [-p slug] [-n N]     sessions, most recent first, with prompts, requests, tool calls, tokens, cost, title
skit show <id> [--turn N]      one session as a timeline; --turn prints a request in full with its tool results;
                               --context adds injected prompt blocks and every attachment Claude Code added
skit stats <id> [--context]    tokens once per request (subagents rolled in), models, tools, compactions, context curve
skit archive [id...] [--debug] copy sessions into ~/.sessionkit/archive (raw JSONL, zstd) and index them for search
skit search <words> [--kind K] find turns across archived sessions; a query of ids or codes weighs exact words more
skit serve [--socket P]        the same operations over HTTP on a Unix socket (/v0/…); watches ~/.claude and archives
skit describe                  machine-readable manifest of every command and flag (for agents)
```

```
skit serve &
curl --unix-socket ~/.sessionkit/skit.sock http://skit/v0/status
curl --unix-socket ~/.sessionkit/skit.sock 'http://skit/v0/search?q=retention+sweep'
```

Every read command takes `--json`. `<id>` is a session id, a unique prefix, or the path to a `.jsonl` transcript.
`list`, `show` and `stats` keep working from the archive after Claude Code has deleted the source. `list` reads indexed
summaries from `~/.sessionkit/skit.sqlite` when a transcript has not changed (`--no-cache` to bypass). The archive is
plain JSONL under zstd: `zstd -dc <file>` gives the transcript back without skit.

## Build and test

Requires Go 1.26, [just](https://github.com/casey/just) and Node (for Prettier). Docker for the hermetic integration
suite.

```
just setup              # once: git hooks (gofmt + prettier on commit) and prettier
just build              # bin/skit
just test               # unit tests
just integration        # hermetic end-to-end suite in Docker
just integration-local  # same suite against a local build
just check              # everything CI runs
```

## Layout

`cmd/skit` (entry), `internal/cli` (Cobra commands), `sessionkit/` (the engine: catalog, transcript, stats, store,
archive, search), `test/integration` (hermetic suite), `docs/` (source of truth, start with `docs/tenets.md`). Swift
client and embedding worker arrive in later milestones.

## License

MIT.
