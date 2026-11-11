import Foundation
import Testing
@testable import SkitKit

/// The contract with the engine: the client's models decode what `skit serve`
/// really answers for the synthetic-basics fixture. A change in the engine
/// that the client cannot read fails here, before it reaches a window.
@Suite struct ContractTests {
    let id = "aaaaaaaa-0000-0000-0000-000000000001"

    @Test func routesCoverWhatTheClientCalls() throws {
        let list = try decode(RouteList.self, "routes.json")
        #expect(SkitClient.missingRoutes(in: list.routes) == [])
        #expect(SkitClient.missingRoutes(in: ["GET /v0/status", "GET /v0/sessions?project=&limit="]).contains("GET /v0/annotations"))
    }

    @Test func status() throws {
        let status = try decode(EngineStatus.self, "status.json")
        #expect(status.sessionsOnDisk == 4)
        #expect(status.skitHome.hasSuffix(".sessionkit"))
        #expect(status.live.first?.sessionId == id)
        #expect(status.cachedSessions != nil)
    }

    @Test func sessionRows() throws {
        let rows = try decode([SessionSummary].self, "sessions.json")
        let row = try #require(rows.first { $0.id == id })
        #expect(rows.count == 4)
        #expect(row.requests == 7)
        #expect(row.turns == 2)
        #expect(row.usage.outputTokens > 0)
        #expect(row.lastAt > row.firstAt)
        #expect(row.models.isEmpty == false)
        #expect(row.context == nil)

        // A session that was opened and never used: every count is zero and every list is empty.
        let empty = try #require(rows.first { $0.id.hasPrefix("bbbbbbbb") })
        #expect(empty.requests == 0 && empty.models.isEmpty && empty.tools.isEmpty)
    }

