import Foundation
import SkitKit

/// A time axis with its idle stretches cut: a gap between two moments longer
/// than `gap` is drawn as a band of fixed width, whatever its length, so a
/// session that slept for a night still shows its work. Between two moments
/// time runs evenly. The Timeline fits one to its width; the Score will lay one
/// out at a scale of its own (plan, M12).
nonisolated struct TimeAxis: Sendable, Equatable {
    /// A stretch nothing happened in, drawn as a band.
    struct Cut: Sendable, Equatable {
        var from: Date
        var to: Date
        var x: CGFloat
        var width: CGFloat
        var seconds: TimeInterval { to.timeIntervalSince(from) }
    }

    struct Knot: Sendable, Equatable {
        var time: TimeInterval
        var x: CGFloat
    }

    /// A moment and where it is drawn, in order of both.
    let knots: [Knot]
    let cuts: [Cut]
    let width: CGFloat

    /// What counts as idle: longer than this between two moments (the mock's 90 s).
    static let idle: TimeInterval = 90

    /// The axis at a scale: `pointsPerSecond`, every step between two moments
    /// no narrower than `minStep` and no wider than `maxStep`, every idle gap
    /// `band` wide. `moments` need not be sorted.
    init(moments: [Date], pointsPerSecond: CGFloat, band: CGFloat, gap: TimeInterval = TimeAxis.idle, minStep: CGFloat = 0, maxStep: CGFloat = .greatestFiniteMagnitude) {
        let times = Array(Set(moments.map(\.timeIntervalSinceReferenceDate))).sorted()
        var knots: [Knot] = []
        var cuts: [Cut] = []
        knots.reserveCapacity(times.count)
        var x: CGFloat = 0
        for (i, time) in times.enumerated() {
            if i > 0 {
                let step = time - times[i - 1]
                if step > gap {
                    cuts.append(Cut(from: Date(timeIntervalSinceReferenceDate: times[i - 1]), to: Date(timeIntervalSinceReferenceDate: time), x: x, width: band))
                    x += band
                } else {
                    x += min(maxStep, max(minStep, CGFloat(step) * pointsPerSecond))
                }
            }
            knots.append(Knot(time: time, x: x))
        }
        self.knots = knots
        self.cuts = cuts
        self.width = x
    }

    /// The axis that is exactly `width` wide: the working time shares what the
    /// bands leave. With many gaps the bands narrow, so they never take more
    /// than a third of the width.
    static func fitted(moments: [Date], width: CGFloat, gap: TimeInterval = TimeAxis.idle, band: CGFloat = 7) -> TimeAxis {
        let times = Array(Set(moments.map(\.timeIntervalSinceReferenceDate))).sorted()
        var working: TimeInterval = 0
        var gaps = 0
        for i in times.indices.dropFirst() {
            let step = times[i] - times[i - 1]
            if step > gap { gaps += 1 } else { working += step }
        }
        let band = gaps == 0 ? 0 : min(band, width / 3 / CGFloat(gaps))
        let scale = working > 0 ? max(0, width - band * CGFloat(gaps)) / CGFloat(working) : 0
        return TimeAxis(moments: moments, pointsPerSecond: scale, band: band, gap: gap)
    }

    /// Where a moment is drawn. A moment inside a cut is inside its band.
    func x(_ date: Date) -> CGFloat {
        let time = date.timeIntervalSinceReferenceDate
        guard let first = knots.first, let last = knots.last else { return 0 }
        if time <= first.time { return first.x }
        if time >= last.time { return last.x }
        var low = 0, high = knots.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if knots[mid].time <= time { low = mid } else { high = mid }
        }
        let a = knots[low], b = knots[high]
        return a.x + (b.x - a.x) * CGFloat((time - a.time) / max(0.000_001, b.time - a.time))
    }

    /// The moment drawn at `x`.
    func date(at x: CGFloat) -> Date {
        guard let first = knots.first, let last = knots.last else { return Date(timeIntervalSinceReferenceDate: 0) }
        if x <= first.x { return Date(timeIntervalSinceReferenceDate: first.time) }
        if x >= last.x { return Date(timeIntervalSinceReferenceDate: last.time) }
        var low = 0, high = knots.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if knots[mid].x <= x { low = mid } else { high = mid }
        }
        let a = knots[low], b = knots[high]
        guard b.x > a.x else { return Date(timeIntervalSinceReferenceDate: b.time) }
        return Date(timeIntervalSinceReferenceDate: a.time + (b.time - a.time) * Double((x - a.x) / (b.x - a.x)))
    }
}

