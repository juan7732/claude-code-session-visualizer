# Primitives: what is installed, and what is used

M22. "Primitives" is the word for what Claude Code is extended with: skills, agents (subagent definitions), slash
commands, connectors (MCP servers), hooks, plugins, and the instructions and memory files. `skit primitives` and the
Primitives page answer two questions about them: where is each one defined, and how much do the sessions use it.

```
skit primitives                      every kind: known, installed, used, unused; then each item
skit primitives skill --days 30      one kind, counting only the last 30 days
skit primitives skill cruise         one item: its definitions, its use by project, the sessions that used it
skit primitives --unused             what is installed or was on offer, and was not used
GET /v0/primitives?kind=&name=&days=&unused=1&root=
```

## Where it looks

The places and the order of precedence are the ones Claude Code's documentation gives (skills, sub-agents, slash
commands, hooks, mcp, plugins and memory pages, read 2026-11-10).

| Scope     | Where                                                                                             |
| --------- | ------------------------------------------------------------------------------------------------- |
| `managed` | `/Library/Application Support/ClaudeCode`: `.claude/skills`, `.claude/agents`, `CLAUDE.md`, hooks |
| `user`    | `~/.claude`: `skills/*/SKILL.md`, `agents/**/*.md`, `commands/**/*.md`, `rules/**/*.md`,          |
|           | `CLAUDE.md`, hooks in `settings.json`; connectors in `~/.claude.json`                             |
| `account` | skills synced from the claude.ai account (`~/.claude/skills/synced/<bucket>/<name>/`), and the    |
|           | account's connectors Claude Code remembers having connected                                       |
| `plugin`  | each install in `~/.claude/plugins/installed_plugins.json`: its `skills/`, `agents/`,             |
|           | `commands/`, `hooks/hooks.json` and `.mcp.json`                                                   |
| `project` | a project's `.claude/` (skills, agents, commands, rules, `settings.json` hooks), `.mcp.json`,     |
|           | `CLAUDE.md`; and the notes Claude Code keeps for it under `~/.claude/projects/<slug>/memory/`     |
| `local`   | a project's `.claude/settings.local.json` and `CLAUDE.local.md`; its connectors in                |
|           | `~/.claude.json`                                                                                  |

Projects are the directories sessions in the index started in, the ones Claude Code remembers in `~/.claude.json`, and
any `--root` given. Each is read, and so are the folders up to two levels below it: a workspace of repositories keeps
each repository's `.claude` one level down, and Claude Code picks those up when it works in them. The home directory,
when a session started there, is read and not searched. `node_modules`, `vendor`, build folders and hidden folders are
skipped. `looked_in` in the report names every directory something was found in.

A name defined in more than one place is one item with several `definitions`, in the order Claude Code prefers them
(`order`): for a skill or a command the organisation's, then the user's, then the project's; for an agent the project's
before the user's; for a connector local, project, user, plugin, account; hooks and memory files all apply together. Two
projects that each define a name do not compete, and both are listed.

What is never read out: what a memory or instructions file says (it is listed by path, size and date), and a connector's
arguments, environment and headers, which is where keys are put. A connector says only how it is reached: the transport,
and the program's name or the host.

A definition that is a file of its own (a skill's `SKILL.md`, an agent, a command, an instructions or memory file) says
how big it is: `bytes` and `lines`. That is the file as it is on disk, which is what the model is given when the thing
is loaded; a skill's other files are not added in. `skit primitives --json | jq` sorts by either, and the app's list has
a column for each (click a heading to sort by it). A hook or a connector lives in a settings file among other things, so
it has no size of its own.

## What counts as a use

Counted from the transcripts, as measured on real ones (2026-11-10), not from Claude Code's own counter:

- **A skill**: a `Skill` tool call (the model chose it), or a slash command whose name is a skill (the person typed it:
  the transcript then has a `<command-name>` block and no tool call). `by_user` is how many of the uses were typed. The
  skill's text arrives in a companion record that names its folder, so a use says which definition it loaded, and each
  definition has its own `calls`.
- **An agent**: an `Agent` (or `Task`) call, by the type the subagent's own file records; with the run's time and the
  tokens the subagent wrote.
- **A command**: any other slash command, Claude Code's own included (`/compact`, `/model`). A command file is offered
  to the model among the skills, so its use joins its definition whichever way the transcript shows it.
- **A connector**: a call to one of its tools (`mcp__<connector>__<tool>`), with failures and the time waited. A
  connector's name in the report is its key in tool names (`claude_ai_Gmail`); `title` is the name as written.
- **A hook**: a record Claude Code wrote because a hook ran and said something back. A hook that runs quietly leaves
  nothing, so a hook is never called unused. A use (`PostToolUse:Edit`) joins the configured hook whose event and
  matcher fit; one that fits none came from an editor or a plugin and is its own item.
- **Instructions and memory**: a file loaded into the context (the `instructions` and `nested_memory` records), and a
  note of Claude Code's memory read back with the `Read` tool.

A session also records what it had **on offer**: the skills listed for it, the agent types (and which are built in), the
connectors whose tools it was given. So three states can be told apart: used; there and not used (`unused` counts what
is installed or was on offer, and had no use in the period); and never there. An item with no definition was offered or
used: it comes with Claude Code (the bundled skills, the built-in agents, its own commands), or it was defined somewhere
that is gone. Only agents say "built in" themselves.

Claude Code's own counter (`skillUsage` in `~/.claude.json`) is shown beside a skill's use as `claude_code_counter`. It
counts on this machine since it began counting, sessions no longer kept included, and it does not say where or when; the
two can differ, in either direction.

## How it is kept

The index (schema 8) has two tables, filled when a session is archived:

- `uses`: session, kind, name, **UTC day**, calls, errors, typed, seconds, output tokens, first and last use, the turn
  of the first use that day, and the folder a skill was loaded from. A row a day, so "this month" can be asked of a
  session that ran for weeks. The day is UTC so the index reads the same in another time zone; `first_at` and `last_at`
  are exact.
- `offered`: session, kind, name, built in.

`skit primitives` reads the disk each time (it is a few hundred small files) and joins it with those tables; no
transcript is read. `--days N` counts uses in the last N days; `last_used_at` on an item is its last use at any time.

A fix came with it. A schema step that adds a table only `archive` fills (files at schema 7, these at 8) relied on every
session being indexed again. `list` refreshes a summary without filling those tables, and it stamped the row as current,
so `archive` then skipped it: after an upgrade, whichever ran first decided whether the tables were filled. A summary
refreshed by `list` now leaves an archived row at its old schema number, and `archive` does the rest.

## Limits

- Use is counted for archived sessions. A session only listed has no rows until it is archived (the background agent
  does it).
- A skill a session loaded from a folder that has moved since is counted for the name, not for a definition.
- A typed command is told from a skill by the skill's text following it or by the session's own list of skills; a
  transcript from before Claude Code wrote either reads it as a command.
- Plugins: written from the documented layout. No plugin was installed on the machine this was built on, so only tests
  have exercised it (`// REVIEW:` in `sessionkit/primitives/inventory.go`). A plugin has no use of its own: it is used
  through what it brings, which carries its name (`plugin:skill`).
- Synced skills are named `anthropic-skills:<folder>`, which is what sessions call them here; another account's may be
  named otherwise.
- Output styles, the status line and key bindings are not listed.
