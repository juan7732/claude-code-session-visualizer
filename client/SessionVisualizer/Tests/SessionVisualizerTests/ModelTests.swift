import Foundation
import SkitKit
import SkitTestSupport
import Testing
@testable import SessionVisualizer

/// The session model the Transcript and the drawer draw from, built from the
/// engine's own answers for the synthetic fixture.
@Suite struct ModelTests {
    static func model() throws -> SessionModel {
        let decoder = JSONDecoder.skit()
        return SessionModel(doc: try decoder.decode(SessionDocument.self, from: Fixtures.data("document.json")),
                            relations: try decoder.decode(Relations.self, from: Fixtures.data("relations.json")))
    }

    @Test func rowsAreInReadingOrder() throws {
        let model = try Self.model()
        // Turn 0: a prompt and four actions. The compaction falls between the turns. Turn 1: a prompt and two actions.
        // The API error between a2 and a3 is a system record, so it gets its own line;
        // the message Claude Code wrote itself is action 5 and needs none.
        #expect(model.items.map(\.id) == ["T0", "a0", "a1", "a2", "e0", "a3", "end0", "c0", "T1", "a4", "a5", "end1"])
        #expect(model.items.first == .prompt(turn: 0))
        // What j and k walk. An action with one tool call is one stop, not two:
        // its drawer shows the call. A strand is a stop of its own.
        #expect(model.focusOrder(folded: []) == [
            .turn(0), .action(0), .action(1), .action(2), .subagent("a1b2c3d4e5f607182"), .action(3),
            .compaction(0), .turn(1), .action(4), .action(5),
        ])
    }

    @Test func aTurnsToolCallsFoldIntoOneLinePerRun() throws {
        let model = try Self.model()
        // Action 0 says something and calls a tool; 1 and 2 only call tools; an API error
        // breaks the run; 3 is a run of its own.
        #expect(model.runs == [0: [0, 1, 2], 3: [3]])
        #expect(model.calls(inRun: 0).map(\.id) == ["toolu_01", "toolu_02", "toolu_03"])
        #expect(model.rows(folded: []) == model.items)

        let folded = model.rows(folded: [0])
        // The words of action 0 stay; its call and the next two are one line; turn 1 is untouched.
        #expect(folded.map(\.id) == ["T0", "a0", "w0", "e0", "w3", "end0", "c0", "T1", "a4", "a5", "end1"])
        #expect(folded[2] == .work(turn: 0, actions: [0, 1, 2]))
        #expect(model.focusOrder(folded: [0]) == [.turn(0), .action(0), .work(0), .work(3), .compaction(0), .turn(1), .action(4), .action(5)])
        #expect(model.rows(folded: [1]) == model.items, "a turn with no tool calls has nothing to fold")

        #expect(model.isHiddenWhenFolded(.action(1)) && model.isHiddenWhenFolded(.tool("toolu_01")) && model.isHiddenWhenFolded(.subagent("a1b2c3d4e5f607182")))
        #expect(!model.isHiddenWhenFolded(.action(0)) && !model.isHiddenWhenFolded(.turn(0)) && !model.isHiddenWhenFolded(.action(4)))
        #expect(model.itemID(for: .work(3)) == "w3" && model.turnIndex(of: .work(3)) == 0)
        #expect(model.siblings(of: .work(0)) == [.work(0), .work(3)])
    }

    @Test func arrowsOpenAndCloseThenFoldTheTurn() throws {
        let model = try Self.model()
        let window = WindowState()
        window.page = .session(model.doc.id)
        let state = window.transcript

        // → on an action opens its thinking and its tool calls, and says which results to load.
        #expect(window.expand(.action(0), in: model) == [0])
        #expect(state.open == [.tool("toolu_01")] && state.openThoughts == [0])
        // ← closes them; nothing folds while something was open.
        window.collapse(.action(0), in: model)
        #expect(state.open.isEmpty && state.openThoughts.isEmpty && state.folded.isEmpty)
        // ← again, with nothing open: the turn's tool calls fold, and the keyboard stays on what is visible.
        state.focus = .action(1)
        window.collapse(.action(1), in: model)
        #expect(state.folded == [0] && state.focus == .work(0))
        // → on the folded line shows the calls again.
        window.expand(.work(0), in: model)
        #expect(state.folded.isEmpty && state.focus == .action(0))

        // A tool call: → opens its input and result, ← closes it, ← again folds the turn.
        #expect(window.expand(.tool("toolu_04"), in: model) == [3])
        window.collapse(.tool("toolu_04"), in: model)
        #expect(state.open.isEmpty && state.folded.isEmpty)
        window.collapse(.tool("toolu_04"), in: model)
        #expect(state.folded == [0])

        // A prompt: ← folds, → shows; a turn with no tool calls has nothing to fold.
        window.expand(.turn(0), in: model)
        #expect(state.folded.isEmpty)
        window.collapse(.turn(0), in: model) // closes the long prompt first
        window.collapse(.turn(0), in: model)
        #expect(state.folded == [0])
        window.collapse(.action(4), in: model)
        #expect(state.folded == [0], "turn 1 called no tools")
        window.collapse(.work(3), in: model)
        window.collapse(.compaction(0), in: model)
        #expect(state.folded == [0])
    }

    @Test func foldingKeepsTheKeyboardOnSomethingVisible() throws {
        let model = try Self.model()
        let window = WindowState()
        window.page = .session(model.doc.id)
        window.transcript.focus = .action(1)
        window.selection = .tool("toolu_04")

        window.setFolded(0, true, in: model)
        #expect(window.transcript.folded == [0])
        #expect(window.transcript.focus == .work(0), "the focused action is inside the first run")
        #expect(window.selection == .work(3), "the selected call is the second run")

        window.setFolded(0, false, in: model)
        #expect(window.transcript.focus == .action(0) && window.selection == .action(3))

        // Words stay where they are; selecting something hidden shows the turn again.
        window.transcript.focus = .action(0)
        window.setFolded(0, true, in: model)
        #expect(window.transcript.focus == .action(0))
        window.select(.tool("toolu_02"), in: model)
        #expect(window.transcript.folded.isEmpty && window.selection == .tool("toolu_02"))
    }

    @Test func aGapOfMoreThanAMinuteIsSaid() throws {
        var doc = try JSONDecoder.skit().decode(SessionDocument.self, from: Fixtures.data("document.json"))
        doc.turns[1].startAt = doc.turns[0].endAt.addingTimeInterval(1260)
        let model = SessionModel(doc: doc, relations: Relations())
        #expect(model.items.contains(.gap(beforeTurn: 1, seconds: 1260)))
        #expect(SessionModel.duration(1260) == "21m 0s")
    }

    @Test func nodesFindTheirRowsAndTheirNeighbours() throws {
        let model = try Self.model()
        #expect(model.itemID(for: .tool("toolu_04")) == "a3")
        #expect(model.itemID(for: .subagent("a1b2c3d4e5f607182")) == "a2")
        #expect(model.itemID(for: .compaction(0)) == "c0")
        #expect(model.turnIndex(of: .tool("toolu_02")) == 0)
        #expect(model.siblings(of: .action(1)) == [.action(0), .action(1), .action(2), .action(3)])
        #expect(model.siblings(of: .tool("toolu_01")) == [.tool("toolu_01")])
        #expect(model.siblings(of: .turn(1)) == [.turn(0), .turn(1)])
        #expect(NodeKey.tool("toolu_01AbC").noteKey == "tool:toolu_01AbC")
        #expect(NodeKey.turn(3).noteKey == "turn:3")
    }

    @Test func aSubagentHangsUnderTheCallThatSpawnedIt() throws {
        let model = try Self.model()
        let sub = try #require(model.subagentsByTool["toolu_03"])
        let steps = model.steps(of: sub)
        #expect(steps.count == 2)
        #expect(steps[0].family == .shell)
        #expect(steps[0].title.hasPrefix("Bash"))
        #expect(model.relations.handbacks.first?.agentId == sub.agentId)
    }

    @Test func whatShapedAnAction() throws {
        let model = try Self.model()
        let first = model.feeds(of: try #require(model.action(0)))
        #expect(first.first?.text == "your prompt")
        #expect(first.first?.link == .turn(0))
        #expect(first.last?.text == "its own thinking first")
        let second = model.feeds(of: try #require(model.action(1)))
        #expect(second.first?.text == "the results of 1 tool call from action 0: Bash")
        #expect(second.first?.link == .action(0))
        // The first action of the second turn was opened by a prompt with an injected block.
        #expect(model.feeds(of: try #require(model.action(4))).first?.text == "your prompt and 1 injected block")
    }

    @Test func toolCallsSayWhatTheyAre() throws {
        func call(_ name: String, _ input: String) throws -> ToolCall {
            try JSONDecoder.skit().decode(ToolCall.self, from: Data(#"{"id":"t","name":"\#(name)","input":\#(input),"at":"2026-11-08T10:00:00Z","paired":true,"turn":0,"action":0}"#.utf8))
        }
        let bash = try call("Bash", #"{"command":"ls -la","description":"List files"}"#)
        #expect(bash.family == .shell && bash.label == "List files")
        #expect(bash.inputText == "List files\n\nls -la")
        let read = try call("Read", #"{"file_path":"/Users/me/a.go"}"#)
        #expect(read.family == .file && read.label == "/Users/me/a.go" && read.inputText == "/Users/me/a.go")
        let mcp = try call("mcp__claude_ai_Google_Drive__search_files", #"{"query":"plan"}"#)
        #expect(mcp.family == .connector && mcp.displayName == "Google Drive · search files" && mcp.label == "plan")
        #expect(try call("WebFetch", #"{"url":"https://x.dev"}"#).family == .web)
        #expect(try call("Agent", #"{"prompt":"probe","description":"Probe layout"}"#).family == .agent)
        #expect(try call("TaskOutput", #"{"task_id":"b1"}"#).family == .control)
        let odd = try call("Mystery", #"{"n":3}"#)
        #expect(odd.family == .other && odd.label == #"{  "n": 3 }"#)
        #expect(try call("Mystery", "{}").label == "")
    }

    @Test func wording() {
        #expect(SessionModel.firstLine("\n## **Recap**\nmore") == "Recap")
        #expect(SessionModel.firstLine("- a   list\titem") == "a list item")
        #expect(SessionModel.firstLine(String(repeating: "x", count: 100), max: 10) == String(repeating: "x", count: 9) + "…")
        #expect(SessionModel.duration(0) == "0s")
        #expect(SessionModel.duration(0.635) == "635ms")
        #expect(SessionModel.duration(38) == "38.0s")
        #expect(SessionModel.duration(125) == "2m 5s")
        #expect(SessionModel.duration(6660) == "1h 51m")
        #expect(SessionModel.originLabel("task_notification") == "Task notification")
        #expect(SessionModel.originLabel("something_new") == "Something new")
    }

    @Test func markdownBlocks() {
        let text = """
        Now adding the `agent` folder.
        Second line of the paragraph.

        ## Recap
        - one
        - two
          wrapped
        1. first
        2. second

        ```sh
        ls -la
          indented
        ```
        | a | b |
        |---|---|
        | 1 | 2 |
        tail
        """
        #expect(MarkdownBlock.parse(text) == [
            .paragraph("Now adding the `agent` folder.\nSecond line of the paragraph."),
            .heading("Recap"),
            .list(["one", "two wrapped"], ordered: false),
            .list(["first", "second"], ordered: true),
            .code("ls -la\n  indented"),
            .table([["a", "b"], ["1", "2"]]),
            .paragraph("tail"),
        ])
        // A header with empty cells, as Claude writes for two-column facts; two tables apart stay apart.
        #expect(MarkdownBlock.parse("| | |\n|---|---|\n| Texts | 1,367 |\n\n| x |\n| y |") == [
            .table([["", ""], ["Texts", "1,367"]]), .table([["x"], ["y"]]),
        ])
        #expect(MarkdownBlock.parse("#hashtag is not a heading") == [.paragraph("#hashtag is not a heading")])
        #expect(MarkdownBlock.parse("```\nunclosed") == [.code("unclosed")])
        #expect(MarkdownBlock.parse("") == [])
    }
}

/// The session model through the store: loaded once, notes kept by the engine.
@Suite struct SessionStoreTests {
    @Test func loadsTheModelAndTheFullResultOnDemand() async throws {
        let server = try Fake.engine()
        let store = StoreTests.store(server)
        await store.connect()
        await store.loadModel("aaa")
        let model = try #require(store.model("aaa"))
        #expect(model.doc.actions.count == 6)
        let requests = server.requests.count
        await store.loadModel("aaa")
        #expect(server.requests.count == requests, "a loaded session is not fetched again")

        await store.loadAction("aaa", 3)
        guard case .loaded(let detail) = store.actionDetails["aaa"]?[3] else {
            Issue.record("the action's results should load")
            return
        }
        #expect(detail.toolCalls.first?.result?.hasPrefix("full output line 1") == true)

        await store.loadModel("zzz")
        #expect(store.models["zzz"] == .failed("no route"))
    }

    @Test func aNoteIsKeptByTheEngineUnderTheNodesKey() async throws {
        let server = try Fake.engine()
        let store = StoreTests.store(server)
        await store.connect()
        await store.setNote("aaa", key: NodeKey.tool("toolu_01AbC").noteKey, "  check this  ")
        #expect(store.annotation("aaa").notes == ["tool:toolu_01AbC": "check this"])
        #expect(server.requests.last?.hasSuffix(#"{"notes":{"tool:toolu_01AbC":"check this"}}"#) == true)

        // What a relaunch would see: a new store asking the engine again.
        let relaunched = StoreTests.store(server)
        await relaunched.connect()
        #expect(relaunched.annotation("aaa").notes["tool:toolu_01AbC"] == "check this")

        await store.setNote("aaa", key: "tool:toolu_01AbC", "")
        #expect(store.annotation("aaa").notes.isEmpty)
    }

    @Test func selectingOpensWhatHidesTheNode() throws {
        let model = try ModelTests.model()
        let window = WindowState()
        window.page = .session(model.doc.id)
        window.select(.subagent("a1b2c3d4e5f607182"), in: model)
        #expect(window.selection == .subagent("a1b2c3d4e5f607182"))
        #expect(window.transcript.open.contains(.tool("toolu_03")))
        #expect(window.transcript.scrollTarget == "a2")
        #expect(window.transcript.focus == .subagent("a1b2c3d4e5f607182"))
        // Leaving the session forgets its selection and what was open.
        window.page = .sessions
        #expect(window.selection == nil && window.transcript.open.isEmpty)
    }
}
