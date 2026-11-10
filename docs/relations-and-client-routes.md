# Relations and the routes the client needs

The UX mocks (`ux-mocks/NOTES.md`, iterations 7 to 13) mined several things from the session document on the client.
They now live in the engine so the CLI, the API and the Swift client agree. Each has a `--json` shape first and a `/v0`
route that returns the same document.

| What                            | CLI                                                           | Route                                                                  |
| ------------------------------- | ------------------------------------------------------------- | ---------------------------------------------------------------------- |
| Relations of a session          | `skit relations <session>`                                    | `GET /v0/sessions/{id}/relations`                                      |
| Images, list and bytes          | `skit images <session> [--extract N --out file]`              | `GET /v0/sessions/{id}/images`, `/images/{n}`                          |
| Pin, tags and notes             | `skit annotate <session> [--pin] [--tag t] [--note key=text]` | `GET` and `PATCH /v0/sessions/{id}/annotations`, `GET /v0/annotations` |
| Claude Code's own configuration | `skit claude [--root dir] [--flags]`                          | `GET /v0/claude?root=`                                                 |
| Working directory per action    | `cwd` on every action in `skit show --json`                   | same field on `/v0/sessions/{id}`                                      |

Added with M6 (2026-11-10), for the client as well:

- `rewound` on prompts, actions and turns in the session document, and `rewound_turns`, `rewound_actions`,
  `rewound_usage` in stats: work on a branch the conversation left (`stats-and-cost.md`).
- `GET /v0/archive/verify` (`skit archive --verify`): every archived copy checked against the index.
- `cached_sessions` on `/v0/status`. A session is parsed once and kept while it is being read, so `/turns/{n}` and
  `/actions/{n}` answer in about a millisecond after the first request.
- `skit service status --json`: whether the background agent that runs `serve` is installed and running.

## Relations

`Session.Relations()` derives, on read:

- **spans**: per action, when the model stopped writing (`gen_end`), when its tools finished (`tools_end`) and when the
  next action of the turn began (`end`). The gap after `tools_end` is waiting: on a subagent, a background task, or the
  human. This is what the Score canvas and the Timeline draw.
- **tasks**: commands started in the background (a result saying "running in background with ID", or
  `run_in_background`), every later call that read the task's output, the call that stopped it, and the output as last
  read.
- **handbacks**: for each subagent, the first action of the parent that started after the subagent finished, with the
  subagent's hand-back message.
- **retries**: a failed tool call and the next call of the same tool in a later action of the same turn.
- **files**: paths read or written, from `Read`/`Write`/`Edit` inputs and from paths in shell commands (found by file
  extension; a redirect, `tee`, `sed -i`, `cp`, `mv` or `touch` counts as a write).
- **outside**: web hosts fetched, web searches, skills and MCP connectors.
- **events**: API errors (system records) and messages Claude Code wrote itself, each with its time and turn.

Relations are heuristics over tool inputs and results, computed on read and not stored, so they can improve without a
re-index.

## Annotations

`~/.sessionkit/annotations.json` holds what the human adds: a pin, tags, and notes keyed by `session`, `turn:N`,
`action:N` or `tool:<id>`. It is a plain file apart from the index and the archive, so deleting `skit.sqlite` or
re-archiving never loses it.

## Claude Code's configuration

`skit claude` is read-only and whitelisted. It reports the settings layers (user, user local, and for each `--root` the
project and project-local files) with the value in effect per key and the layers it overrides; the experiment
assignments cached in `~/.claude.json` (experiment id, variation, value); the cached feature flags; known projects with
their MCP server names; memory files; skills on disk and their use counts. The account, tokens and ids in
`~/.claude.json` are never copied: the snapshot says only whether each is set. Managed policy and command-line flags are
not readable from here.

## Not done yet

- A file's content at a turn and a diff per write, from `file-history-snapshot` and `file-history-delta` records.
- Parent and child session ids for forks and resumes.
- The model's context-window limit beside `models`.
- Snapshots of experiments and flags over time, to see what changed when sessions began to misbehave.
- A `file` search kind over the files relation.
