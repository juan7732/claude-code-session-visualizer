# Roadmap source

_Promoted from the workspace `sessions-study` scratchpad on 2026-11-08 (observed on Claude Code 2.1.289–2.1.319)._

Unranked. Each line is a candidate for the visualizer roadmap, grounded in what the session files actually contain.
Added 2026-11-07, extended after Juan's review.

## Archive and ownership
- **Long-term archive.** Claude Code sweeps transcripts after `cleanupPeriodDays`. The visualizer's index is the
  durable copy: ingest early, keep parsed turns, stats, text, and image bytes, and let the original be deleted.
  Sizing in `archive-sizing.md`.
- **Retention guard.** Show days until each session is swept, and whether it has been archived.
- **Central session service (separate repo, future).** A service Juan runs that receives session state from every
  laptop and device, so one view covers all machines. Engine pushes parsed sessions or raw transcripts; service
  stores and serves the same API as the local engine. Same IDL, different host.
- **Export** of one session to self-contained HTML or Markdown.

## Timeline views
- **Context-window curve** per request, cache reads vs cache creation stacked, compactions as drops (`stats-and-cost.md`).
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

## Live and integration
- **Live view** from `~/.claude/sessions/<pid>.json`, tailing the transcript.
- **Hooks installer** in the UI: writes `SessionStart`/`Stop`/`PostCompact`/`SessionEnd` hooks that hand the
  `transcript_path` to the engine. The hook must be deterministic and near-zero cost: a tiny binary or shell line that
  writes one line to a socket or spool file and exits in milliseconds, never blocking Claude Code, with a timeout.
  Fallback: file watching.
- **Resume in terminal** button: `claude --resume <id>`, `--fork-session`, `--from-pr`.
- **Project registry link**: feed session summaries into `project-central`.
