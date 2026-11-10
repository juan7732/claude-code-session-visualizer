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
  runs on the Mac that built it and Gatekeeper refuses it elsewhere. Notarizing and stapling are not in the script yet.
- **Links are `skit-visualizer://session/<id>`**, with the view and one node in the query: `?view=transcript&action=60`,
  `&turn=3`, `&tool=<id>`, `&subagent=<agent id>[&step=4]`, `&compaction=0`, `&file=<path>`, `&outside=<kind:name>`. The
  scheme name is Juan's choice (2026-11-10). A link selects its node, so the drawer opens on it; a link to a session
  that is not on this Mac opens the "no such session" page. Unknown views and keys are ignored, so a link written by a
  newer build still opens the session.

**Consequences.** A link works only where the app is installed and only for a session that Mac has: session ids are not
global addresses, and the archive is local (tenet 2). The app and its helper are built from one commit, so the bundle
cannot ship a client that asks for routes its own engine lacks. Two things are left open: the app has no icon, and a
build that other Macs accept needs a Developer ID, which this Mac does not have.
