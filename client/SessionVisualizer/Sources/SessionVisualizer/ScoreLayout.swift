import CoreGraphics
import CoreText
import Foundation
import SkitKit

/// The Score's geometry, in canvas points at 100 % (the mock's `layoutScore`).
nonisolated enum SC {
    static let youHeight: CGFloat = 46
    static let chipTop: CGFloat = 10
    static let chipHeight: CGFloat = 26
    static let chipMax: CGFloat = 260
    /// An action's bar on the Agent row, and the lanes of tool calls under it.
    static let barTop: CGFloat = 8
    static let barHeight: CGFloat = 22
    static let laneTop: CGFloat = 36
    static let laneStep: CGFloat = 14
    static let toolHeight: CGFloat = 11
    /// A subagent's strand on its row, with its steps along the bottom.
    static let strandRow: CGFloat = 54
    static let strandTop: CGFloat = 6
    static let strandHeight: CGFloat = 42
    static let stepTop: CGFloat = 32
    static let stepHeight: CGFloat = 10
    static let taskStep: CGFloat = 20
    static let taskHeight: CGFloat = 16
    static let fileRow: CGFloat = 24
    static let tick: CGFloat = 8
    /// An idle gap, however long; and how close two moments may be drawn.
    static let band: CGFloat = 64
    static let minStep: CGFloat = 14
    static let maxStep: CGFloat = 700
    /// What stays put over the canvas: row names at the left, the ruler on top.
    static let gutter: CGFloat = 118
    static let ruler: CGFloat = 46
    /// A file has a row of its own from this many touches, and at most this many files do.
    static let hotTouches = 3
    static let hotFiles = 8
}

nonisolated struct ScoreOptions: Equatable, Sendable {
    var subagents = true
    var tasks = true
    var files = true
    /// The time scale: canvas points for a second of work (the mock's Tight 1, Normal 1.8, Wide 3.2).
    var pointsPerSecond = 1.8
}

