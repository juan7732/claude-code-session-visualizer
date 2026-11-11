import Foundation
import SkitKit
import SkitTestSupport
import Testing
@testable import SessionVisualizer

/// What M9 added on top of the session model: the Summary's reads, the nodes
/// only the Summary and the drawer select, search hits, links, the hours grid.
@Suite struct SummaryTests {
    static func outsideModel() throws -> SessionModel {
        let decoder = JSONDecoder.skit()
        var doc = try decoder.decode(SessionDocument.self, from: Fixtures.data("document.json"))
        doc.id = "ccc"
        return SessionModel(doc: doc, relations: try decoder.decode(Relations.self, from: Fixtures.data("relations-outside.json")))
    }

    @Test func whatItIsAboutAndWhereItEnded() throws {
        let model = try ModelTests.model()
        #expect(model.firstPrompt?.index == 0)
        // Turn 0 never stopped on text for the human: the last thing it wrote stands in.
        #expect(model.lastSaid(inTurn: 0)?.index == 0)
        // Turn 1 ends on a message Claude Code wrote itself; what the agent said is the action before it.
        #expect(model.lastSaid(inTurn: 1)?.index == 4)
        #expect(model.ending?.index == 4)
        #expect(model.failedCalls.isEmpty)
        #expect(model.writtenByTurn == [0: ["/xxx/y.go"]])
    }

    @Test func filesServicesAndStepsAreNodes() throws {
        let model = try ModelTests.model()
        let file = NodeKey.file("/xxx/y.go")
        #expect(model.filesByPath["/xxx/y.go"]?.writes == 1)
        #expect(model.siblings(of: file) == [file], "beside a written file, the written files")
        #expect(model.siblings(of: .file("/xxx/x.png")).count == 2, "beside a file that was only read, every file")
        #expect(model.itemID(for: file) == nil && model.turnIndex(of: file) == nil)
        #expect(file.noteKey == "file:/xxx/y.go")

        // A subagent's step lives in the row of the call that spawned the subagent.
        let step = NodeKey.step(agent: "a1b2c3d4e5f607182", index: 1)
        #expect(model.itemID(for: step) == "a2" && model.turnIndex(of: step) == 0)
        #expect(model.siblings(of: step) == [.step(agent: "a1b2c3d4e5f607182", index: 0), step])
        #expect(model.tools(ofStep: 0, agent: "a1b2c3d4e5f607182").map(\.name) == ["Bash"])
        #expect(model.tools(ofStep: 9, agent: "a1b2c3d4e5f607182").isEmpty && model.tools(ofStep: 0, agent: "nobody").isEmpty)
        #expect(model.isHiddenWhenFolded(step))

        let outside = try Self.outsideModel()
        #expect(outside.outsideByID["web:docs.example.com"]?.calls.count == 1)
        #expect(outside.siblings(of: .outside("web:docs.example.com")) == [.outside("connector:notes"), .outside("web:docs.example.com")])
    }

    @Test func selectingAStepOpensItsStrand() throws {
        let model = try ModelTests.model()
        let window = WindowState()
        window.page = .session(model.doc.id)
        window.setFolded(0, true, in: model)
        window.select(.step(agent: "a1b2c3d4e5f607182", index: 1), in: model)
        #expect(!window.transcript.folded.contains(0), "the turn unfolds to show it")
        #expect(window.transcript.open.contains(.tool("toolu_03")))
        #expect(window.transcript.scrollTarget == "a2")
        // Folding the turn again moves the selection to the folded line that holds it.
        window.setFolded(0, true, in: model)
        #expect(window.selection == .work(0))
    }

    @Test func revealShowsANodeWithoutSelectingIt() throws {
        let model = try ModelTests.model()
        let window = WindowState()
        window.page = .session(model.doc.id)
        window.sessionView = .summary
        window.setFolded(0, true, in: model)
        window.reveal(.action(1), in: model, query: "docker")
        #expect(window.sessionView == .transcript && window.selection == nil)
        #expect(window.transcript.focus == .action(1) && window.transcript.scrollTarget == "a1")
        #expect(!window.transcript.folded.contains(0))
        // Find-in-session carries the query and starts on this node.
        #expect(window.transcript.query == "docker" && window.transcript.startAt == .action(1))
    }

    @Test func aHitOrALinkWaitsForItsSession() throws {
        let model = try ModelTests.model()
        let window = WindowState()
        window.open(session: model.doc.id, at: .action(3), query: "edit")
        #expect(window.page == .session(model.doc.id) && window.sessionView == .transcript)
        #expect(window.transcript.query == "edit" && window.transcript.focus == nil, "nothing to land on until the session is read")
        window.applyPending(in: model)
        #expect(window.pending == nil && window.transcript.focus == .action(3) && window.selection == nil)

        // A link selects, so the drawer opens on what it names.
        window.open(session: model.doc.id, at: .file("/xxx/y.go"), select: true, view: .summary)
        window.applyPending(in: model)
        #expect(window.selection == .file("/xxx/y.go") && window.sessionView == .summary)

        // Another session's model is not this link's.
        window.open(session: "elsewhere", at: .turn(0))
        window.applyPending(in: model)
        #expect(window.pending != nil)
    }

