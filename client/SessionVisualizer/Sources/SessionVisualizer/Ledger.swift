import SkitKit
import SwiftUI

/// The ledger under the strip (mock: `?view=timeline`, the ledger): time runs
/// down, one row per action with its clock time, what it did and what came
/// back, and a bar of how long the model worked and how long its tools ran.
/// The row the playhead is in is lit; a click on a row moves the playhead there.
struct Ledger: View {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var model: SessionModel
    var rows: [LedgerItem]
    /// The engine's split of each turn's time, when it has arrived.
    var time: SessionTime?
    var onSelect: (NodeKey) -> Void

    var body: some View {
        let timeline = window.timeline
        let hits = Set(window.transcript.hits)
        let scale = LedgerScale(model: model, time: time)
        let turnTimes = Dictionary((time?.turns ?? []).map { ($0.turn, $0) }, uniquingKeysWith: { a, _ in a })
        ScrollViewReader { proxy in
            ScrollView {
                // One lazy stack, and nothing lazy inside a row (see the client's README).
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { item in
                        row(item, hits: hits, scale: scale, turnTimes: turnTimes).id(item.id)
                    }
                }
                .frame(maxWidth: 980)
                .padding(.horizontal, 28).padding(.top, 6).padding(.bottom, 80)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: timeline.scrollTarget) { _, target in
                guard let target else { return }
                if timeline.playing {
                    proxy.scrollTo(target, anchor: .center)
                } else {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(target, anchor: .center) }
                }
                timeline.scrollTarget = nil
            }
            .onAppear {
                if let target = timeline.scrollTarget {
                    proxy.scrollTo(target, anchor: .center)
                    timeline.scrollTarget = nil
                }
            }
        }
    }

    @ViewBuilder private func row(_ item: LedgerItem, hits: Set<NodeKey>, scale: LedgerScale, turnTimes: [Int: SessionTime.TurnTime]) -> some View {
        switch item {
        case .gap(let turn, let seconds, let forYou):
            QuietRow(clock: model.turn(turn - 1)?.endAt ?? model.turn(turn)?.startAt, symbol: forYou ? "person" : "clock.arrow.circlepath",
                     text: SessionModel.duration(seconds) + (forYou ? " idle, waiting for you" : " waiting for background work"), hatched: true)
        case .compaction(let n):
            CompactionRow(model: model, index: n, onSelect: onSelect)
        case .turn(let n):
            TurnRow(model: model, index: n, split: turnTimes[n], scale: scale, hit: hits.contains(.turn(n)), onSelect: onSelect)
        case .action(let n):
            ActionRow(model: model, index: n, scale: scale, hit: hits.contains(.action(n)), onSelect: onSelect)
        case .waited(let action, let seconds):
            QuietRow(clock: nil, symbol: "hourglass", text: Self.waitText(after: action, seconds: seconds, model: model), hatched: false)
        case .event(let n):
            if model.relations.events.indices.contains(n) {
                let event = model.relations.events[n]
                QuietRow(clock: event.at, symbol: "exclamationmark.triangle", text: Self.eventText(event), hatched: false, color: palette.err)
            }
        }
    }

    /// "spoke to you, then waited 3m 47s for the subagent to hand back".
    static func waitText(after action: Int, seconds: TimeInterval, model: SessionModel) -> String {
        let next = model.action(action).flatMap { model.turn($0.turn) }.flatMap { turn -> Int? in
            guard let at = turn.actionIndexes.firstIndex(of: action), at + 1 < turn.actionIndexes.count else { return nil }
            return turn.actionIndexes[at + 1]
        }
        let handback = next.flatMap { model.handbacksByAction[$0]?.first }
        let whom = handback.map { "for the subagent “\(model.subagent($0.agentId)?.meta?.description ?? "subagent")” to hand back" } ?? "until it was brought back"
        return "spoke to you, then waited \(SessionModel.duration(seconds)) \(whom)"
    }

    static func eventText(_ event: Relations.Event) -> String {
        let what = event.kind.replacingOccurrences(of: "_", with: " ")
        guard let message = event.message, !message.isEmpty else { return what }
        return what + " · " + SessionModel.firstLine(message, max: 110)
    }
}

