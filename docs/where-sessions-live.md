# Where sessions live

_Promoted from the workspace `sessions-study` scratchpad on 2026-11-08 (observed on Claude Code 2.1.289–2.1.319)._

## Layout (observed + official)

```
~/.claude/                                      or $CLAUDE_CONFIG_DIR
  projects/<project-slug>/                      slug = cwd with every non-alphanumeric char → "-" (e.g. -Users-juanv-ergo-workspaces-tools)
    <session-uuid>.jsonl                        THE transcript: one JSON record per line, append-only
    <session-uuid>.orphaned-<ts>-<suffix>.jsonl earlier transcript set aside (not in the picker)
    <session-uuid>.jsonl.superseded-<ts>        same idea
    <session-uuid>/                             companion dir, created lazily
      tool-results/<id>.txt                     large tool outputs spilled to files; the jsonl keeps a preview + this path
      subagents/*.jsonl                         subagent transcripts, same format (none on this machine yet)
      mcp-tasks/                                state of long-running MCP tasks
    memory/*.md + MEMORY.md                     auto memory (Claude's notes); NOT swept while non-empty
  sessions/<pid>.json (+ .key)                  LIVE registry: one file per running process: sessionId, cwd, name, status busy|idle,
                                                version, entrypoint, messagingSocketPath. Removed on exit.
  file-history/<session-uuid>/<hash>@vN         pre-edit snapshots for /rewind checkpoints (referenced from file-history-* records)
  history.jsonl                                 every prompt typed: {display, pastedContents, timestamp, project, sessionId}. Not swept.
  stats-cache.json                              daily aggregates for /usage (messageCount, sessionCount, toolCallCount, tokensByModel)
  session-env/<session-uuid>/                   per-session env metadata
  shell-snapshots/, backups/, cache/, plugins/, skills/, ide/, debug/, plans/, paste-cache/, uploads/, tasks/, usage-data/
~/.claude.json                                  app state. projects[<cwd>] has lastSessionId, lastCost, lastModelUsage,
                                                lastTotal*Tokens, lastDuration, allowedTools, mcpServers, trust flags
/private/tmp/claude-<uid>/<project-slug>/<session-uuid>/scratchpad/   per-session scratchpad (macOS); images/ beside it since 2.1.274
```

The `<project-slug>` is our free grouping key for "which workspace or repo". It is lossy (both `/` and `_` and `.` become
`-`), so recover the real path from the `cwd` field inside the records, not from the folder name.

## What Claude Code calls a "project"

A project is **the directory Claude Code was started in**, nothing more: not a git repo, not a VS Code workspace.
The slug is that absolute path; `~/.claude.json → projects` is keyed by the same path (trust, allowed tools, MCP
servers, last-session stats); project settings are read from `<cwd>/.claude/`. Consequences:

- An ergo workspace started at its root (`/Users/juanv/ergo-workspaces/tools`) is one project, whatever repos it holds.
  Started inside `tools/engineering`, it is a different project with its own transcripts and memory.
- Sub-repo work shows up in the records, not the slug: every record carries `cwd` (which can change with `/cd`) and
  `gitBranch`; tool inputs carry file paths. "Which repo was this about" is derived from paths, and the visualizer
  can map paths to ergo workspaces and repos by reading `~/.ergo/workspaces/*.toml`.
- `--worktree` sessions run in a worktree directory, so they land in a different project slug than the main checkout.

## Retention: the single most important constraint

- `cleanupPeriodDays` (default **30**, minimum 1) sweeps at startup: transcripts, companion dirs, `file-history/`,
  `plans/`, `debug/`, scratchpads, and more. Sessions started or last continued in Claude Desktop or Cowork are exempt
  by default (`desktopSessionCleanupPeriodDays`).
- `history.jsonl`, `stats-cache.json`, auto memory and `~/.claude.json` are kept.
- `claude purge [path]` deletes a project's transcripts, memory, file-history, history lines and `~/.claude.json` entry.
- `CLAUDE_CODE_SKIP_PROMPT_HISTORY=1` or `-p --no-session-persistence` stop transcripts being written at all.
- Community bug reports (unverified) describe transcripts disappearing despite a huge `cleanupPeriodDays`, and subagent
  files not being swept. Treat the directory as volatile.

**Implication for the visualizer:** our index is the durable archive. Ingest early and keep what we need (parsed turns,
stats, text for search, image thumbnails), so a session is still browsable after Claude Code deletes it. Tell the user
their retention setting and offer to raise it. Never write into `~/.claude/projects`.

## Security note
Transcripts are plaintext and contain everything a tool saw: file contents, command output, pasted text, and the
system prompt + tool definitions of every request. Anything we build that copies or indexes them inherits that
sensitivity. Keep the index under the user's own Application Support, same permissions, no network.
