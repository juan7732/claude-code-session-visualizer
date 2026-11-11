import CoreGraphics
import CoreText
import Foundation
import SkitKit

/// The Braid's geometry, in canvas points at 100 % (the mock's `BR`): the
/// prompt at the left, the chain of steps beside it, subagent strands beside
/// the chain, background threads in lanes at the far right.
nonisolated enum BR {
    static let promptWidth: CGFloat = 270
    static let chainX: CGFloat = 312
    static let cardWidth: CGFloat = 330
    static let strandX: CGFloat = 700
    static let strandWidth: CGFloat = 260
    static let threadX: CGFloat = 1000
    static let threadStep: CGFloat = 18
    /// Between two cards of a chain; between two turns.
    static let gap: CGFloat = 14
    static let turnGap: CGFloat = 54
    /// A chip is as wide as what it says, up to the card's inside.
    static let chipMax: CGFloat = cardWidth - 18
    static let chipHeight: CGFloat = 22
    static let stepRow: CGFloat = 20
}

/// A colour of the palette, named: the layout is made off the main thread and
/// before the appearance is known, so it says which colour, not what it is.
nonisolated enum Tint: Sendable {
    case ink, ink2, muted, accent, tool, plug, warn, ctx, err

    init(_ family: ToolFamily) {
        switch family {
        case .shell: self = .tool
        case .file: self = .ink2
        case .web, .connector: self = .plug
        case .agent: self = .warn
        case .skill: self = .accent
        case .control: self = .ctx
        case .other: self = .muted
        }
    }
}

// MARK: Content: what each node says, laid out once per session

/// A tool call inside a step with several: a chip.
nonisolated struct ChipContent: Sendable {
    var toolID: String
    var symbol: String
    var tint: Tint
    var name: LaidText
    var label: LaidText
    var duration: LaidText
    var failed: Bool
    /// The call started something that outlives it: a subagent, a background command.
    var async: Bool

    var width: CGFloat {
        min(BR.chipMax, 22 + name.width + (label.isEmpty ? 0 : 5 + label.width) + (duration.isEmpty ? 0 : 10 + duration.width) + 10)
    }
}

/// What a step's tool calls connect to, for the edges.
nonisolated struct CallLinks: Sendable {
    var toolID: String
    var subagent: String?
    var launches: String?
    var picksUp: [String]
    var stops: String?
    var resultHead: String
}

/// What came back from a step, written on the arrow to the next one.
nonisolated struct ResultNote: Sendable {
    var text: LaidText
    var failed: Bool
    var key: NodeKey?
}

nonisolated struct StepBadge: Sendable {
    var text: LaidText
    var tint: Tint
}

/// One action of the agent: a card of the chain.
nonisolated struct StepContent: Sendable {
    var index: Int
    var symbol: String
    var tint: Tint
    var title: LaidText
    var subtitle: LaidText
    var right: LaidText
    var badges: [StepBadge]
    var thoughtFirst: Bool
    var body: LaidText
    /// The body is the model's thinking, or a stand-in for it: drawn muted.
    var bodyMuted: Bool
    var chips: [ChipContent]
    var calls: [CallLinks]
    var said: Bool
    var failed: Bool
    var note: ResultNote?
    var height: CGFloat
    /// The card in words, for when it is too small to read.
    var tip: String

    /// Where the chips start, below the header and the body.
    var chipsTop: CGFloat { 7 + 16 + (body.isEmpty ? 0 : 4 + body.height) + 7 }

    /// The chips' rectangles inside a card at `origin`: one to a row, so each can say what it was for.
    func chipRects(origin: CGPoint) -> [CGRect] {
        chips.enumerated().map { i, chip in
            CGRect(x: origin.x + 9, y: origin.y + chipsTop + CGFloat(i) * (BR.chipHeight + 4), width: chip.width, height: BR.chipHeight)
        }
    }
}

nonisolated struct StrandStepContent: Sendable {
    var index: Int
    var symbol: String
    var tint: Tint
    var title: LaidText
    var hand: Bool
}