/// What the Timeline's strip draws, in time: turn marks, the three stretches of
/// every action, subagent and background bars. Built once per session from what
/// the engine served; where each thing is drawn is the axis's business.
nonisolated struct TimelineContent: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        /// Waiting for the model, its thinking, its writing.
        case model
        case tools
        /// The agent spoke and waits to be brought back.
        case waiting
    }

    struct Stretch: Sendable, Equatable {
        var action: Int
        var phase: Phase
        var from: Date
        var to: Date
    }

    struct TurnMark: Sendable, Equatable {
        var turn: Int
        var at: Date
        var end: Date
        var human: Bool
    }

    /// A subagent's run or a background command, on a lane of its row.
    struct Bar: Sendable, Equatable {
        var key: NodeKey
        var label: String
        var from: Date
        var to: Date
        var lane: Int
    }

    struct Cut: Sendable, Equatable {
        var index: Int
        var at: Date
    }

    var first: Date
    var last: Date
    /// Every moment something began or ended: what the axis is cut and scaled by.
    var moments: [Date]
    var turns: [TurnMark]
    var stretches: [Stretch]
    /// Actions that spoke to the human, and when.
    var said: [Stretch]
    var subagents: [Bar]
    var subagentLanes: Int
    var tasks: [Bar]
    var taskLanes: Int
    var compactions: [Cut]
    /// Each action with the moment the model began on it, in time order.
    var starts: [(at: Date, action: Int)]

    static func == (a: TimelineContent, b: TimelineContent) -> Bool {
        a.first == b.first && a.last == b.last && a.stretches == b.stretches && a.turns == b.turns && a.subagents == b.subagents && a.tasks == b.tasks
    }

    init(model: SessionModel) {
        let doc = model.doc
        let first = doc.turns.first?.startAt ?? doc.firstAt
        let last = doc.turns.last?.endAt ?? doc.lastAt
        (self.first, self.last) = (first, last)
        var moments: [Date] = [first, last]
        turns = doc.turns.map { TurnMark(turn: $0.index, at: $0.startAt, end: $0.endAt, human: $0.isHuman) }
        for turn in doc.turns { moments += [turn.startAt, turn.endAt] }

        var stretches: [Stretch] = [], said: [Stretch] = []
        var starts: [(Date, Int)] = []
        for span in model.relations.spans.sorted(by: { $0.start < $1.start }) {
            starts.append((span.start, span.action))
            moments += [span.start, span.at, span.genEnd, span.toolsEnd, span.end]
            if span.genEnd > span.start { stretches.append(Stretch(action: span.action, phase: .model, from: span.start, to: span.genEnd)) }
            if span.toolsEnd > span.genEnd { stretches.append(Stretch(action: span.action, phase: .tools, from: span.genEnd, to: span.toolsEnd)) }
            if span.said == true {
                said.append(Stretch(action: span.action, phase: .model, from: span.at, to: span.at))
                if span.end > span.toolsEnd { stretches.append(Stretch(action: span.action, phase: .waiting, from: span.toolsEnd, to: span.end)) }
            }
        }
        self.stretches = stretches
        self.said = said
        self.starts = starts

        var subagents: [Bar] = []
        for sub in doc.subagents {
            guard let run = sub.session else { continue }
            subagents.append(Bar(key: .subagent(sub.agentId), label: sub.meta?.description ?? sub.meta?.agentType ?? "subagent", from: run.firstAt, to: max(run.firstAt, run.lastAt), lane: 0))
            moments += [run.firstAt, run.lastAt]
        }
        (self.subagents, subagentLanes) = Self.laned(subagents)

        var tasks: [Bar] = []
        for task in model.relations.tasks {
            // A background command runs from its launch to the last time anything looked at it or stopped it.
            let end = ([task.stop?.at] + task.pickups.map { Optional($0.at) }).compactMap { $0 }.max() ?? model.toolsByID[task.launch.toolId]?.endedAt ?? task.launch.at
            tasks.append(Bar(key: .tool(task.launch.toolId), label: task.label ?? "task \(task.id)", from: task.launch.at, to: max(task.launch.at, end), lane: 0))
            moments += [task.launch.at, end]
        }
        (self.tasks, taskLanes) = Self.laned(tasks)

        compactions = doc.compactions.enumerated().map { Cut(index: $0.offset, at: $0.element.at) }
        self.moments = moments.filter { $0 >= first && $0 <= last }
    }

    /// Gives each bar the first lane that is free when it starts.
    private static func laned(_ bars: [Bar]) -> ([Bar], Int) {
        var ends: [Date] = []
        var out: [Bar] = []
        for var bar in bars.sorted(by: { $0.from < $1.from }) {
            if let lane = ends.firstIndex(where: { $0 <= bar.from }) {
                bar.lane = lane
                ends[lane] = bar.to
            } else {
                bar.lane = ends.count
                ends.append(bar.to)
            }
            out.append(bar)
        }
        return (out, max(1, ends.count))
    }

    // MARK: What was happening at a moment

    /// What the session was doing at a moment: the playhead's "now".
    struct Moment: Equatable, Sendable {
        enum Doing: Equatable, Sendable {
            case beforeTheFirstPrompt
            /// Between two turns. `forYou` is false when the next turn was started by a notification.
            case betweenTurns(after: Int, forYou: Bool)
            case afterTheLastTurn
            case model, tools, waiting
        }

        var doing: Doing
        var turn: Int?
        var action: Int?
        /// Subagents and background commands that were running.
        var subagents: [NodeKey] = []
        var tasks: [NodeKey] = []
    }

    /// The action the model had begun on at `date`, if any: the row the ledger lights.
    func action(at date: Date) -> Int? {
        var low = 0, high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid].at <= date { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? starts[low - 1].action : nil
    }

    func turn(at date: Date) -> TurnMark? { turns.last { $0.at <= date } }

    func moment(at date: Date) -> Moment {
        let running = subagents.filter { $0.from <= date && date <= $0.to }.map(\.key)
        let live = tasks.filter { $0.from <= date && date <= $0.to }.map(\.key)
        guard let turn = turn(at: date) else {
            return Moment(doing: .beforeTheFirstPrompt, subagents: running, tasks: live)
        }
        if date > turn.end {
            guard let next = turns.first(where: { $0.at > date }) else {
                return Moment(doing: .afterTheLastTurn, turn: turn.turn, subagents: running, tasks: live)
            }
            return Moment(doing: .betweenTurns(after: turn.turn, forYou: next.human), turn: turn.turn, subagents: running, tasks: live)
        }
        let action = action(at: date)
        // The stretch the moment falls in; between two stretches the model is at work.
        let stretch = stretches.last { $0.action == action && $0.from <= date && date <= $0.to }
        let doing: Moment.Doing = switch stretch?.phase {
        case .tools: .tools
        case .waiting: .waiting
        case .model, nil: .model
        }
        return Moment(doing: doing, turn: turn.turn, action: action, subagents: running, tasks: live)
    }

    /// When a node happened: where the playhead goes when it is selected.
    func date(of key: NodeKey, in model: SessionModel) -> Date? {
        switch key {
        case .turn(let n): model.turn(n)?.startAt
        case .action(let n), .work(let n): model.spans[n]?.start ?? model.action(n)?.at
        case .tool(let id): model.toolsByID[id]?.at
        case .subagent(let id): model.subagent(id)?.session?.firstAt
        case .step(let agent, let index):
            model.subagent(agent)?.session.flatMap { $0.actions.indices.contains(index) ? $0.actions[index].at : nil }
        case .compaction(let n): model.doc.compactions.indices.contains(n) ? model.doc.compactions[n].at : nil
        case .file, .outside: nil
        }
    }
}

