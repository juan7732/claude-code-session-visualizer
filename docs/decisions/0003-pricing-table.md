# 0003 · Pricing is a user-configured table

Date: 2026-11-08. Status: accepted, not implemented. Deferred on 2026-11-10 (issue #1): until it is built, cost is
Claude Code's own `cost-state` figure where a transcript has one, and unknown otherwise.

**Context.** Cost needs prices per model and token category. Claude Code writes its own `cost-state` for most sessions,
but not for all (crashes, subagents, older versions), and prices change.

**Decision.** skit ships a starter pricing table the user can edit or replace (model id → price per million tokens for
input, output, cache creation, cache read). Cost is computed from that table and shown next to Claude Code's own figure
when both exist. No network lookup in the engine. A pulled price source may arrive with the sync service.

**Consequences.** Unknown models show cost as unknown, never estimated. The table lives under `~/.sessionkit/`.
