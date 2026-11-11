import SkitKit
import SwiftUI

/// The session over time (mock: `?view=timeline`): the strip is the overview
/// and the playhead, the ledger under it is the detail. Dragging the playhead
/// lights the ledger's row; a click on a row moves the playhead. "Where the
/// time went" is the engine's split of the wall time (`skit time`).
struct TimelineView: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    @AppStorage(SettingsKey.inspector) private var inspector = true
    @AppStorage(SettingsKey.keyHint) private var showHint = true
    @AppStorage(SettingsKey.timelineFollow) private var follow = true
    var model: SessionModel
    @State private var content: TimelineContent?
    @State private var rows: [LedgerItem] = []
    @FocusState private var keyboard: Bool

    private var id: String { model.doc.id }

    private var context: [ContextPoint] {
        if case .loaded(let stats) = store.stats[id] { stats.context ?? [] } else { [] }
    }

    private var time: SessionTime? {
        if case .loaded(let time) = store.times[id] { time } else { nil }
    }

    var body: some View {
        let timeline = window.timeline
        VStack(spacing: 0) {
            if let content {
                TimelineStrip(model: model, content: content, context: context,
                              onMove: { move(to: $0, scroll: follow) }, onRest: rest, onSelect: { choose($0, scroll: true) })
                    .padding(.horizontal, 24).padding(.top, 14)
                NowLine(model: model, content: content, context: context, onStep: stepQuietly(turns:), onPlay: togglePlay)
                    .padding(.horizontal, 28).padding(.vertical, 8)
                Rectangle().fill(palette.line).frame(height: 1)
                Ledger(model: model, rows: rows, time: time, onSelect: { choose($0, scroll: false) })
                    .overlay(alignment: .topTrailing) {
                        if timeline.whereShown {
                            WherePanel(model: model, time: store.times[id], onSelect: { choose($0, scroll: true) }, onWait: show)
                                .padding(.trailing, 24).padding(.top, 10)
                                .transition(.opacity.combined(with: .offset(y: -6)))
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if showHint { KeyHint(keys: Self.keys).padding(14) }
                    }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(palette.bg)
        .animation(.easeOut(duration: 0.12), value: timeline.whereShown)
        .focusable().focusEffectDisabled().focused($keyboard)
        .onKeyPress(phases: .down) { press in handle(press) ? .handled : .ignored }
        .task(id: id + "\(model.doc.actions.count)") {
            let made = TimelineContent(model: model)
            content = made
            rows = LedgerItem.rows(of: model)
            keyboard = true
            // The playhead starts on what is selected, else at the first prompt. Coming back
            // from another view it goes to what was selected there, else it is where it was left.
            let key = window.selection ?? window.transcript.focus
            if timeline.placedFor != id || (key != nil && key != timeline.own) {
                timeline.placedFor = id
                move(to: key.flatMap { made.date(of: $0, in: model) } ?? timeline.time ?? made.first, scroll: false)
                timeline.own = key
                timeline.scrollTarget = key.flatMap { model.itemID(for: $0) } ?? timeline.current.map { "a\($0)" }
            } else {
                timeline.scrollTarget = timeline.current.map { "a\($0)" }
            }
        }
        .task(id: id) { await store.loadTime(id) }
        // Find stepping, a link, the drawer's previous and next: the playhead goes where they point.
        .onChange(of: window.transcript.focus) { _, key in arrive(at: key) }
        .onChange(of: window.selection) { _, key in arrive(at: key) }
        .onDisappear { timeline.playing = false }
    }

    // MARK: The playhead

    /// Puts the playhead on a moment and lights the row of the action the
    /// model had begun on; with `scroll`, the ledger follows.
    private func move(to date: Date, scroll: Bool) {
        guard let content else { return }
        let timeline = window.timeline
        timeline.time = min(max(date, content.first), content.last)
        let current = content.action(at: timeline.time ?? date)
        if timeline.current != current {
            timeline.current = current
            if scroll, let current { timeline.scrollTarget = "a\(current)" }
        }
    }

    /// The playhead came to rest after a drag or a play: the keyboard is on the
    /// action it rests in, and an open drawer shows that action.
    private func rest() {
        guard let content, let time = window.timeline.time, let action = content.moment(at: time).action else { return }
        land(on: .action(action))
    }

    private func land(on key: NodeKey) {
        window.timeline.own = key
        window.transcript.focus = key
        if window.selection != nil { window.selection = key }
    }

    /// A click on a row, a mark of the strip or a line of the panel: the
    /// playhead goes to the node and the drawer opens on it.
    private func choose(_ key: NodeKey, scroll: Bool) {
        guard let content else { return }
        let timeline = window.timeline
        timeline.playing = false
        if let date = content.date(of: key, in: model) { move(to: date, scroll: false) }
        timeline.own = key
        window.transcript.focus = key
        if inspector { window.selection = key }
        if scroll { timeline.scrollTarget = model.itemID(for: key) }
    }

    /// The keyboard or the selection moved from somewhere else.
    private func arrive(at key: NodeKey?) {
        let timeline = window.timeline
        guard let key, let content, key != timeline.own else { return }
        timeline.own = nil
        timeline.playing = false
        if let date = content.date(of: key, in: model) { move(to: date, scroll: false) }
        timeline.scrollTarget = model.itemID(for: key)
    }

    /// A wait between two turns: the playhead at its start, its row in view.
    private func show(_ wait: SessionTime.Wait) {
        window.timeline.playing = false
        move(to: wait.at, scroll: false)
        window.timeline.scrollTarget = wait.seconds > 60 ? "gap\(wait.beforeTurn)" : "T\(wait.beforeTurn)"
    }

    private func togglePlay() {
        guard let content else { return }
        let timeline = window.timeline
        if timeline.playing {
            timeline.playing = false
            rest()
        } else {
            // From the end, play starts over.
            if let time = timeline.time, time >= content.last { move(to: content.first, scroll: follow) }
            timeline.playing = true
        }
    }

    // MARK: Keyboard

    /// Space plays, ← → turns, ↑ ↓ rows, Return or i inspects, w where the time
    /// went, / find, ? the list, esc closes what is open.
    private func handle(_ press: KeyPress) -> Bool {
        let timeline = window.timeline
        if press.modifiers.contains(.command) || press.modifiers.contains(.control) { return false }
        switch press.key {
        case .space: togglePlay(); return true
        case .leftArrow: stepQuietly(turns: -1); return true
        case .rightArrow: stepQuietly(turns: 1); return true
        case .downArrow: step(rows: 1); return true
        case .upArrow: step(rows: -1); return true
        case .return: inspect(); return true
        case .escape:
            if window.transcript.helpShown { window.transcript.helpShown = false } else if timeline.whereShown { timeline.whereShown = false } else if window.selection != nil { window.selection = nil } else { return false }
            return true
        default: break
        }
        switch press.characters {
        case "j": step(rows: 1)
        case "k": step(rows: -1)
        case "J": stepQuietly(turns: 1)
        case "K": stepQuietly(turns: -1)
        case "i": inspect()
        case "w", "W": timeline.whereShown.toggle()
        case "/": window.transcript.findRequests += 1
        case "?": window.transcript.helpShown.toggle()
        default: return false
        }
        return true
    }

    static let keys: [(String, String)] = [
        ("space", "play or pause"), ("drag the strip", "move the playhead"),
        ("← / →", "previous, next turn"), ("↑ / ↓", "previous, next row"),
        ("Return / i", "inspect the row in the drawer"), ("w", "where the time went"),
        ("/", "find"), ("esc", "close the panel or the drawer"), ("?", "this list"),
    ]

    /// Moves like a click would, without opening the drawer; it follows when it is open.
    private func walk(to key: NodeKey) {
        guard let content else { return }
        let timeline = window.timeline
        timeline.playing = false
        if let date = content.date(of: key, in: model) { move(to: date, scroll: false) }
        land(on: key)
        timeline.scrollTarget = model.itemID(for: key)
    }

    /// The start of the turn before the playhead, or of the next one.
    private func stepQuietly(turns by: Int) {
        guard let content, let time = window.timeline.time else { return }
        let target = by > 0 ? content.turns.first { $0.at > time } : content.turns.last { $0.at < time.addingTimeInterval(-0.5) }
        if let target { walk(to: .turn(target.turn)) }
    }

    private func step(rows by: Int) {
        let order = rows.compactMap(\.key)
        guard !order.isEmpty else { return }
        let here = window.transcript.focus ?? window.timeline.current.map { NodeKey.action($0) }
        guard let here, let at = order.firstIndex(of: here) else {
            walk(to: order[by > 0 ? 0 : order.count - 1])
            return
        }
        walk(to: order[min(max(at + by, 0), order.count - 1)])
    }

    private func inspect() {
        guard let key = window.transcript.focus ?? window.timeline.current.map({ NodeKey.action($0) }) else { return }
        inspector = true
        window.timeline.own = key
        window.transcript.focus = key
        window.selection = key
    }
}

/// Under the strip: the moment the playhead is on, in words, and the controls.
struct NowLine: View {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var model: SessionModel
    var content: TimelineContent
    var context: [ContextPoint]
    var onStep: (Int) -> Void
    var onPlay: () -> Void
    @State private var optionsShown = false

    var body: some View {
        let timeline = window.timeline
        let time = timeline.time ?? content.first
        let moment = content.moment(at: time)
        HStack(spacing: 10) {
            Text(Self.offset(time, from: content.first) + " · " + time.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.muted).fixedSize()
            Text(Self.words(moment, model: model, palette: palette)).font(.system(size: 12.5)).lineLimit(1).truncationMode(.tail)
            if !moment.subagents.isEmpty {
                Badge(text: moment.subagents.count == 1 ? "a subagent running" : "\(moment.subagents.count) subagents running", color: palette.warn)
            }
            if !moment.tasks.isEmpty {
                Badge(text: moment.tasks.count == 1 ? "a command in the background" : "\(moment.tasks.count) commands in the background", color: palette.ctx)
            }
            Spacer(minLength: 8)
            Text("context " + (context.last { $0.at <= time }.map { Format.tokens($0.tokens) } ?? "—"))
                .font(.system(size: 11.5)).foregroundStyle(palette.muted).monospacedDigit().fixedSize()
            HStack(spacing: 2) {
                Button { onStep(-1) } label: { Image(systemName: "backward.end.fill") }.help("Previous turn (←)")
                Button(action: onPlay) { Image(systemName: timeline.playing ? "pause.fill" : "play.fill").frame(width: 16) }
                    .help(timeline.playing ? "Pause (space)" : "Play (space)")
                Button { onStep(1) } label: { Image(systemName: "forward.end.fill") }.help("Next turn (→)")
            }
            Button("Where the time went") { timeline.whereShown.toggle() }
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(timeline.whereShown ? palette.accentSoft : .clear, in: Capsule())
                .help("Waiting for you against in turns, the model against tools (W)")
            Button { optionsShown.toggle() } label: { Image(systemName: "gearshape") }
                .help("Timeline options")
                .popover(isPresented: $optionsShown, arrowEdge: .bottom) { TimelineOptions().padding(14).frame(width: 330) }
        }
        .buttonStyle(.borderless).font(.system(size: 12))
    }

    /// "+0:04:12": how far into the session.
    static func offset(_ date: Date, from start: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(start).rounded()))
        // Past two days the hours stop meaning much: "+6d 22:47:16".
        if seconds >= 48 * 3600 { return String(format: "+%dd %02d:%02d:%02d", seconds / 86_400, seconds % 86_400 / 3600, seconds % 3600 / 60, seconds % 60) }
        return String(format: "+%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
    }

    /// What was happening, in words: the turn, the action, and which of its stretches.
    static func words(_ moment: TimelineContent.Moment, model: SessionModel, palette: Palette) -> AttributedString {
        func plain(_ text: String) -> AttributedString {
            var out = AttributedString(text)
            out.foregroundColor = palette.ink2
            return out
        }
        switch moment.doing {
        case .beforeTheFirstPrompt: return plain("before the first prompt")
        case .afterTheLastTurn: return plain("after the last turn")
        case .betweenTurns(let after, let forYou):
            return plain(forYou ? "waiting for you after turn \(after)" : "waiting for background work after turn \(after)")
        case .model, .tools, .waiting:
            var out = AttributedString("turn \(moment.turn ?? 0)")
            out.font = .system(size: 12.5, weight: .bold)
            guard let index = moment.action, let action = model.action(index) else { return out + plain(" · the model is starting") }
            let calls = model.tools(of: action)
            let title = calls.first.map { $0.displayName + ($0.label.isEmpty ? "" : " " + SessionModel.firstLine($0.label, max: 80)) }
                ?? SessionModel.firstLine(action.text.isEmpty ? action.thinking : action.text, max: 80)
            let doing = switch moment.doing {
            case .tools: calls.count > 1 ? "\(calls.count) tools running" : "running"
            case .waiting: "spoke, waiting to be brought back"
            default: "the model working"
            }
            var phase = AttributedString("  " + doing)
            phase.foregroundColor = moment.doing == .tools ? palette.tool : moment.doing == .waiting ? palette.muted : palette.accent
            return out + plain(" · action \(index) · " + title) + phase
        }
    }
}

/// The ⚙ of the Timeline, and its Settings tab.
struct TimelineOptions: View {
    @AppStorage(SettingsKey.timelineSpeed) private var speed = 30.0
    @AppStorage(SettingsKey.timelineFollow) private var follow = true

    var body: some View {
        Form {
            Picker("Playback", selection: $speed) {
                Text("Slow").tag(15.0)
                Text("Normal").tag(30.0)
                Text("Fast").tag(60.0)
            }
            .pickerStyle(.segmented)
            Toggle("The ledger follows the playhead", isOn: $follow)
        }
    }
}

/// "Where the time went": the wall time split by who the session was waiting
/// on, the turns split by who was working, the slowest tool calls and the
/// longest waits. Every number is the engine's (`skit time`).
struct WherePanel: View {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var model: SessionModel
    var time: Loadable<SessionTime>?
    var onSelect: (NodeKey) -> Void
    var onWait: (SessionTime.Wait) -> Void

    var body: some View {
        // With the drawer open there is less room: the panel scrolls rather than run under it.
        ViewThatFits(in: .vertical) {
            whole
            ScrollView { whole }
        }
        .frame(width: 430, alignment: .leading)
        .background { Panel(shadow: palette.shadow, radius: 16, y: 8) }
        .padding(.bottom, 12)
    }

    private var whole: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("WHERE THE TIME WENT").font(.caps).tracking(0.9).foregroundStyle(palette.muted)
                Spacer()
                Button { window.timeline.whereShown = false } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Close (esc)")
            }
            switch time {
            case .loaded(let time): split(time)
            case .failed(let why): Text(why).font(.system(size: 12)).foregroundStyle(palette.err)
            case .loading, nil: ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        }
        .padding(14)
    }

    @ViewBuilder private func split(_ time: SessionTime) -> some View {
        let turns = time.inTurns
        VStack(alignment: .leading, spacing: 5) {
            Text("Of \(SessionModel.duration(time.wall)) from the first record to the last").font(.system(size: 12)).foregroundStyle(palette.ink2)
            SplitBar(parts: [(time.waitingForYou, palette.muted2), (time.waitingForBackground, palette.ctx), (turns.seconds, palette.ink)], length: 402, height: 9)
            share("waiting for you", time.waitingForYou, of: time.wall, palette.muted2)
            if time.waitingForBackground > 0 { share("waiting for background work", time.waitingForBackground, of: time.wall, palette.ctx) }
            share("in turns", turns.seconds, of: time.wall, palette.ink)
        }
        VStack(alignment: .leading, spacing: 5) {
            Text("In turns").font(.system(size: 12)).foregroundStyle(palette.ink2).padding(.top, 2)
            SplitBar(parts: [(turns.model, palette.accent), (turns.tools, palette.tool), (turns.subagents, palette.warn), (turns.waiting, palette.ctx)], length: 402, height: 9)
            share("the model: waiting for it, thinking, writing", turns.model, of: turns.seconds, palette.accent)
            share("tools running", turns.tools, of: turns.seconds, palette.tool)
            if turns.subagents > 0 { share("subagents running", turns.subagents, of: turns.seconds, palette.warn) }
            if turns.waiting > 0 { share("spoke, waiting for a hand-back", turns.waiting, of: turns.seconds, palette.ctx) }
        }
        if !time.slowestCalls.isEmpty {
            Text("SLOWEST TOOL CALLS").font(.caps).tracking(0.9).foregroundStyle(palette.muted).padding(.top, 4)
            VStack(spacing: 1) {
                ForEach(time.slowestCalls.prefix(5), id: \.toolId) { call in
                    let family = ToolFamily(toolName: call.name)
                    line(symbol: family.symbol, color: palette.color(family), title: model.toolsByID[call.toolId]?.displayName ?? call.name,
                         detail: call.summary ?? "", trailing: SessionModel.duration(call.seconds), failed: call.isError == true) { onSelect(.tool(call.toolId)) }
                }
            }
        }
        if !time.longestWaits.isEmpty {
            Text("LONGEST WAITS").font(.caps).tracking(0.9).foregroundStyle(palette.muted).padding(.top, 4)
            VStack(spacing: 1) {
                ForEach(time.longestWaits.prefix(4), id: \.beforeTurn) { wait in
                    line(symbol: wait.whom == "you" ? "person" : "clock.arrow.circlepath", color: palette.muted, title: wait.whom == "you" ? "for you" : "for background work",
                         detail: "after turn \(wait.afterTurn) · " + Format.dateTime(wait.at), trailing: SessionModel.duration(wait.seconds), failed: false) { onWait(wait) }
                }
            }
        }
        Text("A tool call that waited for your permission counts as tool time: a transcript does not record that wait.")
            .font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
    }

    private func share(_ label: String, _ part: Double, of whole: Double, _ color: Color) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(label).font(.system(size: 12))
            Spacer(minLength: 8)
            Text(Self.percent(part, of: whole) + " · " + SessionModel.duration(part)).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.ink2)
        }
    }

    /// "71%", and "<1%" for a share that is there but rounds to nothing.
    static func percent(_ part: Double, of whole: Double) -> String {
        guard whole > 0, part > 0 else { return "0%" }
        let share = part / whole * 100
        return share < 0.5 ? "<1%" : "\(Int(share.rounded()))%"
    }

    private func line(symbol: String, color: Color, title: String, detail: String, trailing: String, failed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 16, height: 16).background(color, in: RoundedRectangle(cornerRadius: 4))
                (Text(title).font(.system(size: 12, weight: .semibold)) + Text("  " + detail).foregroundStyle(palette.ink2)).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 6)
                if failed { Badge(text: "failed", color: palette.err) }
                Text(trailing).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.ink2).fixedSize()
            }
            .padding(.vertical, 3).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