    /// An engine from before lists were always lists sends null for an empty one.
    @Test func nullListsAreEmpty() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: fixture("sessions.json")) as? [[String: Any]])
        object[0]["models"] = NSNull()
        object[0].removeValue(forKey: "tools")
        let rows = try JSONDecoder.skit().decode([SessionSummary].self, from: JSONSerialization.data(withJSONObject: object))
        #expect(rows[0].models.isEmpty && rows[0].tools.isEmpty)
        let status = try JSONDecoder.skit().decode(EngineStatus.self, from: Data(#"{"version":"v","uptime":"1s","claude_dir":"/c","skit_home":"/s","index":{"sessions":0,"archived":0,"segments":0,"bytes":0},"live":null,"sessions_on_disk":0}"#.utf8))
        #expect(status.live.isEmpty)
        let note = try JSONDecoder.skit().decode(Annotation.self, from: Data(#"{"pinned":true,"tags":null,"notes":null}"#.utf8))
        #expect(note.pinned && note.tags.isEmpty && note.notes.isEmpty)
    }

    @Test func stats() throws {
        let stats = try decode(SessionSummary.self, "stats.json")
        #expect(stats.id == id)
        // One point per action of the main transcript; the subagent's two requests are in `requests` only.
        #expect((stats.context ?? []).count == 5)
        #expect(stats.requests == 7)
        #expect(stats.compactions == 1)
        #expect(stats.compactionList?.first?.preTokens == 6400)
        #expect(stats.rewoundActions == 0)
        // What the Summary's cards read beyond the counts.
        #expect(stats.inTurns == "12s")
        #expect(stats.injectedBlocks == 1 && stats.attachments != nil)
    }

    @Test func annotationsKeepTheirKeysAsWritten() throws {
        #expect(try decode(Annotation.self, "annotation-empty.json") == Annotation(updatedAt: RFC3339.date("0001-01-01T00:00:00Z")))
        let one = try decode(Annotation.self, "annotation.json")
        #expect(one.pinned)
        #expect(one.tags == ["keep"])
        // A decoder that converts snake_case would rewrite this key.
        #expect(one.notes["tool:toolu_01AbC"] == "on a tool call")
        let all = try decode([String: Annotation].self, "annotations.json")
        #expect(all[id] == one)
    }

    @Test func archiveResults() throws {
        let results = try decode([ArchiveResult].self, "archive.json")
        #expect(results.first?.id == id)
        #expect(["archived", "updated", "unchanged"].contains(results.first?.action ?? ""))
    }

    @Test func serviceStatus() throws {
        let status = try decode(ServiceStatus.self, "service-status.json")
        #expect(status.label == "dev.sessionkit.skit")
        #expect(status.running == false)
    }

    @Test func patchIsWrittenInTheEnginesKeys() throws {
        let patch = AnnotationPatch(pinned: true, addTags: ["keep"], notes: ["tool:toolu_01AbC": "n"])
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as? [String: Any])
        #expect(object["pinned"] as? Bool == true)
        #expect(object["add_tags"] as? [String] == ["keep"])
        #expect((object["notes"] as? [String: String])?["tool:toolu_01AbC"] == "n")
        #expect(object["remove_tags"] == nil)
    }
}

/// The session document and what hangs off it: the shapes M8's views read.
@Suite struct DocumentContractTests {
    let id = "aaaaaaaa-0000-0000-0000-000000000001"

    @Test func document() throws {
        let doc = try decode(SessionDocument.self, "document.json")
        #expect(doc.id == id)
        #expect(doc.prompts.count == 2 && doc.turns.count == 2 && doc.actions.count == 6 && doc.toolCalls.count == 4)
        #expect(doc.summary.requests == 7)

        // A turn refers to its prompt and its actions by index.
        let first = doc.turns[0]
        #expect(first.isHuman && first.promptIndex == 0)
        #expect(first.actionIndexes == [0, 1, 2, 3])
        #expect(doc.turns.flatMap(\.actionIndexes) == doc.actions.map(\.index))
        #expect(doc.prompts[1].context.count == 1)

        // Blocks keep their order; a tool call is found by the id in its tool_use block.
        let action = doc.actions[0]
        #expect(action.blocks.map(\.type) == ["thinking", "text", "tool_use"])
        #expect(action.thinking == "xxxx")
        let call = try #require(doc.toolCalls.first { $0.id == action.toolUseIDs.first })
        #expect(call.name == "Bash" && call.paired && call.action == 0 && call.turn == 0)
        #expect(call.input?["command"]?.string == "xx -xx")
        #expect(abs((call.duration ?? 0) - 0.8) < 1e-6)
        #expect(call.resultHead?.isEmpty == false)

        // An unanswered call has no end and no result: the engine writes Go's zero time for it.
        let open = try JSONDecoder.skit().decode(ToolCall.self, from: Data(#"{"id":"t9","name":"Bash","input":{},"at":"2026-11-08T10:00:02Z","ended_at":"0001-01-01T00:00:00Z","paired":false,"turn":0,"action":0}"#.utf8))
        #expect(open.endedAt == nil && open.duration == nil && open.resultHead == nil && !open.isError)

        let cut = try #require(doc.compactions.first)
        #expect(cut.metadata?.preTokens == 6400 && cut.metadata?.trigger == "auto")
        #expect(cut.summary?.isEmpty == false)

        let sub = try #require(doc.subagents.first)
        #expect(sub.toolUseId == "toolu_03" && sub.meta?.model == "haiku")
        #expect(sub.session?.actions.count == 2)
        #expect(doc.toolCalls.contains { $0.id == sub.toolUseId })
    }

    @Test func actionDetailCarriesTheFullResult() throws {
        let detail = try decode(ActionDetail.self, "action.json")
        #expect(detail.index == 3 && detail.turn == 0)
        let result = try #require(detail.toolCalls.first)
        #expect(result.name == "Edit")
        #expect(result.result?.hasPrefix("full output line 1") == true)
        // The output was spilled to a file; the source says which.
        #expect(result.resultSource?.hasSuffix("toolu_04.txt") == true)
    }

    @Test func relations() throws {
        let relations = try decode(Relations.self, "relations.json")
        #expect(relations.spans.count == 6)
        #expect(relations.spans.allSatisfy { $0.end >= $0.at })
        let handback = try #require(relations.handbacks.first)
        #expect(handback.spawn.toolId == "toolu_03")
        // Files, most written first, each with its touches.
        let file = try #require(relations.files.first)
        #expect(file.path == "/xxx/y.go" && file.writes == 1 && file.turns == 1)
        #expect(file.touches.first?.mode == "write" && file.touches.first?.tool == "Edit" && file.touches.first?.toolId == "toolu_04")
        #expect(relations.outside.isEmpty && relations.commits.isEmpty)
    }

    /// The three stretches of an action are in order, and the first action of
    /// a turn starts with its prompt: the model's wait is the model's time.
    @Test func spansCarryTheModelsStart() throws {
        let relations = try decode(Relations.self, "relations.json")
        let document = try decode(SessionDocument.self, "document.json")
        #expect(relations.spans.allSatisfy { $0.start <= $0.at && $0.at <= $0.genEnd && $0.genEnd <= $0.toolsEnd })
        #expect(relations.spans.first?.start == document.turns.first?.startAt)
        #expect(relations.spans[1].start == relations.spans[0].toolsEnd)
    }

    /// `skit time`: the parts add up to the whole.
    @Test func timeAddsUp() throws {
        let time = try decode(SessionTime.self, "time.json")
        #expect(time.wall == 64 && time.waitingForYou == 51.5 && time.waitingForBackground == 0)
        let split = time.inTurns
        #expect(abs(split.seconds - (split.model + split.tools + split.subagents + split.waiting)) < 0.002)
        #expect(abs(time.wall - (time.waitingForYou + time.waitingForBackground + split.seconds)) < 0.002)
        #expect(time.turns.count == 2 && time.turns[0].actions == 4 && time.turns[0].origin == "human")
        // top=3 was asked for.
        #expect(time.slowestCalls.count == 3)
        let slowest = try #require(time.slowestCalls.first)
        #expect(slowest.toolId == "toolu_01" && slowest.name == "Bash" && slowest.seconds == 0.8 && slowest.summary?.isEmpty == false)
        let wait = try #require(time.longestWaits.first)
        #expect(wait.whom == "you" && wait.afterTurn == 0 && wait.beforeTurn == 1 && wait.seconds == 50.5)
    }

    /// `skit overview`: every session added up, and the days hold what the totals hold.
    @Test func overviewAddsUp() throws {
        let overview = try decode(Overview.self, "overview.json")
        let rows = try decode([SessionSummary].self, "sessions.json")
        #expect(overview.sessions == rows.count && overview.timezone == "UTC")
        #expect(overview.totals.actions == rows.map(\.requests).reduce(0, +))
        #expect(overview.totals.toolCalls == rows.map(\.toolCalls).reduce(0, +))
        #expect(overview.days.map(\.actions).reduce(0, +) == overview.totals.actions)
        #expect(overview.projects.map(\.sessions).reduce(0, +) == overview.sessions)
        let day = try #require(overview.days.first)
        #expect(day.day.count == 10 && !day.sessions.isEmpty)
        #expect(abs(overview.time.wall - (overview.time.waitingForYou + overview.time.waitingForBackground + overview.time.seconds)) < 0.01)
        // A session's row carries what the overview adds up.
        let row = try #require(rows.first { $0.id.hasPrefix("aaaaaaaa") })
        #expect(row.shape?.first == 4 && row.time?.wall == 64)
    }

    /// `skit claude`: the snapshot decodes from a Mac with next to nothing set, and from one with everything.
    @Test func claudeConfiguration() throws {
        let bare = try decode(ClaudeSnapshot.self, "claude.json")
        #expect(!bare.claudeDir.isEmpty && !bare.layers.isEmpty)
        #expect(bare.layers.allSatisfy { !$0.name.isEmpty && !$0.path.isEmpty })
        let full = try JSONDecoder.skit().decode(ClaudeSnapshot.self, from: Data(#"""
        {"claude_dir":"/h/.claude","layers":[{"name":"user","path":"/h/.claude/settings.json","exists":true,"modified":"2026-11-08T10:00:00Z","settings":{"model":"opus","env":{"A":"1"}}}],
         "effective":[{"key":"model","value":"opus","from":"user","also":["project"]},{"key":"cleanupPeriodDays","value":30,"from":"user"}],
         "experiments":[{"flag":"tengu_x","experiment_id":"tengu_x_experiment","variation_id":1,"value":true},{"flag":"tengu_y","experiment_id":"other","variation_id":0,"value":{"b":2,"a":"q"}}],
         "flags":[{"key":"tengu_x","value":true,"in_experiment":true},{"key":"tengu_n","value":2.5}],"flags_cached_at":"2026-11-08T09:00:00Z",
         "projects":[{"path":"/h/work","allowed_tools":3,"mcp_servers":["notes"],"trusted":true}],"connectors":["notes"],
         "memory":[{"path":"/h/.claude/CLAUDE.md","bytes":120,"lines":4,"modified":"2026-11-08T10:00:00Z"}],
         "skills":[{"name":"review","uses":7,"on_disk":false}],"state":{"numStartups":41},"identity":{"userID":"set"}}
        """#.utf8))
        #expect(full.effective[0].also == ["project"] && full.effective[1].also.isEmpty && full.effective[1].value.compact == "30")
        #expect(full.experiments[1].value.compact == #"{"a": "q", "b": 2}"# && full.experiments[0].value.bool == true)
        #expect(full.flags[0].inExperiment == true && full.flags[1].value.compact == "2.5" && full.flagsCachedAt != nil)
        #expect(full.projects[0].mcpServers == ["notes"] && full.skills[0].uses == 7 && full.skills[0].onDisk == false)
        #expect(full.state?["numStartups"]?.compact == "41" && full.identity?["userID"] == "set")
    }

    /// `skit primitives`: what is installed where, on offer, and used; then one item with its sessions.
    @Test func primitivesInstalledOfferedAndUsed() throws {
        let report = try decode(PrimitivesReport.self, "primitives.json")
        #expect(report.since == nil && report.sessions >= 2 && !report.lookedIn.isEmpty)
        #expect(report.kinds.map(\.kind) == ["skill", "agent", "command", "connector", "hook", "plugin", "instructions", "memory"])
        func item(_ kind: String, _ name: String) throws -> PrimitivesReport.Item { try #require(report.items.first { $0.kind == kind && $0.name == name }) }

        // Defined for the user and again in a project: the user's comes first for a skill.
        let deploy = try item("skill", "deploy")
        #expect(deploy.installed && deploy.order == "user-first" && deploy.definitions.map(\.scope) == ["user", "project"])
        #expect(deploy.definitions[0].calls == 2 && deploy.definitions[1].calls == nil && deploy.definitions[1].where?.hasSuffix("/proj") == true)
        #expect(deploy.description == "Ship it, for every project" && deploy.definitions[0].modified != nil)
        #expect(deploy.usage.calls == 2 && deploy.usage.byUser == 1 && deploy.usage.sessions == 1 && deploy.usage.offeredSessions == 1)
        #expect(deploy.usage.days.map(\.day) == ["2026-11-09"] && deploy.usage.projects.first?.calls == 2 && deploy.lastUsedAt != nil)
        #expect(deploy.counter?.uses == 5 && deploy.counter?.lastUsedAt != nil && deploy.sessions.isEmpty)

        // Installed, on offer, never used; on offer and nowhere on disk; known to Claude Code's counter alone.
        let tidy = try item("skill", "tidy")
        #expect(tidy.installed && tidy.usage.calls == 0 && tidy.usage.offeredSessions == 1 && tidy.lastUsedAt == nil)
        let bundled = try item("skill", "init")
        #expect(!bundled.installed && bundled.definitions.isEmpty && bundled.usage.offeredSessions == 1)
        #expect(try item("skill", "old-skill").counter?.uses == 2)
        #expect(try item("skill", "anthropic-skills:pdf").definitions.first?.scope == "account")

        let explore = try item("agent", "Explore")
        #expect(explore.builtIn == true && !explore.installed && explore.usage.calls == 1 && explore.usage.seconds == 30)
        #expect(try item("agent", "reviewer").definitions.first?.scope == "user")
        #expect(try item("command", "compact").usage.byUser == 1)

        // A connector is keyed as its tools name it; how it is reached is told, what it is given is not.
        let notes = try item("connector", "notes")
        #expect(notes.usage.errors == 1 && notes.definitions.first?.detail == ["transport": "stdio", "program": "notes-mcp"])
        #expect(try item("connector", "claude_ai_Gmail").title == "claude.ai Gmail")
        let hook = try item("hook", "PostToolUse:Edit|Write")
        #expect(hook.order == "merged" && hook.usage.calls == 1 && hook.definitions.first?.detail?["command"] == "gofmt -l .")
        #expect(report.items.filter { $0.kind == "instructions" }.allSatisfy { $0.name.hasPrefix("/") && $0.usage.calls == 1 })
        #expect(report.items.filter { $0.kind == "memory" }.count == 2)
        let skills = try #require(report.kinds.first)
        #expect(skills.items == 5 && skills.installed == 3 && skills.used == 1 && skills.unused == 3)

        let one = try #require(try decode(PrimitivesReport.self, "primitive.json").items.first)
        #expect(one.name == "deploy" && one.sessions.count == 1)
        let use = try #require(one.sessions.first)
        #expect(use.session.hasPrefix("dddddddd") && use.title == "Deploy to staging" && use.calls == 2 && use.byUser == 1 && use.turn == 0 && use.firstAt < use.lastAt)
    }

    /// `skit file`: a file a session touched, as it is now, with the sessions that touched it.
    @Test func aTouchedFileAndItsHistory() throws {
        let file = try decode(FileView.self, "file.json")
        // The fixture's file was never on this disk.
        #expect(file.path == "/xxx/y.go" && !file.exists && file.reason == "deleted" && file.text == nil)
        let entry = try #require(file.sessions.first)
        #expect(entry.session.hasPrefix("aaaaaaaa") && entry.raw == "/xxx/y.go" && entry.writes == 1 && entry.reads == 0 && entry.firstAt <= entry.lastAt)
    }

    /// `skit images`: where each picture is, never its bytes.
    @Test func imagesAreListedWithoutTheirBytes() throws {
        let images = try decode([SessionImage].self, "images.json")
        let image = try #require(images.first)
        #expect(image.index == 0 && image.mediaType.hasPrefix("image/") && image.size > 0)
        #expect(["prompt", "tool_result"].contains(image.place))
        #expect(images.map(\.index) == Array(images.indices))
    }

    /// A session that fetched a page, used a connector and committed.
    @Test func relationsOutsideAndCommits() throws {
        let relations = try decode(Relations.self, "relations-outside.json")
        #expect(relations.outside.map(\.id) == ["connector:notes", "web:docs.example.com"])
        #expect(relations.outside[1].calls.first?.toolId == "toolu_w1")
        let commit = try #require(relations.commits.first)
        #expect(commit.sha == "2b4b1ec" && commit.branch == "main" && commit.subject == "Add the guide")
        #expect(commit.call.toolId == "toolu_c1" && commit.call.action == 1)
        #expect(relations.spans.last?.said == true)
        // A quiet commit has no id to read.
        let quiet = try JSONDecoder.skit().decode(Relations.Commit.self, from: Data(#"{"subject":"Notes","call":{"tool_id":"t","action":1,"turn":0,"at":"2026-11-08T11:00:04Z"}}"#.utf8))
        #expect(quiet.sha == nil && quiet.subject == "Notes")
    }

    @Test func compactionDetail() throws {
        let cut = try decode(CompactionDetail.self, "compaction.json")
        #expect(cut.index == 0 && cut.trigger == "auto")
        #expect(cut.preTokens == 6400 && cut.postTokens == 900 && cut.cumulativeDropped == 5500)
        #expect(cut.lastActionBefore == 3 && cut.firstActionAfter == 4)
        #expect(cut.summary?.sections.map(\.title) == ["Primary Request and Intent", "Key Technical Concepts", "Pending Tasks"])
        #expect(cut.preserved.count == 2 && cut.preserved[0].kind == "tool_use" && cut.preserved[0].action == 3)
        #expect(cut.reinjected.map(\.type) == ["instructions", "compact_file_reference"])
        #expect(cut.fileRefs == ["/Xxxxx/xxxx/xxxx/notes.md"])
    }

    @Test func subagentStepCarriesItsResults() throws {
        let step = try decode(ActionDetail.self, "subagent-action.json")
        #expect(step.index == 0)
        #expect(step.toolCalls.first?.result != nil)
    }

    @Test func documentSaysHowItRan() throws {
        let doc = try decode(SessionDocument.self, "document.json")
        #expect(doc.versions == ["2.1.319"] && doc.entrypoints == ["cli"])
        #expect(doc.cwds.count == 2 && doc.cwds.first == doc.cwd)
    }

    @Test func exportIsMarkdownText() throws {
        let text = String(decoding: try fixture("export-turn.md"), as: UTF8.self)
        #expect(text.hasPrefix("## Turn 0 · 2026-11-08 10:00\n\n**You**\n"))
        #expect(text.contains("- `Edit` /xxx/y.go"))
    }

    @Test func searchAcrossSessionsNamesTheSession() throws {
        let hits = try decode([SearchHit].self, "search-prompts.json")
        let hit = try #require(hits.first)
        #expect(hit.session == id && hit.title == "Synthetic basics" && hit.project == "-Users-me-work")
        #expect(hit.kind == "prompt" && hit.action == -1 && hit.turn == 0 && hit.match == "keyword")
        #expect(hit.cosine == nil)
        // A meaning hit, as `?mode=meaning` answers (the fixture engine has no model to make one with).
        let close = try JSONDecoder.skit().decode(SearchHit.self, from: Data(#"{"session":"s","project":"p","title":"T","turn":9,"action":20,"kind":"assistant","at":"2026-09-28T06:58:00Z","snippet":"Starting with the ergo repo changes.","coverage":0,"score":0.775,"match":"meaning","cosine":0.775,"z":4.14}"#.utf8))
        #expect(close.match == "meaning" && close.cosine == 0.775 && close.action == 20)
    }

    @Test func searchHitsSayWhereTheyAre() throws {
        let hits = try decode([SearchHit].self, "search.json")
        #expect(!hits.isEmpty)
        #expect(hits.allSatisfy { $0.session == id })
        #expect(hits.contains { $0.kind == "tool_use" && $0.action >= 0 && $0.snippet.contains("«") })
    }

    @Test func toolInputsStayAsWritten() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"b":[1,2.5,true,null],"a":{"path":"x/y","n":3},"s":"q\"uote"}"#.utf8))
        #expect(value["a"]?["path"]?.string == "x/y")
        #expect(value.firstString("missing", "s") == "q\"uote")
        #expect(value["b"] == .array([.number(1), .number(2.5), .bool(true), .null]))
        #expect(value.pretty == "{\n \"a\": {\n  \"n\": 3,\n  \"path\": \"x/y\"\n },\n \"b\": [\n  1,\n  2.5,\n  true,\n  null\n ],\n \"s\": \"q\\\"uote\"\n}")
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) == value)
    }
}