/// How long a duration's bar is: by its logarithm, so a 4 s step and a 4 min
/// step are both readable (the mock's `bw`).
nonisolated struct LedgerScale: Equatable, Sendable {
    static let width: CGFloat = 190
    var longestAction: TimeInterval
    var longestTurn: TimeInterval

    init(model: SessionModel, time: SessionTime?) {
        longestAction = max(1, model.relations.spans.map { $0.toolsEnd.timeIntervalSince($0.start) }.max() ?? 1)
        longestTurn = max(1, model.doc.turns.map(\.duration).max() ?? 1)
    }

    func action(_ seconds: TimeInterval) -> CGFloat { Self.length(seconds, of: longestAction) }
    func turn(_ seconds: TimeInterval) -> CGFloat { Self.length(seconds, of: longestTurn) }

    static func length(_ seconds: TimeInterval, of longest: TimeInterval) -> CGFloat {
        guard seconds > 0 else { return 0 }
        return max(2, CGFloat(log1p(seconds) / log1p(max(1, longest))) * width)
    }
}

/// The columns every ledger row shares: clock, icon, what, bar, duration.
private struct LedgerColumns<Icon: View, What: View, Bar: View>: View {
    @Environment(\.palette) private var palette
    var clock: Date?
    var duration: String?
    @ViewBuilder var icon: Icon
    @ViewBuilder var what: What
    @ViewBuilder var bar: Bar

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(clock.map { $0.formatted(date: .omitted, time: .shortened) } ?? "")
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(palette.muted)
                .frame(width: 62, alignment: .leading).padding(.top, 2)
            icon.frame(width: 18)
            what.frame(maxWidth: .infinity, alignment: .leading)
            bar.frame(width: LedgerScale.width, alignment: .leading).padding(.top, 5)
            Text(duration ?? "").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(palette.muted)
                .frame(width: 58, alignment: .trailing).padding(.top, 2)
        }
    }
}

/// The frame of a row that stands for a node: lit when the playhead is in it,
/// ringed when it is selected, marked when find matched it.
private struct NodeRow: ViewModifier {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var key: NodeKey
    var model: SessionModel
    var current: Bool
    var hit: Bool
    var onSelect: (NodeKey) -> Void
    @State private var hover = false

    func body(content: Content) -> some View {
        let selected = window.selection == key
        content
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(current ? palette.panel : hover ? palette.panel2.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(alignment: .leading) {
                if current || hit {
                    RoundedRectangle(cornerRadius: 1.5).fill(hit ? palette.warn : palette.err).frame(width: 3).padding(.vertical, 5)
                }
            }
            .overlay {
                if selected { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(palette.accent, lineWidth: 2) }
            }
            .focusRing(key, radius: 9)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { onSelect(key) }
            .contextMenu {
                Button("Inspect") {
                    UserDefaults.standard.set(true, forKey: SettingsKey.inspector)
                    onSelect(key)
                    window.selection = key
                }
                Button("Show in Transcript") { window.reveal(key, in: model) }
                Button("Show on the Canvas") {
                    window.transcript.focus = key
                    window.sessionView = .canvas
                }
                Divider()
                Button("Copy Link") {
                    if let url = SessionLink.url(session: model.doc.id, view: .timeline, key: key) { Exporter.copy(url.absoluteString) }
                }
            }
    }
}

private struct TurnRow: View {
    @Environment(\.palette) private var palette
    @Environment(WindowState.self) private var window
    var model: SessionModel
    var index: Int
    var split: SessionTime.TurnTime?
    var scale: LedgerScale
    var hit: Bool
    var onSelect: (NodeKey) -> Void

