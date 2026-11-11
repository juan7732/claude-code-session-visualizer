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
- **Injected-context lane** (attachments, `isMeta` messages). Off by default, a setting. First cut:
  `skit show --context`.
- **Context lane** charting what the model received per action: system prompt, tool definitions, injected attachments,
  messages, cache breakpoints (the `api-request*` records are always archived, ADR 0007). First cut: `skit context`.

## Search

- **Cross-session search** of prompts from `history.jsonl`, even when the transcript is gone.
- **Image search**: proxy text now, OCR to keywords with the Swift client, true image vectors with the EmbeddingGemma 2
  encoder (`images-and-modalities.md`). Other modalities later for users who feed audio or documents through MCP tools.
- Session card = slug + title + cwd + project; `slug` is stable, titles change.

## Models on top of the archive

Added 2026-11-10 during M14. Juan took all of it up the same day: it is M17 (no new model), M18 (a second small model)
and M19 (a small language model) in `plan-v0.md`, after v1. This section stays the list of ideas the milestones draw
from. Two rules for all of it. **The eval decides**: an idea earns a place when it moves a number on queries with known
answers (`meaning-search.md`), not when it demos well. **Models come in tiers and each tier is opt-in**: the embedder is
the core (one 310 MB download); anything heavier is its own explicit download with its own line in `doctor`, loads only
when used, and never arrives because another feature was turned on. Early thinking on three of these lives in the
engineering repo's `thoughts/` (2026-11-10).

With the vectors already there, no new model:

- **A session's own summary vector**, so a query in the user's words ("my jev assignment") reaches a session that calls
  the thing something else ("the SLT"). The cheapest test of a personal vocabulary.
- **Chapters.** Where consecutive turns stop resembling each other, the subject changed: chapter marks for the Timeline
  and the Summary without a language model.
- **"You have been here before."** The nearest earlier turns to the prompt just typed, across sessions: the same
  question asked last month, with its answer. Also "more like this" from any turn, and related sessions on a session's
  Summary.
- **A map of subjects.** Cluster the pieces across all sessions; each cluster is something the user works on. An answer
  to "what have I been doing" that no single session holds, and a home for the registry of projects.
- **Images and audio by description**, with the encoder ADR 0005 already measured (tier C in
  `images-and-modalities.md`).
- **A ranking that learns from use.** Which hit was opened, pinned or copied is a label. A few numbers per hit (keyword
  score, coverage, cosine, kind, age) and a logistic regression fitted on those labels and the eval could replace
  hand-set weights in `hybrid`. Small, local, and it stays explainable.
- **Two-pass search for large archives.** The vectors are Matryoshka-trained: score everything at 256 dimensions, then
  the best few hundred at 768. Only if brute force ever hurts.

With a second small model that reads a query and a passage together (a reranker or decision model):

- **Answer or near miss.** The gate today is a cosine floor, and it cannot tell a passage on the same subject from one
  that answers the question (6 of 8 near misses in the eval get hits). A reranker over the top twenty is the fix the
  eval is waiting to judge. `llama-server` serves reranker models through the same API.
- **What kind of turn this is**: a decision, a question, a correction, a dead end, a commitment with a date. Five of the
  first thirteen eval questions begin "what did we decide" or "when did we decide": a register of decisions across
  sessions, each pointing at its turn, would answer the commonest question directly. The same labels give the Finder
  facets and the Summary its outline.
- **Things that should not leave the machine.** Before a session is exported or a link is shared: keys, tokens, names,
  health or grade data. Patterns catch the first two; a classifier is for the rest.

With a small language model (the heaviest tier):

- **What a tool call did**, in a sentence, embedded with the call (issue #4).
- **Titles and abstracts** for the sessions Claude Code never titled, and a line per turn for the Summary's digest.
- **A query rewritten before it is searched**: expanded with the user's other names for the thing, or answered
  hypothetically and the answer embedded, which sits closer to real answers than a question does.

With the model the user already has:

- **Claude Code answers from the archive.** The agent is the first user (tenet 3): a skill that calls
  `skit search --json` and `skit show --turn` lets a Claude Code session answer "what did we decide about X" with the
  turns cited. No local language model, nothing new to download; the transcript text goes where the user's sessions
  already go, and only when they ask.
- **The eval grows itself.** Proposing queries with their turns from the sessions is what was done by hand on
  2026-11-10; as a skill it is repeatable, with the human still approving each one.

Not models at all, but in the same spirit:

- **How I work.** Tool-call sequences mined for patterns (which prompts lead to long agent turns, where sessions stall,
  what precedes a compaction) with counting and simple statistics first.
- **Warnings before they happen**: the context curve already shows a compaction coming.

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
- **Background agent** (done, M6): `skit service install` keeps `skit serve` running under launchd; the watcher and an
  hourly sweep keep the archive current. The hooks below would make it immediate instead of a few seconds late.
- **Hooks installer** in the UI: writes `SessionStart`/`Stop`/`PostCompact`/`SessionEnd` hooks that hand the
  `transcript_path` to the engine. The hook must be deterministic and near-zero cost: a tiny binary or shell line that
  writes one line to a socket or spool file and exits in milliseconds, never blocking Claude Code, with a timeout.
  Fallback: file watching.
- **Resume in terminal** button: `claude --resume <id>`, `--fork-session`, `--from-pr`.
- **Project registry link**: feed session summaries into `project-central`.
