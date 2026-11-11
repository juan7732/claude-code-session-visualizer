import SkitKit
import SwiftUI

/// The session as a conversation, read top to bottom (mock: `?view=transcript`).
struct TranscriptView: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    @AppStorage(SettingsKey.scrollMap) private var showMap = true
    @AppStorage(SettingsKey.keyHint) private var showHint = true
    @AppStorage(SettingsKey.inspector) private var inspector = true
    @AppStorage(SettingsKey.foldByDefault) private var foldByDefault = false
    var model: SessionModel
    @FocusState private var keyboard: Bool

    var body: some View {
        let state = window.transcript
        let rows = model.rows(folded: state.folded)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { item in
                        TranscriptRow(model: model, item: item)
                            .id(item.id)
                            .onAppear { state.visible.insert(item.id) }
                            .onDisappear { state.visible.remove(item.id) }
                    }
                }
                .frame(maxWidth: 840)
                .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 80)
                .padding(.trailing, showMap ? 40 : 0)
                .frame(maxWidth: .infinity)
            }
            .background(palette.bg)
            .overlay(alignment: .trailing) {
                if showMap {
                    ScrollMap(model: model, rows: rows) { id in
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .top) }
                    }
                    .padding(.trailing, 10).padding(.vertical, 10)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if showHint { KeyHint(keys: Self.keys).padding(14) }
            }
            .focusable().focusEffectDisabled().focused($keyboard)
            .onKeyPress(phases: .down) { press in handle(press) ? .handled : .ignored }
            .onChange(of: state.scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(target, anchor: .center) }
                state.scrollTarget = nil
            }
            .onAppear {
                keyboard = true
                if foldByDefault, !state.foldApplied { state.folded = Set(model.doc.turns.filter { $0.toolCalls > 0 }.map(\.index)) }
                state.foldApplied = true
                if let key = window.selection ?? state.focus, let id = model.itemID(for: key) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    // MARK: Keyboard (NOTES, iteration 11)

    /// j/k items, J/K turns, Return or i inspect in the drawer, → open (an
    /// action's calls, a call's input and result, a folded run), ← close, and
    /// with nothing open fold the turn's tool calls; e/c every call of the
    /// turn, g/G ends, / find, ? the list.
    private func handle(_ press: KeyPress) -> Bool {
        let state = window.transcript
        if press.modifiers.contains(.command) || press.modifiers.contains(.control) { return false }
        switch press.key {
        case .downArrow: move(1); return true
        case .upArrow: move(-1); return true
        case .rightArrow: open(true); return true
        case .return: inspect(); return true
        case .leftArrow: open(false); return true
        case .escape:
            if state.helpShown { state.helpShown = false } else if window.selection != nil { window.selection = nil } else { return false }
            return true
        default: break
        }
        switch press.characters {
        case "j": move(1)
        case "k": move(-1)
        case "J": moveTurn(1)
        case "K": moveTurn(-1)
        case "e": setTurnCalls(open: true)
        case "c": setTurnCalls(open: false)
        case "i": inspect()
        case "g": focus(order.first)
        case "G": focus(order.last)
        case "/": state.findRequests += 1
        case "?": state.helpShown.toggle()
        default: return false
        }
        return true
    }

    private func focus(_ key: NodeKey?) {
        guard let key else { return }
        let state = window.transcript
        state.focus = key
        // A tool row or a strand inside a closed parent has to be reachable.
        if case .subagent(let id) = key, let tool = model.subagent(id)?.toolUseId { state.open.insert(.tool(tool)) }
        state.scrollTarget = model.itemID(for: key)
        if window.selection != nil { window.selection = key }
    }

    private var order: [NodeKey] { model.focusOrder(folded: window.transcript.folded) }

    /// The first stop that is on screen: where the keyboard starts when
    /// nothing is focused, or when what was focused has been scrolled away.
    private func firstVisible(_ order: [NodeKey]) -> NodeKey? {
        let state = window.transcript
        guard let row = model.rows(folded: state.folded).first(where: { state.visible.contains($0.id) && $0.key != nil }) else { return order.first }
        return row.key.flatMap { order.contains($0) ? $0 : nil } ?? order.first
    }

    private func move(_ step: Int) {
        let state = window.transcript
        let order = self.order
        guard !order.isEmpty else { return }
        // Start from what is on screen, not from the ends of the session.
        guard let focus = state.focus, let current = order.firstIndex(of: focus),
              model.itemID(for: focus).map(state.visible.contains) ?? false
        else {
            self.focus(firstVisible(order))
            return
        }
        self.focus(order[min(max(current + step, 0), order.count - 1)])
    }

    private func moveTurn(_ step: Int) {
        let turns = model.doc.turns.map(\.index)
        guard !turns.isEmpty else { return }
        let current = window.transcript.focus.flatMap { model.turnIndex(of: $0) } ?? (step > 0 ? -1 : turns.count)
        focus(.turn(min(max(current + step, 0), turns.count - 1)))
    }

    /// → opens what the focused item holds; ← closes it, and when nothing of it
    /// is open, folds the turn's tool calls. The rules live in WindowState.
    private func open(_ open: Bool) {
        guard let focus = window.transcript.focus else { return }
        if open {
            for action in window.expand(focus, in: model) { Task { await store.loadAction(model.doc.id, action) } }
        } else {
            window.collapse(focus, in: model)
        }
    }

    /// Return and i: the focused item in the drawer.
    private func inspect() {
        guard let focus = window.transcript.focus else { return }
        inspector = true
        window.select(focus, in: model, scroll: false)
    }

    private func setTurnCalls(open: Bool) {
        let state = window.transcript
        guard let turn = state.focus.flatMap({ model.turnIndex(of: $0) }).flatMap({ model.turn($0) }) else { return }
        for call in turn.actionIndexes.compactMap({ model.action($0) }).flatMap({ model.tools(of: $0) }) {
            if open { state.open.insert(.tool(call.id)) } else { state.open.remove(.tool(call.id)) }
        }
    }
}

