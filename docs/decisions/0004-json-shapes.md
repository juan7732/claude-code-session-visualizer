# 0004 · JSON shapes are additive until 1.0

Date: 2026-11-08. Status: accepted.

**Context.** `--json` output is the agent contract. `skit serve` will version its routes under `/v0/`. The CLI needs a
policy too, without ceremony this early.

**Decision.** Before 1.0, JSON shapes only gain fields; nothing is renamed or removed. Every JSON document carries no
version field of its own; the binary version from `skit describe` identifies the shape. At 1.0 the shapes are frozen as
`v1`, `serve` moves to `/v1/`, and breaking changes bump both together.

**Consequences.** Agents can rely on fields once they appear. Removing or renaming a field before 1.0 requires a
documented exception.