    var body: some View {
        if let turn = model.turn(index) {
            let prompt = model.prompt(ofTurn: index)
            let inline = InlineText(palette: palette, query: window.transcript.query)
            let said = prompt.map { SessionModel.firstLine($0.text, max: 140) } ?? ""
            VStack(spacing: 0) {
                Rectangle().fill(palette.line2).frame(height: 1).padding(.bottom, 4)
                LedgerColumns(clock: turn.startAt, duration: SessionModel.duration(turn.duration)) {
                    Image(systemName: turn.isHuman ? "person.fill" : "bell").font(.system(size: 10)).foregroundStyle(palette.muted).padding(.top, 3)
                } what: {
                    (Text("Turn \(index)").font(.system(size: 13, weight: .bold))
                        + Text("  ·  ").foregroundStyle(palette.muted2)
                        + Text(inline.attributed(turn.isHuman && !said.isEmpty ? said : SessionModel.originLabel(turn.origin) + (turn.isHuman ? "" : " opened the turn"), markdown: false)).foregroundStyle(palette.ink2))
                        .font(.system(size: 12.5)).lineLimit(1)
                } bar: {
                    if let split {
                        SplitBar(parts: [(split.model, palette.accent), (split.tools, palette.tool), (split.subagents, palette.warn), (split.waiting, palette.ctx.opacity(0.7))],
                                 length: scale.turn(split.seconds))
                            .help(Self.help(split))
                    }
                }
                .modifier(NodeRow(key: .turn(index), model: model, current: false, hit: hit, onSelect: onSelect))
            }
            .padding(.top, 10)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Turn \(index), \(SessionModel.duration(turn.duration))")
        }
    }

    static func help(_ split: SessionTime.TurnTime) -> String {
        var parts = ["the model \(SessionModel.duration(split.model))", "tools \(SessionModel.duration(split.tools))"]
        if split.subagents > 0 { parts.append("subagents \(SessionModel.duration(split.subagents))") }
        if split.waiting > 0 { parts.append("waiting for a hand-back \(SessionModel.duration(split.waiting))") }
        return parts.joined(separator: " · ")
    }
}

private struct ActionRow: View {
    @Environment(\.palette) private var palette
    @Environment(WindowState.self) private var window
    var model: SessionModel
    var index: Int
    var scale: LedgerScale
    var hit: Bool
    var onSelect: (NodeKey) -> Void

    var body: some View {
        if let action = model.action(index) {
            let calls = model.tools(of: action)
            let span = model.spans[index]
            let said = model.said.contains(index)
            let working = span.map { $0.genEnd.timeIntervalSince($0.start) } ?? 0
            let running = span.map { $0.toolsEnd.timeIntervalSince($0.genEnd) } ?? 0
            let inline = InlineText(palette: palette, query: window.transcript.query)
            LedgerColumns(clock: span?.start ?? action.at, duration: working + running > 0 ? SessionModel.duration(working + running) : nil) {
                icon(calls, said: said)
            } what: {
                VStack(alignment: .leading, spacing: 2) {
                    (Text(ActionRowText.verb(action, calls, said: said)).font(.system(size: 12.5, weight: .semibold))
                        + Text("  ") + Text(inline.attributed(ActionRowText.what(action, calls), markdown: false)).foregroundStyle(palette.ink2))
                        .font(.system(size: 12.5)).lineLimit(2)
                    if let note = ActionRowText.result(calls) {
                        Text(inline.attributed(note.text, markdown: false)).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(note.failed ? palette.err : palette.muted).lineLimit(2)
                    }
                    ForEach(model.handbacksByAction[index] ?? [], id: \.agentId) { handback in
                        Label("hand-back from “\(model.subagent(handback.agentId)?.meta?.description ?? "subagent")”", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 11.5)).foregroundStyle(palette.warn)
                    }
                    ForEach(calls.filter { model.subagentsByTool[$0.id] != nil || model.tasksByLaunch[$0.id] != nil }, id: \.id) { call in
                        relation(of: call)
                    }
                }
            } bar: {
                if working + running > 0 {
                    SplitBar(parts: [(working, palette.accent), (running, palette.tool)], length: scale.action(working + running), logarithmic: scale)
                        .help("the model \(SessionModel.duration(working))" + (running > 0 ? " · tools \(SessionModel.duration(running))" : ""))
                }
            }
            // A long step is a taller row: time runs down the page (the mock's ledger).
            .frame(minHeight: min(64, 22 + (working + running) / 6), alignment: .top)
            .modifier(NodeRow(key: .action(index), model: model, current: window.timeline.current == index, hit: hit, onSelect: onSelect))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Action \(index), \(ActionRowText.verb(action, calls, said: said)) \(ActionRowText.what(action, calls))")
        }
    }