extension TranscriptView {
    static let keys: [(String, String)] = [
        ("j / ↓", "next item"), ("k / ↑", "previous item"), ("J / K", "next, previous turn"),
        ("Return / i", "inspect the item in the drawer"),
        ("→", "open: an action's tool calls, a call's input and result, a turn's folded calls"),
        ("←", "close what is open; otherwise fold the turn's tool calls into one line"),
        ("e / c", "open or close every call in the turn"),
        ("g / G", "top, bottom"), ("/", "find"), ("esc", "close the drawer"), ("?", "this list"),
    ]
}

/// The keys of a view, behind a small "? keys" at the bottom.
struct KeyHint: View {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var keys: [(String, String)]

    var body: some View {
        let state = window.transcript
        Group {
            if state.helpShown {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(keys, id: \.0) { key, what in
                        GridRow {
                            Text(key).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.ink)
                            Text(what).font(.system(size: 11.5)).foregroundStyle(palette.ink2)
                        }
                    }
                }
                .padding(12)
            } else {
                HStack(spacing: 6) {
                    Text("?").font(.system(size: 11, design: .monospaced)).padding(.horizontal, 5)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(palette.line2))
                    Text("keys").font(.system(size: 11.5))
                }
                .foregroundStyle(palette.muted)
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .background { Panel(shadow: palette.shadow.opacity(0.5), radius: 8, y: 4) }
        .contentShape(Rectangle())
        .onTapGesture { state.helpShown.toggle() }
        .accessibilityLabel("Keyboard shortcuts")
    }
}

/// The whole transcript at the right edge: every row drawn to an estimated
/// scale, the rows on screen framed, matches and the selection marked. A click
/// or a drag scrolls there.
private struct ScrollMap: View {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var model: SessionModel
    var rows: [TranscriptItem]
    var jump: (String) -> Void

    var body: some View {
        let state = window.transcript
        let weights = rows.map { Self.weight($0, model, folded: state.folded) }
        let total = max(1, weights.reduce(0, +))
        let hits = Set(state.hits.compactMap { model.itemID(for: $0) })
        let selected = window.selection.flatMap { model.itemID(for: $0) }
        GeometryReader { geo in
            Canvas { context, size in
                var y: CGFloat = 0
                var top: CGFloat?, bottom: CGFloat = 0
                for (item, weight) in zip(rows, weights) {
                    let height = max(1, weight / total * size.height)
                    let rect = CGRect(x: 6, y: y, width: size.width - 12, height: max(1, height - 1))
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Self.color(item, palette)))
                    if hits.contains(item.id) {
                        context.fill(Path(CGRect(x: 0, y: y, width: 4, height: max(2, height))), with: .color(palette.warn))
                    }
                    if item.id == selected {
                        context.fill(Path(CGRect(x: size.width - 4, y: y, width: 4, height: max(2, height))), with: .color(palette.accent))
                    }
                    if state.visible.contains(item.id) {
                        if top == nil { top = y }
                        bottom = y + height
                    }
                    y += height
                }
                if let top {
                    let frame = CGRect(x: 0.5, y: top, width: size.width - 1, height: max(8, bottom - top))
                    context.stroke(Path(roundedRect: frame, cornerRadius: 3), with: .color(palette.accent), lineWidth: 1)
                    context.fill(Path(roundedRect: frame, cornerRadius: 3), with: .color(palette.accent.opacity(0.10)))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                // The row under the pointer.
                var y: CGFloat = 0
                let target = min(max(0, value.location.y), geo.size.height)
                for (item, weight) in zip(rows, weights) {
                    y += weight / total * geo.size.height
                    if y >= target { jump(item.id); break }
                }
            })
        }
        .frame(width: 38)
        .background(palette.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(palette.line))
        .help("Click or drag to scroll")
        .accessibilityHidden(true)
    }

    /// How tall a row is likely to be, in arbitrary units: enough to give the map its shape.
    private static func weight(_ item: TranscriptItem, _ model: SessionModel, folded: Set<Int>) -> CGFloat {
        switch item {
        case .gap: 3
        case .compaction, .systemTurn, .event: 3
        case .turnEnd: 1.5
        // The lengths were counted when the model was built: the map is redrawn with every scroll.
        case .prompt(let turn): 4 + min(14, CGFloat(model.promptLength(ofTurn: turn)) / 90)
        case .work: 2.6
        case .action(let n):
            model.action(n).flatMap { action in
                model.prose(n).map { 1 + min(30, CGFloat($0.length) / 110) + (folded.contains(action.turn) ? 0 : CGFloat($0.calls) * 2.2) }
            } ?? 2
        }
    }

    private static func color(_ item: TranscriptItem, _ palette: Palette) -> Color {
        switch item {
        case .prompt: palette.ink
        case .action, .work: palette.tool.opacity(0.75)
        case .compaction: palette.warn
        case .event: palette.err
        case .systemTurn: palette.ctx
        case .gap, .turnEnd: palette.line2
        }
    }
}
