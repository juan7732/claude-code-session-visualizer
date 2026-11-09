# skit · Design tenets

> These tenets guide what skit is and how it is built. They are not ranked. When two pull in different directions,
> use judgment, but a decision that violates a tenet must be conscious and written down, not accidental.

---

## The transcript is evidence.

Claude Code's files are the record of what happened. skit reads them and never writes under `~/.claude`. It does not
reformat, repair or "clean up" a transcript in place. Everything skit knows can be traced back to a line in a file,
and the parser keeps the line even when it does not understand it.

---

## Own the archive.

Claude Code deletes transcripts after thirty days by default. skit exists so that the user keeps their own history,
on their own disk, in a format they can read without skit. The archive is the durable copy; the originals are the
feed. Ingest early, keep what matters, never depend on the source still being there.

---

## Agents are first-class users.

An agent should learn skit in one call (`skit describe`) and use every read command with `--json`. Field names are
stable, exit codes mean something, errors are JSON when JSON was asked for, and nothing prompts without a TTY. If a
human has to translate for the agent, the interface failed.

---

## One engine, many faces.

The CLI, the service and the app expose the same operations with the same names and shapes, because they call the same
engine functions. The engine has no I/O opinions: no printing, no flags, no environment reads. A face is a thin layer
that can be added or removed without touching the engine.

---

## Parse generously, count precisely.

The transcript format is undocumented and changes with every Claude Code release. Unknown record types are kept as
opaque events, never errors. But the numbers skit reports (turns, tokens, cost, tool calls) are exact: usage is summed
once per request, fixtures pin the expected counts, and a parser change that shifts a count fails a test before it
reaches a user.

---

## Show the whole session.

A session is more than the chat. Tool calls and their results, thinking, compactions, subagents, retries, injected
context, images: all of it is in the timeline, with the noisier layers behind settings rather than hidden for good.
When skit summarises, the detail is one step away.

---

## Local first, private by default.

Everything runs on the user's machine. The only network traffic is downloading an embedding model, once, from a pinned
revision with a checksum. Transcripts hold secrets by accident; the archive inherits that sensitivity and gets the
same file permissions, no telemetry, no sync unless the user runs their own service.

---

## Measure before you tune.

Search quality, parser behaviour and performance are judged by evals and measurements, not by taste. A scoring change
carries the eval delta in its commit message. A speed change carries before and after numbers from the same machine.

---

## Earn every abstraction.

Nothing is built speculatively. A pattern must hurt twice before it gets a feature; an interface must have a second
real implementation before it widens. The IDL waits for a second face. Composition with the shell is the system working.

---

## Safe by default, destructive by intent.

Reading, indexing and archiving are always safe to run, twice, by accident. Deleting from the archive requires a flag
and a confirmation. skit never touches Claude Code's own files, so there is nothing it can break there.

---

## Done is a feeling, not a date.

Milestones have no time estimates. Work continues until the result feels right, then the next milestone starts.
Scope is cut by judgment, never by the calendar.