    @ViewBuilder private func icon(_ calls: [ToolCall], said: Bool) -> some View {
        let family = calls.first?.family
        Image(systemName: family?.symbol ?? (said ? "text.bubble" : "text.alignleft"))
            .font(.system(size: 10, weight: .semibold)).foregroundStyle(family == nil && said ? palette.bg : .white)
            .frame(width: 18, height: 18)
            .background(family.map { palette.color($0) } ?? (said ? palette.ink : palette.muted), in: RoundedRectangle(cornerRadius: 5))
    }

    /// A subagent the action started, or a command it left running: a line that selects it.
    @ViewBuilder private func relation(of call: ToolCall) -> some View {
        if let sub = model.subagentsByTool[call.id] {
            let run = sub.session
            Button {
                onSelect(.subagent(sub.agentId))
            } label: {
                Label("subagent “\(sub.meta?.description ?? "subagent")” · \(run?.actions.count ?? 0) steps" + (run.map { " · " + SessionModel.duration($0.lastAt.timeIntervalSince($0.firstAt)) } ?? ""),
                      systemImage: "person.2")
                    .font(.system(size: 11.5)).foregroundStyle(palette.warn)
            }
            .buttonStyle(.plain)
        } else if let task = model.tasksByLaunch[call.id] {
            Label("started in the background" + (task.pickups.first.map { " · read back in turn \($0.turn), \(SessionModel.duration($0.at.timeIntervalSince(call.at))) later" } ?? " · never read"),
                  systemImage: "clock.arrow.circlepath")
                .font(.system(size: 11.5)).foregroundStyle(palette.ctx)
        }
    }
}

/// The words of an action's row.
enum ActionRowText {
    static func verb(_ action: Action, _ calls: [ToolCall], said: Bool) -> String {
        if calls.count == 1 { return calls[0].displayName }
        if calls.count > 1 { return "\(calls.count) tool calls" }
        if said { return "Said" }
        if action.synthetic == true { return "Claude Code" }
        return SessionModel.hasProse(action) ? "Wrote" : "Thought"
    }

    static func what(_ action: Action, _ calls: [ToolCall]) -> String {
        if calls.count == 1 { return SessionModel.firstLine(calls[0].label, max: 150) }
        let text = SessionModel.firstLine(action.text.isEmpty ? action.thinking : action.text, max: 150)
        if calls.count > 1, text.isEmpty { return SessionModel.firstLine(calls.map(\.label).first { !$0.isEmpty } ?? "", max: 150) }
        return text
    }

    /// "Read ×4, Bash": the tools of several calls, each once.
    static func names(_ calls: [ToolCall]) -> String {
        var order: [String] = [], counts: [String: Int] = [:]
        for call in calls {
            if counts[call.displayName] == nil { order.append(call.displayName) }
            counts[call.displayName, default: 0] += 1
        }
        return order.map { counts[$0] == 1 ? $0 : "\($0) ×\(counts[$0] ?? 0)" }.joined(separator: ", ")
    }