/// A subagent's run: an amber group beside the step that spawned it.
nonisolated struct StrandContent: Sendable {
    var agentID: String
    var model: LaidText
    var duration: LaidText
    var description: LaidText
    var steps: [StrandStepContent]
    var hasHandback: Bool
    var height: CGFloat

    static let stepsTop: CGFloat = 8 + 16 + 3 + 16 + 6

    func stepRects(origin: CGPoint) -> [CGRect] {
        steps.indices.map { i in
            CGRect(x: origin.x + 9, y: origin.y + Self.stepsTop + CGFloat(i) * (BR.stepRow + 3), width: BR.strandWidth - 18, height: BR.stepRow)
        }
    }
}

/// The card that opens a turn: your prompt, or what else started it.
nonisolated struct PromptContent: Sendable {
    var human: Bool
    var who: LaidText
    var time: LaidText
    var right: LaidText
    var text: LaidText
    var height: CGFloat
    var tip: String
}

/// A collapsed turn: one pill that says how much is inside.
nonisolated struct SummaryContent: Sendable {
    /// One dot per action, dark where the agent spoke to you.
    var dots: [Bool]
    var text: LaidText
    var failed: LaidText
}

nonisolated struct TurnContent: Sendable {
    var index: Int
    var name: LaidText
    var facts: LaidText
    var card: PromptContent
    var steps: [StepContent]
    var summary: SummaryContent
    /// Seconds since the turn before ended.
    var gapBefore: TimeInterval
    /// Compactions that happened between the turn before and this one.
    var compactions: [(index: Int, text: LaidText)]
}

nonisolated struct TaskContent: Sendable {
    var id: String
    var label: String
    var launchTool: String
    var lastReader: String?
}

