# 0006 · Vocabulary: turn, action, tool call

Date: 2026-11-09. Status: accepted. Supersedes the use of "turn" for an API request in M1–M5.

**Context.** The parser called each API request a "turn", so one prompt showed "many turns". That is not how the
conversation works. A session is a chat: the human takes a turn (the prompt), the agent takes a turn (everything it does
until it stops and waits). Inside the agent's turn there are steps, each one an API request in which the model thinks,
responds and issues tool calls; the tool results feed the next step. A subagent's work is its own nested turn under the
Agent tool call, handed back when it finishes. Juan's diagram (2026-11-09) is the reference.

**Decision.**

- **Turn** = one turn of the conversation. A human turn is a prompt; the agent turn answering it holds every action
  until the agent stops. A turn can also be started by something other than a human (a task notification, hook output):
  `origin` records that. Turn index counts all turns in order.
- **Action** = one API request within an agent turn: thinking, text, tool_use blocks, usage once. `actions` replaces the
  old `turns` array; each action carries its `turn` index.
- **Tool call** = a tool_use block and its result, under an action; carries `turn` and `action`.
- **Subagent** = a nested session under the Agent tool call that spawned it; its own turns and actions; rolled into the
  parent's totals.
- Thinking is part of an action (`Action.Thinking()`), shown on request (`--thinking`, the detail views) and indexed.

**JSON shapes.** This renames `turns` → `actions` in the session document and changes what `turns` means, which ADR 0004
forbids before 1.0 without a documented exception. This is that exception: the vocabulary was wrong at the data model
level and no client exists yet. `/v0/sessions/{id}/turns/{n}` now returns an agent turn;
`/v0/sessions/{id}/ actions/{n}` returns one action. Index schema 2 adds `segments.action` and `sessions.schema`;
`skit archive` re-indexes rows written by schema 1.

**Consequences.** The CLI timeline groups by turn and shows actions inside it; `stats` reports turns and requests
separately; search hits point at turn and action. The UX mocks and the Swift client use the same words.
