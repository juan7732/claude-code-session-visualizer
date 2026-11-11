#!/usr/bin/env python3
"""Writes a made-up home for pictures: a ~/.claude with sessions nobody had.

    make_demo_home.py <home> [--running-editor PID] [--running-terminal PID] [--editor-host PID]

Everything in a picture of SessionVisualizer is somebody's work: prompts, file
names, what the agent said. Pictures for the README and for a launch therefore
come from this home and from nowhere else. It holds one invented developer
with three small projects (a tide-times API, its web page, a notes folder),
some thirty sessions over two months, skills, an agent, a hook, a connector, and
(when process ids are given) sessions that look as if they were running now.

<home> is used as $HOME by `skit serve`: sessions go to <home>/.claude, the
projects' files to <home>/<project>. The clock is this machine's: sessions are
placed so many days and minutes before now.

Only the Python standard library. The record shapes are the ones Claude Code
2.1 writes, cut down to what the engine reads (docs/record-anatomy.md).
"""
import argparse
import datetime as dt
import json
import os
import random
import sys
import uuid

MAIN = "claude-sonnet-5-5"
SMALL = "claude-haiku-5-5"
VERSION = "2.1.319"
NOW = dt.datetime.now().astimezone().replace(microsecond=0)  # this machine's zone: a session at 9 is at 9 here
rng = random.Random(7)


def iso(t):
    t = t.astimezone(dt.timezone.utc)
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}Z"


def sid(name):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "sessionvisualizer-demo/" + name))


class Tool:
    def __init__(self, name, input, result="", secs=1.2, error=False, sub=None, sub_type="Explore", folder=""):
        self.name, self.input, self.result, self.secs, self.error = name, input, result, secs, error
        # sub: the steps of the subagent an Agent call starts. folder: where a Skill call's skill lives.
        self.sub, self.sub_type, self.folder = sub, sub_type, folder


class Session:
    """One transcript being written, record after record, with a clock."""

    def __init__(self, home, name, project, start, title, entrypoint="claude-vscode", model=MAIN, branch="main"):
        self.home, self.id, self.title = home, sid(name), title
        self.cwd = os.path.join(home, project)
        self.slug = self.cwd.replace("/", "-").replace(".", "-")
        self.t, self.entry, self.model, self.branch = start, entrypoint, model, branch
        self.recs, self.parent, self.n, self.req = [], None, 0, 0
        self.ctx = rng.randint(18_000, 26_000)   # the system prompt and the tools
        self.pending_new = 0                     # tokens the next request sends that no cache has yet
        self.out_total = self.read_total = self.write_total = 0
        self.subagents = []
        self.ttl = "ephemeral_1h_input_tokens"
        self.last_prompt = ""
        self.agent = None                        # set for a subagent's transcript

    def _id(self, prefix):
        self.n += 1
        return f"{prefix}{self.n:04d}-{self.id[:8]}"

    def emit(self, rec, chain=True):
        rec.setdefault("sessionId", self.id)
        if "timestamp" not in rec and rec["type"] in ("user", "assistant", "system", "attachment"):
            rec["timestamp"] = iso(self.t)
        if self.agent:
            rec["isSidechain"], rec["agentId"] = True, self.agent
        if chain and rec["type"] in ("user", "assistant", "system", "attachment"):
            rec.setdefault("uuid", self._id("r"))
            rec["parentUuid"] = self.parent
            self.parent = rec["uuid"]
        self.recs.append(rec)
        return rec

    def tick(self, seconds):
        self.t += dt.timedelta(seconds=seconds)

    def attach(self, kind, **fields):
        self.emit({"type": "attachment", "cwd": self.cwd, "version": VERSION, "entrypoint": self.entry, "attachment": {"type": kind, **fields}})

    def offer(self, skills, agents, connectors=()):
        """What Claude Code tells a session it has: its skills, agent types and connectors."""
        self.attach("skill_listing", names=list(skills), isInitial=True, skillCount=len(skills))
        self.attach("agent_listing_delta", addedTypes=list(agents), builtInTypes=[a for a in agents if a in ("Explore", "Plan", "general-purpose")], isInitial=True)
        if connectors:
            self.attach("deferred_tools_delta", addedNames=[f"mcp__{c}__{tool}" for c, tool in connectors], surfacedNames=[])

    def loads(self, *paths):
        self.attach("instructions", files=[{"path": p, "type": "AutoMem" if "/memory/" in p else "Project", "content": ""} for p in paths])

    def prompt(self, text, after=0, command=None):
        """The person's turn. `command` is a slash command typed in place of prose."""
        self.tick(after)
        self.last_prompt = text if not command else f"/{command}"
        content = text if not command else f"<command-message>{command}</command-message>\n<command-name>/{command}</command-name>\n<command-args>{text}</command-args>"
        self.emit({"type": "user", "isSidechain": False, "turnOrigin": "human", "promptId": self._id("p"), "cwd": self.cwd, "gitBranch": self.branch,
                   "version": VERSION, "entrypoint": self.entry, "message": {"role": "user", "content": content}})
        self.pending_new += len(text) // 4 + 20
        self.emit({"type": "last-prompt", "lastPrompt": self.last_prompt[:200]}, chain=False)
        self.emit({"type": "ai-title", "aiTitle": self.title}, chain=False)

    def skill_text(self, folder, call=None):
        rec = {"type": "user", "isMeta": True, "message": {"role": "user", "content": [{"type": "text", "text": f"Base directory for this skill: {folder}\n\n(the skill's instructions)"}]}}
        if call:
            rec["sourceToolUseID"] = call
        self.emit(rec)

    def act(self, text=None, tools=(), thinking=None, secs=None, end=False, model=None):
        """One request to the model and what came of it: thinking, words, tool calls and their results."""
        model = model or self.model
        self.req += 1
        blocks = []
        if thinking:
            blocks.append({"type": "thinking", "thinking": thinking, "signature": "sig"})
        if text:
            blocks.append({"type": "text", "text": text})
        calls = []
        for tool in tools:
            call = self._id("toolu_")
            calls.append((call, tool))
            blocks.append({"type": "tool_use", "id": call, "name": tool.name, "input": tool.input})
        # What is written out is a fraction of what the model wrote: its thinking is long and mostly unseen.
        thought = rng.randint(120, 900) if not self.agent else rng.randint(20, 120)
        out = sum(len(json.dumps(b)) for b in blocks) // 3 + thought
        written = self.pending_new + rng.randint(40, 160)
        usage = {"input_tokens": rng.randint(3, 9), "output_tokens": out, "cache_read_input_tokens": self.ctx, "cache_creation_input_tokens": written,
                 "cache_creation": {"ephemeral_1h_input_tokens": 0, "ephemeral_5m_input_tokens": 0}, "output_tokens_details": {"thinking_tokens": thought}}
        usage["cache_creation"][self.ttl] = written
        self.ctx += written + out
        self.pending_new = 0
        self.out_total, self.read_total, self.write_total = self.out_total + out, self.read_total + usage["cache_read_input_tokens"], self.write_total + written
        # The answer arrives block by block; the model's time is before the first of them.
        self.tick(secs if secs is not None else 3 + out / 38)
        stop = "tool_use" if calls else "end_turn"
        for i, block in enumerate(blocks):
            self.emit({"type": "assistant", "requestId": f"req_{self.id[:6]}_{self.req}", "apiBlockIndex": i, "cwd": self.cwd, "version": VERSION,
                       "message": {"id": f"msg_{self.id[:6]}_{self.req}", "model": model, "role": "assistant", "content": [block], "stop_reason": stop, "usage": usage}})
            self.tick(0.15)
        for call, tool in calls:
            if tool.name == "Skill":
                self.tick(0.3)
            result = tool.result
            extra = {"toolUseResult": {"stdout": result[:200]}, "permissionDecision": {"decision": "accept", "source": "config"}}
            if tool.sub is not None:
                agent = self.subagent(call, tool)
                extra = {"toolUseResult": {"status": "completed", "agentId": agent, "resolvedModel": SMALL}}
            else:
                self.tick(tool.secs)
            self.emit({"type": "user", **extra, "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": call, "content": result, **({"is_error": True} if tool.error else {})}]}})
            # A result is longer than the line of it kept here: a file read is thousands of tokens.
            self.pending_new += len(result) // 4 + {"Read": 2400, "Bash": 700, "Grep": 500, "WebFetch": 3200, "WebSearch": 1800, "Agent": 900}.get(tool.name, 150) * rng.uniform(0.5, 1.6)
            self.pending_new = int(self.pending_new)
            if tool.name == "Skill":
                self.skill_text(tool.folder, call)
        if end:
            self.tick(0.2)

    def subagent(self, call, tool):
        """A subagent's own transcript, beside the session's, for the time its call took."""
        agent = uuid.uuid5(uuid.NAMESPACE_URL, self.id + call).hex[:17]
        sub = Session(self.home, self.id + agent, os.path.relpath(self.cwd, self.home), self.t, "", model=SMALL)
        sub.id, sub.agent, sub.ctx = self.id, agent, rng.randint(9_000, 12_000)
        sub.n = 5000 + 500 * len(self.subagents)  # its records and calls are numbered apart from the session's
        sub.emit({"type": "user", "promptId": sub._id("sp"), "message": {"role": "user", "content": tool.input.get("prompt", "")}})
        for step in tool.sub:
            sub.act(**step)
        self.t = sub.t
        self.subagents.append((agent, {"agentType": tool.sub_type, "isBuiltIn": tool.sub_type in ("Explore", "Plan", "general-purpose"), "description": tool.input.get("description", ""),
                                       "toolUseId": call, "spawnDepth": 1, "model": "haiku", "finished": True}, sub.recs))
        return agent

    def compact(self, summary):
        before = self.ctx
        self.tick(4)
        self.emit({"type": "system", "subtype": "compact_boundary", "level": "info", "content": "Conversation compacted",
                   "compactMetadata": {"trigger": "auto", "preTokens": before, "postTokens": 14_000, "cumulativeDroppedTokens": before - 14_000, "durationMs": 41_000}})
        self.tick(41)
        self.emit({"type": "user", "isCompactSummary": True, "turnOrigin": "human", "isVisibleInTranscriptOnly": True,
                   "message": {"role": "user", "content": "This session is being continued from a previous conversation that ran out of context.\n\nSummary:\n" + summary}})
        self.ctx = 14_000 + 22_000

    def write(self, cost=True):
        folder = os.path.join(self.home, ".claude", "projects", self.slug)
        os.makedirs(folder, exist_ok=True)
        if cost:
            usd = round((self.out_total * 15 + self.read_total * 0.3 + self.write_total * 6) / 1e6 * 2.2, 2)
            self.emit({"type": "cost-state", "totalCostUSD": usd, "totalLinesAdded": rng.randint(8, 140), "totalLinesRemoved": rng.randint(0, 40),
                       "modelUsage": {self.model: {"inputTokens": 400, "outputTokens": self.out_total, "cacheReadInputTokens": self.read_total, "cacheCreationInputTokens": self.write_total, "costUSD": usd}}}, chain=False)
        path = os.path.join(folder, self.id + ".jsonl")
        with open(path, "w") as f:
            for rec in self.recs:
                f.write(json.dumps(rec) + "\n")
        when = self.t.timestamp()
        os.utime(path, (when, when))
        for agent, meta, recs in self.subagents:
            sub = os.path.join(folder, self.id, "subagents")
            os.makedirs(sub, exist_ok=True)
            with open(os.path.join(sub, f"agent-{agent}.jsonl"), "w") as f:
                for rec in recs:
                    f.write(json.dumps(rec) + "\n")
            with open(os.path.join(sub, f"agent-{agent}.meta.json"), "w") as f:
                json.dump(meta, f)
        return path


