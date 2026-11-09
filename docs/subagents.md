# Subagents

Probed live on 2026-11-07 (Claude Code 2.1.319): spawned a trivial Haiku subagent from this session and inspected disk.

## Where they land

```
~/.claude/projects/<project-slug>/<session-uuid>/subagents/
  agent-<agentId>.jsonl        the subagent's transcript, same record format as the parent
  agent-<agentId>.meta.json    {agentType, isBuiltIn, description, toolUseId, spawnDepth, requestShape: "background",
                                requestNonInteractive, model, pickedEffortModel, finished}
```

`agentId` is a 17-hex-char id (e.g. `a7095561895d75191`). A 27-line probe transcript was 259 KB because it carries its
own `api-request*` records (system prompt and tool list again).

## Linkage to the parent, three ways

1. **`meta.json → toolUseId`** equals the `tool_use.id` of the `Agent` call in the parent transcript. Definitive.
2. **Parent `tool_result.toolUseResult`** for that call carries `agentId`, `description`, `resolvedModel`
   (`claude-haiku-5-5` here even though the input said `haiku`), `status: async_launched`, `isAsync`, `outputFile` (a
   tasks file under the temp dir), `canContinueAgent`.
3. **Every subagent record** carries `agentId`, `isSidechain: true`, `sessionId` of the parent, and `parentUuid` chains
   inside the subagent file only (its first record has `parentUuid: null`). Assistant records carry
   `attributionAgent: "general-purpose"` and `model: claude-haiku-5-5`.

Older Claude Code versions wrote sidechain records into the parent file with `isSidechain: true`; none of the 8 local
sessions do, but the parser must accept both.

## Shape of a subagent transcript

Same as a session: a first `user` record with the prompt (plain string), `attachment`s with injected context, an
`isMeta` user record, `assistant` records split per block with `requestId`, tool results, `api-request*`. It has no
`ai-title`, `cost-state`, `session-owner`, or `last-prompt`. Its cost therefore shows up only in the **parent's**
`cost-state.modelUsage` (per model) and must be computed from the subagent's own `usage` to attribute it.

## For the visualizer

- Enumerate `<session>/subagents/*.jsonl` when loading a session; join on `meta.toolUseId`.
- Render as a **lane nested under the `Agent` tool call**, collapsed by default, with its own request count, tokens,
  model, duration (first to last timestamp) and whether `finished` is true.
- The parent's `Agent` tool call has two moments: launch (`async_launched`) and the hand-back, which arrives as a later
  user record (a `SubagentHandback` style message). Draw the lane spanning both.
- Subagent transcripts are swept with the parent; archive them together. Background agents and forks (`spawnDepth` > 1)
  nest recursively.
- Teammates and cross-session messages (`SendMessage`) are a different mechanism; not probed here.
