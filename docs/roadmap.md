# Roadmap source

Unranked. Each line is a candidate for the visualizer roadmap, grounded in what the session files actually contain.
Added 2026-11-07, extended after Juan's review.

## Archive and ownership

- **Forked sessions.** `--fork-session` and `/rewind` copy history into a new transcript. The archive captures the fork
  as an event (shared prefix of record uuids with another session) so counts can treat the shared part once and the
  timeline can show where the fork happened.

- **Long-term archive.** Claude Code sweeps transcripts after `cleanupPeriodDays`. The visualizer's index is the durable
  copy: ingest early, keep parsed turns, stats, text, and image bytes, and let the original be deleted. Sizing in
  `archive-sizing.md`.
- **Retention guard.** Show days until each session is swept, and whether it has been archived.
- **Central session service (separate repo, future).** A service that runs that receives session state from every laptop
  and device, so one view covers all machines. Engine pushes parsed sessions or raw transcripts; service stores and
  serves the same API as the local engine. Same IDL, different host.
- **Export** of one session to self-contained HTML or Markdown.

## Timeline views

- **Context-window curve** per request, cache reads vs cache creation stacked, compactions as drops
  (`stats-and-cost.md`).
- **Tool call heatmap** by tool and time; long Bash gaps; denied permissions as marks.
- **Subagent lanes** nested under the `Agent` tool call that spawned them (`subagents.md`).
- **Compaction summaries** as chapter markers and as search anchors; a "story so far" view from summaries only.
- **Files-touched sidebar** from `file-history-*`, with before/after diffs from the `@vN` snapshots.
- **Error timeline**: `api_error` retries and tool failures.
- **Injected-context lane** (attachments, `isMeta` messages). Off by default, a setting.
- **Debug mode** that captures and shows `api-request*` records: the exact system prompt, tool list, parameters and
  cache breakpoints of each request. Off by default; opt in per session or globally.

## Search

- **Cross-session search** of prompts from `history.jsonl`, even when the transcript is gone.
- **Image search**: proxy text now, OCR to keywords with the Swift client, true image vectors with the EmbeddingGemma 2
  encoder (`images-and-modalities.md`). Other modalities later for users who feed audio or documents through MCP tools.
- Session card = slug + title + cwd + project; `slug` is stable, titles change.

## Agents

- **Discoverable progression.** `skit describe` lists one line per command; `skit describe <command>` gives the full
  detail with examples; `--help` stays the human form. Agents spend tokens only on what they need. Open question on the
  best LLM-readable shape in the engineering repo's `thoughts/2026-11-08-llm-readable-output.md`: count tokens across
  JSON, compact JSON, aligned text and Markdown, then run an accuracy-per-token eval before adding any third mode.
- **Agent manifest completeness check** in CI: every command and flag appears in `describe`, every read command has
  `--json`.

## Workspace and repository context (optional plugins)

- **ergo workspace integration.** An optional extension that knows the ergo workspace a session ran in: how the
  workspace looked (its TOML, repos, groups and tags), which files in it were created or changed per turn, captured as
  workspace snapshots alongside the session, and workspace-level stats (files touched per repo, turns per repo, cost per
  repo). Maps `cwd` and tool-input paths onto ergo repos by reading `~/.ergo/workspaces/*.toml`.
- **Git visibility.** A companion extension that ties git state into the timeline: branch and commit at each turn, diffs
  produced between turns, commits and PRs made during the session (`pr-link` records), and a per-turn view of the
  working tree. Reuses the `file-history-*` snapshots where they exist.
- Both are plugins over the engine, not engine features: the core stays about transcripts.

## Live and integration

- **Live view** from `~/.claude/sessions/<pid>.json`, tailing the transcript.
- **Hooks installer** in the UI: writes `SessionStart`/`Stop`/`PostCompact`/`SessionEnd` hooks that hand the
  `transcript_path` to the engine. The hook must be deterministic and near-zero cost: a tiny binary or shell line that
  writes one line to a socket or spool file and exits in milliseconds, never blocking Claude Code, with a timeout.
  Fallback: file watching.
- **Resume in terminal** button: `claude --resume <id>`, `--fork-session`, `--from-pr`.
- **Project registry link**: feed session summaries into `project-central`.