def put(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


# ---------------------------------------------------------------------------------------------
# The projects' own files: what the file viewer shows.

CACHE_GO = '''package tides

import (
	"sync"
	"time"
)

// cache keeps a station's answer for an hour: NOAA publishes predictions
// once, and asking again for the same day returns the same numbers.
type cache struct {
	mu      sync.Mutex
	entries map[string]entry
	now     func() time.Time
}

type entry struct {
	at    time.Time
	tides []Tide
}

const keep = time.Hour

func (c *cache) get(station string) ([]Tide, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.entries[station]
	if !ok || c.now().Sub(e.at) > keep {
		return nil, false
	}
	return e.tides, true
}

func (c *cache) put(station string, tides []Tide) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.entries[station] = entry{at: c.now(), tides: tides}
}
'''

TIDES_GO = '''package tides

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// Tide is one high or low water at a station.
type Tide struct {
	At     time.Time `json:"at"`
	Kind   string    `json:"kind"` // "high" or "low"
	Metres float64   `json:"metres"`
}

// Handler serves GET /stations/{id}/tides.
func (s *Server) Handler(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	tides, ok := s.cache.get(id)
	if !ok {
		var err error
		if tides, err = s.noaa.Predictions(r.Context(), id, time.Now()); err != nil {
			http.Error(w, fmt.Sprintf("station %s: %v", id, err), http.StatusBadGateway)
			return
		}
		s.cache.put(id, tides)
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(tides)
}
'''

CHART_TSX = '''import { scaleTime, scaleLinear, line, curveNatural } from "d3";
import type { Tide } from "./api";

/** The day's tide as one curve, with high and low water marked. */
export function TideChart({ tides, width = 640, height = 220 }: { tides: Tide[]; width?: number; height?: number }) {
  const x = scaleTime().domain([tides[0].at, tides[tides.length - 1].at]).range([24, width - 24]);
  const y = scaleLinear().domain([-0.5, 3.5]).range([height - 24, 16]);
  const path = line<Tide>().x((t) => x(t.at)).y((t) => y(t.metres)).curve(curveNatural)(tides);
  return (
    <svg viewBox={`0 0 ${width} ${height}`} role="img" aria-label="Tide heights today">
      <path d={path ?? ""} fill="none" stroke="currentColor" strokeWidth={2} />
      {tides.map((t) => (
        <circle key={+t.at} cx={x(t.at)} cy={y(t.metres)} r={3.5} className={t.kind} />
      ))}
    </svg>
  );
}
'''


def projects(home):
    put(f"{home}/tidepool/cache.go", CACHE_GO)
    put(f"{home}/tidepool/tides.go", TIDES_GO)
    put(f"{home}/tidepool/cache_test.go", "package tides\n\nimport \"testing\"\n\nfunc TestCacheExpires(t *testing.T) {\n\t// the clock is the test's own\n}\n")
    put(f"{home}/tidepool/noaa.go", "package tides\n\n// noaa asks the CO-OPS API for a station's predictions.\n")
    put(f"{home}/tidepool/ratelimit.go", "package tides\n\n// limiter allows each client sixty requests a minute.\n")
    put(f"{home}/tidepool/fly.toml", 'app = "tidepool"\nprimary_region = "sea"\n\n[http_service]\n  internal_port = 8080\n')
    put(f"{home}/tidepool/README.md", "# tidepool\n\nToday's high and low tides for a NOAA station, as JSON.\n")
    put(f"{home}/tidepool/CLAUDE.md", "# tidepool\n\nGo 1.26. `just check` before saying a change is done. Never call NOAA from a test.\n")
    put(f"{home}/tidepool/.claude/skills/release-notes/SKILL.md", "---\nname: release-notes\ndescription: Write the release notes for a tag from the commits since the last one, grouped by what a user would notice.\n---\nSteps.\n")
    put(f"{home}/tidepool/.claude/agents/reviewer.md", "---\nname: reviewer\ndescription: Reviews a change before it is committed. Reads the diff, runs the tests, says what it would not ship.\ntools: Read, Grep, Bash\n---\nReview.\n")
    put(f"{home}/tidepool/.claude/settings.json", json.dumps({"hooks": {"PostToolUse": [{"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "gofmt -l ."}]}]}}, indent=2))
    put(f"{home}/tidepool/.mcp.json", json.dumps({"mcpServers": {"github": {"type": "http", "url": "https://api.githubcopilot.com/mcp/"}}}, indent=2))
    put(f"{home}/tidepool-web/src/TideChart.tsx", CHART_TSX)
    put(f"{home}/tidepool-web/src/api.ts", "export type Tide = { at: Date; kind: \"high\" | \"low\"; metres: number };\n")
    put(f"{home}/tidepool-web/src/theme.css", ":root { color-scheme: light dark; }\n")
    put(f"{home}/tidepool-web/package.json", json.dumps({"name": "tidepool-web", "scripts": {"test": "vitest run", "dev": "vite"}}, indent=2))
    put(f"{home}/tidepool-web/CLAUDE.md", "# tidepool-web\n\nReact and d3. `npm test` runs vitest.\n")
    put(f"{home}/notes/2026-week-45.md", "# Week 45\n\n- tidepool: rate limiting shipped\n")
    # What Claude Code holds for the person.
    claude = f"{home}/.claude"
    put(f"{claude}/CLAUDE.md", "# Mine\n\nBe brief. Show the command you ran.\n")
    put(f"{claude}/skills/deploy/SKILL.md", "---\nname: deploy\ndescription: Deploy the current project. Runs the checks, builds, ships to the environment named, and watches the first minute of logs.\n---\nSteps.\n")
    put(f"{claude}/skills/tidy-notes/SKILL.md", "---\nname: tidy-notes\ndescription: Turn a week of loose notes into one page with what was decided and what is open.\n---\nSteps.\n")
    for name, what in (("pdf", "Read, fill in and make PDF files."), ("xlsx", "Read and write spreadsheets."), ("docx", "Read and write Word documents.")):
        put(f"{claude}/skills/synced/bucket/{name}/SKILL.md", f"---\nname: {name}\ndescription: {what}\n---\n")
    put(f"{claude}/settings.json", json.dumps({"model": "sonnet", "cleanupPeriodDays": 30, "permissions": {"allow": ["Bash(go test:*)", "Bash(npm test:*)", "Bash(git status)"]}}, indent=2))
    slug = f"{home}/tidepool".replace("/", "-")
    put(f"{claude}/projects/{slug}/memory/MEMORY.md", "- [NOAA station ids](noaa-stations.md)\n- [Deploys go to sea first](deploy-order.md)\n")
    put(f"{claude}/projects/{slug}/memory/noaa-stations.md", "Seattle is 9447130.\n")
    put(f"{claude}/projects/{slug}/memory/deploy-order.md", "Seattle region first, then the rest.\n")
    put(f"{claude}.json", json.dumps({
        "numStartups": 412, "firstStartTime": "2026-03-02T17:20:11.000Z", "autoCompactEnabled": True,
        "skillUsage": {"deploy": {"usageCount": 11, "lastUsedAt": int((NOW - dt.timedelta(days=2)).timestamp() * 1000)}, "release-notes": {"usageCount": 3, "lastUsedAt": int((NOW - dt.timedelta(days=9)).timestamp() * 1000)}},
        "claudeAiMcpEverConnected": ["claude.ai Google Drive"],
        "cachedGrowthBookFeatures": {"tengu_amber_prism": True, "tengu_quiet_harbor": False, "tengu_slate_finch": {"limit": 3}, "tengu_marble_run": "b"},
        "cachedExperimentData": {"tengu_amber_prism": {"experimentId": "tengu_amber_prism_experiment", "variationId": 1, "value": True}},
        "projects": {f"{home}/tidepool": {"allowedTools": ["Bash(go test:*)"], "hasTrustDialogAccepted": True, "mcpServers": {}}, f"{home}/tidepool-web": {"allowedTools": [], "hasTrustDialogAccepted": True}},
    }, indent=2))


SKILLS = ["deploy", "tidy-notes", "release-notes", "anthropic-skills:pdf", "anthropic-skills:xlsx", "anthropic-skills:docx", "init", "code-review", "security-review", "loop"]
AGENTS = ["Explore", "Plan", "general-purpose", "reviewer"]
GITHUB = [("github", "create_pull_request"), ("github", "list_issues"), ("claude_ai_Google_Drive", "search")]


def begin(home, name, project, days, hour, title, minute=0, at=None, **kw):
    start = at or (NOW - dt.timedelta(days=days)).replace(hour=hour, minute=minute, second=rng.randint(0, 50))
    if start > NOW:
        start -= dt.timedelta(days=1)
    s = Session(home, name, project, start, title, **kw)
    s.offer(SKILLS if project == "tidepool" else [k for k in SKILLS if k != "release-notes"], AGENTS if project == "tidepool" else AGENTS[:3], GITHUB if project == "tidepool" else GITHUB[2:])
    paths = [f"{home}/.claude/CLAUDE.md"]
    if project != "notes":
        paths.append(f"{home}/{project}/CLAUDE.md")
    if project == "tidepool":
        paths.append(f"{home}/.claude/projects/{(home + '/tidepool').replace('/', '-')}/memory/MEMORY.md")
    s.loads(*paths)
    return s


# ---------------------------------------------------------------------------------------------
# The sessions that are opened in pictures: written out by hand.

def tide_endpoint(home):
    s = begin(home, "endpoint", "tidepool", 19, 9, "Tide table endpoint from NOAA predictions")
    p = f"{home}/tidepool"
    s.prompt("Add GET /stations/{id}/tides. It should return today's high and low tides for a NOAA station as JSON. Cache each station's answer for an hour so we do not hammer their API.")
    s.act("I'll look at how the server is laid out before adding a route.", [Tool("Read", {"file_path": f"{p}/main.go"}, "package main\n\nfunc main() {\n\tmux := http.NewServeMux()\n\t…"), Tool("Grep", {"pattern": "HandleFunc", "path": p}, "main.go:14:\tmux.HandleFunc(\"GET /healthz\", health)")],
          thinking="There is one route so far. A handler per file keeps it readable; the cache can be a small type of its own with an injectable clock so the test does not sleep.")
    s.act(None, [Tool("WebFetch", {"url": "https://api.tidesandcurrents.noaa.gov/api/prod/", "prompt": "How are high and low tide predictions requested for one station and one day?"}, "product=predictions&interval=hilo returns only the highs and lows. datum=MLLW, units=metric, time_zone=gmt, format=json. One request covers a date range.", secs=3.8)])
    s.act("NOAA returns only highs and lows with `interval=hilo`, which is exactly what we need. Writing the client, the cache and the handler.", [
        Tool("Write", {"file_path": f"{p}/noaa.go", "content": "package tides\n…"}, "File created successfully", secs=0.4),
        Tool("Write", {"file_path": f"{p}/cache.go", "content": CACHE_GO}, "File created successfully", secs=0.4),
        Tool("Write", {"file_path": f"{p}/tides.go", "content": TIDES_GO}, "File created successfully", secs=0.4)], secs=38)
    s.act(None, [Tool("Write", {"file_path": f"{p}/cache_test.go", "content": "package tides\n…"}, "File created successfully", secs=0.3),
                 Tool("Bash", {"command": "go test ./...", "description": "Run the tests"}, "--- FAIL: TestCacheExpires (0.00s)\n    cache_test.go:31: entry was still served after 61 minutes\nFAIL\tgithub.com/maya/tidepool\t0.212s", secs=6.2, error=True)])
    s.act("The expiry compares against the wall clock, not the cache's own clock, so the test's clock is ignored. Fixing that one line.", [
        Tool("Edit", {"file_path": f"{p}/cache.go", "old_string": "time.Since(e.at) > keep", "new_string": "c.now().Sub(e.at) > keep"}, "The file has been updated.", secs=0.3),
        Tool("Bash", {"command": "go test ./...", "description": "Run the tests again"}, "ok  \tgithub.com/maya/tidepool\t0.187s", secs=5.9)])
    s.act("`GET /stations/{id}/tides` is in. It asks NOAA for today's highs and lows (`interval=hilo`), keeps each station's answer for an hour, and answers 502 with NOAA's own message when a station id is wrong.\n\nThe cache takes its clock as a field, so the expiry test runs without sleeping. One thing I did not do: there is no limit on how many stations are cached. With a few hundred stations that is a few hundred kilobytes; say if you want a bound.", end=True)
    s.prompt("Try it against Seattle, 9447130.", after=140)
    s.act(None, [Tool("Bash", {"command": "go run . & sleep 1; curl -s localhost:8080/stations/9447130/tides | jq '.[0:2]'", "description": "Ask the running server for Seattle's tides"},
                      '[\n  {"at": "2026-10-23T04:12:00Z", "kind": "low", "metres": 0.31},\n  {"at": "2026-10-23T11:02:00Z", "kind": "high", "metres": 3.42}\n]', secs=4.4)])
    s.act("Seattle answers: a low of 0.31 m at 04:12 UTC and a high of 3.42 m at 11:02. A second request came back in 2 ms, from the cache.", end=True)
    s.prompt("Good. Commit it.", after=45)
    s.act(None, [Tool("Bash", {"command": "git add -A && git commit -m 'Add the tides endpoint with an hour's cache'", "description": "Commit the endpoint"}, "[main 4e1c9a2] Add the tides endpoint with an hour's cache\n 4 files changed, 118 insertions(+)", secs=0.9)])
    s.act("Committed as `4e1c9a2`.", end=True)
    return s.write()


def flaky_test(home):
    s = begin(home, "flaky", "tidepool", 12, 14, "Why the cache test fails one run in ten", minute=20)
    p = f"{home}/tidepool"
    s.prompt("TestCacheConcurrent fails about one run in ten on CI and never on my laptop. Find out why before changing anything.")
    s.act("I'll reproduce it first, then read the test with that in mind.", [Tool("Bash", {"command": "go test -run TestCacheConcurrent -count=200 -race ./...", "description": "Run the test two hundred times under the race detector"},
          "WARNING: DATA RACE\nRead at 0x00c000126180 by goroutine 31:\n  tidepool.(*cache).get()\n      cache.go:27 +0x64\nPrevious write at 0x00c000126180 by goroutine 30:\n  tidepool.(*cache).put()\n      cache.go:38 +0x9c\nFAIL", secs=21.5, error=True)],
          thinking="CI has more cores than the laptop, which is why it shows there. The race detector should say where.")
    s.act("The race detector names it at once. Two readers will look for every place the map is touched while I read the test.", [
        Tool("Agent", {"description": "Find every access to the cache's map", "prompt": "List every read and write of cache.entries in this repository and say whether the mutex is held.", "subagent_type": "Explore"},
             "cache.entries is touched in four places. get and put hold the mutex. `size()` (cache.go:44) and the test helper `reset()` (cache_test.go:12) do not.", sub=[
                 dict(tools=[Tool("Grep", {"pattern": "\\.entries", "path": p}, "cache.go:27\ncache.go:38\ncache.go:44\ncache_test.go:12", secs=0.4)]),
                 dict(tools=[Tool("Read", {"file_path": f"{p}/cache.go"}, CACHE_GO[:400], secs=0.2), Tool("Read", {"file_path": f"{p}/cache_test.go"}, "func reset(c *cache) { c.entries = map[string]entry{} }", secs=0.2)]),
                 dict(text="cache.entries is touched in four places. get and put hold the mutex. `size()` and the test helper `reset()` do not.", end=True)]),
        Tool("Agent", {"description": "Check how CI runs the tests", "prompt": "Read the CI workflow and say how the tests are run there, and with how many processors.", "subagent_type": "Explore"},
             "CI runs `go test -race -count=1 ./...` on a 16-core runner; GOMAXPROCS is not set.", sub=[
                 dict(tools=[Tool("Read", {"file_path": f"{p}/.github/workflows/ci.yml"}, "runs-on: ubuntu-latest-16-cores\n      - run: go test -race -count=1 ./...", secs=0.3)]),
                 dict(text="CI runs `go test -race -count=1 ./...` on a 16-core runner.", end=True)])])
    s.act("**Why it fails:** the test's own helper `reset()` replaces the map without holding the mutex, while goroutines started by the previous subtest are still calling `get`. On 16 cores they overlap about one run in ten; on your laptop they almost never do. `size()` has the same flaw but nothing calls it concurrently yet.\n\nThe cache itself is right. The fix is two lines: take the mutex in `reset()` and in `size()`. I have not changed anything, as you asked.", end=True)
    s.prompt("Do it, and run it a thousand times.", after=95)
    s.act(None, [Tool("Edit", {"file_path": f"{p}/cache_test.go", "old_string": "c.entries = map[string]entry{}", "new_string": "c.mu.Lock()\n\tc.entries = map[string]entry{}\n\tc.mu.Unlock()"}, "The file has been updated.", secs=0.3),
                 Tool("Edit", {"file_path": f"{p}/cache.go", "old_string": "return len(c.entries)", "new_string": "c.mu.Lock()\n\tdefer c.mu.Unlock()\n\treturn len(c.entries)"}, "The file has been updated.", secs=0.3)])
    s.attach("hook_additional_context", hookName="PostToolUse:Edit", hookEvent="PostToolUse", content=["gofmt: ok"])
    s.act(None, [Tool("Bash", {"command": "go test -run TestCacheConcurrent -count=1000 -race ./...", "description": "Run it a thousand times under the race detector"}, "ok  \tgithub.com/maya/tidepool\t48.310s", secs=49.6)])
    s.act("A thousand runs under the race detector, no failure. Both places now hold the mutex.", end=True)
    return s.write()


def deploy(home):
    s = begin(home, "deploy", "tidepool", 2, 16, "Deploy to Fly, and the port it listened on", minute=5, entrypoint="cli")
    p = f"{home}/tidepool"
    s.prompt("staging", command="deploy")
    s.skill_text(f"{home}/.claude/skills/deploy")
    s.act("Running the checks before anything is built.", [Tool("Bash", {"command": "just check", "description": "Run the project's checks"}, "go vet ./...\ngo test ./...\nok  \tgithub.com/maya/tidepool\t0.402s", secs=11.3)])
    s.act(None, [Tool("Bash", {"command": "fly deploy --app tidepool-staging", "description": "Deploy to staging"}, "==> Building image\n==> Pushing image\n--> Machine 3d8d9930b32189 failed its health check: connection refused on 0.0.0.0:8080\nError: deployment failed", secs=74.0, error=True)])
    s.act("The machine started and nothing answered on 8080. I'll look at what the server listens on.", [Tool("Grep", {"pattern": "ListenAndServe", "path": p}, 'main.go:22:\thttp.ListenAndServe("localhost:8080", mux)', secs=0.3)],
          thinking="localhost inside the machine is not reachable from Fly's proxy. It has to be all interfaces.")
    s.act("It listens on `localhost:8080`, which Fly's proxy cannot reach from outside the machine. Changing it to all interfaces.", [
        Tool("Edit", {"file_path": f"{p}/main.go", "old_string": '"localhost:8080"', "new_string": '":8080"'}, "The file has been updated.", secs=0.3),
        Tool("Bash", {"command": "fly deploy --app tidepool-staging", "description": "Deploy to staging again"}, "==> Building image\n==> Pushing image\n--> Machine 3d8d9930b32189 is healthy\nVisit https://tidepool-staging.fly.dev", secs=81.0)])
    s.act(None, [Tool("Bash", {"command": "curl -s https://tidepool-staging.fly.dev/stations/9447130/tides | jq length", "description": "Ask staging for Seattle"}, "4", secs=1.8)])
    s.act("Staging is up at https://tidepool-staging.fly.dev and answers for Seattle with four tides.\n\nThe first deploy failed its health check because the server listened on `localhost` only; it now listens on all interfaces. That change is not committed yet.", end=True)
    s.prompt("Commit that, then write the release notes for v0.4.", after=60)
    s.act(None, [Tool("Bash", {"command": "git commit -am 'Listen on all interfaces'", "description": "Commit the fix"}, "[main 9b03f7e] Listen on all interfaces\n 1 file changed, 1 insertion(+), 1 deletion(-)", secs=0.8),
                 Tool("Skill", {"skill": "release-notes"}, "Launching skill: release-notes", secs=0.2, folder=f"{p}/.claude/skills/release-notes")])
    s.act(None, [Tool("Bash", {"command": "git log v0.3.0..HEAD --oneline", "description": "The commits since v0.3"}, "9b03f7e Listen on all interfaces\n71ac210 Limit each client to sixty requests a minute\n4e1c9a2 Add the tides endpoint with an hour's cache", secs=0.4)])
    s.act("## v0.4\n\n- **Tides.** `GET /stations/{id}/tides` returns today's high and low water for a NOAA station.\n- **Fair use.** Each client gets sixty requests a minute; the answer says when to come back.\n- **Fixed.** The server could not be reached when deployed.\n\nSay the word and I'll tag it.", end=True)
    return s.write()


def rate_limit(home):
    """A long afternoon: five prompts, some thirty requests, a reviewer, one compaction. The one the Canvas and the Timeline are shown on."""
    s = begin(home, "ratelimit", "tidepool", 5, 13, "Sixty requests a minute for each client", minute=10)
    p = f"{home}/tidepool"
    s.prompt("People are scraping the tides endpoint in a loop. Limit each client to sixty requests a minute, and tell them when they may come back. Plan it first.")
    s.act("I'll read how requests come in and whether anything already identifies a client.", [Tool("Read", {"file_path": f"{p}/main.go"}, "…"), Tool("Read", {"file_path": f"{p}/tides.go"}, TIDES_GO[:300]), Tool("Grep", {"pattern": "X-Forwarded-For|RemoteAddr", "path": p}, "(no matches)")])
    s.act(None, [Tool("WebSearch", {"query": "Fly.io client IP header Fly-Client-IP"}, "Fly sets Fly-Client-IP to the address of the client that connected to the proxy. X-Forwarded-For may hold a list.", secs=2.9)])
    s.act("**Plan**\n\n1. A token bucket per client: sixty tokens, one back a second.\n2. The client is `Fly-Client-IP` when present (we are behind Fly's proxy), else the connection's address.\n3. Over the limit: 429 with `Retry-After` in seconds.\n4. Buckets not touched for ten minutes are dropped, so the map does not grow for ever.\n5. Tests with the limiter's own clock, as the cache has.\n\nNo new dependency. Shall I go on?", end=True)
    s.prompt("Yes. Keep the limiter in its own file.", after=70)
    steps = [
        ("Writing the limiter.", [Tool("Write", {"file_path": f"{p}/ratelimit.go", "content": "package tides\n…"}, "File created successfully", secs=0.4)]),
        (None, [Tool("Write", {"file_path": f"{p}/ratelimit_test.go", "content": "package tides\n…"}, "File created successfully", secs=0.4), Tool("Bash", {"command": "go test -run Limiter ./...", "description": "Run the limiter's tests"}, "--- FAIL: TestLimiterRefills (0.00s)\n    ratelimit_test.go:40: got 0 tokens after 30s, want 30\nFAIL", secs=5.1, error=True)]),
        ("The refill rounds down to whole minutes. It has to count seconds.", [Tool("Edit", {"file_path": f"{p}/ratelimit.go", "old_string": "elapsed.Minutes()", "new_string": "elapsed.Seconds()"}, "The file has been updated.", secs=0.3), Tool("Bash", {"command": "go test -run Limiter ./...", "description": "Run them again"}, "ok  \tgithub.com/maya/tidepool\t0.201s", secs=4.8)]),
        ("Now the middleware that asks the limiter before the handler runs.", [Tool("Edit", {"file_path": f"{p}/main.go", "old_string": "mux.HandleFunc(\"GET /stations/{id}/tides\", s.Handler)", "new_string": "mux.Handle(\"GET /stations/{id}/tides\", s.limited(s.Handler))"}, "The file has been updated.", secs=0.3)]),
        (None, [Tool("Read", {"file_path": f"{p}/main.go"}, "…", secs=0.2), Tool("Edit", {"file_path": f"{p}/ratelimit.go", "old_string": "// middleware", "new_string": "func (s *Server) limited(next http.HandlerFunc) http.Handler { … }"}, "The file has been updated.", secs=0.3)]),
        (None, [Tool("Bash", {"command": "go vet ./... && go test ./...", "description": "Vet and test everything"}, "ok  \tgithub.com/maya/tidepool\t0.377s", secs=7.4)]),
        ("Trying it for real: seventy requests in a row against a local server.", [Tool("Bash", {"command": "go run . & sleep 1; for i in $(seq 70); do curl -s -o /dev/null -w '%{http_code}\\n' localhost:8080/stations/9447130/tides; done | sort | uniq -c", "description": "Seventy requests in a row"}, "  60 200\n  10 429", secs=9.6)]),
        (None, [Tool("Bash", {"command": "curl -si localhost:8080/stations/9447130/tides | grep -i retry-after", "description": "What the refusal says"}, "Retry-After: 1", secs=0.8)]),
    ]
    for text, tools in steps:
        s.act(text, tools)
    s.act("The limiter is in `ratelimit.go` with its tests. Sixty requests pass and the next ten get 429 with `Retry-After`. The client is taken from `Fly-Client-IP`, else from the connection.\n\nStill to do from the plan: dropping idle buckets (step 4).", end=True)
    s.prompt("Do step 4, and have the reviewer look at the whole change before we commit.", after=180)
    for text, tools in [
        ("A sweep every minute that drops buckets idle for ten.", [Tool("Edit", {"file_path": f"{p}/ratelimit.go", "old_string": "// sweep", "new_string": "func (l *limiter) sweep(now time.Time) { … }"}, "The file has been updated.", secs=0.3)]),
        (None, [Tool("Edit", {"file_path": f"{p}/ratelimit_test.go", "old_string": "// more", "new_string": "func TestLimiterForgetsIdleClients(t *testing.T) { … }"}, "The file has been updated.", secs=0.3), Tool("Bash", {"command": "go test -race ./...", "description": "Test under the race detector"}, "ok  \tgithub.com/maya/tidepool\t1.904s", secs=8.8)]),
    ]:
        s.act(text, tools)
    s.act("Handing the change to the reviewer.", [Tool("Agent", {"description": "Review the rate limiting change", "prompt": "Review the uncommitted change: ratelimit.go, its tests and the wiring in main.go. Say what you would not ship.", "subagent_type": "reviewer"},
          "Two things I would not ship. (1) `Fly-Client-IP` is trusted even when the request did not come through Fly, so anyone can pick their own bucket by sending the header. (2) The sweep holds the limiter's mutex while it walks every bucket. The rest is sound; tests pass.", sub_type="reviewer", sub=[
              dict(tools=[Tool("Bash", {"command": "git diff --stat", "description": "What changed"}, " main.go           |  4 +-\n ratelimit.go      | 86 +++\n ratelimit_test.go | 71 +++", secs=0.4)]),
              dict(tools=[Tool("Read", {"file_path": f"{p}/ratelimit.go"}, "…", secs=0.2), Tool("Read", {"file_path": f"{p}/ratelimit_test.go"}, "…", secs=0.2), Tool("Read", {"file_path": f"{p}/main.go"}, "…", secs=0.2)]),
              dict(tools=[Tool("Grep", {"pattern": "Fly-Client-IP", "path": p}, "ratelimit.go:61", secs=0.3)], thinking="The header is read unconditionally. Outside Fly, or if the app is ever exposed directly, a client can spoof it."),
              dict(tools=[Tool("Bash", {"command": "go test -race -count=3 ./...", "description": "Run the tests three times"}, "ok  \tgithub.com/maya/tidepool\t5.511s", secs=6.1)]),
              dict(text="Two things I would not ship. (1) `Fly-Client-IP` is trusted even when the request did not come through Fly. (2) The sweep holds the mutex while it walks every bucket.", end=True)])])
    s.act("The reviewer found two things, and both are right:\n\n1. **The header is trusted from anyone.** A client can choose its own bucket by sending `Fly-Client-IP`. It should count only when the connection comes from Fly's private network.\n2. **The sweep blocks every request** while it walks the map.\n\nI'd fix both before committing. The first needs a setting for which networks to trust.", end=True)
    s.prompt("Fix both. For the first, trust the header only when FLY_APP_NAME is set.", after=110)
    s.compact("1. Primary Request and Intent:\n   - Limit each client of the tides endpoint to sixty requests a minute, with Retry-After.\n2. Key Technical Concepts:\n   - Token bucket per client; Fly-Client-IP; a sweep for idle buckets.\n3. Pending Tasks:\n   - Trust Fly-Client-IP only when FLY_APP_NAME is set. Make the sweep not block requests.")
    for text, tools in [
        ("Trusting the header only on Fly.", [Tool("Read", {"file_path": f"{p}/ratelimit.go"}, "…", secs=0.2), Tool("Edit", {"file_path": f"{p}/ratelimit.go", "old_string": "r.Header.Get(\"Fly-Client-IP\")", "new_string": "clientOf(r, onFly)"}, "The file has been updated.", secs=0.3)]),
        (None, [Tool("Edit", {"file_path": f"{p}/ratelimit_test.go", "old_string": "// spoof", "new_string": "func TestHeaderIgnoredOffFly(t *testing.T) { … }"}, "The file has been updated.", secs=0.3)]),
        ("The sweep now copies the idle keys under the lock and deletes them in a second, short pass.", [Tool("Edit", {"file_path": f"{p}/ratelimit.go", "old_string": "func (l *limiter) sweep", "new_string": "func (l *limiter) sweep"}, "The file has been updated.", secs=0.3)]),
        (None, [Tool("Bash", {"command": "go test -race -count=5 ./...", "description": "Test five times under the race detector"}, "ok  \tgithub.com/maya/tidepool\t9.220s", secs=10.4)]),
        (None, [Tool("Bash", {"command": "go test -bench Limiter -benchmem ./...", "description": "How much a request pays for the limiter"}, "BenchmarkLimiter-10    18431066    64.2 ns/op    0 B/op    0 allocs/op", secs=6.6)]),
    ]:
        s.act(text, tools)
    s.act("Both are fixed. The header counts only when `FLY_APP_NAME` is set, with a test that a spoofed header is ignored elsewhere. The sweep no longer holds the lock while it deletes. The limiter costs a request 64 ns and no allocation.", end=True)
    s.prompt("Commit, push, and open a pull request.", after=50)
    s.act(None, [Tool("Bash", {"command": "git checkout -b rate-limit && git add -A && git commit -m 'Limit each client to sixty requests a minute' && git push -u origin rate-limit", "description": "Commit and push the branch"}, "[rate-limit 71ac210] Limit each client to sixty requests a minute\n 3 files changed, 161 insertions(+), 2 deletions(-)\nbranch 'rate-limit' set up to track 'origin/rate-limit'", secs=3.9)])
    s.act(None, [Tool("mcp__github__create_pull_request", {"owner": "maya", "repo": "tidepool", "title": "Limit each client to sixty requests a minute", "head": "rate-limit", "base": "main"}, "https://github.com/maya/tidepool/pull/31", secs=2.2)])
    s.emit({"type": "pr-link", "prNumber": 31, "prUrl": "https://github.com/maya/tidepool/pull/31", "prRepository": "maya/tidepool", "timestamp": iso(s.t)}, chain=False)
    s.act("Pushed as `71ac210` on `rate-limit`, and the pull request is open: https://github.com/maya/tidepool/pull/31", end=True)
    return s.write()


def chart(home):
    s = begin(home, "chart", "tidepool-web", 8, 10, "A tide chart for the station page", minute=40)
    p = f"{home}/tidepool-web"
    s.prompt("Draw today's tides as a smooth curve on the station page, with the highs and lows marked. Use d3 for the scales only; the SVG should be plain React.")
    s.act("I'll see what the page has and what shape the API's answer takes.", [Tool("Read", {"file_path": f"{p}/src/api.ts"}, 'export type Tide = { at: Date; kind: "high" | "low"; metres: number };'), Tool("Glob", {"pattern": "src/**/*.tsx", "path": p}, "src/App.tsx\nsrc/StationPage.tsx")])
    s.act("Four points a day is too few for a line, so the curve has to be drawn through them rather than between them. A natural spline does that without overshooting much.", [
        Tool("Write", {"file_path": f"{p}/src/TideChart.tsx", "content": CHART_TSX}, "File created successfully", secs=0.4),
        Tool("Edit", {"file_path": f"{p}/src/StationPage.tsx", "old_string": "{/* chart */}", "new_string": "<TideChart tides={tides} />"}, "The file has been updated.", secs=0.3)], secs=31)
    s.act(None, [Tool("Bash", {"command": "npm test", "description": "Run the tests"}, " ✓ src/TideChart.test.tsx (3 tests) 41ms\n ✓ src/api.test.ts (5 tests) 12ms\n\n Test Files  2 passed (2)", secs=8.7)])
    s.act("The chart is on the station page: one curve through the day's highs and lows, a dot at each, drawn with plain SVG and d3's scales and line only. It takes its colour from the text colour, so it follows light and dark.", end=True)
    s.prompt("The curve dips below the lowest low between two points. Can it not?", after=200)
    s.act("That is the spline overshooting. A monotone curve cannot, at the price of flatter shoulders.", [Tool("Edit", {"file_path": f"{p}/src/TideChart.tsx", "old_string": "curveNatural", "new_string": "curveMonotoneX"}, "The file has been updated.", secs=0.3), Tool("Bash", {"command": "npm test", "description": "Run the tests"}, " Test Files  2 passed (2)", secs=8.1)])
    s.act("Switched to a monotone curve: it never goes past a high or a low. The shoulders are a little flatter than a real tide's.", end=True)
    return s.write()


# ---------------------------------------------------------------------------------------------
# The rest of two months: short sessions made from a list, so the lists, the year and the search have something in them.

SHORT = [
    ("tidepool", "Station search by name", "Let people find a station by typing part of its name.", ["Read", "Grep", "Write", "Bash"], "Search matches any part of a station's name, case and accents aside."),
    ("tidepool", "Health check that asks NOAA", "The health check should say whether NOAA answers, without calling it on every probe.", ["Read", "Edit", "Bash"], "The health check reports NOAA's state from the last real request, never from a probe of its own."),
    ("tidepool", "Metric units by default", "Return metres unless the client asks for feet.", ["Grep", "Edit", "Edit", "Bash"], "Metres by default; `?units=ft` for feet."),
    ("tidepool", "Why the cache hit ratio is low", "The cache serves only a third of requests. Why?", ["Bash", "Read", "Grep"], "The key included the request's time of day, so every minute was its own entry. The key is the station and the date now."),
    ("tidepool", "Structured logs", "Switch the logs to slog with one line per request.", ["Read", "Edit", "Edit", "Bash"], "One JSON line per request: method, path, status, duration, cache hit or miss."),
    ("tidepool", "Dependabot's Go bump", "Dependabot wants Go 1.26.3. Is anything in the way?", ["Bash", "Read"], "Nothing is in the way. The tests pass on 1.26.3 and no dependency pins an older one."),
    ("tidepool", "Graceful shutdown", "Let requests in flight finish when the machine is stopped.", ["Read", "Edit", "Bash"], "On SIGTERM the server stops accepting and gives requests in flight ten seconds."),
    ("tidepool", "A station that has no predictions", "Station 9449880 returns 502. Should it?", ["Bash", "WebFetch", "Edit", "Bash"], "That station only reports water level, not predictions. It is a 404 now, with a sentence saying so."),
    ("tidepool", "Error when NOAA is slow", "What happens when NOAA takes thirty seconds?", ["Read", "Edit", "Bash"], "The request to NOAA now gives up after five seconds, and the last cached answer is served with a header that says it is stale."),
    ("tidepool", "README for the API", "Write a README someone could use the API from.", ["Read", "Write"], "The README has the three endpoints, an example of each, and the limits."),
    ("tidepool", "Tides for a given date", "Accept ?date=2026-11-20.", ["Read", "Edit", "Edit", "Bash"], "`?date=` takes a day up to a year ahead; anything else is a 400 that names the format."),
    ("tidepool", "CORS for the web page", "The web page cannot call the API from its own domain.", ["Grep", "Edit", "Bash"], "The API answers CORS for the web page's origin and for localhost, and for nothing else."),
    ("tidepool-web", "Dark mode", "Follow the system's light and dark.", ["Read", "Edit", "Write", "Bash"], "The page follows the system. Colours are in one stylesheet as variables."),
    ("tidepool-web", "Station picker", "A box to type a station's name into, with suggestions.", ["Read", "Write", "Edit", "Bash"], "The picker suggests as you type and remembers the last station."),
    ("tidepool-web", "Times in the visitor's zone", "Show times in the reader's time zone, not UTC.", ["Grep", "Edit", "Bash"], "Times are shown in the reader's zone, with the zone's short name beside the first one."),
    ("tidepool-web", "Loading and error states", "The page is blank while it loads and when the API fails.", ["Read", "Edit", "Edit", "Bash"], "A skeleton while loading; a sentence and a retry button when the API fails."),
    ("tidepool-web", "Bundle size", "Why is the bundle 900 kB?", ["Bash", "Read", "Edit", "Bash"], "All of d3 was imported. With the three modules the chart uses, the bundle is 212 kB."),
    ("tidepool-web", "Accessibility pass on the chart", "Can a screen reader make sense of the chart?", ["Read", "Edit", "Bash"], "The chart has a title and a table of the same numbers that only a screen reader sees."),
    ("tidepool-web", "Deploy previews", "A preview for every pull request.", ["Read", "Write", "Bash"], "Every pull request gets its own preview address, posted on the pull request."),
    ("tidepool-web", "Vitest instead of Jest", "Move the tests to Vitest.", ["Bash", "Edit", "Edit", "Bash"], "The eight tests run under Vitest in a third of the time."),
    ("notes", "Week 44 notes into one page", "Tidy this week's notes.", ["Read", "Read", "Write"], "One page: four decisions, three things still open."),
    ("notes", "What did we decide about caching?", "Find what I wrote about how long to cache.", ["Grep", "Read"], "On 21 October you settled on an hour, because NOAA publishes predictions once a day."),
    ("notes", "Talk outline", "Outline a ten-minute talk about tidepool.", ["Read", "Write"], "An outline in five parts, with the one demo in the middle."),
    ("tidepool", "Flyctl secrets", "Which secrets does staging have that production does not?", ["Bash", "Bash"], "Staging has NOAA_TOKEN_TEST, which production does not need. Everything else matches."),
    ("tidepool", "Benchmark the handler", "How many requests a second does one machine take?", ["Bash", "Bash", "Read"], "About 21,000 a second from the cache on one shared CPU; NOAA is the limit for the rest."),
    ("tidepool", "Sunrise and sunset too", "Would it be much work to add sunrise and sunset?", ["WebSearch", "Read"], "Not much: it is arithmetic on the station's coordinates, with no second service. A day's work with tests."),
]

RESULTS = {"Read": "…", "Grep": "3 matches", "Glob": "4 files", "Edit": "The file has been updated.", "Write": "File created successfully", "Bash": "ok", "WebFetch": "(the page)", "WebSearch": "(results)"}
WHAT = {"Read": "Reading how it is done today.", "Grep": "Looking for every place it is used.", "Edit": "Making the change.", "Write": "Writing it.", "Bash": "Running the tests.", "WebFetch": "Reading the documentation.", "WebSearch": "Looking it up."}
FILES = {"tidepool": ["main.go", "tides.go", "cache.go", "noaa.go", "ratelimit.go", "cache_test.go"], "tidepool-web": ["src/TideChart.tsx", "src/StationPage.tsx", "src/api.ts", "src/theme.css", "package.json"], "notes": ["2026-week-45.md", "2026-week-44.md", "decisions.md"]}


def short_sessions(home):
    days = sorted(rng.sample(range(3, 58), len(SHORT)))
    for (project, title, ask, tools, answer), day in zip(SHORT, days):
        s = begin(home, "short/" + title, project, day, rng.choice([8, 9, 10, 11, 13, 14, 15, 16, 17, 20]), title, minute=rng.randint(0, 55), entrypoint=rng.choice(["claude-vscode", "claude-vscode", "cli"]))
        s.prompt(ask)
        said = False
        for name in tools:
            target = f"{home}/{project}/{rng.choice(FILES[project])}"
            inp = {"Bash": {"command": "npm test" if project == "tidepool-web" else "go test ./...", "description": "Run the tests"}, "Grep": {"pattern": title.split()[0].lower(), "path": f"{home}/{project}"},
                   "WebFetch": {"url": "https://api.tidesandcurrents.noaa.gov/api/prod/", "prompt": ask}, "WebSearch": {"query": ask}}.get(name, {"file_path": target})
            fail = name == "Bash" and rng.random() < 0.12
            s.act(None if said and rng.random() < 0.5 else WHAT[name], [Tool(name, inp, "FAIL" if fail else RESULTS[name], secs=rng.uniform(4, 12) if name == "Bash" else rng.uniform(0.2, 2.5), error=fail)])
            said = True
        s.act(answer, end=True)
        if rng.random() < 0.35:
            s.prompt("Thanks. Commit it." if project != "notes" else "Good, thanks.", after=rng.randint(40, 400))
            if project != "notes":
                s.act(None, [Tool("Bash", {"command": f"git commit -am '{title}'", "description": "Commit"}, f"[main {rng.randrange(16**7):07x}] {title}\n 2 files changed", secs=0.8)])
            s.act("Done." if project == "notes" else "Committed.", end=True)
        s.write()


# ---------------------------------------------------------------------------------------------
# Sessions that look as if they were running: their last record is seconds or minutes old.

def running(home, editor_pid, terminal_pid, editor_host):
    sessions = os.path.join(home, ".claude", "sessions")
    os.makedirs(sessions, exist_ok=True)

    def process(pid, s, status, name, entry, since):
        ms = int(since.timestamp() * 1000)
        put(os.path.join(sessions, f"{pid}.json"), json.dumps({"pid": pid, "sessionId": s.id, "cwd": s.cwd, "name": name, "status": status, "entrypoint": entry, "kind": "interactive",
                                                               "startedAt": ms - 3_600_000, "updatedAt": int(NOW.timestamp() * 1000), "statusUpdatedAt": ms}))

    out = {}
    # In the editor: the tests of the web page have been running for forty seconds.
    s = begin(home, "run/web", "tidepool-web", 0, 0, "Tide heights in feet for the US", at=NOW - dt.timedelta(minutes=23))
    p = f"{home}/tidepool-web"
    s.prompt("US visitors want feet. Add a units switch that remembers the choice.")
    s.act("I'll find where heights are formatted.", [Tool("Grep", {"pattern": "metres", "path": p}, "src/TideChart.tsx:8\nsrc/StationPage.tsx:31\nsrc/api.ts:1")])
    s.act("One formatter for heights, a switch in the header, and the choice kept in local storage.", [Tool("Write", {"file_path": f"{p}/src/units.ts", "content": "…"}, "File created successfully", secs=0.4), Tool("Edit", {"file_path": f"{p}/src/StationPage.tsx", "old_string": "…", "new_string": "…"}, "The file has been updated.", secs=0.3)], secs=24)
    s.t = NOW - dt.timedelta(seconds=44)
    s.act(None, [Tool("Bash", {"command": "npm test", "description": "Run the web page's tests"}, "", secs=0)])
    s.recs = s.recs[:-1]  # the tests have not come back
    out["web"] = s
    s.write(cost=False)
    if editor_pid:
        process(editor_pid, s, "busy", "tidepool-web-3", "claude-vscode", NOW - dt.timedelta(minutes=23))

    # In a terminal: it finished six minutes ago and its cache has minutes left.
    s = begin(home, "run/api", "tidepool", 0, 0, "Tides for a week at once", at=NOW - dt.timedelta(minutes=31), entrypoint="cli")
    s.ttl = "ephemeral_5m_input_tokens"
    p = f"{home}/tidepool"
    s.prompt("Can the endpoint return a whole week when asked with ?days=7?")
    s.act("NOAA takes a date range, so a week is still one request to them.", [Tool("Read", {"file_path": f"{p}/noaa.go"}, "…"), Tool("Edit", {"file_path": f"{p}/noaa.go", "old_string": "…", "new_string": "…"}, "The file has been updated.", secs=0.3)])
    s.t = NOW - dt.timedelta(minutes=2, seconds=20)
    s.act(None, [Tool("Bash", {"command": "go test ./...", "description": "Run the tests"}, "ok  \tgithub.com/maya/tidepool\t0.391s", secs=5.2)])
    s.act("`?days=` takes 1 to 7 and is still one request to NOAA. The cache keeps a week under its own key, so a day's answer is not served for a week's question.\n\nI did not raise the limit past seven: a month would be 120 tides in one answer. Say if you want it.", end=True)
    out["api"] = s
    s.write(cost=False)
    if terminal_pid:
        process(terminal_pid, s, "idle", "tidepool-1", "cli", s.t)

    # Closed twenty minutes ago, cache still warm: worth picking up again.
    s = begin(home, "run/closed", "tidepool", 0, 0, "Release notes for v0.4", at=NOW - dt.timedelta(minutes=27))
    s.prompt("Tag v0.4 with the notes from yesterday.")
    s.act(None, [Tool("Bash", {"command": "git tag -a v0.4.0 -F notes.md && git push --tags", "description": "Tag and push"}, " * [new tag]         v0.4.0 -> v0.4.0", secs=2.4)])
    s.act("Tagged `v0.4.0` with the notes and pushed.", end=True)
    s.write(cost=False)

    if editor_pid and editor_host:
        # The editor's window, as its extension records it for Claude Code.
        put(os.path.join(home, ".claude", "ide", "4455.lock"), json.dumps({"pid": editor_host, "workspaceFolders": [f"{home}/tidepool-web"], "ideName": "Visual Studio Code"}))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("home")
    ap.add_argument("--running-editor", type=int, default=0)
    ap.add_argument("--running-terminal", type=int, default=0)
    ap.add_argument("--editor-host", type=int, default=0)
    args = ap.parse_args()
    home = os.path.abspath(args.home)
    if os.path.exists(os.path.join(home, ".claude")) and not os.path.exists(os.path.join(home, ".demo-home")):
        sys.exit(f"{home} has a .claude that this script did not make; refusing to write into it")
    os.makedirs(home, exist_ok=True)
    put(os.path.join(home, ".demo-home"), "Made by docs/launch/tools/make_demo_home.py. Safe to delete.\n")
    projects(home)
    named = {"endpoint": tide_endpoint(home), "flaky": flaky_test(home), "deploy": deploy(home), "ratelimit": rate_limit(home), "chart": chart(home)}
    short_sessions(home)
    live = running(home, args.running_editor, args.running_terminal, args.editor_host)
    ids = {name: os.path.basename(path)[:-len(".jsonl")] for name, path in named.items()}
    ids.update({"run-" + name: s.id for name, s in live.items()})
    print(json.dumps(ids, indent=2))


if __name__ == "__main__":
    main()
