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

Added with M8 (2026-11-10), for the Transcript:

- `result_head` and `result_bytes` on every answered tool call in the session document: the first line of what came
  back, shortened to 200 characters, and the result's full size. A transcript row can say what shaped the next step
  without fetching the result; the full text stays on `/actions/{n}`.
- Lists in the session document and in stats are always lists, never `null`: a session with no prompts has an empty list
  of prompts.

Added with M9 (2026-11-10), for the Summary, Search and export:

- `commits` in the relations: the commits the session made (below).
- `in_turns` in stats: the part of `duration` spent inside turns. The rest is the session waiting for its human.
- `skit export <session> [--turn N] [--thinking] [--out file]` and `GET /v0/sessions/{id}/export?format=markdown&turn=`:
  the session, or one turn, as Markdown. The route answers `text/markdown`, the one text route besides images. The app's
  "Export Session as Markdown" and "Copy Turn as Markdown" are this text, so the CLI and the app write the same thing.
- `skit show <session> --agent <id> --action N` and `GET /v0/sessions/{id}/actions/{n}?agent=<id>`: one step of a
  subagent with the full text of its results, in the shape of a parent action.

Opening a session, made fast (2026-11-10, issue #2). Measured on the largest session on the development machine (166 MB
transcript, 255 actions), through the background agent:

|                                     | before | after  |
| ----------------------------------- | ------ | ------ |
| Document, session not in memory     | 2.7 s  | 0.41 s |
| Document, session in memory         | 190 ms | 7 ms   |
| Relations, first call after a parse | 490 ms | 61 ms  |
| Relations, again                    | 490 ms | 1 ms   |

- Transcript lines are decoded in parallel (`transcript.ReadAll`): 1.93 s → 0.38 s for that file on 16 cores.
- The relations and the encoded session document are kept with the parsed session in `skit serve`'s cache and derived
  again only when the transcript changes. When an ingest re-parses a session a reader has open, both are made ready
  before the reader asks.
- `writesTo` looks at what stands before each mention of a path, where it ran one pattern per path over the whole
  command. Same files and writes on both sessions checked (201 and 112, 192 and 46).
- The agent runs as an interactive process, not a background one (ADR 0009): throttled, it took six times as long.
- `skit serve` answers in compact JSON. `skit <command> --json` prints the same shapes indented.

Added with M11 (2026-11-10), for the Timeline:

- `start` on every span, and a corrected reading of what a span means (below).
- `skit time <session> [--top N]` and `GET /v0/sessions/{id}/time?top=`: where the wall time went (below).

## Relations

`Session.Relations()` derives, on read:

- **spans**: per action, three stretches. The model worked from `start` (the turn's start, or the end of the action
  before) until `gen_end`: waiting for the response, thinking and writing. Its tools ran from `gen_end` until
  `tools_end`. The next action of the turn began at `end`; for an action that `said` something, `tools_end` to `end` is
  the agent waiting to be brought back by a hand-back or a notification. `at` is when the action's first block was
  complete. This is what the Timeline draws and the Score canvas will.
- **tasks**: commands started in the background (a result saying "running in background with ID", or
  `run_in_background`), every later call that read the task's output, the call that stopped it, and the output as last
  read.
- **handbacks**: for each subagent, the first action of the parent that started after the subagent finished, with the
  subagent's hand-back message.
- **retries**: a failed tool call and the next call of the same tool in a later action of the same turn.
- **files**: paths read or written, from `Read`/`Write`/`Edit` inputs and from paths in shell commands (found by file
  extension; a redirect, `tee`, `sed -i`, `cp`, `mv` or `touch` counts as a write).
- **outside**: web hosts fetched, web searches, skills and MCP connectors.
- **commits**: each `git commit` at a command position in a Bash call that did not fail, with the call that ran it. The
  subject is the first line of the message (`-m "…"`, or a heredoc inside `"$(cat <<'EOF' …)"`). The id (`sha`) is there
  only when the output named the commit: git's own `[main 2b4b1ec] Subject` line, or a `git log --oneline` line that
  starts with the subject. Agents usually commit with `-q`, so the command is the evidence and the id is often absent.
  "nothing to commit" in the output and `--dry-run` are not commits.
- **events**: API errors (system records) and messages Claude Code wrote itself, each with its time and turn.

Relations are heuristics over tool inputs and results. They are derived from the parsed session and never written to the
index, so they can improve without a re-index; `skit serve` keeps them in memory beside the parsed session.

## Where the time went

`skit time` (`stats.TimeOf`) splits a session's wall time, in seconds, so that the parts add up:

```
wall      = waiting for you + waiting for background work + in turns
in turns  = the model + tools + subagents + waiting for a hand-back
```

- **Outside turns** the session waited: for you when the next turn is a prompt of yours, for background work when a
  notification started it.
- **The model** is every span's `start` to `gen_end`, and what is left of a turn after its last action.
- **Tools** is `gen_end` to `tools_end`; the part covered by calls that ran a subagent is **subagents**.
- **Waiting** is `tools_end` to `end` of an action that spoke.

Then the same split per turn (`turns`), the slowest tool calls with what each was for (`slowest_calls`) and the longest
waits between turns (`longest_waits`); `--top` bounds those two lists, 10 by default.

Why the time before an action's first block is the model's: a transcript stamps a block when it is complete, so an
action that is one long `Write` has nearly all of its generation before its own timestamp. Measured on real sessions
(2026-11-10): a session with no subagent and no background task had 1430 s in the gaps after `tools_end`, as much as
between `at` and `gen_end`; one 394 s gap came before an action of 47k output tokens; and the time from each prompt to
the first action (650 to 1271 s a session) was in no span. The mock, and this document before M11, called those gaps
"waiting on a subagent, a task or the human". They are not.

What the split cannot see: a tool call that waited for the human's permission counts as tool time, because a transcript
does not record that wait. The command and the app both say so.

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
