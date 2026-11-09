# Working with sessions

_Promoted from the workspace `sessions-study` scratchpad on 2026-11-08 (observed on Claude Code 2.1.289–2.1.319)._

## Parsing rules (for the Go parser)
1. **Stream the file line by line.** Lines reach 1 MB+ (images, big tool results). Never load whole files eagerly.
2. **Dispatch on `type`, keep unknowns.** Store unknown types as opaque events with their timestamp when present.
3. **Build the tree by `uuid`/`parentUuid`;** find the tip via `last-prompt.leafUuid`, else the latest timestamp.
   Main chain = walk up from the tip. Mark compaction roots via `logicalParentUuid`.
4. **Reassemble turns by `requestId`.** Order blocks by `apiBlockIndex`. Take `usage` once. Pair `tool_use.id` with the
   later `tool_result.tool_use_id`; a `tool_use` with no result is "in flight" or interrupted.
5. **Resolve spilled tool results** from `<session>/tool-results/<id>.txt` when the result text names one.
6. **Treat the file as live.** Claude Code appends while a session runs. Use `sessions/<pid>.json` to know which
   sessions are live, and tail from the last parsed byte offset. Partial last lines happen; keep them for the next read.
7. **Record provenance:** Claude Code `version` per record, so a format change is diagnosable per version.
8. **Skip by default** `api-request`, `api-request-blob`, `api-request-shape`, `queue-operation`, `atis-latch`,
   `bridge-session` for the timeline. Keep `session-owner` (account/org). **Debug mode** (a setting, per session or
   global) ingests `api-request*` too, for a "what exactly did the model see" view: system prompt, tool list,
   parameters, cache breakpoints. Expect roughly 2× storage for sessions captured in debug mode.
9. **Parser eval from day one:** copies of real sessions as fixtures, expected counts (prompts, requests, tool calls,
   tokens, compactions, images), run in CI. A Claude Code update then fails a test instead of silently miscounting.

## Finding and identifying sessions
- Enumerate `~/.claude/projects/*/*.jsonl`, plus `.orphaned-*` and `.superseded-*` variants, plus `<session>/subagents/*.jsonl`.
- Identity = `sessionId` (file name), display = last `ai-title`, or the session `name` from `sessions/<pid>.json`
  while live (set by `claude -n` or `/rename`), else the first human prompt.
- Resume handles we can offer the user: `claude --resume <id|name|absolute path to .jsonl>`, `--fork-session` to
  branch, `-c` for the latest in a cwd, `--from-pr <n|url>` when a `pr-link` record exists. A "Resume in terminal"
  button is a one-liner.

## Triggers instead of polling
Claude Code hooks (`SessionStart`, `Stop`, `SessionEnd`, `PostCompact`, `PostToolUse`) receive `session_id`,
`transcript_path` and `cwd` on stdin. A tiny hook that hands `transcript_path` to the engine gives near-real-time
indexing with zero file watching. Requirements: the **UI installs and removes the hooks** (it edits
`~/.claude/settings.json` `hooks` entries, showing the diff first); the hook is **deterministic and cheap**: a small
compiled binary or one shell line that appends a line to a spool file or writes to a Unix socket and exits in
milliseconds, never waits on the engine, and declares a short `timeout`. Dev experience must not notice it. Fall back to
watching `~/.claude/projects` (FSEvents from the Swift client, or `fsnotify` in Go) when hooks are not installed.

## Alternative feed: print mode
`claude -p --output-format stream-json --verbose` emits the same message shapes live, and `--forward-subagent-text`
tags subagent output with `parent_tool_use_id`. Useful for a demo or for tests, not needed for the product.

## Ideas
See `roadmap.md`.
