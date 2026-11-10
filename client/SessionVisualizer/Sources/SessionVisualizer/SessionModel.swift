import Foundation
import SkitKit

/// What can be selected, focused and annotated inside a session. One selection
/// is shared by every view of the session (NOTES, iteration 12).
nonisolated enum NodeKey: Hashable, Sendable {
    case turn(Int)
    case action(Int)
    case tool(String)
    case subagent(String)
    case compaction(Int)
    /// A folded run of tool calls, named by the first action in it.
    case work(Int)
    /// One step of a subagent: an action of its own transcript.
    case step(agent: String, index: Int)
    /// A file the session touched, by its path as the engine reports it.
    case file(String)
    /// A service beyond the machine, by the engine's kind and name ("web:github.com").
    case outside(String)

    /// The key a note about this node is stored under (opaque to the engine).
    var noteKey: String {
        switch self {
        case .turn(let n): "turn:\(n)"
        case .action(let n): "action:\(n)"
        case .tool(let id): "tool:\(id)"
        case .subagent(let id): "subagent:\(id)"
        case .compaction(let n): "compaction:\(n)"
        case .work(let n): "work:\(n)"
        case .step(let agent, let index): "step:\(agent):\(index)"
        case .file(let path): "file:\(path)"
        case .outside(let id): "outside:\(id)"
        }
    }

    var kindLabel: String {
        switch self {
        case .turn: "turn"
        case .action: "action"
        case .tool: "tool"
        case .subagent: "subagent"
        case .compaction: "compaction"
        case .work: "tool calls"
        case .step: "subagent step"
        case .file: "file"
        case .outside: "outside"
        }
    }
}

/// What a tool call is for, by its name: decides its icon and its colour.
nonisolated enum ToolFamily: Sendable {
    case shell, file, web, agent, skill, connector, control, other

    init(toolName name: String) {
        switch name {
        case "Agent", "Task": self = .agent
        case "Bash": self = .shell
        case "Read", "Write", "Edit", "MultiEdit", "Glob", "Grep", "LS", "NotebookEdit": self = .file
        case "Skill", "ToolSearch": self = .skill
        case "TaskStop", "TaskOutput", "SubagentHandback", "SendMessage", "ScheduleWakeup", "AskUserQuestion": self = .control
        case _ where name.hasPrefix("Web"): self = .web
        case _ where name.hasPrefix("mcp__"): self = .connector
        default: self = .other
        }
    }

    var symbol: String {
        switch self {
        case .shell: "terminal"
        case .file: "doc"
        case .web: "globe"
        case .agent: "person.2"
        case .skill: "sparkles"
        case .connector: "puzzlepiece.extension"
        case .control: "stop.circle"
        case .other: "wrench.adjustable"
        }
    }
}

nonisolated extension ToolCall {
    var family: ToolFamily { ToolFamily(toolName: name) }

    /// "Bash", or for a connector's tool "server · tool" instead of mcp__server__tool.
    var displayName: String {
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2 else { return name }
        let server = parts[0].replacingOccurrences(of: "claude_ai_", with: "").replacingOccurrences(of: "_", with: " ")
        return server + " · " + parts.dropFirst().joined(separator: " ").replacingOccurrences(of: "_", with: " ")
    }

    /// What the call was for, in the model's own words when it gave a description.
    var label: String {
        input?.firstString("description", "file_path", "pattern", "query", "url", "command", "prompt", "path", "skill")
            ?? (input.map { $0 == .object([:]) ? "" : $0.pretty.replacingOccurrences(of: "\n", with: " ") } ?? "")
    }

    /// The part of the input worth reading in full: the command, the path, the prompt.
    var inputText: String {
        let body = input?.firstString("command", "prompt", "file_path", "query", "url") ?? input?.pretty ?? ""
        if let description = input?["description"]?.string, !description.isEmpty, description != body {
            return description + "\n\n" + body
        }
        return body
    }
}

