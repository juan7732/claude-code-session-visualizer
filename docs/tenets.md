# skit · Tenets

A tenet is a belief that accelerates decision-making: it says what matters here and, by extension, what does not, so a
trade-off can be settled without a meeting. Each one has a defensible opposite. They are listed in descending order of
priority, so when two collide the higher one wins. Design and engineering guidance that follows from them lives in
`design-principles.md`.

Unless you know better ones.

---

**1. We never lose a session.** Claude Code deletes transcripts after thirty days. skit exists so that the user keeps
their history. When choosing between a smaller archive and a lossless one, between indexing later and ingesting now, or
between a clever derived format and the raw lines, we pick the option that cannot lose data. _Opposite we reject: keep
only what the current features need._

**2. Everything stays on the user's machine.** Transcripts hold file contents, command output and secrets by accident.
skit reads them, stores them and searches them locally, with no telemetry and no network beyond a one-time, checksummed
model download. A feature that needs a server is a feature the user runs themselves. _Opposite we reject: sync to a
hosted service by default for convenience._ _Known exception: a sync service that aggregates sessions across a user's
own devices is planned as a supported, opt-in integration the user runs or chooses. It bends this tenet knowingly; the
local-only default stays._

**3. The agent is the first user.** Every operation is reachable from the CLI with `--json` and discoverable through
`skit describe` before any human interface exists. When the human view and the agent view compete for effort, the agent
view ships first, because it is what makes the tool composable. _Opposite we reject: build the app first and expose a
CLI later._

**4. Exact numbers beat fast estimates.** Token counts, costs, tool counts and turn counts are computed from the records
with fixtures pinning the expected values. If we cannot compute a number exactly we show it as unknown rather than
approximate it, and a parser change that shifts a count fails a test before it ships. _Opposite we reject: approximate
quickly and refine later._

**5. The whole session beats a tidy summary.** Tool calls, thinking, compactions, subagents, retries, injected context
and images are all part of the record and all reachable in the timeline, with the noisy layers behind settings. We
summarise on top of the detail, never instead of it. _Opposite we reject: curate a clean chat view and drop the rest._

**6. A working slice beats a complete design.** We ship the thinnest vertical slice that works end to end, then widen
it. The CLI came before the parser was finished, the parser before the archive, the archive before search. Designs that
have not been exercised by running code are drafts. Choosing the verticals with intent is itself design work: this tenet
is about sequencing, not about skipping thought. _Opposite we reject: design the full system, then build it._

**7. We change the engine, never the transcript.** Claude Code's files are read-only evidence. When the format changes,
skit adapts its parser and keeps unknown records as opaque events; it never normalises, migrates or repairs a transcript
in place. _Opposite we reject: rewrite transcripts into our own canonical format._

---

Tensions these create on purpose: 1 against 4 (keep everything, yet report only what we can count exactly), 3 against 5
(agents want compact output, the timeline wants completeness), 6 against 4 (ship thin, but never ship a wrong number).
When they collide, the lower-numbered tenet wins.
