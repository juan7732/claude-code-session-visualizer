# 0009 · A launchd agent keeps the archiver running

Date: 2026-11-10. Status: accepted.

**Context.** Tenet 1 depends on sessions being archived before Claude Code sweeps them, and until now that happened only
while someone had `skit serve` running or remembered `skit archive`. On the day of the review nothing was running and
eleven of twelve sessions were archived by hand. Juan's condition: whatever keeps the archive current is managed by the
tool (CLI, engine or app), not set up by hand.

**Decision.** `skit service install` writes one launchd agent, `~/Library/LaunchAgents/dev.sessionkit.skit.plist`, that
runs `skit serve --quiet` from login on and restarts it if it stops. `skit service status` and `skit service uninstall`
complete the set, and `skit doctor` reports the agent and how many sessions on disk are not archived or changed since.
The Swift client will run `skit service install` for its bundled `skit` on first launch (M7), so a person who only ever
opens the app gets the same thing. `serve` now sweeps every session when it starts and hourly after, because a file
watcher only hears about changes made while it runs.

Considered and not chosen: Claude Code hooks (`SessionEnd`, `Stop`) that call `skit archive`. They are immediate, but
they mean editing the user's Claude Code settings, they do not fire for a session that crashes, and they need the same
catch-up sweep anyway. They stay on the roadmap as an addition.

**Consequences.** One process stays resident. It holds a parsed session only while something reads it and drops it after
ten idle minutes (`archive.DefaultCacheBytes`). The plist is the one file skit writes outside `~/.sessionkit`: launchd
reads agents from nowhere else. The agent points at an absolute path to `skit`; if that binary moves, `status` and
`doctor` say so and `install` fixes it. macOS only for now: elsewhere the command says so and `skit serve` can run under
any supervisor. The log (`~/.sessionkit/serve.log`) is not rotated; without per-request lines it grows by a line per
archived change.
