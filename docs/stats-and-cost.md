# Stats and cost

## Per request: `assistant.message.usage`

`input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`,
`cache_creation{ephemeral_5m_input_tokens, ephemeral_1h_input_tokens}`, `output_tokens_details{thinking_tokens}`,
`server_tool_use{web_search_requests, web_fetch_requests}`, `service_tier`, `speed`, `inference_geo`, `iterations[]`.
Same object repeated on every split record of the request: **sum once per `requestId`**.

Largest session, summed once per request: input 5.8k, output 327k, cache creation 1.38M, cache read 44.7M tokens over
224 requests. Cache reads dominate by two orders of magnitude; any cost view must show them separately.

## Context window fill, for free

`input_tokens + cache_creation_input_tokens + cache_read_input_tokens` of a request ≈ the context size at that moment.
Plot it per request and you get the context-window curve, with compaction as the vertical drop
(`compactMetadata.preTokens → postTokens` confirms it). This is probably the single most useful chart for a session.

## Claude Code's own totals: `cost-state`

`totalCostUSD`,
`modelUsage{model → inputTokens, outputTokens, thinkingTokens, cacheReadInputTokens, cacheCreationInputTokens, webSearchRequests, costUSD}`,
`totalDuration`, `totalAPIDuration`, `totalAPIDurationWithoutRetries`, `totalToolDuration`, `totalLinesAdded`,
`totalLinesRemoved`, `hasUnknownModelCost`. Written periodically (1 to 5 records per session seen); last one wins.
Observed: $46.06 for the 18 MB session.

Use it as the reference number, and compute our own from usage × a pricing table so sessions without a `cost-state`
record (crashes, older versions) still get a cost. Show both when they disagree. For subscription users the dollar
figure is an API-equivalent, not a bill; label it that way.

## Other sources

- `~/.claude.json → projects[<cwd>]`: `lastSessionId`, `lastCost`, `lastModelUsage`, `lastTotal*Tokens`, `lastDuration`,
  `lastAPIDuration`, `lastToolDuration`, `lastLinesAdded/Removed`. Last session per project only.
- `~/.claude/stats-cache.json`: `dailyActivity[{date, messageCount, sessionCount, toolCallCount}]`,
  `dailyModelTokens[{date, tokensByModel}]`. Powers `/usage`. Was last computed 2026-09-09 here, so it lags.
- `~/.claude/history.jsonl`: one line per prompt typed, with `project` and `sessionId`. Cheap prompt index across
  everything, including sessions whose transcripts are gone.

## Per-session metadata worth extracting at index time

title (last `ai-title`), slug, cwd and project slug, git branch(es), Claude Code version(s), entrypoint, first/last
timestamp, wall duration, prompts (human turns), requests, assistant text blocks, tool calls by name, tool errors
(`toolUseResult` failures, `permissionDecision` denials), models used, tokens by category, thinking tokens, compactions
(count, dropped tokens), api_error count, files touched (`file-history-*`), PR links, images attached, cost (Claude
Code's and ours), permission mode(s), skills invoked (`attributionSkill`).
