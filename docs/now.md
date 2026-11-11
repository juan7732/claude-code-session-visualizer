# Now: what the sessions at work are doing

M20. `skit now` and the Now page list every session that did something in the last hour and say, for each, what it is
doing at this moment and how long its prompt cache will last.

```
skit now                     sessions at work in the last 60 minutes
skit now --minutes 240       a wider window
GET /v0/now?minutes=
```

This takes back a decision: live tailing was declined on 2026-11-09. It is done here without tailing: the engine is
asked every few seconds and reads only the end of the transcripts that changed.

## What was measured first (2026-11-11)

On this Mac, 17 transcripts, one of them a session running at the time:

- **Claude Code keeps a file per running process**, `~/.claude/sessions/<pid>.json`: the session id, the directory it
  started in, its own name for the session ("tools-77"), `entrypoint` ("claude-vscode", "cli"), `status` (`busy`,
  `idle`, `waiting`), `statusUpdatedAt`, and `waitingFor` when it waits (its binary writes "dialog open", "input
  needed", "sandbox request", "worker request", or what the open dialog names). It is not removed when a process dies
  badly, so a process is asked for by signal 0 before its file is believed.
- **What exactly it is doing is in the last records of its transcript**: a `tool_use` with no result yet is a tool
  running, and says which and since when; a last record that is the person's or a tool's means the model is being asked;
  an answer that stopped without asking for a tool ended the turn, and its text is what the agent last said.
  `last-prompt` and `ai-title` records are written every few records, so a turn of hundreds of actions does not hide the
  prompt that started it. On five transcripts all of this lay within the last 32 kB. The running session's transcript
  was 115 MB.
- **A waiting permission prompt is not in a transcript.** How a call was allowed is written on its result
  (`permissionDecision`: config, hook, user_temporary), after the fact. A prompt that is still open shows only as the
  process's `status: waiting`.
- **How long a cache lives is on every request.** A request's usage splits what it wrote to the cache into
  `ephemeral_5m_input_tokens` and `ephemeral_1h_input_tokens`. All 2,211 requests here wrote one-hour entries; 7 wrote
  nothing. A transcript that keeps copies of its requests (`api-request` records) also says when each was sent.
- **Subagents still running**: `subagents/agent-<id>.meta.json` gets `finished: true` when one is done.

## What a session is doing

`state` is one of:

| State        | Means                                                          | `since`                      |
| ------------ | -------------------------------------------------------------- | ---------------------------- |
| `model`      | the model is being asked or is answering                       | the last record handed to it |
| `tool`       | one or more tool calls are out (`tools`: name, summary, since) | the oldest call still out    |
| `blocked`    | Claude Code says it waits for the person inside a turn         | when the process said so     |
|              | (`waiting_for`, in its words)                                  |                              |
| `background` | the agent stopped, and subagents it started have not finished  | when it stopped              |
| `you`        | the turn is over (`said`: the first line of what it last said) | when it stopped              |
| `closed`     | no process has the session open; it can be resumed             | its last record              |

The process is believed for whether work is going on, the transcript for what the work is. They are written by different
parts of Claude Code, and after a turn was interrupted they disagree for good: the transcript ends on a call that will
never come back, and the process is idle. That reads as `you`, since the moment the process went idle. Busy with a
transcript whose last turn ended is `model`: the next turn has begun and is not written yet.

Each session also carries its `title`, `last_prompt`, the process's `name`, `entrypoint` and `pid`, `cwd` (where it
started) and `work_dir` (where its last record was written from), `model`, `last_at` and the transcript's size.

A session is in the window by when its transcript was last written, which costs a `stat` and no read. Processes that run
and were quiet for longer are counted in `running_outside_window`. A process whose session has no transcript yet (just
opened, nothing asked) is listed from its file alone.

## The prompt cache

`cache` is read off the last request of the main conversation:

- how much of its input was read from the cache, written to it, and neither; `hit_ratio`; and `context_tokens`, which is
  what the next prompt pays for in full once the cache is gone;
- `ttl_seconds`: the lifetime of the last write the tail shows, 300 or 3600 (where a request wrote both kinds, 300: the
  conversation is what the short one holds), 0 when no request in the tail wrote anything;
- `last_request_at`: when the last request was sent, or, in a transcript that keeps no copies of its requests, when it
  was answered;
- `expires_at` = `last_request_at` + `ttl_seconds`, and `seconds_left` at the moment asked.

So expiry is told from the last request alone, which was the plan's question. It rests on one thing a transcript cannot
show: that reading an entry refreshes it. That is how the cache is documented to behave, and it is why every request of
a busy session pushes the end back. A subagent's requests keep their own cache warm, not the session's.

## What it costs to keep current

Each answer lists `~/.claude/projects` (a `stat` per transcript), reads the few process files, and reads the **tail** of
each transcript in the window that changed since the last answer: the last megabyte, four times more (up to 16 MB) only
when that megabyte holds no request, as when one line is a 3 MB image. `skit serve` keeps what it read by size and time,
so an unchanged transcript is not read again. On this Mac `skit now` answers in about 20 ms with a 115 MB transcript
running.

The app asks every 3 seconds while the Now page shows and every 10 seconds otherwise (for the count on the rail, the
reminders, and the mark on Refresh). The clocks on the cards count by themselves between two answers.

## The page

A card per session: a colour and a line for the state with a running clock, the title, what is running or what was last
said, what was last asked, and the cache as a bar that empties, green until the reminder time, amber inside it, grey
with "the next prompt pays for 513k" once expired. Running sessions come first, in the order their processes started, so
cards do not trade places as sessions take turns writing; closed ones follow, the latest first. The window is an hour,
four hours or a day.

**Reminders.** A card's bell asks for one notification when that session's cache has five minutes left (2, 5, 10 or 15:
Settings › General › Now). The app keeps one pending notification per session and moves it each time the engine reports
a later end. Notifications need the installed app; run from the build directory the bell only marks the card.

**Refresh (⌘R)**, by the back and forward arrows, on every page: the sessions, and whatever the page in front shows,
read again. The app reads a session once when it is opened; the button carries a dot when the session in front has moved
on since (the engine's `last_at` is later than the document's).

## Limits

- **A permission prompt in VS Code may read as a tool running.** It shows as `blocked` only if Claude Code marks the
  process as waiting while the editor's own dialog is open, which was not verified: the session this was built in runs
  in a mode that does not ask. In a terminal the dialog is Claude Code's own, and it does.
- Background shell commands are not counted: a session that stopped with one still running reads as `you`.
- A subagent that wrote nothing for half an hour is not counted as running: one that was interrupted never gets its
  `finished`.
- An open session's page does not follow by itself. Refresh reads it again; whether it should follow a running session,
  and how (a 100 MB session is not free to read every few seconds), is open.
- A notification is scheduled by the app: quit the app and the last one scheduled stands, even if the session went on
  working and its cache now ends later.