    @Test func searchHitsNameTheirNode() throws {
        let hits = try JSONDecoder.skit().decode([SearchHit].self, from: Fixtures.data("search.json"))
        let keys = Set(hits.compactMap(SessionModel.key(for:)))
        #expect(keys.contains(.action(0)))
        let prompt = try JSONDecoder.skit().decode([SearchHit].self, from: Fixtures.data("search-prompts.json"))
        #expect(prompt.first.flatMap(SessionModel.key(for:)) == .turn(0))
        var sub = hits[0]
        sub.agent = "a1b2"
        #expect(SessionModel.key(for: sub) == .subagent("a1b2"))
        sub.agent = nil
        sub.action = -1
        sub.turn = -1
        #expect(SessionModel.key(for: sub) == nil, "a piece of the session as a whole has no node")
    }

    @Test func hitsAreGroupedBySessionMostHitsFirst() throws {
        func hit(_ session: String, turn: Int, action: Int) -> SearchHit {
            SearchHit(session: session, project: nil, title: "S " + session, agent: nil, turn: turn, action: action, kind: "assistant", tool: nil, at: nil, snippet: "«x»", match: "keyword")
        }
        let ordered = SearchPage.ordered([hit("a", turn: 3, action: 9), hit("b", turn: 5, action: 20), hit("b", turn: 1, action: 2), hit("c", turn: 0, action: 0), hit("b", turn: 1, action: -1)])
        // b has three hits and leads; inside it the engine's order stays (best match first).
        // a and c have one each: the one the engine ranked higher comes first.
        #expect(ordered.map { "\($0.session)\($0.turn)/\($0.action)" } == ["b5/20", "b1/2", "b1/-1", "a3/9", "c0/0"])
        // By meaning or hybrid the engine's order is the ranking: the session with the best hit leads.
        let ranked = SearchPage.ordered([hit("a", turn: 3, action: 9), hit("b", turn: 5, action: 20), hit("b", turn: 1, action: 2), hit("a", turn: 0, action: 1)], byCount: false)
        #expect(ranked.map { "\($0.session)\($0.turn)" } == ["a3", "a0", "b5", "b1"])
        let groups = SearchPage.groups(ordered)
        #expect(groups.map(\.id) == ["b", "a", "c"] && groups[0].title == "S b")
        #expect(groups.flatMap { $0.rows.map(\.index) } == [0, 1, 2, 3, 4], "the cursor counts through the groups")
    }

    @Test func aFoldedSessionIsOneStopOfTheCursor() {
        func hit(_ session: String, _ n: Int) -> SearchHit {
            SearchHit(session: session, turn: n, action: n, kind: "assistant", snippet: "«x»")
        }
        let hits = [hit("a", 0), hit("a", 1), hit("a", 2), hit("b", 0), hit("b", 1), hit("c", 0)]
        #expect(SearchPage.stops(hits, folded: []) == [0, 1, 2, 3, 4, 5])
        // A folded session is stopped at once, on its first hit: the one its preview shows.
        #expect(SearchPage.stops(hits, folded: ["a", "c"]) == [0, 3, 4, 5])
        #expect(SearchPage.stops(hits, folded: ["a", "b", "c"]) == [0, 3, 5])

        let state = SearchState()
        state.hits = hits
        state.selected = 4
        state.setAllFolded(true)
        #expect(state.folded == ["a", "b", "c"] && state.selected == 3, "the cursor stays on its session, at its line")
        state.setAllFolded(false)
        #expect(state.folded.isEmpty && state.selected == 3)

        // What is being asked for: the mode, the words, the scope. A search is current when it carries the same stamp.
        state.query = "  ergo "
        state.kind = "prompt"
        #expect(state.stamp == "\nergo\nprompt")
        state.mode = "meaning"
        #expect(state.stamp == "meaning\nergo\nprompt")
    }