/// One row of the Transcript, top to bottom.
nonisolated enum TranscriptItem: Hashable, Sendable, Identifiable {
    /// Time passed between two turns ("21m later").
    case gap(beforeTurn: Int, seconds: TimeInterval)
    case compaction(Int)
    /// A human turn's prompt.
    case prompt(turn: Int)
    /// A turn something else started: a task notification, a hook.
    case systemTurn(turn: Int)
    case action(Int)
    /// An API error or a message Claude Code wrote itself (index into the relations' events).
    case event(Int)
    case turnEnd(turn: Int)
    /// The tool calls of several actions in a row, folded into one line
    /// (only in a turn whose tool calls are folded).
    case work(turn: Int, actions: [Int])

    var id: String {
        switch self {
        case .gap(let turn, _): "gap\(turn)"
        case .compaction(let n): "c\(n)"
        case .prompt(let turn), .systemTurn(let turn): "T\(turn)"
        case .action(let n): "a\(n)"
        case .event(let n): "e\(n)"
        case .turnEnd(let turn): "end\(turn)"
        case .work(_, let actions): "w\(actions.first ?? -1)"
        }
    }

    /// The node a click on the row selects.
    var key: NodeKey? {
        switch self {
        case .compaction(let n): .compaction(n)
        case .prompt(let turn), .systemTurn(let turn): .turn(turn)
        case .action(let n): .action(n)
        case .work(_, let actions): actions.first.map { .work($0) }
        case .gap, .event, .turnEnd: nil
        }
    }
}

/// One step of a subagent, as its strand lists it.
nonisolated struct SubagentStep: Hashable, Sendable {
    var index: Int
    var family: ToolFamily?
    var title: String
    var seconds: TimeInterval
}

