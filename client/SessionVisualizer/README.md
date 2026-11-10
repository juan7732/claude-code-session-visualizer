# SessionVisualizer

The native macOS client for skit: SwiftUI, macOS 14 or later, a Swift package with no dependencies. It talks only to
`skit serve` over its Unix socket and never reads a transcript itself. Plan: `docs/plan-v0.md`, M7 onwards. Reference
for layout and behaviour: the mocks in the workspace (`ux-mocks/app.html`, `ux-mocks/NOTES.md`).

```
just client-build         build the app (debug)
just client-run           build and launch it
just client-test          contract, transport and state tests
just client-contract      record /v0 from this checkout's engine, then run the tests against that recording
just client-fixtures      refresh the recorded responses checked in under Sources/SkitTestSupport/Fixtures
just client-snapshot out.png --page sessions --appearance dark    render one state to a PNG, no window shown
```

## Layout

| Path                           | What                                                                                               |
| ------------------------------ | -------------------------------------------------------------------------------------------------- |
| `Sources/SkitKit`              | What talks to the engine, no UI: `UnixHTTP` (ADR 0010), the typed `/v0` client, models, connector. |
| `Sources/SessionVisualizer`    | The app: `AppStore` (shared by all windows), `WindowState` (one per window), the shell, the views. |
| `Sources/SkitTestSupport`      | A Unix-socket server that plays `skit serve` in tests, and the recorded `/v0` responses.           |
| `Tests/SkitKitTests`           | Contract tests over recorded responses, the transport, the connector, formatting.                  |
| `Tests/SessionVisualizerTests` | The app's state without its windows: the store, the session model, Markdown blocks, selection.     |
| `Scripts/record-fixtures.sh`   | Serves the `synthetic-basics` fixture from a throwaway home and records the routes the tests read. |

## Rules

- **The client never parses or derives.** What a view needs and `/v0` does not serve becomes a `--json` shape and a
  route in the engine first.
- **The contract is tested.** `SkitKit`'s models decode what the engine really answers; `just client-contract` and CI
  record from the engine in the same commit, so an engine change the client cannot read fails before it ships.
- **Keys are spelled out** (`CodingKeys`), never converted by the decoder: the conversion rewrites dictionary keys too,
  and note keys such as `tool:toolu_01AbC` must arrive as written.
- **Lists are never optional in a view.** An older engine's `null` or missing list decodes as empty (`@EmptyWhenNull`).
- **Bento is the one style** (`Theme.swift`): light and dark follow the system, pure black is a setting.
- **Every command is in the menu bar** (`Commands.swift`), disabled until its view exists.

## Engine at launch

The app attaches to the `skit serve` that answers on `$SKIT_HOME/skit.sock` (default `~/.sessionkit`). If nothing
answers, it looks for `skit` (`$SKIT_BIN`, the bundle's `Contents/Helpers`, `PATH`, `~/go/bin`, Homebrew), runs
`skit service install` and waits for the agent. An engine that lacks a route the app calls is reported as too old.

## Snapshots

`--snapshot` renders a page offscreen and exits. It only attaches to a running engine and never installs anything.
Options: `--page sessions|session:<id>|search|stats|claude`, `--view summary|transcript|canvas|timeline|files`,
`--appearance light|dark|oled`, `--size 1500x940`, `--socket <path>`, `--flyout`, and inside a session
`--select action:6|turn:0|tool:<id>|subagent:<id>|compaction:0`, `--tab details|io|note`, `--query <text>`,
`--open-calls`, `--fold`.

`--measure <session id>` prints how long each step of opening a session takes (fetch, decode, build), twice: once as
found and once with the session in the engine's memory. One known limit: the toolbar's glass controls draw as white
shapes in a dark offscreen capture; in a real window they are dark.

## Toolchain

Swift 6.2 or later. Xcode does not have to be the selected toolchain: the Command Line Tools build and run the app.
Their copy of the Testing framework is off the default search paths, which `just client-test` adds. With Xcode selected
(`xcode-select -s /Applications/Xcode.app`), plain `swift test` works.
