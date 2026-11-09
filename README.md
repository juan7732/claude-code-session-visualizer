# skit

Browse, archive and search your Claude Code sessions. Claude Code keeps transcripts under `~/.claude/projects` and
deletes them after 30 days by default; skit reads them, keeps a durable copy in `~/.sessionkit/`, shows a session as a
timeline with its stats, and searches across all of them. Agents can use every command with `--json`.

Status: M2. The read path works end to end on real sessions; the archive and keyword search (M3) are next. See
`docs/plan-v0.md`.

```
skit doctor                where Claude Code keeps sessions, retention setting, live sessions, disk use
skit projects              projects (start directories) that have sessions
skit list [-p slug] [-n N] sessions, most recent first, with prompts, requests, tool calls, tokens, cost, title
skit show <id> [--turn N]  one session as a timeline; --turn prints a request in full with its tool results;
                           --context adds injected prompt blocks and every attachment Claude Code added
skit stats <id> [--context] tokens once per request (subagents rolled in), models, tools, compactions, context curve
skit describe              machine-readable manifest of every command and flag (for agents)
```

Every read command takes `--json`. `<id>` is a session id, a unique prefix, or the path to a `.jsonl` transcript. `list`
caches per-session summaries under `~/.sessionkit/cache/` (`--no-cache` to bypass).

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

`cmd/skit` (entry), `internal/cli` (Cobra commands), `sessionkit/` (the engine), `test/integration` (hermetic suite),
`docs/` (source of truth, start with `docs/tenets.md`). Swift client and embedding worker arrive in later milestones.

## License

MIT.
