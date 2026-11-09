# Record anatomy

Counts are across the 8 local sessions (6,000+ records) unless noted. Record types are **not documented**; the set grows
with Claude Code versions. Parse what you know, keep the rest as opaque events, never fail on an unknown type.

## Vocabulary (decisions/0006-turns-and-actions.md)

A session is a chat. The **human turn** is a prompt. The **agent turn** is everything the agent does in answer until it
stops. Inside it, each API request is an **action**: the model thinks, responds and issues **tool calls**, whose results
feed the next action. A **subagent** is a nested turn under the Agent tool call that spawned it. In the records: a
`user` record with `turnOrigin: human` and no `tool_result` opens a turn; every `assistant` record set sharing a
`requestId` is an action; `tool_result` user records continue the turn; a non-human `turnOrigin` (a task notification)
opens a system-originated turn. "Request" in counts means action.

## Record types

| type                       | count | what it is                                                                                                                                                                                                                | timeline?                                                                           |
| -------------------------- | ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| `user`                     | 1027  | A human prompt, a tool result, injected context, or a compaction summary (see flavours)                                                                                                                                   | yes                                                                                 |
| `assistant`                | 1666  | One content block of a model response (see request splitting)                                                                                                                                                             | yes                                                                                 |
| `attachment`               | 1688  | Context Claude Code injected as `<system-reminder>` text: environment, date, deferred tools, token reminders, skill listings, edited-file notices… `rendered[].content` holds the text, `renderedRole` says where it went | setting: off by default, shown as an injected-context lane when on                  |
| `system`                   | 59    | `subtype`: `api_error` (retries, `retryAttempt`/`maxRetries`), `compact_boundary` (see compaction), `informational`                                                                                                       | yes, as markers                                                                     |
| `api-request`              | 287   | The exact request sent: `params` (model, betas, max_tokens, thinking, effort), `cacheControl`, `shapeHash`, `tail` hashes → blobs                                                                                         | no; context-window analytics                                                        |
| `api-request-blob`         | 574   | Content-addressed message bodies referenced by `api-request.tail` (duplicates user content, incl. images)                                                                                                                 | no                                                                                  |
| `api-request-shape`        | 6     | The system prompt + tool definitions for a `shapeHash`                                                                                                                                                                    | no; "what did the model see"                                                        |
| `queue-operation`          | 571   | Prompt queue enqueue/dequeue                                                                                                                                                                                              | no                                                                                  |
| `bridge-session`           | 527   | Remote Control bridge ids + owner account/org                                                                                                                                                                             | no                                                                                  |
| `last-prompt`              | 525   | `lastPrompt` text + `leafUuid` (the current tip of the tree)                                                                                                                                                              | pointer                                                                             |
| `atis-latch`               | 515   | opaque hash                                                                                                                                                                                                               | no                                                                                  |
| `ai-title`                 | 482   | `aiTitle`: generated session title. Rewritten often; **last one wins** (214 records, 1 distinct title in one session)                                                                                                     | session metadata                                                                    |
| `file-history-snapshot`    | 267   | checkpoint: `messageId` + `trackedFileBackups{path → backupFileName@vN}`                                                                                                                                                  | files-touched lane                                                                  |
| `file-history-delta`       | 61    | one file backed up before an edit: `trackingPath`, `backup.version`                                                                                                                                                       | files-touched lane                                                                  |
| `mode` / `permission-mode` | 196   | `normal`/plan…, `default`/`auto`…                                                                                                                                                                                         | markers                                                                             |
| `cost-state`               | 23    | Claude Code's own totals: `totalCostUSD`, `modelUsage{model → tokens, costUSD}`, durations, lines added/removed                                                                                                           | session stats                                                                       |
| `session-owner`            | 25    | account + org uuid                                                                                                                                                                                                        | keep: tells which account/org ran the session (multi-account, multi-device archive) |
| `pr-link`                  | 15    | `prNumber`, `prUrl`, `prRepository`                                                                                                                                                                                       | session metadata                                                                    |
| `tools-used`               | 3     | list of tool names                                                                                                                                                                                                        | session metadata                                                                    |

Byte share in an 18 MB session: `api-request` 58%, `user` 17%, `assistant` 11%, `attachment` 5%, blobs 4%. Across all 8
sessions (47 MB): `user` 32%, `api-request` 29%, `assistant` 16%, blobs 10%, `attachment` 8%. The timeline needs about
half the bytes at most. A streaming parser that discards `api-request*` early stays fast.

## Envelope on `user`, `assistant`, `attachment`, `system`

`uuid`, `parentUuid`, `isSidechain`, `sessionId`, `timestamp` (ISO 8601 UTC), `cwd`, `gitBranch`, `version`,
`entrypoint` (`claude-vscode`, `cli`, …), `userType`, `slug` (a readable per-session codename, e.g.
`sequential-toasting-squirrel`). Assistant adds `requestId`, `apiBlockIndex`, `requestRef` (→ `api-request.id`),
`requestedModel`, `effort`, `perTurnEffort`, `thinkingDurationMs`, `attributionSkill`, `wireToolInputs`.

## Working directories

`cwd` is on every timeline record and can change mid-session (`/cd`, worktrees). The parser keeps **all** distinct
working directories in order of first appearance (`Session.Cwds`), since mapping a session onto ergo workspaces and
repos depends on every directory it touched, not just the first.

## What the model actually receives (seed context)