/// A session ready to draw: the document, the relations, and the lookups every
/// view needs. It orders and indexes what the engine served; it derives no new
/// facts (background tasks, hand-backs, retries and events come from /relations).
nonisolated struct SessionModel: Sendable, Equatable {
    let doc: SessionDocument
    let relations: Relations

    /// Two models are the same when they were built from the same state of the
    /// same session; comparing megabytes of document on every view update is not worth it.
    static func == (a: SessionModel, b: SessionModel) -> Bool {
        a.doc.id == b.doc.id && a.doc.lastAt == b.doc.lastAt && a.doc.actions.count == b.doc.actions.count && a.items.count == b.items.count
    }

    let toolsByID: [String: ToolCall]
    let subagentsByTool: [String: Subagent]
    let tasksByLaunch: [String: Relations.BackgroundTask]
    let tasksByPickup: [String: Relations.BackgroundTask]
    let handbacksByAction: [Int: [Relations.Handback]]
    /// A retry, keyed by the retrying call; and by the call that failed.
    let retryOf: [String: Relations.CallRef]
    let retriedBy: [String: Relations.CallRef]
    /// Actions whose text was said to the human: the turn stopped on them.
    let said: Set<Int>
    let spans: [Int: Relations.Span]

    /// The rows with every tool call shown. `rows(folded:)` is what the view draws.
    let items: [TranscriptItem]
    /// Runs of tool calls that fold into one line, by the first action in them.
    let runs: [Int: [Int]]
    /// The run an action's tool calls fold into.
    let runOfAction: [Int: Int]
    /// The files each turn wrote, in the order it first wrote them.
    let writtenByTurn: [Int: [String]]
    let filesByPath: [String: Relations.FileTouched]
    let outsideByID: [String: Relations.Outside]

    init(doc: SessionDocument, relations: Relations) {
        self.doc = doc
        self.relations = relations
        toolsByID = Dictionary(doc.toolCalls.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        subagentsByTool = Dictionary(doc.subagents.compactMap { s in s.toolUseId.map { ($0, s) } }, uniquingKeysWith: { a, _ in a })
        tasksByLaunch = Dictionary(relations.tasks.map { ($0.launch.toolId, $0) }, uniquingKeysWith: { a, _ in a })
        tasksByPickup = Dictionary(relations.tasks.flatMap { t in t.pickups.map { ($0.toolId, t) } }, uniquingKeysWith: { a, _ in a })
        handbacksByAction = Dictionary(grouping: relations.handbacks, by: \.action)
        retryOf = Dictionary(relations.retries.map { ($0.retry.toolId, $0.failed) }, uniquingKeysWith: { a, _ in a })
        retriedBy = Dictionary(relations.retries.map { ($0.failed.toolId, $0.retry) }, uniquingKeysWith: { a, _ in a })
        said = Set(relations.spans.filter { $0.said == true }.map(\.action))
        spans = Dictionary(relations.spans.map { ($0.action, $0) }, uniquingKeysWith: { a, _ in a })

        // The rows, in time order. A compaction or an event sits before the first
        // action that came after it, wherever in a turn that is.
        var items: [TranscriptItem] = []
        var nextCompaction = 0, nextEvent = 0
        // An event that is an action (a message Claude Code wrote itself) is
        // already a row; only the ones outside any action get a line of their own.
        let events = relations.events.enumerated().filter { $0.element.action == nil }.sorted { $0.element.at < $1.element.at }
        func flush(before time: Date?) {
            while nextCompaction < doc.compactions.count, time.map({ doc.compactions[nextCompaction].at <= $0 }) ?? true {
                items.append(.compaction(nextCompaction))
                nextCompaction += 1
            }
            while nextEvent < events.count, time.map({ events[nextEvent].element.at <= $0 }) ?? true {
                items.append(.event(events[nextEvent].offset))
                nextEvent += 1
            }
        }
        for (i, turn) in doc.turns.enumerated() {
            if i > 0 {
                let gap = turn.startAt.timeIntervalSince(doc.turns[i - 1].endAt)
                if gap > 60 { items.append(.gap(beforeTurn: turn.index, seconds: gap)) }
            }
            flush(before: turn.startAt)
            items.append(turn.isHuman && turn.promptIndex != nil ? .prompt(turn: turn.index) : .systemTurn(turn: turn.index))
            for index in turn.actionIndexes where doc.actions.indices.contains(index) {
                flush(before: doc.actions[index].at)
                items.append(.action(index))
            }
            if !turn.actionIndexes.isEmpty { items.append(.turnEnd(turn: turn.index)) }
        }
        flush(before: nil)
        self.items = items

        // Runs: the tool calls between two pieces of prose. An action that says
        // something keeps its words on screen and its calls start the run; the
        // actions after it that only call tools join it, until the next prose,
        // a compaction, an error or the end of the turn.
        var runs: [Int: [Int]] = [:]
        var runOfAction: [Int: Int] = [:]
        var run: [Int] = []
        func close() {
            if let first = run.first, run.contains(where: { !doc.actions[$0].toolUseIDs.isEmpty }) {
                runs[first] = run
                for index in run { runOfAction[index] = first }
            }
            run = []
        }
        for item in items {
            guard case .action(let index) = item else {
                close()
                continue
            }
            let action = doc.actions[index]
            if action.synthetic == true {
                close()
            } else if Self.hasProse(action) {
                close()
                if !action.toolUseIDs.isEmpty { run = [index] }
            } else {
                run.append(index)
            }
        }
        close()
        self.runs = runs
        self.runOfAction = runOfAction

        filesByPath = Dictionary(relations.files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        outsideByID = Dictionary(relations.outside.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var written: [Int: [(Date, String)]] = [:]
        for file in relations.files where file.writes > 0 {
            var seen = Set<Int>()
            for touch in file.touches where touch.mode == "write" && seen.insert(touch.turn).inserted {
                written[touch.turn, default: []].append((touch.at, file.path))
            }
        }
        writtenByTurn = written.mapValues { $0.sorted { $0.0 < $1.0 }.map(\.1) }
    }

    /// The action wrote something for the human to read.
    static func hasProse(_ action: Action) -> Bool {
        !action.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The rows to draw. In a folded turn each run of tool calls is one line and
    /// only the prose stays; everywhere else every call has its row.
    func rows(folded: Set<Int>) -> [TranscriptItem] {
        guard !folded.isEmpty else { return items }
        var out: [TranscriptItem] = []
        out.reserveCapacity(items.count)
        for item in items {
            guard case .action(let index) = item, let action = action(index), folded.contains(action.turn),
                  let first = runOfAction[index]
            else {
                out.append(item)
                continue
            }
            if Self.hasProse(action) { out.append(item) } // its words; its calls are in the run below
            if runs[first]?.last == index { out.append(.work(turn: action.turn, actions: runs[first] ?? [])) }
        }
        return out
    }

    /// Every stop of the keyboard in reading order: what j and k walk. An action
    /// with a single tool call is one stop (its drawer shows the call); with
    /// several, each call is a stop too.
    func focusOrder(folded: Set<Int>) -> [NodeKey] {
        var out: [NodeKey] = []
        for item in rows(folded: folded) {
            switch item {
            case .prompt(let turn), .systemTurn(let turn): out.append(.turn(turn))
            case .compaction(let n): out.append(.compaction(n))
            case .work(_, let actions): if let first = actions.first { out.append(.work(first)) }
            case .action(let index):
                out.append(.action(index))
                guard let action = action(index), !folded.contains(action.turn) else { continue }
                let calls = tools(of: action)
                for call in calls {
                    if calls.count > 1 { out.append(.tool(call.id)) }
                    if let sub = subagentsByTool[call.id] { out.append(.subagent(sub.agentId)) }
                }
            case .gap, .event, .turnEnd: break
            }
        }
        return out
    }

    /// The tool calls of a run, in order.
    func calls(inRun first: Int) -> [ToolCall] {
        (runs[first] ?? []).compactMap { action($0) }.flatMap { tools(of: $0) }
    }

    /// Whether a node has no row of its own while its turn is folded.
    func isHiddenWhenFolded(_ key: NodeKey) -> Bool {
        switch key {
        case .tool(let id): toolsByID[id].map { runOfAction[$0.action] != nil } ?? false
        case .subagent, .step: true
        case .action(let n): runOfAction[n] != nil && !(action(n).map(Self.hasProse) ?? true)
        case .turn, .compaction, .work, .file, .outside: false
        }
    }

    // MARK: Lookups

    func turn(_ index: Int) -> Turn? { doc.turns.indices.contains(index) ? doc.turns[index] : nil }
    func action(_ index: Int) -> Action? { doc.actions.indices.contains(index) ? doc.actions[index] : nil }
    func prompt(ofTurn index: Int) -> Prompt? {
        turn(index)?.promptIndex.flatMap { doc.prompts.indices.contains($0) ? doc.prompts[$0] : nil }
    }

    func tools(of action: Action) -> [ToolCall] { action.toolUseIDs.compactMap { toolsByID[$0] } }
    func subagent(_ agentID: String) -> Subagent? { doc.subagents.first { $0.agentId == agentID } }

    /// The row a node lives in: where the transcript scrolls to show it.
    func itemID(for key: NodeKey) -> String? {
        switch key {
        case .turn(let n): "T\(n)"
        case .action(let n): "a\(n)"
        case .compaction(let n): "c\(n)"
        case .work(let n): "w\(n)"
        case .tool(let id): toolsByID[id].map { "a\($0.action)" }
        case .subagent(let id), .step(let id, _): subagent(id)?.toolUseId.flatMap { toolsByID[$0] }.map { "a\($0.action)" }
        case .file, .outside: nil
        }
    }

    /// The turn a node belongs to.
    func turnIndex(of key: NodeKey) -> Int? {
        switch key {
        case .turn(let n): n
        case .action(let n): action(n)?.turn
        case .tool(let id): toolsByID[id]?.turn
        case .subagent(let id), .step(let id, _): subagent(id)?.toolUseId.flatMap { toolsByID[$0] }?.turn
        case .work(let n): action(n)?.turn
        case .compaction, .file, .outside: nil
        }
    }

    /// The nodes beside this one: the turn's actions, the action's tool calls, all turns.
    func siblings(of key: NodeKey) -> [NodeKey] {
        switch key {
        case .turn:
            return doc.turns.map { .turn($0.index) }
        case .action(let n):
            return (action(n).flatMap { turn($0.turn) }?.actionIndexes ?? []).map { .action($0) }
        case .tool(let id):
            return (toolsByID[id].flatMap { action($0.action) }.map { tools(of: $0) } ?? []).map { .tool($0.id) }
        case .subagent:
            return doc.subagents.map { .subagent($0.agentId) }
        case .compaction:
            return doc.compactions.indices.map { .compaction($0) }
        case .work(let n):
            let turn = action(n)?.turn
            return runs.keys.sorted().filter { action($0)?.turn == turn }.map { .work($0) }
        case .step(let agent, _):
            return (subagent(agent)?.session?.actions.indices).map { $0.map { .step(agent: agent, index: $0) } } ?? []
        case .file(let path):
            // Beside a written file, the other written files; else every file.
            let written = (filesByPath[path]?.writes ?? 0) > 0
            return relations.files.filter { !written || $0.writes > 0 }.map { .file($0.path) }
        case .outside:
            return relations.outside.map { .outside($0.id) }
        }
    }

    /// The node a search hit is in: a subagent's text belongs to its strand, a
    /// prompt to its turn, everything else to its action.
    static func key(for hit: SearchHit) -> NodeKey? {
        if let agent = hit.agent, !agent.isEmpty { return .subagent(agent) }
        if hit.action >= 0 { return .action(hit.action) }
        if hit.turn >= 0 { return .turn(hit.turn) }
        return nil
    }

    // MARK: What the Summary reads

    /// The first prompt a human wrote: what the session is about.
    var firstPrompt: Prompt? {
        doc.turns.first { $0.isHuman && $0.promptIndex != nil }.flatMap { prompt(ofTurn: $0.index) }
    }

    /// What the agent said when a turn stopped: the text it ended on, else the
    /// last text it wrote in the turn.
    func lastSaid(inTurn index: Int) -> Action? {
        guard let actions = turn(index)?.actionIndexes.compactMap({ action($0) }) else { return nil }
        return actions.last { said.contains($0.index) } ?? actions.last { $0.synthetic != true && Self.hasProse($0) }
    }

    /// The last thing the agent said in the session, and the turn it said it in.
    var ending: Action? {
        for turn in doc.turns.reversed() {
            if let action = lastSaid(inTurn: turn.index) { return action }
        }
        return nil
    }

    var failedCalls: [ToolCall] { doc.toolCalls.filter(\.isError) }

    /// The tool calls of a subagent's step.
    func tools(ofStep index: Int, agent: String) -> [ToolCall] {
        guard let run = subagent(agent)?.session, run.actions.indices.contains(index) else { return [] }
        let ids = Set(run.actions[index].toolUseIDs)
        return run.toolCalls.filter { ids.contains($0.id) }
    }

    func steps(of sub: Subagent) -> [SubagentStep] {
        guard let run = sub.session else { return [] }
        let calls = Dictionary(run.toolCalls.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return run.actions.enumerated().map { i, action in
            let tools = action.toolUseIDs.compactMap { calls[$0] }
            let end = tools.compactMap(\.endedAt).max() ?? (i + 1 < run.actions.count ? run.actions[i + 1].at : run.lastAt)
            let title = tools.first.map { $0.displayName + ($0.label.isEmpty ? "" : " · " + $0.label) }
                ?? Self.firstLine(action.text, max: 120)
            return SubagentStep(index: i, family: tools.first?.family, title: title.isEmpty ? "thinking" : title, seconds: max(0, end.timeIntervalSince(action.at)))
        }
    }

    /// What shaped an action, in the order it reached the model.
    func feeds(of action: Action) -> [(text: String, link: NodeKey?)] {
        guard let turn = turn(action.turn), let position = turn.actionIndexes.firstIndex(of: action.index) else { return [] }
        var out: [(String, NodeKey?)] = []
        if position == 0 {
            if turn.isHuman, let prompt = prompt(ofTurn: turn.index) {
                let n = prompt.context.count
                out.append(("your prompt" + (n > 0 ? " and \(n) injected block\(n == 1 ? "" : "s")" : ""), .turn(turn.index)))
            } else {
                out.append(("a \(Self.originLabel(turn.origin).lowercased()) opened the turn", .turn(turn.index)))
            }
        } else if let previous = self.action(turn.actionIndexes[position - 1]) {
            let calls = tools(of: previous)
            if calls.isEmpty {
                out.append(("action \(previous.index) ended without tools, so the model went on from its own text", .action(previous.index)))
            } else {
                let names = calls.map(\.displayName).joined(separator: ", ")
                out.append(("the results of \(calls.count) tool call\(calls.count == 1 ? "" : "s") from action \(previous.index): \(names)", .action(previous.index)))
                let failed = calls.filter(\.isError).count
                if failed > 0 { out.append(("\(failed) of those failed", .action(previous.index))) }
            }
        }
        for handback in handbacksByAction[action.index] ?? [] {
            let name = subagent(handback.agentId)?.meta?.description ?? "a subagent"
            out.append(("the hand-back from subagent “\(name)”", .subagent(handback.agentId)))
        }
        for call in tools(of: action) {
            if let task = tasksByPickup[call.id] {
                out.append(("it read the output of background task \(task.id)", .tool(task.launch.toolId)))
            }
        }
        if !action.thinking.isEmpty { out.append(("its own thinking first", nil)) }
        return out
    }

    // MARK: Wording shared by the views

    static func originLabel(_ origin: String) -> String {
        switch origin {
        case "human": return "You"
        case "task_notification": return "Task notification"
        case "hook": return "Hook output"
        default:
            let words = origin.replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }

    /// The first line with words in it, without leading markup, cut to `max`.
    static func firstLine(_ text: String, max: Int = 90) -> String {
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = Substring(raw).drop { "#>*- \t".contains($0) }
            line = Substring(line.replacingOccurrences(of: "**", with: ""))
            let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !collapsed.isEmpty else { continue }
            return collapsed.count > max ? String(collapsed.prefix(max - 1)) + "…" : collapsed
        }
        return ""
    }

    /// 420ms, 38.0s, 2m 5s, 1h 51m, 16d 16h.
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds == 0 { return "0s" }
        if seconds < 1 { return "\(Int((seconds * 1000).rounded()))ms" }
        if seconds < 59.95 { return String(format: "%.1fs", seconds) }
        // Whole seconds from here on, rounded once, so 419.6 s is 7m 0s and not 6m 60s.
        let whole = Int(seconds.rounded())
        if whole < 3600 { return "\(whole / 60)m \(whole % 60)s" }
        if whole < 48 * 3600 { return "\(whole / 3600)h \(whole % 3600 / 60)m" }
        return "\(whole / 86_400)d \(whole % 86_400 / 3600)h"
    }
}
