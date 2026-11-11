# Contributing

Thank you for looking. This is one person's project, shared as it comes. Bug reports are welcome, and so are fixes. For
anything larger than a fix, open an issue before writing code: the [tenets](docs/tenets.md) settle most questions here,
and sometimes the answer they give is no.

Two things are settled and are not worth a pull request:

- **Apple silicon Macs only.** The engine's tests run on Linux, but no other platform is supported and there is no app
  elsewhere.
- **Nothing leaves the machine.** No telemetry, no update check, no feature that needs someone's server.

## Never commit a real session

Transcripts hold file contents, command output, paths and, by accident, secrets. Nobody's real session belongs in this
repository, yours included: not as a fixture, not in a test, not in an issue, not in a screenshot.

- **A fixture** is either written by hand (`internal/testdata/sessions/synthetic-basics`) or a real transcript passed
  through the redactor, which keeps structure, ids, times and numbers and masks every string:
  `go run ./internal/tools/redact <session.jsonl> <out-dir>`. Read the result before you commit it.
- **A screenshot** comes from the made-up home: `docs/launch/tools/shots.sh` (see
  [`docs/launch/`](docs/launch/README.md)).
- **The pre-commit hook** refuses a staged line that looks like a key or a token. It is a net, not a licence.

## Reporting a bug

Open an issue with:

- What you did, what you expected, and what happened.
- `skit --version`, the macOS version, and the Claude Code version the session came from.
- The output of `skit doctor --json`. It contains paths under your home; look it over first.
- For a session that is read wrongly: the smallest redacted transcript that shows it (the redactor above), or the record
  types and counts if you cannot share even that. Never the raw transcript.

The transcript format is undocumented and changes with Claude Code releases, so "it broke after an update" is a useful
report all by itself.

For a security problem, please do not open a public issue. Report it privately through GitHub's private vulnerability
reporting: <https://github.com/juan7732/claude-code-session-visualizer/security/advisories/new>.

## Building

You need an Apple silicon Mac, Go 1.26 or later, Swift 6.2 or later (Xcode, or only the Command Line Tools),
[just](https://github.com/casey/just), and Node for Prettier. Docker is needed for the hermetic integration suite;
[staticcheck](https://staticcheck.dev) for `just lint`.

```sh
just setup               # once: the git hooks (gofmt, Prettier, the key check) and Prettier itself
just build               # bin/skit
just run doctor --json   # build and run with arguments
just client-run          # build the app (debug) and launch it
```

`just client-run` attaches to whatever archiver is already serving. To try a change without touching your own archive,
give the engine a home of its own:

```sh
SKIT_HOME=/tmp/skit-try bin/skit serve &
SKIT_HOME=/tmp/skit-try client/SessionVisualizer/.build/debug/SessionVisualizer
```

## Testing

```sh
just test                # the engine's unit tests
just integration-local   # the end-to-end suite against a local build
just check               # what CI runs for the engine: tidy, format, vet, lint, race tests, integration in Docker
just client-test         # the app's tests: contract, transport, state
just client-contract     # the same, against responses recorded from this checkout's engine
```

Run `just check`, and `just client-contract` if you touched the app or a JSON shape, before you open a pull request. CI
runs the same three jobs: the engine, the integration suite, the client.

How the tests are laid out:

- **Unit tests sit beside the package.** Counts are pinned by fixtures: `internal/testdata/sessions/<name>/` holds a
  transcript and an `expected.json` written by an independent script (`internal/tools/expected/expected.py`). A parser
  change that shifts a number fails before it ships.
- **The integration suite runs the real binary** in a temporary home with a seeded `~/.claude`. External tools (`ps`,
  `lsof`, `launchctl`) are stood in for by scripts on `PATH`. Internal packages are never mocked.
- **The app's contract is recorded, not written.** `client/SessionVisualizer/Scripts/record-fixtures.sh` serves a
  fixture from a throwaway home and saves what the engine really answers; the Swift models must decode it. When you
  change a shape on purpose, run `just client-fixtures` and commit the new recording with the change.

## What a change needs

- **The engine first.** The app never parses a transcript or derives a number. What a view needs becomes an engine
  function, a `skit` command with `--json`, and a `/v0` route, in that order; then the view.
- **Every read command takes `--json`,** with errors as JSON on stderr when it is set, and `skit describe` must list
  every command and flag: it is how an agent learns the tool.
- **Never write under `~/.claude`.** Claude Code's files are input. What this tool keeps goes in `~/.sessionkit/`.
- **Keep [`PRIVACY.md`](PRIVACY.md) true.** A change to what is read, stored or sent changes that file in the same pull
  request.
- **Exact or absent.** A number that cannot be computed from the records is shown as unknown, not estimated.
- **Tests with the change,** and the docs it makes untrue updated in the same pull request. `docs/` is the source of
  truth; `docs/plan-v0.md` says what is in scope.
- **Mark judgment calls** in the code: `// DECISION:` (chosen among alternatives, with the reason), `// REVIEW:`
  (unsure), `// SPEC:` (the doc that forced it), `// TODO:` (a known gap).
- **Formatting is not a discussion.** Go through gofmt, docs and config through Prettier; `just fmt` does both.
- **No time estimates,** in docs, issues or comments. Things are done when they are right.

Engine code lives under `sessionkit/` and has no opinions about input and output; `internal/cli/` only parses, calls and
prints. [`docs/architecture.md`](docs/architecture.md) has the boundaries, and
[`client/SessionVisualizer/README.md`](client/SessionVisualizer/README.md) the app's own rules.

## Pull requests

- One change per pull request, small enough to read in a sitting.
- Say what changed and why, and how you checked it. A picture for anything visible, from the made-up home.
- Plain commit messages. No generated-by or co-author trailers from tools.
- If you work with a coding agent, [`AGENTS.md`](AGENTS.md) holds these conventions in the form it reads. You answer for
  what you send, whoever typed it.

By contributing you agree that your work is released under the project's [MIT licence](LICENSE).
