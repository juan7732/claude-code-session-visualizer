# 0002 · No IDL until a second face exists

Date: 2026-11-08. Status: accepted.

**Context.** Smithy (with custom traits) is the preferred contract language, and both Go and Swift have Smithy code
generators, but they assume HTTP protocols, generate clients only, and are early-stage for non-AWS services. MCP is a
possible generated face, not the contract.

**Decision.** For v0 the contract is: one CLI subcommand = one engine function = one service endpoint, same names, same
JSON shapes, discoverable via `skit describe`. Revisit when the Swift client or the sync service needs generated types.

**Consequences.** Hand-written handlers in `serve`. `describe` is the agent manifest in the meantime.