Measured on a real first action (45.5k reported context tokens): the **tool definitions dominate** (16 tools, 72k chars,
~18k tokens), then a skill's loaded content delivered as `tool_addition` blocks in a system-role message (~8k), the
attachments Claude Code injects into turn 0 (skill listing ~5k, deferred tools, agent listing, MCP instructions,
environment, model, date… ~8.6k together), the system prompt (3 blocks, ~4.4k), and finally the user's own message with
its injected blocks (~2.7k). **CLAUDE.md arrives as an attachment of type `instructions`**, rendered as a
`<system-reminder>` that begins "Codebase and user instructions are shown below" inside the first user message;
CLAUDE.md files met later in subdirectories arrive as `nested_memory`. All of this is reconstructable from `api-request`
(params, cache breakpoints, `tail` hashes), `api-request-blob` (message bodies) and `api-request-shape` (system prompt +
tools per shape hash) plus the `attachment` records: `skit context <session> [--action N]` prints the breakdown,
`--show instructions` the injected CLAUDE.md text. The archive keeps these records (ADR 0007), so the breakdown works on
archived sessions too, unless the copy was made with `--strip-requests`.

## Synthetic messages

Some `assistant` records have `message.model = "<synthetic>"`, zero usage and no `requestId`: Claude Code wrote them
itself so the transcript keeps alternating and records what the UI showed. Two kinds observed: API error notices ("API
Error: Can't reach the API server (ENOTFOUND)", with `isApiErrorMessage: true` and `error: "server_error"`) and the
placeholder "No response requested." after a turn that needed no model reply. The parser keeps them as turns with
`synthetic_kind` (`api_error`, `no_response`, `other`) and counts them separately; they are not API requests.

## Injected blocks in prompts

A human prompt's content often holds text blocks the IDE or Claude Code added: `<ide_opened_file>` (94 of 374 prompt
text blocks on this machine), `<ide_selection>`, `<system-reminder>`. The parser keeps them as `Prompt.Context` and
leaves them out of `Prompt.Text`. `<pasted_content>` and the `<command-message>` wrapper of a slash command are the
user's own intent and stay in the text. `skit show --context` prints the injected blocks under each prompt and every
`attachment` record with its size, which is how the context grows turn by turn.

## The tree is a tree of records, not of messages

`parentUuid` links records, and a response split into several records chains them block by block. A `tool_result` record
points at the **specific record holding its `tool_use`**, not at the last record of the response. With parallel tool
calls, every tool-use record therefore has two children: the next block of the same response and its own result.
Attachments and system notes also hang off the same parent as the following message. None of these are conversation
branches. A real branch (`/rewind`, `--fork-session`) shows two human prompts or two different `requestId`s under one
parent, and that is what `Session.Branches` counts (45 false positives → 0 on the bootstrap session once this was
understood).

## The tree

`parentUuid` makes a tree, not a list. In the largest session: 1,221 uuid records, 2 roots, 0 branch points. Roots are
the first prompt and the `compact_boundary` record (its `parentUuid` is null; `logicalParentUuid` points at the
pre-compaction leaf). Branches appear with `/rewind` and `--fork-session`; `last-prompt.leafUuid` names the live tip.
Render the main chain as the timeline; keep other branches reachable. Subagents are separate files under
`<session>/subagents/`, in the same format; older versions used `isSidechain: true` in the main file. Handle both.

## `user` flavours (largest session)

| count | content                                  | flags                                                                                                                                      |
| ----- | ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| 183   | `[tool_result]`                          | `toolUseResult` (tool-specific metadata, e.g. `{success, commandName}`), `sourceToolAssistantUUID`, `permissionDecision{decision, source}` |
| 39    | `[text]`                                 | `turnOrigin: human`, `promptId`, `turnPosition{promptIndex, turnIndex}`, `permissionMode`, `promptSource`                                  |
| 2     | `[image, text]` or `[text, image, text]` | `turnOrigin: human`, `imagePasteIds`                                                                                                       |
| 3     | `[text]`                                 | `isMeta: true` (context Claude Code injected as a user message)                                                                            |
| 1     | string                                   | `isCompactSummary: true`, `summarizedTurnPromptUuids`, `isVisibleInTranscriptOnly`                                                         |

A `tool_result` block has `tool_use_id` → the `tool_use.id` in an earlier assistant record (0 orphans observed), and
`content` is a string (711), a list with `image` blocks (18: the Read tool on a PNG), or `tool_reference` (13). Large
outputs are truncated in place with a pointer to `<session>/tool-results/<id>.txt`.

## `assistant` and request splitting

`message` is the API response: `id` (msg\_…), `model`, `role`, `content[]`, `stop_reason`, `usage`. One response is
written as **one record per content block**, in order, sharing `requestId` and `message.id`, with `apiBlockIndex` 0, 1,
2… (max 3 seen: thinking, text, tool_use). **Reassemble a turn by `requestId`, and count `usage` once per request**, or
tokens triple. Block types seen: `text`, `tool_use` (`id`, `name`, `input`, `caller{type: direct}`), `thinking`
(`thinking` text + `signature`; full text present, not redacted), `tool_addition`.

Models seen: `claude-fable-5-1` (1658), `<synthetic>` (8: Claude Code-generated messages, no API call). Titles are
generated by Haiku (`claude-haiku-5-5` / `claude-haiku-4-5` appear in `cost-state.modelUsage` with tiny token counts).

## Compaction

A `system` record with `subtype: compact_boundary` and
`compactMetadata{trigger: auto|manual, preTokens, postTokens, cumulativeDroppedTokens, preservedSegment{headUuid, anchorUuid, tailUuid}, preservedMessages}`
(observed 249k → 12k), followed by a `user` record with `isCompactSummary: true` whose text begins "This session is
being continued from a previous conversation…". Render as a cut in the timeline with the before/after token counts; the
summary is a great anchor for search (it is a dense, model-written abstract of everything before it).
