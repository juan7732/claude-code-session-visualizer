# 0007 · The archive keeps the request records

Date: 2026-11-09. Status: accepted. Revises the M3 choice to drop `api-request*` records unless `--debug`.

**Context.** `api-request`, `api-request-blob` and `api-request-shape` records hold what the model actually received:
the system prompt, every tool definition, the message bodies including the injected CLAUDE.md, the parameters and cache
breakpoints. They are about 40–60% of a transcript's raw bytes, so M3 dropped them by default. Juan wants to know, for
every archived session, which tools were available, what CLAUDE.md said and what the system prompt was. Tenet 1 (we
never lose a session) points the same way.

**Decision.** `skit archive` keeps every record by default. `--strip-requests` (CLI) and `strip_requests` (API) drop the
request records for a smaller copy, at the cost of `skit context` for those sessions. The index remembers which copies
have them; a copy made the other way is rewritten on the next `archive`.

**Consequences.** Archives grow (zstd takes much of the sting out: the request bodies are repetitive JSON; measured
figures in `../archive-sizing.md`). `skit context` and `/v0/sessions/{id}/actions/{n}/context` work on archived sessions
after Claude Code has deleted the source. The "debug mode" roadmap item becomes about presentation, not capture.