/// Everything the Braid writes, broken into lines and measured: built once
/// per session, off the main thread. Positions are the layout's job.
nonisolated struct BraidContent: Sendable {
    var turns: [TurnContent]
    var strands: [String: StrandContent]
    var tasks: [String: TaskContent]
    /// The hand-backs each action received, by action index.
    var handbacks: [Int: [String]]

    init(model: SessionModel) {
        let doc = model.doc
        var tasks: [String: TaskContent] = [:]
        var pickupTurn: [Int: Relations.BackgroundTask] = [:]
        for task in model.relations.tasks {
            let last = task.pickups.last ?? task.stop
            tasks[task.id] = TaskContent(id: task.id, label: task.label ?? task.id, launchTool: task.launch.toolId, lastReader: task.pickups.last?.toolId)
            if let last { pickupTurn[last.turn] = task }
        }
        self.tasks = tasks
        handbacks = model.handbacksByAction.mapValues { $0.map(\.agentId) }

        var strands: [String: StrandContent] = [:]
        for sub in doc.subagents {
            let steps = model.steps(of: sub)
            let hasHandback = model.relations.handbacks.contains { $0.agentId == sub.agentId && $0.action >= 0 }
            let seconds = sub.session.map { $0.lastAt.timeIntervalSince($0.firstAt) } ?? 0
            let message = model.relations.handbacks.first { $0.agentId == sub.agentId }?.message ?? ""
            let rows = steps.map { step -> StrandStepContent in
                // The step that hands back says what it handed back, not the call's JSON.
                let hand = step.title.hasPrefix("SubagentHandback")
                let title = hand ? "Handed back" + (message.isEmpty ? "" : ": " + SessionModel.firstLine(message, max: 120)) : step.title
                return StrandStepContent(index: step.index, symbol: hand ? "arrow.uturn.backward" : step.family?.symbol ?? "text.bubble",
                                         tint: hand ? .warn : step.family.map(Tint.init) ?? .muted,
                                         title: LaidText(title, font: CanvasFont.small, width: BR.strandWidth - 18 - 50), hand: hand)
            }
            let duration = LaidText(SessionModel.duration(seconds), font: CanvasFont.mono, width: 70)
            strands[sub.agentId] = StrandContent(
                agentID: sub.agentId,
                model: LaidText(sub.meta?.model ?? "", font: CanvasFont.meta, width: BR.strandWidth - 18 - 86 - duration.width),
                duration: duration,
                description: LaidText(sub.meta?.description ?? sub.agentId, font: CanvasFont.strand, width: BR.strandWidth - 18, lineHeight: 16),
                steps: rows, hasHandback: hasHandback,
                height: StrandContent.stepsTop + CGFloat(rows.count) * BR.stepRow + CGFloat(max(0, rows.count - 1)) * 3 + 8)
        }
        self.strands = strands

        var turns: [TurnContent] = []
        var nextCompaction = 0
        for (i, turn) in doc.turns.enumerated() {
            var cuts: [(Int, LaidText)] = []
            while nextCompaction < doc.compactions.count, i > 0, doc.compactions[nextCompaction].at <= turn.startAt {
                let cut = doc.compactions[nextCompaction]
                cuts.append((nextCompaction, LaidText("context compacted · \(Format.tokens(cut.metadata?.preTokens ?? 0)) → \(Format.tokens(cut.metadata?.postTokens ?? 0))", font: CanvasFont.small, width: 400)))
                nextCompaction += 1
            }
            if i == 0 { while nextCompaction < doc.compactions.count, doc.compactions[nextCompaction].at <= turn.startAt { nextCompaction += 1 } }
            let actions = turn.actionIndexes.compactMap { model.action($0) }
            let calls = actions.flatMap { model.tools(of: $0) }
            let steps = actions.enumerated().map { position, action in
                Self.step(action, model: model, last: position == actions.count - 1)
            }
            let clock = turn.startAt.formatted(date: .omitted, time: .shortened)
            let name = LaidText("Turn \(turn.index)", font: CanvasFont.turn, width: 120)
            let facts = "· \(clock) · \(SessionModel.duration(turn.duration)) · \(actions.count) action\(actions.count == 1 ? "" : "s")"
                + (calls.isEmpty ? "" : " · \(calls.count) tool call\(calls.count == 1 ? "" : "s")") + (turn.rewound ? " · rewound" : "")
            let failed = calls.filter(\.isError).count
            let subagents = calls.filter { model.subagentsByTool[$0.id] != nil }.count
            let background = calls.filter { model.tasksByLaunch[$0.id] != nil }.count
            let summary = "\(actions.count) action\(actions.count == 1 ? "" : "s") · \(calls.count) tool call\(calls.count == 1 ? "" : "s") · \(SessionModel.duration(turn.duration))"
                + (subagents > 0 ? " · \(subagents) subagent\(subagents == 1 ? "" : "s")" : "") + (background > 0 ? " · \(background) background" : "")
            turns.append(TurnContent(
                index: turn.index, name: name, facts: LaidText(facts, font: CanvasFont.caps, width: 620),
                card: Self.card(turn, model: model, actions: actions.count, clock: clock, task: pickupTurn[turn.index]),
                steps: steps,
                summary: SummaryContent(dots: actions.prefix(36).map { model.said.contains($0.index) }, text: LaidText(summary, font: CanvasFont.strand, width: 330),
                                        failed: failed > 0 ? LaidText("\(failed) failed", font: CanvasFont.strand, width: 80) : .empty),
                gapBefore: i > 0 ? turn.startAt.timeIntervalSince(doc.turns[i - 1].endAt) : 0,
                compactions: cuts))
        }
        self.turns = turns
    }

    private static func card(_ turn: Turn, model: SessionModel, actions: Int, clock: String, task: Relations.BackgroundTask?) -> PromptContent {
        let time = LaidText(clock, font: CanvasFont.meta, width: 70)
        if turn.isHuman, let prompt = model.prompt(ofTurn: turn.index) {
            let right = LaidText("\(actions) action\(actions == 1 ? "" : "s")", font: CanvasFont.mono, width: 80)
            let text = LaidText(prompt.text.isEmpty ? "(empty prompt)" : prompt.text, font: CanvasFont.prompt, width: BR.promptWidth - 22, maxLines: 3, lineHeight: 17.5)
            return PromptContent(human: true, who: LaidText("You", font: CanvasFont.title, width: 60), time: time, right: right, text: text,
                                 height: 9 + 16 + 5 + max(17.5, text.height) + 10,
                                 tip: "Turn \(turn.index) · you: " + SessionModel.firstLine(prompt.text, max: 160))
        }
        let line = task.map { "Background task \($0.id) finished: \($0.label ?? "")" } ?? "The agent continued without a prompt from you."
        let text = LaidText(line, font: CanvasFont.strand, width: BR.promptWidth - 18, maxLines: 2, lineHeight: 16)
        return PromptContent(human: false, who: LaidText(SessionModel.originLabel(turn.origin), font: CanvasFont.title, width: 150), time: time, right: .empty, text: text,
                             height: 7 + 16 + 4 + max(16, text.height) + 7, tip: "Turn \(turn.index) · " + line)
    }

    private static func step(_ action: Action, model: SessionModel, last: Bool) -> StepContent {
        let calls = model.tools(of: action)
        let said = model.said.contains(action.index)
        let failed = calls.filter(\.isError).count
        let one = calls.count == 1 ? calls.first : nil
        let prose = action.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // The icon says what the step did: the family its calls mostly belong to, a bubble when it spoke, a thought when it only thought.
        var symbol = "brain", tint = Tint.muted
        if said || (calls.isEmpty && !prose.isEmpty) {
            (symbol, tint) = ("text.bubble", said ? .ink : .accent)
        } else if !calls.isEmpty {
            var counts: [String: (ToolFamily, Int)] = [:]
            for call in calls { counts[call.family.symbol, default: (call.family, 0)].1 += 1 }
            let family = counts.values.max { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.symbol > $1.0.symbol }?.0 ?? .other
            (symbol, tint) = (family.symbol, Tint(family))
        }

        let titleText = said ? "Said" : one?.displayName ?? (calls.count > 1 ? "\(calls.count) tool calls in parallel" : !prose.isEmpty ? "Wrote" : "Thought")
        let subtitleText = one.map { $0.family == .file ? Self.shortPath($0.input?["file_path"]?.string ?? $0.label) : $0.label } ?? ""
        let seconds = model.spans[action.index].map { $0.end.timeIntervalSince($0.at) } ?? 0
        let right = LaidText("#\(action.index)" + (last && said ? "" : " · " + SessionModel.duration(seconds)), font: CanvasFont.mono, width: 110)

        var badges: [StepBadge] = []
        if failed > 0 { badges.append(StepBadge(text: LaidText("failed", font: CanvasFont.mono, width: 50), tint: .err)) }
        if model.handbacksByAction[action.index] != nil { badges.append(StepBadge(text: LaidText("hand-back", font: CanvasFont.mono, width: 70), tint: .warn)) }
        if calls.contains(where: { model.tasksByPickup[$0.id] != nil }) { badges.append(StepBadge(text: LaidText("task output", font: CanvasFont.mono, width: 80), tint: .ctx)) }
        let thoughtFirst = !action.thinking.isEmpty && !said
        // What is left of the header line for the title and the subtitle.
        let taken = 18 + 22 + right.width + 8 + badges.reduce(0) { $0 + $1.text.width + 14 } + (thoughtFirst ? 18 : 0)
        let title = LaidText(titleText, font: CanvasFont.title, width: BR.cardWidth - taken)
        let subtitle = LaidText(subtitleText, font: CanvasFont.text, width: BR.cardWidth - taken - title.width - 6)

        var body = LaidText.empty, muted = false
        if !prose.isEmpty {
            body = LaidText(SessionModel.firstLine(prose, max: 150), font: CanvasFont.text, width: BR.cardWidth - 18, maxLines: 2, lineHeight: 17)
        } else if calls.isEmpty {
            let thought = SessionModel.firstLine(action.thinking, max: 150)
            body = LaidText(thought.isEmpty ? (action.synthetic == true ? "Written by Claude Code" : "Continued without output") : thought,
                            font: CanvasFont.text, width: BR.cardWidth - 18, maxLines: 2, lineHeight: 17)
            muted = true
        }

        let chips: [ChipContent] = calls.count < 2 ? [] : calls.map { call in
            let duration = LaidText(call.duration.map(SessionModel.duration) ?? "", font: CanvasFont.mono, width: 50)
            let name = LaidText(call.displayName, font: CanvasFont.smallBold, width: 150)
            return ChipContent(toolID: call.id, symbol: call.family.symbol, tint: Tint(call.family), name: name,
                               label: LaidText(call.label, font: CanvasFont.small, width: BR.chipMax - 22 - name.width - 5 - duration.width - 22),
                               duration: duration, failed: call.isError,
                               async: model.subagentsByTool[call.id] != nil || model.tasksByLaunch[call.id] != nil)
        }
        let links = calls.map { call in
            CallLinks(toolID: call.id, subagent: model.subagentsByTool[call.id]?.agentId, launches: model.tasksByLaunch[call.id]?.id,
                      picksUp: model.relations.tasks.filter { task in task.pickups.contains { $0.toolId == call.id } }.map(\.id),
                      stops: model.relations.tasks.first { $0.stop?.toolId == call.id }?.id, resultHead: call.resultHead ?? "")
        }

        // What came back, for the arrow to the next step.
        var note: ResultNote?
        if let one {
            let head = one.resultHead ?? ""
            if !head.isEmpty || one.isError {
                note = ResultNote(text: LaidText((one.isError ? "✕ " : "→ ") + (head.isEmpty ? "failed" : head), font: CanvasFont.note, width: BR.cardWidth - 40, lineHeight: 16),
                                  failed: one.isError, key: .tool(one.id))
            }
        } else if calls.count > 1 {
            note = ResultNote(text: LaidText((failed > 0 ? "✕ " : "→ ") + "\(calls.count) results came back" + (failed > 0 ? ", \(failed) failed" : ""),
                                             font: CanvasFont.note, width: BR.cardWidth - 40, lineHeight: 16),
                              failed: failed > 0, key: .action(action.index))
        }

        let rows = chips.count
        let height = 7 + 16 + (body.isEmpty ? 0 : 4 + body.height) + (rows == 0 ? 0 : 7 + CGFloat(rows) * BR.chipHeight + CGFloat(rows - 1) * 4) + 8
        return StepContent(index: action.index, symbol: symbol, tint: tint, title: title, subtitle: subtitle, right: right, badges: badges,
                           thoughtFirst: thoughtFirst, body: body, bodyMuted: muted, chips: chips, calls: links, said: said, failed: failed > 0,
                           note: note, height: height,
                           tip: "#\(action.index) · " + titleText + (subtitleText.isEmpty ? "" : " · " + SessionModel.firstLine(subtitleText, max: 100))
                               + (prose.isEmpty ? "" : "\n" + SessionModel.firstLine(prose, max: 160)))
    }

    static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.count > 2 ? parts.suffix(2).joined(separator: "/") : path
    }
}

