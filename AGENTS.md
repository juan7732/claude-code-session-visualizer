# AGENTS.md

Conventions for agents working in this repository.

- Read `docs/tenets.md` (tie-breaking beliefs, in priority order) and `docs/design-principles.md` before changing
  behaviour.
- Docs and config are formatted by Prettier, Go by gofmt; `just setup` installs the pre-commit hook that enforces both.
- `docs/` is the source of truth; `docs/plan-v0.md` says what is in scope now. No time estimates anywhere.
- Engine code lives under `sessionkit/` and has no I/O opinions. CLI code under `internal/cli/` only parses, calls,
  prints.
- Every read command takes `--json`; errors are JSON on stderr when `--json` is set. `skit describe` must stay complete.
- Never write under `~/.claude`. Archive data goes to `~/.sessionkit/`.
- Mark judgment calls: `// DECISION:` (chosen, with reason), `// REVIEW:` (unsure), `// SPEC:` (doc that forced it),
  `// TODO:`.
- Tests: unit tests beside packages; the hermetic suite in `test/integration/` execs the real binary in a temp HOME.
  Stub external tools with PATH shims, never mock internal packages. Run `just check` before committing.
- No attribution lines in commit messages.
