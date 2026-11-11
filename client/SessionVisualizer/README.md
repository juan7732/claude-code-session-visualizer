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
just client-app           SessionVisualizer.app with this checkout's skit in Contents/Helpers, signed (build.sh)
just client-app-install   the same, copied into /Applications
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
| `build.sh`                     | Builds and signs the app bundle (ADR 0011). `SIGN_IDENTITY` picks the identity; ad hoc without it. |

The views, by file: `SessionsView` (home), `SummaryView` (the dashboard, search in this session, the digest, the hours
grid), `TranscriptView` and `TranscriptRows`, `Drawer` (the inspector under both), `SearchPage` (the Finder),
`PaletteView` (⌘K), `CanvasView` (the Braid: `BraidLayout` says what each node says and where it is, `BraidCanvas` is
the AppKit view that draws it and takes the pointer, ADR 0012), `ArcsMap` (the Summary's map), `TimelineView` (the strip
and the playhead in `TimelineStrip`, the rows in `Ledger`; `TimelineLayout` holds `TimeAxis`, which cuts idle time and
maps moments to points, and what the strip draws). `SessionModel` is what they all read; `Commands` holds every command
once, for the menu bar and the palette; `Export` writes Markdown through the engine and builds and reads
`skit-visualizer://` links.

## Rules

- **The client never parses or derives.** What a view needs and `/v0` does not serve becomes a `--json` shape and a
  route in the engine first.
- **The contract is tested.** `SkitKit`'s models decode what the engine really answers; `just client-contract` and CI
  record from the engine in the same commit, so an engine change the client cannot read fails before it ships.
- **Keys are spelled out** (`CodingKeys`), never converted by the decoder: the conversion rewrites dictionary keys too,
  and note keys such as `tool:toolu_01AbC` must arrive as written.
- **Lists are never optional in a view.** An older engine's `null` or missing list decodes as empty (`@EmptyWhenNull`).
- **Bento is the one style** (`Theme.swift`): light and dark follow the system, pure black is a setting.
- **Every command is in the menu bar** (`Commands.swift`), disabled until its view exists. The ⌘K palette lists the same
  commands from the same list.
- **Numbers the transcript does not record are not guessed.** The context window is a setting, and the card says so.
- **One lazy stack per scroll view, and none on the Summary.** A lazy stack inside another re-estimates its height as
  rows come and go; with rows that highlight under the pointer that became a loop on the main thread and the window
  froze while scrolling (2026-11-10). A snapshot cannot show this; `just client-exercise` can.

## Engine at launch

The app attaches to the `skit serve` that answers on `$SKIT_HOME/skit.sock` (default `~/.sessionkit`). If nothing
answers, it looks for `skit` (`$SKIT_BIN`, the bundle's `Contents/Helpers`, `PATH`, `~/go/bin`, Homebrew), runs
`skit service install` and waits for the agent. An engine that lacks a route the app calls is reported as too old.

## The bundle and links

`build.sh` puts the release build and `skit` into `SessionVisualizer.app` and signs it. The bundle declares the
`skit-visualizer` scheme: Edit › Copy Link (⇧⌘C) copies `skit-visualizer://session/<id>?view=…` with the selected node,
and opening such a link brings the app to that node. Run from the build directory the app can copy links but nothing
routes them to it. Opened links are logged (`log stream --predicate 'subsystem == "dev.sessionkit.SessionVisualizer"'`).

## Snapshots

`--snapshot` renders a page offscreen and exits. It only attaches to a running engine and never installs anything.
Options: `--page sessions|session:<id>|search|stats|claude`, `--view summary|transcript|canvas|timeline|files`,
`--appearance light|dark|oled`, `--size 1500x940`, `--socket <path>`, `--flyout`, and inside a session
`--select action:6|turn:0|tool:<id>|subagent:<id>|step:<agent>:<n>|compaction:0|work:1|file:<path>|outside:<kind:name>`,
`--tab details|io|note`, `--query <text>` (find in the Transcript, the Summary's search box, or the Search page),
`--open-calls`, `--fold`, `--palette`, `--set <key>=<value>` (a setting for this picture only), `--scroll-through`, and
on the Search page `--mode meaning`, `--kind <kind>` (chosen after the first results, as a click would), `--unfold`
(every session's hits shown), and on the Canvas `--zoom 0.3`, `--fit all|width`, `--collapse`. The offscreen window
never takes the keyboard, and a snapshot neither reads nor writes where a session's canvas was left.

`--measure-canvas <session id> [--size 1728x1000]` builds the Braid of a session and prints what a frame costs along a
pan at each level of detail and through a zoom (use a release build: `swift build -c release`).

`--measure <session id>` prints how long each step of opening a session takes (fetch, decode, build), twice: once as
found and once with the session in the engine's memory. One known limit: the toolbar's glass controls draw as white
shapes in a dark offscreen capture; in a real window they are dark.

## The live exercise

`just client-exercise summary <session id>` (or `transcript <id>`, `timeline <id>`, `search <words>`) opens a real
window on that page, scrolls it from top to bottom with a pointer resting on the page, and quits; on the Timeline it
then plays the playhead for a few seconds with the ledger following. If the scroll stops advancing, the main thread is
stuck: the script samples the process and exits 1. Run it on a long session after changing how a scrolling page is laid
out. The window appears on screen for a few seconds. `--scroll-through` does the same offscreen in snapshot mode, which
found nothing the day the Summary froze: only a live window with a pointer did.

## Toolchain

Swift 6.2 or later. Xcode does not have to be the selected toolchain: the Command Line Tools build and run the app.
Their copy of the Testing framework is off the default search paths, which `just client-test` adds. With Xcode selected
(`xcode-select -s /Applications/Xcode.app`), plain `swift test` works.