/// One row of the Timeline's ledger, top to bottom.
nonisolated enum LedgerItem: Hashable, Sendable, Identifiable {
    /// Time between two turns. `forYou` is false when a notification started the next one.
    case gap(beforeTurn: Int, seconds: TimeInterval, forYou: Bool)
    case compaction(Int)
    case turn(Int)
    case action(Int)
    /// After an action that spoke: the wait until something brought the agent back.
    case waited(action: Int, seconds: TimeInterval)
    case event(Int)

    /// The ids of the Transcript's rows, so one lookup finds a node's row in both.
    var id: String {
        switch self {
        case .gap(let turn, _, _): "gap\(turn)"
        case .compaction(let n): "c\(n)"
        case .turn(let n): "T\(n)"
        case .action(let n): "a\(n)"
        case .waited(let n, _): "wait\(n)"
        case .event(let n): "e\(n)"
        }
    }

    var key: NodeKey? {
        switch self {
        case .compaction(let n): .compaction(n)
        case .turn(let n): .turn(n)
        case .action(let n): .action(n)
        case .gap, .waited, .event: nil
        }
    }

    /// The ledger of a session: the Transcript's rows without their prose, with
    /// the waits the spans record.
    static func rows(of model: SessionModel) -> [LedgerItem] {
        var out: [LedgerItem] = []
        for item in model.items {
            switch item {
            case .gap(let turn, let seconds):
                out.append(.gap(beforeTurn: turn, seconds: seconds, forYou: model.turn(turn)?.isHuman ?? true))
            case .compaction(let n): out.append(.compaction(n))
            case .prompt(let turn), .systemTurn(let turn): out.append(.turn(turn))
            case .event(let n): out.append(.event(n))
            case .action(let n):
                out.append(.action(n))
                if let span = model.spans[n], span.said == true {
                    let waited = span.end.timeIntervalSince(span.toolsEnd)
                    if waited >= 1 { out.append(.waited(action: n, seconds: waited)) }
                }
            case .turnEnd, .work: break
            }
        }
        return out
    }
}