// MARK: Layout: where each node is

/// What the Braid shows of the session besides the chain.
nonisolated struct BraidOptions: Sendable, Equatable {
    var subagents = true
    var tasks = true
    var resultNotes = true
}

/// The Braid laid out: every node with its rectangle, the edges between them,
/// the notes on the arrows, the labels. Reading order, top to bottom; nothing
/// moves unless a turn is collapsed, so places stay where they were.
nonisolated struct CanvasLayout: Sendable {
    enum Kind: Sendable, Equatable {
        /// The card that opens turn number `turn` of the content.
        case prompt(turn: Int)
        case step(turn: Int, step: Int)
        case strand(agent: String)
        case summary(turn: Int)
    }

    struct Node: Sendable {
        var key: NodeKey
        var kind: Kind
        var rect: CGRect
    }

    enum EdgeKind: Sendable { case chain, spawn, handback, launch, thread, pickup }

    /// A straight line or a cubic curve from `from` to `to`.
    struct Edge: Sendable {
        var kind: EdgeKind
        var from: CGPoint
        var to: CGPoint
        var control1: CGPoint?
        var control2: CGPoint?
        var arrow = false

        var bounds: CGRect {
            var rect = CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y))
            if let control1 { rect = rect.union(CGRect(origin: control1, size: .zero)) }
            if let control2 { rect = rect.union(CGRect(origin: control2, size: .zero)) }
            return rect.insetBy(dx: -6, dy: -6)
        }
    }

    enum NoteKind: Sendable { case result(failed: Bool), task }

    struct Note: Sendable {
        var kind: NoteKind
        var rect: CGRect
        var text: LaidText
        var key: NodeKey?
    }

    enum PillKind: Sendable { case gap, compaction, neverRead }

    /// A small label centred on a point: "21m later", a compaction.
    struct Pill: Sendable {
        var kind: PillKind
        var center: CGPoint
        var text: LaidText
        var key: NodeKey?

        var rect: CGRect {
            let width = text.width + 18 + (kind == .compaction ? 16 : 0)
            return CGRect(x: center.x - width / 2, y: center.y - 9, width: width, height: 18)
        }
    }

    struct TurnLabel: Sendable {
        var turn: Int
        var origin: CGPoint
    }

    var nodes: [Node] = []
    var edges: [Edge] = []
    var notes: [Note] = []
    var pills: [Pill] = []
    var labels: [TurnLabel] = []
    /// The rules between turns: a y and how far right it runs.
    var separators: [(y: CGFloat, width: CGFloat)] = []
    var bounds = CGRect.zero
    var index: [NodeKey: Int] = [:]
    /// Each turn's extent, top to bottom, by position in the content, and the nodes it holds.
    var turnSpans: [ClosedRange<CGFloat>] = []
    var turnNodes: [Range<Int>] = []

    init(content: BraidContent, closed: Set<Int> = [], options: BraidOptions = BraidOptions()) {
        var y: CGFloat = 0
        var slots: [String?] = []
        var threadFrom: [String: CGPoint] = [:]
        var slotOf: [String: Int] = [:]
        var strandRect: [String: CGRect] = [:]
        var pendingBack: [String: CGPoint] = [:]
        let chainRight = BR.chainX + BR.cardWidth

        func taskNote(_ text: String, at cy: CGFloat, lane tx: CGFloat, task: TaskContent) -> Note {
            let width = tx - chainRight - 24
            return Note(kind: .task, rect: CGRect(x: chainRight + 12, y: cy - 22, width: width, height: 16),
                        text: LaidText(text, font: CanvasFont.small, width: width - 16, lineHeight: 16), key: .tool(task.launchTool))
        }

        for (position, turn) in content.turns.enumerated() {
            if position > 0 {
                separators.append((y + BR.turnGap / 2, BR.threadX + 40))
                if turn.gapBefore > 60 {
                    pills.append(Pill(kind: .gap, center: CGPoint(x: BR.chainX + BR.cardWidth / 2, y: y + BR.turnGap / 2),
                                      text: LaidText(SessionModel.duration(turn.gapBefore) + " later", font: CanvasFont.small, width: 200), key: nil))
                }
                y += BR.turnGap
            }
            for (offset, cut) in turn.compactions.enumerated() {
                pills.append(Pill(kind: .compaction, center: CGPoint(x: BR.promptWidth / 2, y: y - BR.turnGap / 2 + CGFloat(offset) * 22), text: cut.text, key: .compaction(cut.index)))
            }
            let turnTop = y
            let firstNode = nodes.count
            labels.append(TurnLabel(turn: position, origin: CGPoint(x: 0, y: y)))
            y += 24
            let top = y
            nodes.append(Node(key: .turn(turn.index), kind: .prompt(turn: position), rect: CGRect(x: 0, y: top, width: BR.promptWidth, height: turn.card.height)))
            var bottom = top + turn.card.height

            if closed.contains(turn.index) {
                if !turn.steps.isEmpty {
                    // The pill stands for the turn: selecting it selects the turn.
                    nodes.append(Node(key: .turn(turn.index), kind: .summary(turn: position), rect: CGRect(x: BR.chainX, y: top, width: BR.cardWidth + 150, height: 30)))
                    edges.append(Edge(kind: .chain, from: CGPoint(x: BR.promptWidth, y: top + 20), to: CGPoint(x: BR.chainX, y: top + 15),
                                      control1: CGPoint(x: BR.promptWidth + 24, y: top + 20), control2: CGPoint(x: BR.chainX - 24, y: top + 15)))
                    bottom = max(bottom, top + 30)
                }
            } else {
                var ay = top
                var previous: (rect: CGRect, step: StepContent)?
                var strandBottoms: [CGFloat] = []
                for (stepPosition, step) in turn.steps.enumerated() {
                    let received = options.subagents ? content.handbacks[step.index] ?? [] : []
                    // The chain waits for a hand-back: the step that received it sits below the strand.
                    for agent in received { if let rect = strandRect[agent] { ay = max(ay, rect.maxY + BR.gap) } }
                    if let previous, options.resultNotes, let note = previous.step.note {
                        ay = max(ay, previous.rect.maxY + 30)
                        notes.append(Note(kind: .result(failed: note.failed), rect: CGRect(x: BR.chainX + 34, y: previous.rect.maxY + 7, width: BR.cardWidth - 40, height: 16),
                                          text: note.text, key: note.key))
                    }
                    let rect = CGRect(x: BR.chainX, y: ay, width: BR.cardWidth, height: step.height)
                    nodes.append(Node(key: .action(step.index), kind: .step(turn: position, step: stepPosition), rect: rect))
                    if let previous {
                        edges.append(Edge(kind: .chain, from: CGPoint(x: BR.chainX + 22, y: previous.rect.maxY), to: CGPoint(x: BR.chainX + 22, y: ay), arrow: true))
                    } else {
                        edges.append(Edge(kind: .chain, from: CGPoint(x: BR.promptWidth, y: top + 22), to: CGPoint(x: BR.chainX, y: top + 22),
                                          control1: CGPoint(x: BR.promptWidth + 24, y: top + 22), control2: CGPoint(x: BR.chainX - 24, y: top + 22)))
                    }
                    if options.subagents {
                        for call in step.calls {
                            guard let agent = call.subagent, let strand = content.strands[agent] else { continue }
                            var sy = ay
                            for taken in strandBottoms where sy < taken { sy = taken + BR.gap }
                            let strandFrame = CGRect(x: BR.strandX, y: sy, width: BR.strandWidth, height: strand.height)
                            nodes.append(Node(key: .subagent(agent), kind: .strand(agent: agent), rect: strandFrame))
                            strandRect[agent] = strandFrame
                            strandBottoms.append(strandFrame.maxY)
                            edges.append(Edge(kind: .spawn, from: CGPoint(x: chainRight, y: rect.maxY - 19), to: CGPoint(x: BR.strandX, y: sy + 18),
                                              control1: CGPoint(x: chainRight + 30, y: rect.maxY - 19), control2: CGPoint(x: BR.strandX - 30, y: sy + 18), arrow: true))
                            if strand.hasHandback { pendingBack[agent] = CGPoint(x: BR.strandX, y: strandFrame.maxY - 10) }
                        }
                        for agent in received {
                            guard let from = pendingBack.removeValue(forKey: agent) else { continue }
                            edges.append(Edge(kind: .handback, from: from, to: CGPoint(x: chainRight, y: ay + 14),
                                              control1: CGPoint(x: from.x - 40, y: from.y), control2: CGPoint(x: chainRight + 40, y: ay + 14), arrow: true))
                        }
                    }
                    if options.tasks {
                        for call in step.calls {
                            if let id = call.launches, let task = content.tasks[id] {
                                let slot = slots.firstIndex(of: nil) ?? slots.count
                                if slot == slots.count { slots.append(id) } else { slots[slot] = id }
                                slotOf[id] = slot
                                let tx = BR.threadX + CGFloat(slot) * BR.threadStep
                                let cy = rect.maxY - 19
                                edges.append(Edge(kind: .launch, from: CGPoint(x: chainRight, y: cy), to: CGPoint(x: tx, y: cy)))
                                notes.append(taskNote("started in the background · " + task.label, at: cy, lane: tx, task: task))
                                threadFrom[id] = CGPoint(x: tx, y: cy)
                            }
                            for id in call.picksUp + (call.stops.map { [$0] } ?? []) {
                                guard let from = threadFrom[id], let task = content.tasks[id] else { continue }
                                let cy = ay + 14
                                edges.append(Edge(kind: .thread, from: from, to: CGPoint(x: from.x, y: cy)))
                                edges.append(Edge(kind: .pickup, from: CGPoint(x: from.x, y: cy), to: CGPoint(x: chainRight, y: cy), arrow: true))
                                if call.stops != id {
                                    notes.append(taskNote("task \(id) · " + SessionModel.firstLine(call.resultHead, max: 60), at: cy, lane: from.x, task: task))
                                }
                                if call.stops == id || task.lastReader == call.toolID {
                                    if let slot = slotOf[id] { slots[slot] = nil }
                                    threadFrom[id] = nil
                                } else {
                                    threadFrom[id] = CGPoint(x: from.x, y: cy)
                                }
                            }
                        }
                    }
                    previous = (rect, step)
                    ay += step.height + BR.gap
                }
                bottom = max(bottom, ay - BR.gap, strandBottoms.max() ?? 0)
            }
            y = bottom
            turnSpans.append(turnTop...max(turnTop, y))
            turnNodes.append(firstNode..<nodes.count)
        }
        // A background command nobody read: its thread ends in the open.
        for (id, from) in threadFrom.sorted(by: { $0.key < $1.key }) {
            edges.append(Edge(kind: .thread, from: from, to: CGPoint(x: from.x, y: from.y + 60)))
            pills.append(Pill(kind: .neverRead, center: CGPoint(x: from.x, y: from.y + 72), text: LaidText("never read", font: CanvasFont.mono, width: 80),
                              key: content.tasks[id].map { .tool($0.launchTool) }))
        }
        bounds = CGRect(x: -20, y: -20, width: BR.threadX + CGFloat(max(1, slots.count)) * BR.threadStep + 60 + 20, height: y + 40)
        // A collapsed turn has two nodes under its key; the card is the one a key leads to.
        for (i, node) in nodes.enumerated() where index[node.key] == nil { index[node.key] = i }
    }

    /// The nodes of the turns that reach into `rect`, in drawing order. Turns
    /// follow each other downwards and each one's nodes are together, so the
    /// first turn is found by halving.
    func nodes(in rect: CGRect) -> ArraySlice<Node> {
        var lo = 0, hi = turnSpans.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if turnSpans[mid].upperBound < rect.minY { lo = mid + 1 } else { hi = mid }
        }
        var end = lo
        while end < turnSpans.count, turnSpans[end].lowerBound <= rect.maxY { end += 1 }
        guard lo < end else { return [] }
        return nodes[turnNodes[lo].lowerBound..<turnNodes[end - 1].upperBound]
    }

    /// The rectangle a key lives at: its own node's, else the node that holds
    /// it, outwards until one is on the canvas (a tool call's step; a subagent
    /// step's strand; inside a collapsed turn, the turn's card).
    func rect(for key: NodeKey, model: SessionModel) -> CGRect? {
        if let i = index[key] { return nodes[i].rect }
        switch key {
        case .tool(let id):
            return model.toolsByID[id].flatMap { rect(for: .action($0.action), model: model) }
        case .step(let agent, _):
            return rect(for: .subagent(agent), model: model)
        case .subagent(let agent):
            return model.subagent(agent)?.toolUseId.flatMap { rect(for: .tool($0), model: model) }
        case .action(let n), .work(let n):
            return model.action(n).flatMap { index[.turn($0.turn)] }.map { nodes[$0].rect }
        case .compaction(let n):
            return pills.first { $0.key == .compaction(n) }?.rect
        case .turn, .file, .outside:
            return nil
        }
    }
}
