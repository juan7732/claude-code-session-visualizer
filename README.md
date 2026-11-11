# skit

Browse, archive and search your Claude Code sessions. Claude Code keeps transcripts under `~/.claude/projects` and
deletes them after 30 days by default; skit reads them, keeps a durable lossless copy in `~/.sessionkit/`, shows a
session as a timeline with its stats, and searches across all of them. Agents can use every command with `--json`.

Status: M6. Read path, durable archive, keyword search and the service mode work end to end on real sessions, and the
archive is hardened against losing lines. The native Swift client (M7 onwards) is next. See `docs/plan-v0.md`.

```
skit doctor                    where Claude Code keeps sessions, retention setting, live sessions, disk use, index size,
                               whether the background agent runs and how many sessions still wait to be archived
skit projects                  projects (start directories) that have sessions
skit list [-p slug] [-n N]     sessions, most recent first, with prompts, requests, tool calls, tokens, cost, title
skit show <id> [--turn N]      one session as a timeline grouped by turn; --turn N prints an agent turn with all its
                               actions and tool results, --action N one action, --thinking adds thinking text;
                               --context adds injected prompt blocks and every attachment Claude Code added
skit export <id> [--turn N]    the session, or one turn, as Markdown: what was asked, what was said, one line per tool call
skit stats <id> [--context]    tokens once per request (subagents rolled in), models, tools, compactions, context curve
skit time <id> [--top N]       where the wall time went: waiting for you or for background work against in turns; in turns
                               the model, tools, subagents, waiting for a hand-back; slowest calls, longest waits
skit context <id> [--action N] what the model received for an action: system prompt, tool definitions, messages (CLAUDE.md
                               labelled), injected attachments, each with size, next to the reported token counts; --show prints one;
                               --compaction N explains a compaction: before, summary sections, preserved, re-injected, after
skit archive [id...]           copy sessions losslessly into ~/.sessionkit/archive (raw JSONL, zstd) and index them for search;
                               --verify checks every copy against the index and changes nothing
skit search <words> [--kind K] find turns across archived sessions; a query of ids or codes weighs exact words more;
                               --mode meaning ranks by what the text says, shared words or not (after `skit embed`), and
                               says so when nothing is close; --mode hybrid lists those first and the keyword hits after;
                               --session, --project, --kind, --no-tools narrow any mode
skit embed                     give archived prose vectors for meaning search, with EmbeddingGemma 2 in a local
                               llama-server; the first run downloads the model once (310 MB, checksum verified)
skit eval <queries.json>       measure search against queries whose answers are known: R@1, R@5, R@10, MRR per mode
skit serve [--socket P]        the same operations over HTTP on a Unix socket (/v0/…); watches ~/.claude and archives
skit service install           keep `skit serve` running from login on (a launchd agent), so sessions are archived
                               without being asked; `service status`, `service uninstall`
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
plain JSONL under zstd: `zstd -dc <file>` gives the transcript back without skit. It never ends up holding less than it
did: if a transcript shrinks or is replaced, the fuller copy stays beside the new one as `<copy>.prev-<time>`
(`docs/decisions/0008-the-archive-never-shrinks.md`).

Meaning search (`docs/meaning-search.md`): after `skit embed` has downloaded the model once,
`skit search --mode meaning` and `--mode hybrid` work, and `skit serve` keeps the vectors current by itself. It needs
`llama-server` (`brew install llama.cpp`). Nothing leaves the machine; the only network use in skit is that one
download.

Apple silicon Macs only. It is shared as it comes, without warranty.

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

## The app

`client/SessionVisualizer` is the native macOS client (SwiftUI, a Swift package; Xcode not required).

```
just client-run         # build and launch
just client-test        # contract, transport and state tests
just client-contract    # the same, against /v0 recorded from this checkout's engine
just client-app         # SessionVisualizer.app with this checkout's skit inside, signed (ad hoc unless SIGN_IDENTITY is set)
just client-app-install # build it and put it in /Applications
```

The app in /Applications opens `skit-visualizer://session/<id>?view=transcript&action=60` links (Edit › Copy Link) and,
on a Mac where nothing is serving yet, installs the background agent for the `skit` inside it
(`docs/decisions/0011-the-app-bundle-and-its-links.md`).

## Layout

`cmd/skit` (entry), `internal/cli` (Cobra commands), `sessionkit/` (the engine: catalog, transcript, stats, store,
archive, search, export, embed, serve, service), `client/SessionVisualizer` (the Swift app), `test/integration`
(hermetic suite), `docs/` (source of truth, start with `docs/tenets.md`).

## License

MIT.
