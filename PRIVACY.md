# SessionVisualizer privacy policy

_Applies to SessionVisualizer (the macOS app) and the `skit` command-line tool published from
https://github.com/juan7732/claude-code-session-visualizer. Last updated: 2026-11-11._

SessionVisualizer and `skit` run on your Mac. There is no service behind them, no account system, and no telemetry. They
do handle sensitive material: a Claude Code transcript holds your prompts, the contents of files, the output of commands
and, by accident, secrets. This document describes exactly what is read, what is kept, and what is sent over the
network, so you can judge that for yourself.

## Summary

- SessionVisualizer does **not** collect, transmit, or store analytics, usage data, crash reports, or any personal
  information. It never checks for updates.
- Your sessions do **not** leave your Mac. They are read from Claude Code's folder, copied into `~/.sessionkit/`, and
  indexed and searched there.
- It does **not** read, use, or transmit your Claude credentials, and it never talks to Anthropic.
- The only network request it ever makes is the download of one model file from Hugging Face, and only when **you** run
  `skit embed` to turn on search by meaning. The app itself makes no network request at all.
- The archive it keeps contains everything your transcripts contain, secrets included, for as long as you keep it.
  Deleting `~/.sessionkit/` removes all of it.

## What it reads

Everything here is read from your disk and nothing is written back: no file of Claude Code's is ever changed.

**Claude Code's data.** Under `~/.claude` (or `$CLAUDE_CONFIG_DIR`): the session transcripts in `projects/`, subagent
transcripts included; the small files in `sessions/` that say which sessions are running; settings files, `CLAUDE.md`
and memory files, skills, agents, commands, rules, hooks and installed plugins; and `ide/*.lock`, from which only an
editor window's folders and name are taken (the file also holds a token, which is not read out). From `~/.claude.json`
only a fixed list of harmless fields is taken; for the account and identity fields it records only whether they are set.
Settings managed by an organisation in `/Library/Application Support/ClaudeCode` are read the same way.

**Your project folders.** For the folders your sessions were started in: `CLAUDE.md`, `CLAUDE.local.md`, `.mcp.json` and
what is under `.claude/`. A connector's command, arguments, environment and headers are never copied, and a setting
whose name or value looks like a credential is shown as "set (not shown)".

**Files a session touched.** When you open a file in the Files view, or run `skit file --text`, the file is read as it
is on disk now. Only files that an archived session read or wrote can be opened this way.

**Running processes.** To tell which editor window or terminal a running session belongs to, `skit` runs `ps` and `lsof`
on that session's own processes: the parent process, the port it listens on, and one environment variable
(`CLAUDE_CODE_SSE_PORT`). It also reads the editor's list of open windows
(`~/Library/Application Support/Code/User/globalStorage/storage.json`, or the same file of a VS Code relative). None of
this is stored.

## What it stores on your machine

| Path                                                           | Contents                                                                                                                                                                                                                                 | Written by                                          |
| -------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| `~/.sessionkit/archive/`                                       | A lossless copy of every transcript: plain JSONL under zstd. Everything Claude Code recorded is in it: prompts, answers, tool calls and their results, the system prompt and tool definitions.                                           | The archiver (`skit serve`), `skit archive`         |
| `~/.sessionkit/skit.sqlite` (and `-wal`, `-shm`)               | The index: each session's summary and numbers, the text of prompts, answers and tool results for search, the paths of files touched, which skills, agents and connectors were used, and, after `skit embed`, vectors computed from text. | The archiver, `skit archive`, `skit embed`          |
| `~/.sessionkit/annotations.json`                               | The pins, tags and notes you add to sessions.                                                                                                                                                                                            | You, in the app or with `skit annotate`             |
| `~/.sessionkit/models/`                                        | The embedding model, a public file, once downloaded.                                                                                                                                                                                     | `skit embed`                                        |
| `~/.sessionkit/serve.log`                                      | The archiver's log: times, session ids, record counts and errors, which can name file paths. It is cut back when it passes 50 MB.                                                                                                        | The archiver                                        |
| `~/.sessionkit/skit.sock`, `*.lock`, `run/`                    | The socket the app talks to, lock files, and a note of the model server's process while it runs.                                                                                                                                         | The archiver                                        |
| `~/Library/LaunchAgents/dev.sessionkit.skit.plist`             | The login item that keeps the archiver running.                                                                                                                                                                                          | `skit service install`, or the app's first run      |
| `~/Library/Preferences/dev.sessionkit.SessionVisualizer.plist` | The app's settings, your recent searches (Settings can turn that off), where you left a session's canvas, and which sessions have a reminder on.                                                                                         | The app                                             |
| A place you choose                                             | A session exported as Markdown, or an image extracted from one.                                                                                                                                                                          | You, with Export or `skit export` and `skit images` |