/// The session as time-true staves (mock: Canvas layout Score): time runs left
/// to right on an axis warped twice (idle gaps are bands, close moments are
/// spread, `TimeAxis`), and each row is someone who was working: you, the
/// agent with its tool calls in lanes, each subagent, the background shell, and
/// the files that kept coming back. Both warps are the same for every row, so
/// what stands above what was happening at the same time.
nonisolated struct ScoreLayout: Sendable {
    enum Kind: Sendable, Equatable {
        case prompt(human: Bool)
        /// The whole turn as one bar: what the Agent row shows from far away.
        case turn
        /// An action: how wide the model's part is, then its tools', then (when it spoke) its wait.
        case action(model: CGFloat, tools: CGFloat, said: Bool)
        case tool(failed: Bool, async: Bool)
        case strand
        case step(hand: Bool)
        case task
        case touch(write: Bool, tool: String)
    }

    struct Node: Sendable {
        var key: NodeKey
        var kind: Kind
        var rect: CGRect
        var symbol = ""
        var tint = Tint.accent
        var text = LaidText.empty
        /// The node in words, for the pointer.
        var tip = ""
        /// The node this one belongs to: a tool call's action, a step's subagent. What find matched lights both.
        var parent: NodeKey?
    }

    /// A row's name, where the gutter writes it.
    struct Row: Sendable {
        var name: LaidText
        var count: LaidText
        var y: CGFloat
        var file: Bool
    }

    struct Band: Sendable {
        var rect: CGRect
        var label: LaidText
    }

    struct TurnMark: Sendable {
        var turn: Int
        var x: CGFloat
        var label: LaidText
    }

    var nodes: [Node] = []
    var edges: [CanvasLayout.Edge] = []
    var bands: [Band] = []
    var turns: [TurnMark] = []
    var rows: [Row] = []
    /// The line each file row's touches sit on.
    var fileLines: [(from: CGPoint, to: CGPoint)] = []
    var bounds = CGRect.zero
    var height: CGFloat = 0
    var index: [NodeKey: Int] = [:]
    var axis: TimeAxis
    var start: Date
    var options: ScoreOptions

    init(model: SessionModel, options: ScoreOptions = ScoreOptions()) {
        self.options = options
        let doc = model.doc
        start = doc.turns.first?.startAt ?? doc.firstAt
        let spans = model.relations.spans

        // Every moment something began or ended.
        var moments: [Date] = []
        for turn in doc.turns { moments += [turn.startAt, turn.endAt] }
        for span in spans { moments += [span.start, span.genEnd, span.toolsEnd, span.end] }
        for call in doc.toolCalls { moments += [call.at, call.endedAt ?? call.at] }
        let steps: [String: [(step: SubagentStep, at: Date)]] = Dictionary(doc.subagents.compactMap { sub in
            guard let run = sub.session else { return nil }
            return (sub.agentId, model.steps(of: sub).map { ($0, run.actions[$0.index].at) })
        }, uniquingKeysWith: { a, _ in a })
        if options.subagents {
            for sub in doc.subagents {
                guard let run = sub.session else { continue }
                moments += [run.firstAt, run.lastAt]
                for entry in steps[sub.agentId] ?? [] { moments += [entry.at, entry.at.addingTimeInterval(entry.step.seconds)] }
            }
        }
        let axis = TimeAxis(moments: moments, pointsPerSecond: CGFloat(options.pointsPerSecond), band: SC.band, minStep: SC.minStep, maxStep: SC.maxStep)
        self.axis = axis
        let x = axis.x

        // Rows, top to bottom.
        var y: CGFloat = 0
        func row(_ name: String, _ height: CGFloat, count: String = "", file: Bool = false) -> CGFloat {
            let top = y
            if !name.isEmpty {
                rows.append(Row(name: LaidText(name.uppercased(), font: CanvasFont.caps, width: file ? 170 : 110), count: LaidText(count, font: CanvasFont.small, width: 40),
                                y: top + (file ? SC.fileRow / 2 : 14), file: file))
            }
            y += height
            return top
        }
        let you = row("You", SC.youHeight)

        // Tool calls of one action that overlap each take a lane.
        var laneOf: [String: Int] = [:]
        var lanes = 1
        for action in doc.actions {
            let placed = Self.laned(model.tools(of: action).map { ($0.id, $0.at, $0.endedAt ?? $0.at) })
            for (id, lane) in placed.lanes { laneOf[id] = lane }
            lanes = max(lanes, placed.count)
        }
        let agent = row("Agent", SC.laneTop + CGFloat(lanes) * SC.laneStep + 4)

        let runs = options.subagents ? doc.subagents.filter { $0.session != nil } : []
        let strandLanes = Self.laned(runs.compactMap { sub in sub.session.map { (sub.agentId, $0.firstAt, $0.lastAt) } })
        var strandRows: [CGFloat] = []
        for lane in 0..<(runs.isEmpty ? 0 : strandLanes.count) { strandRows.append(row(lane == 0 ? "Subagents" : "", SC.strandRow)) }

        let tasks = options.tasks ? model.relations.tasks : []
        func taskEnd(_ task: Relations.BackgroundTask) -> Date {
            ([task.stop?.at] + task.pickups.map { Optional($0.at) }).compactMap { $0 }.max() ?? model.toolsByID[task.launch.toolId]?.endedAt ?? task.launch.at
        }
        let taskLanes = Self.laned(tasks.map { ($0.id, $0.launch.at, taskEnd($0)) })
        let taskTop = tasks.isEmpty ? 0 : row("Background", 14 + CGFloat(taskLanes.count) * SC.taskStep)

        let hot = options.files ? Array(model.relations.files.filter { $0.touches.count >= SC.hotTouches }
            .sorted { $0.touches.count != $1.touches.count ? $0.touches.count > $1.touches.count : $0.path < $1.path }.prefix(SC.hotFiles)) : []
        var fileTops: [CGFloat] = []
        for file in hot {
            fileTops.append(row(file.path.split(separator: "/").suffix(2).joined(separator: "/"), SC.fileRow, count: "\(file.touches.count)×", file: true))
        }
        height = y + 10

        // Far away the Agent row is one bar a turn.
        for turn in doc.turns where !turn.actionIndexes.isEmpty {
            let from = x(turn.startAt)
            let text = "T\(turn.index) · \(turn.actionIndexes.count) action\(turn.actionIndexes.count == 1 ? "" : "s") · \(SessionModel.duration(turn.duration))"
            let width = max(10, x(turn.endAt) - from)
            nodes.append(Node(key: .turn(turn.index), kind: .turn, rect: CGRect(x: from, y: agent + SC.barTop, width: width, height: SC.barHeight),
                              text: LaidText(text, font: CanvasFont.small, width: width - 12), tip: text))
        }

        // The agent: a bar per action, its tool calls in lanes under it.
        var barOf: [Int: CGRect] = [:]
        var toolRect: [String: CGRect] = [:]
        for span in spans {
            guard let action = model.action(span.action) else { continue }
            let calls = model.tools(of: action)
            let said = span.said == true
            let from = x(span.start)
            let width = max(8, x(said ? span.end : span.toolsEnd) - from - 2)
            let working = min(width, max(2, x(span.genEnd) - from))
            let running = min(width - working, max(0, x(span.toolsEnd) - x(span.genEnd)))
            let rect = CGRect(x: from, y: agent + SC.barTop, width: width, height: SC.barHeight)
            barOf[span.action] = rect
            let look = Self.look(action, calls, said: said)
            let seconds = (model: span.genEnd.timeIntervalSince(span.start), tools: span.toolsEnd.timeIntervalSince(span.genEnd))
            nodes.append(Node(key: .action(span.action), kind: .action(model: working, tools: running, said: said), rect: rect, symbol: look.symbol, tint: look.tint,
                              text: width >= 110 ? LaidText(look.title, font: CanvasFont.small, width: width - 30) : .empty,
                              tip: "Action \(span.action) · \(look.title) · the model \(SessionModel.duration(seconds.model))" + (seconds.tools > 0 ? ", tools \(SessionModel.duration(seconds.tools))" : "")))
            for call in calls {
                let at = x(call.at)
                let rect = CGRect(x: at, y: agent + SC.laneTop + CGFloat(laneOf[call.id] ?? 0) * SC.laneStep, width: max(6, x(call.endedAt ?? call.at) - at - 1), height: SC.toolHeight)
                toolRect[call.id] = rect
                let async = model.subagentsByTool[call.id] != nil || model.tasksByLaunch[call.id] != nil
                nodes.append(Node(key: .tool(call.id), kind: .tool(failed: call.isError, async: async), rect: rect, symbol: call.family.symbol, tint: Tint(call.family),
                                  text: rect.width > 40 ? LaidText(call.displayName, font: CanvasFont.tiny, width: rect.width - 8) : .empty,
                                  tip: call.displayName + (call.label.isEmpty ? "" : " · " + SessionModel.firstLine(call.label, max: 100))
                                      + (call.duration.map { " · " + SessionModel.duration($0) } ?? "") + (call.isError ? " · failed" : ""),
                                  parent: .action(span.action)))
            }
        }

        // Subagents: a strand on a row of its own, its steps along the bottom,
        // an arrow from the call that spawned it and one into the action that used it.
        let handbacks = Dictionary(model.relations.handbacks.map { ($0.agentId, $0) }, uniquingKeysWith: { a, _ in a })
        for sub in runs {
            guard let run = sub.session, let lane = strandLanes.lanes[sub.agentId], strandRows.indices.contains(lane) else { continue }
            let top = strandRows[lane]
            let from = x(run.firstAt)
            let rect = CGRect(x: from, y: top + SC.strandTop, width: max(60, x(run.lastAt) - from), height: SC.strandHeight)
            let name = sub.meta?.description ?? sub.meta?.agentType ?? "subagent"
            let words = ["Subagent", sub.meta?.model, name, "\(run.actions.count) step\(run.actions.count == 1 ? "" : "s")"].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            nodes.append(Node(key: .subagent(sub.agentId), kind: .strand, rect: rect, symbol: "person.2.fill", tint: .warn,
                              text: rect.width >= 150 ? LaidText(words, font: CanvasFont.small, width: rect.width - 32) : .empty,
                              tip: words + " · " + SessionModel.duration(run.lastAt.timeIntervalSince(run.firstAt))))
            for entry in steps[sub.agentId] ?? [] {
                let at = x(entry.at)
                let hand = entry.step.title.hasPrefix("SubagentHandback")
                nodes.append(Node(key: .step(agent: sub.agentId, index: entry.step.index), kind: .step(hand: hand),
                                  rect: CGRect(x: at, y: top + SC.stepTop, width: max(5, x(entry.at.addingTimeInterval(entry.step.seconds)) - at - 1), height: SC.stepHeight),
                                  tip: "Step \(entry.step.index) · " + (hand ? "Handed back" : entry.step.title), parent: .subagent(sub.agentId)))
            }
            if let spawn = sub.toolUseId.flatMap({ toolRect[$0] }) {
                let from = CGPoint(x: spawn.minX + 3, y: spawn.maxY), to = CGPoint(x: rect.minX + 6, y: rect.minY)
                edges.append(CanvasLayout.Edge(kind: .spawn, from: from, to: to, control1: CGPoint(x: from.x, y: top - 10), control2: CGPoint(x: to.x, y: agent + SC.laneTop), arrow: true))
            }
            if let back = handbacks[sub.agentId], let bar = barOf[back.action] {
                let from = CGPoint(x: rect.maxX - 4, y: rect.minY), to = CGPoint(x: bar.minX + 4, y: bar.maxY)
                edges.append(CanvasLayout.Edge(kind: .handback, from: from, to: to, control1: CGPoint(x: from.x, y: agent + SC.laneTop + 10), control2: CGPoint(x: to.x, y: top - 20), arrow: true))
            }
        }

        // Background commands: a dashed pill from the launch to the last time anything read or stopped it.
        for task in tasks {
            let from = x(task.launch.at)
            let end = max(from + 40, x(taskEnd(task)))
            let rect = CGRect(x: from, y: taskTop + 8 + CGFloat(taskLanes.lanes[task.id] ?? 0) * SC.taskStep, width: end - from, height: SC.taskHeight)
            let words = "task \(task.id)" + (task.label.map { " · " + $0 } ?? "")
            nodes.append(Node(key: .tool(task.launch.toolId), kind: .task, rect: rect, symbol: "clock.arrow.circlepath", tint: .ctx,
                              text: LaidText(words, font: CanvasFont.mono, width: rect.width - 26),
                              tip: words + (task.pickups.isEmpty ? " · never read" : " · read \(task.pickups.count)×")))
            if let launch = toolRect[task.launch.toolId] {
                edges.append(CanvasLayout.Edge(kind: .launch, from: CGPoint(x: launch.minX + 3, y: launch.maxY), to: CGPoint(x: rect.minX + 3, y: rect.minY)))
            }
            for pickup in task.pickups {
                guard let reader = toolRect[pickup.toolId] else { continue }
                edges.append(CanvasLayout.Edge(kind: .pickup, from: CGPoint(x: rect.maxX - 3, y: rect.minY), to: CGPoint(x: reader.minX + 3, y: reader.maxY), arrow: true))
            }
        }

        // Files that kept coming back: a square per touch, filled when it wrote.
        for (file, top) in zip(hot, fileTops) {
            let middle = top + SC.fileRow / 2
            let xs = file.touches.map { x($0.at) }
            if let low = xs.min(), let high = xs.max() { fileLines.append((CGPoint(x: low, y: middle), CGPoint(x: max(high, low + 2), y: middle))) }
            for touch in file.touches {
                nodes.append(Node(key: .file(file.path), kind: .touch(write: touch.mode == "write", tool: touch.toolId),
                                  rect: CGRect(x: x(touch.at) - SC.tick / 2, y: middle - SC.tick / 2, width: SC.tick, height: SC.tick),
                                  tip: "\(file.path) · \(touch.mode == "write" ? "written" : "read") by \(touch.tool) in action \(touch.action)"))
            }
        }

        // You: a chip where each turn began, as wide as the turn leaves room for.
        for (i, turn) in doc.turns.enumerated() {
            let from = x(turn.startAt)
            let next = i + 1 < doc.turns.count ? x(doc.turns[i + 1].startAt) : x(turn.endAt) + 300
            let width = max(26, min(SC.chipMax, max(x(turn.endAt) - from, 26) - 4, next - from - 10))
            let prompt = model.prompt(ofTurn: turn.index).map { SessionModel.firstLine($0.text, max: 120) } ?? ""
            let words = turn.isHuman && !prompt.isEmpty ? prompt : SessionModel.originLabel(turn.origin).lowercased()
            nodes.append(Node(key: .turn(turn.index), kind: .prompt(human: turn.isHuman), rect: CGRect(x: from, y: you + SC.chipTop, width: width, height: SC.chipHeight),
                              symbol: turn.isHuman ? "person.fill" : "clock.arrow.circlepath", tint: turn.isHuman ? .ink : .ctx,
                              text: width >= 70 ? LaidText(words, font: CanvasFont.text, width: width - 36) : .empty,
                              tip: "Turn \(turn.index) · " + words))
            turns.append(TurnMark(turn: turn.index, x: from, label: LaidText("T\(turn.index)", font: CanvasFont.smallBold, width: 60)))
        }

        for cut in axis.cuts {
            // "21m", "2h", "5d": the first unit of how long nothing happened.
            let words = SessionModel.duration(cut.seconds).split(separator: " ").first.map(String.init) ?? ""
            bands.append(Band(rect: CGRect(x: cut.x, y: 0, width: cut.width, height: height), label: LaidText(words, font: CanvasFont.mono, width: SC.band - 8)))
        }
        bounds = CGRect(x: -20, y: -10, width: axis.width + 60, height: height + 10)
        // A key leads to the node that stands for it up close: a turn's chip, not its far-away bar.
        for (i, node) in nodes.enumerated() where node.kind != .turn && index[node.key] == nil { index[node.key] = i }
        for (i, node) in nodes.enumerated() where index[node.key] == nil { index[node.key] = i }
    }

    /// Gives each stretch the first lane that is free when it starts.
    static func laned(_ items: [(id: String, from: Date, to: Date)]) -> (lanes: [String: Int], count: Int) {
        var ends: [Date] = []
        var out: [String: Int] = [:]
        for item in items.sorted(by: { $0.from < $1.from }) {
            if let lane = ends.firstIndex(where: { $0 <= item.from }) {
                out[item.id] = lane
                ends[lane] = item.to
            } else {
                out[item.id] = ends.count
                ends.append(item.to)
            }
        }
        return (out, max(1, ends.count))
    }

    /// What an action's bar says and in which colour: the tool it called, or what it said.
    static func look(_ action: Action, _ calls: [ToolCall], said: Bool) -> (symbol: String, tint: Tint, title: String) {
        if let one = calls.first, calls.count == 1 {
            return (one.family.symbol, Tint(one.family), one.displayName + (one.label.isEmpty ? "" : " · " + SessionModel.firstLine(one.label, max: 80)))
        }
        if let first = calls.first {
            return (first.family.symbol, Tint(first.family), "\(calls.count) tool calls")
        }
        let line = SessionModel.firstLine(action.text.isEmpty ? action.thinking : action.text, max: 80)
        if said { return ("text.bubble", .ink, line.isEmpty ? "Said" : line) }
        let wrote = SessionModel.hasProse(action)
        return (wrote ? "text.bubble" : "brain", wrote ? .accent : .muted, line.isEmpty ? (wrote ? "Wrote" : "Thought") : line)
    }

    /// The rectangle a key lives at: its own node's, else the node that holds it.
    func rect(for key: NodeKey, model: SessionModel) -> CGRect? {
        if let i = index[key] { return nodes[i].rect }
        switch key {
        case .tool(let id): return model.toolsByID[id].flatMap { rect(for: .action($0.action), model: model) }
        case .step(let agent, _): return rect(for: .subagent(agent), model: model)
        case .subagent(let agent): return model.subagent(agent)?.toolUseId.flatMap { rect(for: .tool($0), model: model) }
        case .work(let n): return rect(for: .action(n), model: model)
        case .compaction(let n):
            guard model.doc.compactions.indices.contains(n) else { return nil }
            return CGRect(x: axis.x(model.doc.compactions[n].at), y: 0, width: 2, height: height)
        case .action, .turn, .file, .outside: return nil
        }
    }

    /// "+26m", "+1h 04m", "+2d 3h": how far into the session a moment is, for the ruler.
    static func offset(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        if whole < 3600 { return "+\(whole / 60)m" }
        if whole < 86_400 { return String(format: "+%dh %02dm", whole / 3600, whole % 3600 / 60) }
        return "+\(whole / 86_400)d \(whole % 86_400 / 3600)h"
    }
}

nonisolated extension Camera {
    /// The Score's first view: every row in the height of the view, from the session's start,
    /// with room for the ruler on top and the row names at the left.
    mutating func fitRows(_ bounds: CGRect, in size: CGSize) {
        guard bounds.height > 0, size.height > 200 else { return }
        scale = min(1.3, max(0.3, (size.height - 120) / bounds.height))
        x = SC.gutter + 12 - bounds.minX * scale
        y = SC.ruler + 24 - bounds.minY * scale
    }

    /// Brings the start of `rect` into a view that scrolls sideways through time: a third of
    /// the way in, past the row names. Its row is brought in only when it is out of sight.
    mutating func show(_ rect: CGRect, in size: CGSize, readable: Bool) {
        if readable, scale < 0.5 { scale = 0.9 }
        x = max(SC.gutter + 20, size.width * 0.33) - rect.minX * scale
        let top = rect.minY * scale + y, bottom = rect.maxY * scale + y
        if top < SC.ruler || bottom > size.height { y = size.height / 2 - rect.midY * scale }
    }
}