    @Test func backGoesWhereTheWindowWas() throws {
        let model = try ModelTests.model()
        let window = WindowState()
        #expect(!window.canGoBack && !window.canGoForward)

        // Sessions → a session's Summary → its Transcript (by a link on the Summary).
        window.open(session: model.doc.id, view: .summary)
        window.reveal(.turn(1), in: model)
        #expect(window.sessionView == .transcript)
        #expect(window.backTarget == WindowState.Place(page: .session(model.doc.id), view: .summary))
        window.goBack()
        #expect(window.page == .session(model.doc.id) && window.sessionView == .summary, "Back from the Transcript is the Summary, not the list")
        window.goBack()
        #expect(window.page == .sessions)
        #expect(!window.canGoBack && window.canGoForward)
        window.goForward()
        window.goForward()
        #expect(window.page == .session(model.doc.id) && window.sessionView == .transcript && !window.canGoForward)

        // Search → a hit → Back is the Search page, with what was asked still there.
        window.search.query = "ergo"
        window.page = .search
        window.open(session: "elsewhere", at: .action(3), query: "ergo")
        #expect(window.page == .session("elsewhere") && window.sessionView == .transcript)
        window.goBack()
        #expect(window.page == .search && window.search.query == "ergo")
        // Opening a session is one step, not two (the page, then the view).
        window.goBack()
        #expect(window.page == .session(model.doc.id) && window.sessionView == .transcript)

        // Going somewhere new forgets what was ahead.
        window.page = .sessions
        #expect(!window.canGoForward)

        // A window opened on a page with nothing behind it still has a way out.
        let fresh = WindowState()
        fresh.go(to: .search)
        fresh.goBack()
        #expect(fresh.page == .sessions)
        let alone = WindowState()
        alone.goBack()
        #expect(alone.page == .sessions && !alone.canGoForward)
    }

    @Test func aSessionOpenedFromAListStartsOnItsSummary() {
        let window = WindowState()
        window.open(session: "a", at: .action(1))
        #expect(window.sessionView == .transcript, "a hit means the Transcript")
        window.page = .sessions
        window.open(session: "b", view: .summary)
        #expect(window.sessionView == .summary, "the list does not inherit the last session's view")
    }

    @Test func snippetsCarryTheirMarks() {
        #expect(Snippet.marks("the «Docker» suite and «docker» again, then «integration»") == ["integration", "docker"])
        #expect(Snippet.marks("no marks") == [])
        let long = String(repeating: "a", count: 2000) + " needle " + String(repeating: "b", count: 2000)
        let cut = Snippet.window(long, marks: ["needle"], before: 10, after: 20)
        #expect(cut == "…" + String(repeating: "a", count: 9) + " needle " + String(repeating: "b", count: 13) + "…")
        #expect(Snippet.window("short text", marks: ["text"]) == "short text")
        #expect(Snippet.window("nothing marked", marks: []) == "nothing marked")
        // A meaning hit marks no word: the window opens where its passage begins.
        let reply = String(repeating: "x", count: 400) + "\n\nErgo is clear: a TOML defines repos." + String(repeating: "y", count: 2000)
        let around = Snippet.window(reply, marks: [], passage: "Ergo is clear: a TOML defines repos…", before: 500, after: 900)
        #expect(around.hasPrefix("…" + String(repeating: "x", count: 118) + "\n\nErgo is clear") && around.hasSuffix("…"))
        #expect(Snippet.window("short reply", marks: [], passage: "not in it") == "short reply")
    }

    @Test func linksRoundTrip() throws {
        let cases: [(SessionView?, NodeKey?)] = [
            (nil, nil), (.transcript, .action(60)), (.transcript, .turn(3)), (.summary, .compaction(0)),
            (.transcript, .tool("toolu_01AbC")), (.transcript, .subagent("a1b2")), (.transcript, .step(agent: "a1b2", index: 4)),
            (.summary, .file("docs/a b/plan.md")), (.summary, .outside("web:docs.example.com")),
        ]
        for (view, key) in cases {
            let url = try #require(SessionLink.url(session: "36086585-e295", view: view, key: key))
            #expect(SessionLink.parse(url) == SessionLink.Target(session: "36086585-e295", view: view, key: key), "\(url)")
        }
        #expect(SessionLink.url(session: "s1", view: .transcript, key: .action(60))?.absoluteString == "skit-visualizer://session/s1?view=transcript&action=60")
        #expect(SessionLink.parse(URL(string: "https://session/s1")!) == nil)
        #expect(SessionLink.parse(URL(string: "skit-visualizer://stats")!) == nil)
        #expect(SessionLink.parse(URL(string: "skit-visualizer://session/")!) == nil)
        // A view this build does not know is ignored, not an error.
        #expect(SessionLink.parse(URL(string: "skit-visualizer://session/s1?view=hologram&turn=2")!) == SessionLink.Target(session: "s1", view: nil, key: .turn(2)))
    }

    @Test func hoursAreBinnedInLocalTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        func turn(_ index: Int, _ start: String, _ end: String) throws -> Turn {
            Turn(index: index, origin: "human", promptIndex: index, startAt: try #require(RFC3339.date(start)), endAt: try #require(RFC3339.date(end)),
                 actionIndexes: [], toolCalls: 0, usage: Usage(inputTokens: 0, outputTokens: 0, cacheCreationInputTokens: 0, cacheReadInputTokens: 0))
        }
        // 20:50 to 21:20 local on the 7th: ten minutes in one hour, twenty in the next.
        // 23:50 on the 7th to 00:10 on the 8th: the turn belongs to the 7th, its minutes to both days.
        let grid = try #require(HoursGrid(turns: [
            try turn(0, "2026-11-08T02:50:00Z", "2026-11-08T03:20:00Z"),
            try turn(1, "2026-11-08T05:50:00Z", "2026-11-08T06:10:00Z"),
        ], calendar: calendar))
        #expect(grid.days.count == 2)
        #expect(grid.days[0].minutes == [20: 10, 21: 20, 23: 10] && grid.days[0].turns == [20: [0], 23: [1]])
        #expect(grid.days[1].minutes == [0: 10] && grid.days[1].turnCount == 0)
        #expect(grid.days[0].activeMinutes == 40)
        #expect(grid.hours == 0...23)
        #expect(HoursGrid(turns: [], calendar: calendar) == nil)
    }

    @Test func theDigestMarksLongGapsAndCompactions() throws {
        let model = try ModelTests.model()
        // The fixture's two turns are a minute apart: no gap line; the compaction sits between them.
        #expect(Digest.lines(model).map(\.id) == ["t0", "c0", "t1"])
    }

    @Test func theGaugeSaysWhoseNumberItIs() {
        #expect(ContextCard.caption(share: 0.734, limit: 1_000_000, live: false, compacted: false) == "73% of a 1.0M window (your setting)")
        #expect(ContextCard.caption(share: 0.734, limit: 1_000_000, live: true, compacted: false).hasSuffix("a compaction is getting close"))
        #expect(!ContextCard.caption(share: 0.734, limit: 1_000_000, live: true, compacted: true).contains("close"))
        #expect(ContextCard.caption(share: 3.5, limit: 200_000, live: false, compacted: false).hasPrefix("More than the 200k window in Settings"))
    }

    @Test func exportedFilesAreNamedAfterTheSession() {
        #expect(Exporter.fileName(for: "Ergo workspace CLAUDE.md setup", id: "36086585-e295") == "Ergo-workspace-CLAUDE.md-setup.md")
        #expect(Exporter.fileName(for: "  /// ??? ", id: "36086585-e295") == "36086585.md")
        #expect(Exporter.fileName(for: "a/b: c", id: "x") == "a-b-c.md")
    }
}

/// The new routes through the store: a compaction's detail, a subagent's step, Markdown, search.
@Suite struct M9StoreTests {
    @Test func loadsACompactionAStepAndMarkdown() async throws {
        let server = try Fake.engine()
        let store = StoreTests.store(server)
        await store.connect()

        await store.loadCompaction("aaa", 0)
        guard case .loaded(let cut) = store.compactionDetails["aaa"]?[0] else {
            Issue.record("the compaction's detail should load")
            return
        }
        #expect(cut.preTokens == 6400 && cut.summary?.sections.count == 3)
        await store.loadCompaction("aaa", 7)
        #expect(store.compactionDetails["aaa"]?[7] == .failed("no route"))

        await store.loadStep("aaa", agent: "a1b2c3d4e5f607182", index: 0)
        guard case .loaded(let step) = store.stepDetails["aaa"]?[AppStore.stepKey(agent: "a1b2c3d4e5f607182", index: 0)] else {
            Issue.record("the step's results should load")
            return
        }
        #expect(step.toolCalls.first?.result == "xx")
        #expect(server.requests.contains { $0.hasPrefix("GET /v0/sessions/aaa/actions/0?agent=a1b2c3d4e5f607182 ") })

        #expect(await store.markdown("aaa", turn: 0)?.hasPrefix("## Turn 0 · ") == true)
        #expect(await store.markdown("aaa", turn: 9) == nil)
        #expect(store.notice == "no route", "a failed export says why")
    }

    @Test func searchAcrossSessionsAndInsideOne() async throws {
        let server = try Fake.engine()
        let store = StoreTests.store(server)
        await store.connect()
        guard case .success(let hits) = await store.search("xxxx", kind: "prompt") else {
            Issue.record("the search should answer")
            return
        }
        #expect(hits.first?.kind == "prompt")
        #expect(server.requests.contains { $0.hasPrefix("GET /v0/search?q=xxxx&limit=400&kind=prompt ") })
        _ = await store.find("two words", in: "aaa", kind: "tool_use")
        #expect(server.requests.contains { $0.hasPrefix("GET /v0/search?q=two%20words&limit=500&session=aaa&kind=tool_use ") })
    }
}
