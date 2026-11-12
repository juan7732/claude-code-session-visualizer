# Pictures and questions

What SessionVisualizer is in a few words, pictures of every page, and the questions people ask about it. This is the
material for the README and for showing the app to someone.

- [`faq.md`](faq.md): questions and answers that are true today.
- [`screenshots/`](screenshots): eighteen pictures, all of made-up sessions.
- [`tools/`](tools): what makes the pictures again.

## What it is

**One line.** A native Mac app that keeps every Claude Code session and shows what happened in it.

**One paragraph.** Claude Code writes a transcript of every session and deletes it after 30 days. SessionVisualizer
keeps a lossless copy on your Mac and turns each session into something you can read: a summary, the transcript, a
canvas of how the work branched, a timeline of where the time went, and the files it touched. It searches across all of
them, by words or by meaning, and shows what every running session is doing right now and how long its prompt cache has
left. It is free, open source, and nothing leaves your machine.

**What is in it**, in the order people tend to care:

| What               | In a sentence                                                                                     | Picture                                                                 |
| ------------------ | ------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| An archive         | Every session kept, losslessly, after Claude Code has deleted its own copy.                       | [onboarding-2](screenshots/onboarding-2.png)                            |
| Now                | What each running session is doing, and a countdown to when its prompt cache expires.             | [now](screenshots/now.png)                                              |
| Back to the editor | One click raises the VS Code window that is running that session.                                 | [now](screenshots/now.png)                                              |
| Summary            | What a session was about, how it ended, what it wrote, what failed.                               | [summary](screenshots/summary.png)                                      |
| The map            | On the Summary: each turn down a spine, tied to the files it touched and the services it reached. | [summary-map](screenshots/summary-map.png)                              |
| Transcript         | The conversation, with tool calls, subagents and thinking folded where you want them.             | [transcript](screenshots/transcript.png)                                |
| Canvas             | The session as a braid of prompts, steps, parallel calls and subagents; or as a score in time.    | [canvas](screenshots/canvas.png), [score](screenshots/canvas-score.png) |
| Timeline           | Where the wall time went: the model, tools, subagents, waiting for you.                           | [timeline](screenshots/timeline.png)                                    |
| Files              | Every file a session touched, as it is now, with every other session that touched it.             | [files](screenshots/files.png)                                          |
| Search             | Across every session kept. By words at once; by meaning with a model that runs on your Mac.       | [search](screenshots/search.png)                                        |
| Stats              | A year of days, tools and failures, models, the prompt cache, actions per prompt.                 | [stats](screenshots/stats.png)                                          |
| Primitives         | Skills, agents, connectors, hooks: where each is defined, how big, how much used, what never is.  | [primitives](screenshots/primitives.png)                                |
| A first run        | It says what it reads, what it keeps and what it installs before it does any of it.               | [onboarding-3](screenshots/onboarding-3.png)                            |
| `skit`             | The same engine as a command line tool with `--json` everywhere, for scripts and for agents.      |

**What it is not.** Not made by or affiliated with Anthropic. Not a wrapper around Claude Code: it does not start
sessions, change settings or write under `~/.claude`. Not a cost calculator: the dollar figures it shows are the ones
Claude Code recorded. Not for Intel Macs, Windows or Linux.

## The pictures

All eighteen are of a home that `tools/make_demo_home.py` writes: one invented developer, three small projects (a
tide-times API, its web page, a notes folder), thirty-four sessions over two months. No picture shows a real session, a
real prompt or a real path. Paths read `~/demo/…` because the home is `/Users/Shared/demo` while the pictures are taken.

| Picture                                 | Shows                                                                            |
| --------------------------------------- | -------------------------------------------------------------------------------- |
| `now.png`                               | Three cards: a command running, one waiting with 3 minutes of cache, one closed. |
| `summary.png`                           | A session at a glance: prompts, files written, the failed call, the subagent.    |
| `summary-map.png`                       | The map lower on the Summary: turns, the files and services each one touched.    |
| `transcript.png`                        | A debugging session with two subagents and the answer.                           |
| `canvas.png`, `canvas-score.png`        | The same session as a braid, and laid out in time.                               |
| `timeline.png`                          | The strip, the ledger and "Where the time went".                                 |
| `files.png`                             | A file as it is now, coloured, and the six sessions that touched it.             |
| `search.png`                            | "race detector" across sessions, with the hit.                                   |
| `stats.png`                             | Totals, the year, tools, where the time went.                                    |
| `primitives.png`                        | Skills with where each is defined, its size and lines, and whether it was used.  |
| `sessions.png`, `claude.png`            | The list, and how Claude Code is set up.                                         |
| `onboarding-1.png` … `onboarding-5.png` | The first run, step by step.                                                     |

To take them again:

```
docs/launch/tools/shots.sh              # into docs/launch/screenshots
KEEP=1 docs/launch/tools/shots.sh /tmp/shots   # and leave the made-up home and its engine up, to look around
```

The script builds the engine and the debug app from this checkout, writes the home, serves it on its own socket, draws
each page and removes the home. Your own archive and the app you use are not touched. Pictures are light only: drawn
offscreen, a dark window's toolbar comes out wrong. For a dark picture keep the home (`KEEP=1`), open the app on it and
take a real screenshot:

```
SKIT_HOME=/Users/Shared/demo/.sessionkit client/SessionVisualizer/.build/debug/SessionVisualizer
```
