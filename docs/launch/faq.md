# Questions and answers

Answers that are true of the code today. Where something depends on the release (M16), it says so.

**Does it send my sessions anywhere?** No. There is no account, no telemetry and no update check. The engine listens on
a Unix socket in `~/.sessionkit`, not on a network port. The one thing that uses the network is the download of the
embedding model for search by meaning (about 310 MB from Hugging Face, checksum verified), and only when you run
`skit embed`.

**Does it change Claude Code or my sessions?** No. It reads `~/.claude` and never writes there. It does not start,
resume or steer sessions. Its own files are in `~/.sessionkit`.

**What does it install?** One login item, `dev.sessionkit.skit`, which runs `skit serve`: it archives each session as it
is written and answers the app. The first run explains this and installs nothing until you press the button.
`skit service uninstall` removes it; deleting `~/.sessionkit` removes the archive. If you ask for `skit` in your
terminal, it also makes one link in a folder of yours, and nothing else.

**Why does it need a background program at all?** Because Claude Code deletes transcripts on its own schedule. Something
has to copy a session before that happens, whether or not the app is open.

**How much disk does the archive take?** Transcripts compress well: the archive is a zstd copy of each one plus a SQLite
index. `skit doctor` says how large Claude Code's own folder is and how large the index is. `docs/archive-sizing.md` has
measured numbers.

**Is the cost it shows accurate?** It shows the figure Claude Code itself recorded for a session, and says so. It does
not compute prices. Sessions for which Claude Code recorded none have none.

**Does it work on Intel Macs, Windows or Linux?** The app is for Apple silicon Macs on macOS 14 or later. The engine is
Go and its tests run on Linux, but only Apple silicon is supported, and there is no app elsewhere.

**Does it work with Cursor, Windsurf or the terminal?** It reads Claude Code's sessions wherever Claude Code ran: the VS
Code extension, another editor's, or a terminal. "Open in the editor" was tried with VS Code; its relatives are handled
the same way and were not tried. For a terminal it brings the terminal application forward, not the tab.

**Will a Claude Code update break it?** It can. The transcript format is not documented and changes. The parser keeps
every line it does not understand and counts it rather than failing, and the app says when an engine and an app do not
match. A fix follows the release.

**Can it tell when a session is waiting for my permission?** In a terminal, yes. In an editor Claude Code records
nothing while its permission dialog is open. A question the agent asks you is shown as "needs you"; a file edit that has
been out for ten seconds is shown as "or waiting for your permission", which is a guess and worded as one; a shell
command that waits to be allowed looks like a command that is running.

**What is the prompt cache countdown?** Each request to the model can read earlier context from a cache at a fraction of
the price. Entries live for five minutes or an hour after they were last used. The card counts down from the session's
last request; after that, the next prompt pays for the whole context again. The reminder is a notification five minutes
before.

**Is it affiliated with Anthropic?** No.

**What is `skit`?** The engine as a command line tool: `skit list`, `skit show`, `skit search`, `skit now`,
`skit primitives` and more, each with `--json`. `skit describe` prints every command and flag for an agent to read. The
app carries one inside it; SessionVisualizer › Install Command Line Tool… links it into your terminal.

**Licence?** MIT.
