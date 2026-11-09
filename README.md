# skit

Browse, archive and search your Claude Code sessions. Claude Code keeps transcripts under `~/.claude/projects` and
deletes them after 30 days by default; skit reads them, keeps a durable copy in `~/.sessionkit/`, shows a session as a
timeline with its stats, and searches across all of them. Agents can use every command with `--json`.

Status: M0. `skit doctor` and `skit describe` work; the parser is next. See `docs/plan-v0.md`.

```
skit doctor            where Claude Code keeps sessions, retention setting, live sessions, disk use
skit describe          machine-readable manifest of every command and flag (for agents)
skit --help
```

## Build and test
Requires Go 1.26 and [just](https://github.com/casey/just). Docker for the hermetic integration suite.
```
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