    /// What came back: the first line of one call's result, or how several went.
    static func result(_ calls: [ToolCall]) -> (text: String, failed: Bool)? {
        if calls.count == 1, let call = calls.first {
            let head = call.resultHead ?? ""
            guard !head.isEmpty || call.isError else { return nil }
            return ((call.isError ? "✕ " : "→ ") + (head.isEmpty ? "failed" : head), call.isError)
        }
        guard calls.count > 1 else { return nil }
        let failed = calls.filter(\.isError).count
        return ("in parallel: " + names(calls) + (failed > 0 ? " · \(failed) failed" : ""), false)
    }
}

/// A bar in parts, each in its colour. With `logarithmic`, a part ends where
/// the scale puts the time up to it, as the mock's ledger does; without, the
/// parts share the length by their size.
struct SplitBar: View {
    @Environment(\.palette) private var palette
    var parts: [(seconds: Double, color: Color)]
    var length: CGFloat
    var logarithmic: LedgerScale?
    var height: CGFloat = 7

    var body: some View {
        let total = parts.map(\.seconds).reduce(0, +)
        Canvas { g, size in
            g.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: size.width, height: size.height), cornerRadius: size.height / 2), with: .color(palette.panel2))
            guard total > 0 else { return }
            var clipped = g
            clipped.clip(to: Path(roundedRect: CGRect(x: 0, y: 0, width: min(size.width, length), height: size.height), cornerRadius: size.height / 2))
            var x: CGFloat = 0, sum = 0.0
            for part in parts where part.seconds > 0 {
                sum += part.seconds
                let end = logarithmic.map { $0.action(sum) } ?? length * CGFloat(sum / total)
                clipped.fill(Path(CGRect(x: x, y: 0, width: max(1, end - x), height: size.height)), with: .color(part.color))
                x = max(x + 1, end)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private struct CompactionRow: View {
    @Environment(\.palette) private var palette
    @Environment(WindowState.self) private var window
    var model: SessionModel
    var index: Int
    var onSelect: (NodeKey) -> Void

    var body: some View {
        if model.doc.compactions.indices.contains(index) {
            let cut = model.doc.compactions[index]
            LedgerColumns(clock: cut.at, duration: nil) {
                Image(systemName: "scissors").font(.system(size: 11)).foregroundStyle(palette.warn).padding(.top, 2)
            } what: {
                Text("context compacted" + (Self.sizes(cut) ?? ""))
                    .font(.system(size: 12.5)).foregroundStyle(palette.warn)
            } bar: {
                EmptyView()
            }
            .modifier(NodeRow(key: .compaction(index), model: model, current: false, hit: false, onSelect: onSelect))
        }
    }
}

extension CompactionRow {
    /// " · 160k → 12k", when the transcript recorded both sizes.
    static func sizes(_ cut: Compaction) -> String? {
        guard let before = cut.metadata?.preTokens, let after = cut.metadata?.postTokens else { return nil }
        return " · \(Format.tokens(before)) → \(Format.tokens(after))"
    }
}

/// A row that is not a node: an idle gap, a wait, an error.
private struct QuietRow: View {
    @Environment(\.palette) private var palette
    var clock: Date?
    var symbol: String
    var text: String
    var hatched: Bool
    var color: Color?

    var body: some View {
        LedgerColumns(clock: clock, duration: nil) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(color ?? palette.muted2).padding(.top, 3)
        } what: {
            Text(text).font(.system(size: 12)).italic(color == nil).foregroundStyle(color ?? palette.muted).lineLimit(2)
        } bar: {
            EmptyView()
        }
        .padding(.horizontal, 10).padding(.vertical, hatched ? 9 : 4)
        .background {
            if hatched { Hatch().stroke(palette.line2, lineWidth: 1).background(palette.panel2.opacity(0.25)).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)) }
        }
        .padding(.top, hatched ? 8 : 0)
        .accessibilityElement(children: .combine)
    }

    /// Diagonal lines: the same hatch as the strip's idle bands.
    private struct Hatch: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            var x = -rect.height
            while x < rect.width {
                path.move(to: CGPoint(x: x, y: rect.maxY))
                path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                x += 7
            }
            return path
        }
    }
}
