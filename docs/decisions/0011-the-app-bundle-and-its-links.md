# 0011 · The app bundle, and links into it

Date: 2026-11-10. Status: accepted.

**Context.** Until M9 the client ran from its build directory (`just client-run`). v0 ends with an app in /Applications
that needs nothing else installed, and with "Copy Link": a way to point at a session, or at one turn, action or tool
call of it, from a note or a pull request. A link needs a URL scheme, and macOS only routes a scheme to an app bundle
that declares it.

**Decision.**

- **One script builds the bundle.** `client/SessionVisualizer/build.sh` builds the client in release mode, builds `skit`
  from the same checkout into `Contents/Helpers/skit`, writes `Info.plist`, and signs the helper and then the bundle. No
  Xcode project: the Swift package stays the only build description. The app's bundle id is
  `dev.sessionkit.SessionVisualizer`, beside the agent's `dev.sessionkit.skit` (ADR 0009).
- **The engine travels inside the app.** The connector already prefers `Contents/Helpers/skit` when it has to start an
  engine, so a Mac with no `skit` gets the bundled one installed as the background agent on first launch. A Mac where an
  agent is already serving keeps it: the app attaches to whatever answers and only checks that it serves the routes it
  calls. When it does not (an agent left running from an older build), the window says so and offers to restart the
  agent with the app's own `skit`.
- **Signing is ad hoc unless an identity is given.** `SIGN_IDENTITY` names a Developer ID; with it the script signs with
  the hardened runtime and a timestamp, which is what notarization asks for. Without it the signature is ad hoc: the app
  runs on the Mac that built it and Gatekeeper refuses it elsewhere. Notarizing is a script of its own (`notarize.sh`,
  `just client-app-notarize`, 2026-11-11): it builds with the Developer ID in the keychain, sends the app to Apple
  through a `notarytool` keychain profile, staples the ticket, asks Gatekeeper for its verdict and leaves a zip with its
  checksum. It refuses a checkout with uncommitted changes, so that what is handed out is what a commit says. The
  everyday build stays ad hoc and needs neither certificate nor profile.
- **Links are `skit-visualizer://session/<id>`**, with the view and one node in the query: `?view=transcript&action=60`,
  `&turn=3`, `&tool=<id>`, `&subagent=<agent id>[&step=4]`, `&compaction=0`, `&file=<path>`, `&outside=<kind:name>`. The
  scheme name is Juan's choice (2026-11-10). A link selects its node, so the drawer opens on it; a link to a session
  that is not on this Mac opens the "no such session" page. Unknown views and keys are ignored, so a link written by a
  newer build still opens the session.

**Consequences.** A link works only where the app is installed and only for a session that Mac has: session ids are not
global addresses, and the archive is local (tenet 2). The app and its helper are built from one commit, so the bundle
cannot ship a client that asks for routes its own engine lacks. One thing is left open: a build that other Macs accept
needs a Developer ID, which this Mac does not have. (The icon came on 2026-11-10: `build.sh` makes `AppIcon.icns` from
`Resources/AppIcon.png`.)

**Changed on 2026-11-11**, after the code review of that day.

- **The shipped app starts only its own helper.** A release build whose bundle holds `Contents/Helpers/skit` uses that
  and nothing else. `$SKIT_BIN` and the directories of `PATH` are still tried by a debug build and by a run from the
  build directory. What the app finds it installs as a login agent, so what it finds must be what was signed with it.
- **The agent follows the app, from a place that stays.** The agent's plist names the helper by its path. On every
  launch the app compares that path with its own helper and installs again when the agent's binary is gone or is the
  helper of another copy of the app. An agent someone installed from a `skit` of their own, still there, is kept, as
  above. From a translocated path (`/AppTranslocation/`, where macOS runs an app opened in Downloads) or a mounted
  volume (`/Volumes/`) nothing is installed: those paths are gone after a quit or an eject, and the agent would stop
  archiving without a word. With no agent serving, the window asks for the app to be moved to Applications; with one
  serving, the app works and says so.
- **Compatibility is more than route names.** An engine that serves every route under another version than the app's own
  helper is said once, and Settings › Engine shows both versions beside the restart. An engine whose status, sessions or
  annotations the app cannot decode gets the same page and the same remedy as one that lacks a route.
- **Links in a transcript open the web and nothing else.** Rendered Markdown keeps a link only when it is http or https,
  and writes the host after a label that does not name it. A transcript is whatever a model, a tool result or a fetched
  page put in it; `[notes](file:///…/setup.command)` must not be one click from running. The app's own
  `skit-visualizer://` links are not affected: they arrive through the system, not through rendered text.
- **Open does not run what a session touched.** With no application chosen in Settings, Open hands a file to its default
  application only when it is text, source, a data format, a picture or a PDF, and is neither executable nor a directory
  or bundle. Anything else is shown in Finder. A chosen application still gets whatever file it is given.