Everything under `~/.sessionkit/` except the model is created readable by your user account alone. Nothing is encrypted
beyond what your disk already is: anyone who can read your home folder can read the archive, exactly as they can read
Claude Code's own transcripts.

The archive is deliberately complete. It is not filtered or redacted, because the point of it is to lose nothing. If a
password or a key appeared in a session, it is in the archive and in the index.

## What leaves your machine, and to whom

**Hugging Face, when you run `skit embed` for the first time.** Search by meaning needs an embedding model. `skit embed`
downloads one file, `embeddinggemma-2-Q8_0.gguf` (about 310 MB), from `huggingface.co/ggml-org/embeddinggemma-2-GGUF` at
a pinned revision, and verifies its SHA-256 before using it. What is sent is an ordinary HTTPS request for that file, to
Hugging Face and the content network it redirects to: your IP address, and nothing about you or your sessions. It is
subject to Hugging Face's privacy policy. It happens once, and never unless you run the command.

**Nothing else.** The app and the engine talk to each other over a Unix socket in `~/.sessionkit/`, not over a network
port. Search by meaning runs the model in `llama-server`, a separate program you install yourself; `skit` starts it
bound to `127.0.0.1` only, in offline mode, behind a key made up for that run, and the text it is given does not leave
the Mac. No command checks for updates. The `skit` binary contains no other HTTP client.

A few things happen only because you ask, and stay on your Mac unless you take them further:

- **A link in a transcript** opens in your browser when you click it. That request is your browser's.
- **Open in the editor** and **Open with** hand a folder or a file to another application on your Mac.
- **Copy Link** puts a `skit-visualizer://` address holding a session's id on the clipboard. It means nothing on another
  machine.
- **A cache reminder** is a local notification from macOS. It shows a session's title and a time.
- **An export** is a file. Where it goes after that is up to you.

## Credentials

SessionVisualizer has no login and needs none. It does not read your Claude credentials or your keychain, does not call
Anthropic's API, and does not start or steer Claude Code. Where it shows how Claude Code is set up, it says only whether
an account is present, never who.

It cannot promise the same for what is inside a transcript. Whatever a session printed or was given is in the copy.

## Telemetry and analytics

None. SessionVisualizer does not send usage data, error reports, or identifiers anywhere, and has no opt-in for doing
so.

## Retention and deletion

Everything is kept on your disk for as long as you keep it. The archive exists to outlast Claude Code's own cleanup, so
nothing in it expires, and `skit` has no command that deletes from it. That includes a single session: today the only
complete removal is of the whole archive.

To remove everything SessionVisualizer has written:

1. Run `skit service uninstall`, which stops the archiver and removes its login item.
2. Delete `~/.sessionkit/`.
3. Delete the app, and its settings with `defaults delete dev.sessionkit.SessionVisualizer`.

Claude Code's own files are untouched by any of this. There is no server-side data to request or delete.

## Children

SessionVisualizer is a developer tool and is not directed at children.

## Changes

Changes to this policy are made by commit to this file; the history is at
https://github.com/juan7732/claude-code-session-visualizer/commits/main/PRIVACY.md.

## Contact

Open an issue at https://github.com/juan7732/claude-code-session-visualizer/issues. For security concerns, do not open a
public issue; see [CONTRIBUTING.md](CONTRIBUTING.md).
