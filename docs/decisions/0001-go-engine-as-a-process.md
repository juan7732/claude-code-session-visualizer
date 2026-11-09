# 0001 · The engine is a Go process, not a library linked into the app

Date: 2026-11-08. Status: accepted.

**Context.** The Swift client needs the engine. DigUp links its Swift engine in-process. A Go engine could be linked via
`-buildmode=c-archive`, but the Go runtime would live inside the app, values would cross as C strings, and cgo would
complicate builds. Rust with UniFFI would be the ergonomic in-process option.

**Decision.** The engine stays Go and runs as a separate process (`skit serve`) over a Unix socket. The client never
links it. If in-process ever becomes necessary, the switch is to Rust + UniFFI, not Go via cgo.

**Consequences.** The process boundary is also the future network boundary (sync service, web renderer). Agents use the
CLI. Latency is one local socket hop. Pure-Go SQLite (`modernc.org/sqlite`) keeps the binary cgo-free.
