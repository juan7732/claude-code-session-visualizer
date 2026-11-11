import SkitKit
import SwiftUI

/// What the Canvas of one session remembers while the window shows it.
@Observable
final class CanvasState {
    var camera = Camera()
    /// Turns collapsed to one pill.
    var closed: Set<Int> = []
    var showSubagents = true
    var showTasks = true
    /// The size of the drawing view, and the extent of what is laid out: what Fit needs.
    var viewSize = CGSize.zero
    var bounds = CGRect.zero
    /// The session whose saved camera has been applied.
    var cameraFor: String?
    /// Bumped to centre the camera on the selection or the keyboard's node.
    var focusRequests = 0
    /// The Score is showing: fitting means its rows, not the Braid's width.
    var score = false

    func zoom(by factor: CGFloat) {
        camera.zoom(by: factor, at: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
    }

    func actualSize() {
        camera.zoom(by: 1 / camera.scale, at: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
    }

    func fitWidth() { if score { camera.fitRows(bounds, in: viewSize) } else { camera.fitWidth(bounds, in: viewSize) } }
    func fitAll() { camera.fitAll(bounds, in: viewSize) }
}

/// The session as a canvas (mock: `?view=canvas`), in one of two layouts. The
/// Braid is reading order from top to bottom: each turn a prompt and the chain
/// of steps it started, what came back written on the arrows, subagents
/// braided in beside the chain, background commands as threads at the right.
/// The Score is time from left to right: a row for each who was working.
struct CanvasView: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    @AppStorage(SettingsKey.inspector) private var inspector = true
    @AppStorage(SettingsKey.canvasBackground) private var background = "dots"
    @AppStorage(SettingsKey.canvasMinimap) private var minimap = "left"
    @AppStorage(SettingsKey.canvasLegend) private var legend = true
    @AppStorage(SettingsKey.canvasNotes) private var resultNotes = true
    @AppStorage(SettingsKey.keyHint) private var showHint = true
    @AppStorage(SettingsKey.canvasLayout) private var layoutName = "braid"
    @AppStorage(SettingsKey.scoreScale) private var scoreScale = 1.8
    @AppStorage(SettingsKey.scoreFiles) private var scoreFiles = true
    var model: SessionModel
    @State private var content: BraidContent?
    @State private var layout: CanvasLayout?
    @State private var score: ScoreLayout?
    @State private var optionsShown = false

    private var isScore: Bool { layoutName == "score" }

    private var options: BraidOptions {
        BraidOptions(subagents: window.canvas.showSubagents, tasks: window.canvas.showTasks, resultNotes: resultNotes)
    }

    private var scoreOptions: ScoreOptions {
        ScoreOptions(subagents: window.canvas.showSubagents, tasks: window.canvas.showTasks, files: scoreFiles, pointsPerSecond: scoreScale)
    }

    /// What the minimap draws: every node of the layout on show, in its kind's colour.
    private var map: (bounds: CGRect, marks: [Minimap.Mark])? {
        if isScore {
            guard let score else { return nil }
            return (score.bounds, score.nodes.compactMap { node in
                switch node.kind {
                case .turn, .touch: nil
                case .prompt: Minimap.Mark(rect: node.rect, color: palette.ink)
                case .action: Minimap.Mark(rect: node.rect, color: palette.accent)
                case .tool: Minimap.Mark(rect: node.rect, color: palette.tool.opacity(0.6))
                case .strand, .step: Minimap.Mark(rect: node.rect, color: palette.warn)
                case .task: Minimap.Mark(rect: node.rect, color: palette.ctx)
                }
            })
        }
        guard let layout else { return nil }
        return (layout.bounds, layout.nodes.map { node in
            let color: Color = switch node.kind {
            case .prompt: palette.ink
            case .step, .summary: palette.accent
            case .strand: palette.warn
            }
            return Minimap.Mark(rect: node.rect, color: color)
        })
    }

    var body: some View {
        let canvas = window.canvas
        VStack(spacing: 0) {
            bar(canvas)
            Rectangle().fill(palette.line).frame(height: 1)
            ZStack {
                if isScore {
                    ScoreCanvasHost(layout: score, palette: palette, camera: canvas.camera,
                                    selection: window.selection, focus: window.transcript.focus, matches: Set(window.transcript.hits), background: background,
                                    onCamera: { canvas.camera = $0 }, onSize: { canvas.viewSize = $0 },
                                    onSelect: select, onKey: key, menuItems: menu)
                } else {
                    BraidCanvasHost(model: model, content: content, layout: layout, palette: palette, camera: canvas.camera,
                                    selection: window.selection, focus: window.transcript.focus, matches: Set(window.transcript.hits), background: background,
                                    onCamera: { canvas.camera = $0 }, onSize: { canvas.viewSize = $0 },
                                    onSelect: select, onDoubleClick: toggle, onKey: key, menuItems: menu)
                }
                if isScore ? score == nil : content == nil {
                    ProgressView().controlSize(.small)
                }
            }
            .overlay(alignment: minimap == "right" ? .bottomTrailing : .bottomLeading) {
                if minimap != "off", let map { Minimap(bounds: map.bounds, marks: map.marks).padding(14) }
            }
            .overlay(alignment: minimap == "right" ? .bottomLeading : .bottomTrailing) {
                if legend { Legend(score: isScore).padding(14) }
            }
            .overlay(alignment: isScore ? .topTrailing : .topLeading) {
                // The Score's top left is its ruler and its row names.
                if showHint { KeyHint(keys: isScore ? Self.scoreKeys : Self.keys).padding(14).padding(.top, isScore ? SC.ruler - 8 : 0) }
            }
        }
        .background(palette.bg)
        .task(id: model.doc.id + "\(model.doc.actions.count)" + (isScore ? "score" : "braid")) {
            guard !isScore else { return }
            // Breaking every text into lines is the costly part: once per session, off the main thread.
            let model = self.model
            let built = await Task.detached(priority: .userInitiated) { BraidContent(model: model) }.value
            // Another session, or the Score, took over while this one was being broken into lines.
            guard !Task.isCancelled else { return }
            content = built
            relayout()
            start()
        }
        .task(id: ScoreKey(session: model.doc.id, actions: model.doc.actions.count, on: isScore, options: scoreOptions)) {
            guard isScore else { return }
            // The Score is laid out whole: a change of scale moves every bar and re-breaks every label.
            let model = self.model, options = scoreOptions
            let made = await Task.detached(priority: .userInitiated) { ScoreLayout(model: model, options: options) }.value
            guard !Task.isCancelled else { return }
            // The moment at the left edge stays there when the scale of time changes.
            if let old = score, canvas.cameraFor == model.doc.id, old.options.pointsPerSecond != made.options.pointsPerSecond {
                let moment = old.axis.date(at: (SC.gutter - canvas.camera.x) / canvas.camera.scale)
                canvas.camera.x = SC.gutter - made.axis.x(moment) * canvas.camera.scale
            }
            score = made
            canvas.bounds = made.bounds
            canvas.camera.clamp(to: made.bounds, in: canvas.viewSize)
            start()
        }
        .onChange(of: isScore, initial: true) { _, now in
            // Each layout has its own camera: take it up again when the layout changed.
            guard canvas.score != now else { return }
            canvas.score = now
            canvas.cameraFor = nil
            if !now, let layout {
                canvas.bounds = layout.bounds
                start()
            }
        }
        .onChange(of: canvas.closed) { relayout() }
        .onChange(of: options) { relayout() }
        .onChange(of: canvas.viewSize) { start() }
        .onChange(of: canvas.focusRequests) { center(on: window.selection ?? window.transcript.focus, always: true) }
        // Find stepping, a link, the keyboard: bring what they point at into view.
        .onChange(of: window.transcript.focus) { _, key in center(on: key, always: false) }
        .onChange(of: window.selection) { _, key in center(on: key, always: false) }
        .task(id: canvas.camera) {
            // Remember where this session's canvas was left, once the camera has rested.
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled, !Snapshot.keepsNothing, canvas.cameraFor == model.doc.id, canvas.score == isScore, let data = try? JSONEncoder().encode(canvas.camera) {
                UserDefaults.standard.set(data, forKey: SettingsKey.canvasCamera(model.doc.id, score: isScore))
            }
        }
    }

    private struct ScoreKey: Equatable {
        var session: String
        var actions: Int
        var on: Bool
        var options: ScoreOptions
    }

    /// The rectangle a node has in the layout on show.
    private func rect(for key: NodeKey) -> CGRect? {
        isScore ? score?.rect(for: key, model: model) : layout?.rect(for: key, model: model)
    }

    private func relayout() {
        guard let content, !isScore else { return }
        let canvas = window.canvas
        let made = CanvasLayout(content: content, closed: canvas.closed, options: options)
        // A turn that collapses changes every height below it. The turn at the
        // top of the view stays where it is on screen; the rest moves around it.
        if let old = layout, canvas.viewSize.height > 0 {
            let top = canvas.camera.visible(in: canvas.viewSize).minY
            if let anchor = old.turnSpans.firstIndex(where: { $0.upperBound >= top }), made.turnSpans.indices.contains(anchor) {
                let onScreen = old.turnSpans[anchor].lowerBound * canvas.camera.scale + canvas.camera.y
                canvas.camera.y = onScreen - made.turnSpans[anchor].lowerBound * canvas.camera.scale
            }
            canvas.camera.clamp(to: made.bounds, in: canvas.viewSize)
        }
        layout = made
        canvas.bounds = made.bounds
    }

    /// The first camera of a session: on what is selected, else where it was
    /// left, else the top at a readable size (the Score: its rows, from the start).
    private func start() {
        let canvas = window.canvas
        guard let bounds = isScore ? score?.bounds : layout?.bounds, canvas.viewSize.width > 0, canvas.cameraFor != model.doc.id else { return }
        canvas.cameraFor = model.doc.id
        canvas.bounds = bounds
        let saved = Snapshot.active ? nil : UserDefaults.standard.data(forKey: SettingsKey.canvasCamera(model.doc.id, score: isScore)).flatMap { try? JSONDecoder().decode(Camera.self, from: $0) }
        if isScore {
            // The rows first, so that a camera then brought to a node is at a scale that shows them.
            canvas.camera = Camera()
            canvas.camera.fitRows(bounds, in: canvas.viewSize)
            if let key = window.selection ?? window.transcript.focus, let rect = rect(for: key) {
                canvas.camera.show(rect, in: canvas.viewSize, readable: true)
            } else if let saved {
                canvas.camera = saved
            }
            canvas.camera.clamp(to: bounds, in: canvas.viewSize)
        } else if let key = window.selection ?? window.transcript.focus, let rect = rect(for: key) {
            canvas.camera.center(on: rect, in: canvas.viewSize, bounds: bounds)
        } else if let saved {
            canvas.camera = saved
            canvas.camera.clamp(to: bounds, in: canvas.viewSize)
        } else {
            canvas.camera = Camera()
        }
    }

    private func center(on key: NodeKey?, always: Bool) {
        let canvas = window.canvas
        guard let key, canvas.viewSize.width > 0, canvas.cameraFor == model.doc.id, let rect = rect(for: key) else { return }
        guard always || !canvas.camera.shows(rect, in: canvas.viewSize) else { return }
        if isScore {
            canvas.camera.show(rect, in: canvas.viewSize, readable: always)
        } else if let layout {
            canvas.camera.center(on: rect, in: canvas.viewSize, bounds: layout.bounds, readable: always)
        }
    }

    // MARK: What the drawing view reports

    private func select(_ hit: CanvasHit?) {
        guard let hit else { return }
        window.transcript.focus = hit.key
        if inspector { window.selection = hit.key }
    }

    private func toggle(_ hit: CanvasHit) {
        guard let turn = hit.turn else { return }
        toggle(turn: turn)
    }

    private func toggle(turn: Int) {
        guard !isScore, (model.turn(turn)?.actionIndexes.count ?? 0) > 0 else { return }
        if window.canvas.closed.contains(turn) { window.canvas.closed.remove(turn) } else { window.canvas.closed.insert(turn) }
    }

    private func menu(_ hit: CanvasHit) -> [(title: String, action: () -> Void)] {
        var items: [(String, () -> Void)] = [
            ("Inspect", {
                inspector = true
                window.selection = hit.key
            }),
            ("Add a Note…", {
                inspector = true
                window.inspectorTab = .note
                window.selection = hit.key
            }),
            ("Show in Transcript", { window.reveal(hit.key, in: model) }),
        ]
        if let turn = model.turnIndex(of: hit.key) {
            items.append(("-", {}))
            if !isScore, (model.turn(turn)?.actionIndexes.count ?? 0) > 0 {
                items.append((window.canvas.closed.contains(turn) ? "Expand This Turn" : "Collapse This Turn", { toggle(turn: turn) }))
            }
            items.append(("Copy Turn as Markdown", { Exporter.copyTurn(turn, of: model.doc.id, store: store) }))
        }
        items.append(("Copy Link", {
            if let url = SessionLink.url(session: model.doc.id, view: .canvas, key: hit.key) { Exporter.copy(url.absoluteString) }
        }))
        return items.map { (title: $0.0, action: $0.1) }
    }

    /// ← → turns, ↑ ↓ steps, Return collapses or expands the turn, i inspects,
    /// f centres, esc lets go of the selection.
    private func key(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) { return false }
        let state = window.transcript
        switch event.keyCode {
        case 123: step(turns: -1); return true
        case 124: step(turns: 1); return true
        case 125: step(nodes: 1); return true
        case 126: step(nodes: -1); return true
        case 36, 76:
            if let turn = (window.selection ?? state.focus).flatMap({ model.turnIndex(of: $0) }) { toggle(turn: turn) }
            return true
        case 53:
            if window.selection != nil { window.selection = nil; return true }
            return false
        default: break
        }
        switch event.charactersIgnoringModifiers {
        case "j": step(nodes: 1)
        case "k": step(nodes: -1)
        case "J": step(turns: 1)
        case "K": step(turns: -1)
        case "i":
            if let focus = state.focus {
                inspector = true
                window.selection = focus
            }
        case "f", "F": window.canvas.focusRequests += 1
        case "/": state.findRequests += 1
        case "?": state.helpShown.toggle()
        default: return false
        }
        return true
    }

    static let keys: [(String, String)] = [
        ("scroll", "move"), ("pinch, ⌘ scroll", "zoom where the pointer is"), ("drag", "move"),
        ("↑ / ↓", "previous, next step"), ("← / →", "previous, next turn"),
        ("Return", "collapse or expand the turn"), ("double-click", "the same, on a prompt"),
        ("i", "inspect in the drawer"), ("f", "centre on the selection"),
        ("⌘+ ⌘− ⌘0 ⇧⌘0", "zoom in, out, to 100 %, to the width"), ("/", "find"), ("esc", "close the drawer"), ("?", "this list"),
    ]

    static let scoreKeys: [(String, String)] = [
        ("scroll", "move through time and across rows"), ("pinch, ⌘ scroll", "zoom where the pointer is"), ("drag", "move"),
        ("↑ / ↓", "previous, next action"), ("← / →", "previous, next turn"),
        ("i", "inspect in the drawer"), ("f", "bring the selection into view"),
        ("⌘+ ⌘− ⌘0 ⇧⌘0", "zoom in, out, to 100 %, to the rows"), ("/", "find"), ("esc", "close the drawer"), ("?", "this list"),
    ]

    /// The stops of the keyboard: each turn's card, then its steps while it is open.
    private var stops: [NodeKey] {
        model.doc.turns.flatMap { turn -> [NodeKey] in
            [.turn(turn.index)] + (!isScore && window.canvas.closed.contains(turn.index) ? [] : turn.actionIndexes.map { .action($0) })
        }
    }

    private func land(on key: NodeKey) {
        window.transcript.focus = key
        if window.selection != nil { window.selection = key }
    }

    private func step(nodes by: Int) {
        let stops = self.stops
        guard !stops.isEmpty else { return }
        let current = (window.selection ?? window.transcript.focus).flatMap { key -> Int? in
            if let i = stops.firstIndex(of: key) { return i }
            // A chip or a strand: start from the step that holds it.
            return model.turnIndex(of: key).flatMap { stops.firstIndex(of: .turn($0)) }
        }
        land(on: stops[min(max((current ?? (by > 0 ? -1 : stops.count)) + by, 0), stops.count - 1)])
    }

    private func step(turns by: Int) {
        let turns = model.doc.turns.map(\.index)
        guard !turns.isEmpty else { return }
        let current = (window.selection ?? window.transcript.focus).flatMap { model.turnIndex(of: $0) } ?? (by > 0 ? -1 : turns.count)
        land(on: .turn(min(max(current + by, 0), turns.count - 1)))
    }

    // MARK: The bar

    private func bar(_ canvas: CanvasState) -> some View {
        let hits = window.transcript.hits.count
        return HStack(spacing: 8) {
            Picker("Layout", selection: $layoutName) {
                Text("Braid").tag("braid")
                Text("Score").tag("score")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Braid: reading order, top to bottom. Score: time, left to right, a row for each who was working.")
            if !model.doc.subagents.isEmpty {
                KindPill(symbol: "person.2", label: "Subagents", count: model.doc.subagents.count, color: palette.warn, on: canvas.showSubagents) { canvas.showSubagents.toggle() }
            }
            if !model.relations.tasks.isEmpty {
                KindPill(symbol: "clock.arrow.circlepath", label: "Background", count: model.relations.tasks.count, color: palette.ctx, on: canvas.showTasks) { canvas.showTasks.toggle() }
            }
            Spacer(minLength: 8)
            if hits > 0 { Text("\(hits) match\(hits == 1 ? "" : "es")").font(.system(size: 11.5)).foregroundStyle(palette.muted) }
            HStack(spacing: 2) {
                Button { canvas.zoom(by: 1 / 1.25) } label: { Image(systemName: "minus") }.help("Zoom out (⌘−)")
                Text("\(Int((canvas.camera.scale * 100).rounded()))%").font(.system(size: 11.5)).monospacedDigit().frame(width: 44)
                Button { canvas.zoom(by: 1.25) } label: { Image(systemName: "plus") }.help("Zoom in (⌘+)")
            }
            Button(isScore ? "Fit Rows" : "Fit Width") { canvas.fitWidth() }.help(isScore ? "Every row in view, from where the canvas is (⇧⌘0)" : "Fit the width (⇧⌘0)")
            Button("All") { canvas.fitAll() }.help("Show the whole session")
            Button("Focus") { canvas.focusRequests += 1 }.disabled(window.selection == nil && window.transcript.focus == nil).help("Centre on the selection (F)")
            if !isScore {
                let turns = model.doc.turns.filter { !$0.actionIndexes.isEmpty }.map(\.index)
                Button(canvas.closed.isEmpty ? "Collapse All" : "Expand All") {
                    canvas.closed = canvas.closed.isEmpty ? Set(turns) : []
                }
                .help("Collapse every turn to one line, or show them all")
            }
            Button { optionsShown.toggle() } label: { Image(systemName: "gearshape") }
                .help("Canvas options")
                .popover(isPresented: $optionsShown, arrowEdge: .bottom) { CanvasOptions().pickerStyle(.segmented).padding(14).frame(width: 360) }
        }
        .buttonStyle(.borderless).font(.system(size: 12))
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(palette.bg)
    }
}

private struct KindPill: View {
    @Environment(\.palette) private var palette
    var symbol: String
    var label: String
    var count: Int
    var color: Color
    var on: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(on ? color : palette.muted)
                Text(label).font(.system(size: 12, weight: .semibold))
                Text("\(count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.muted)
            }
            .foregroundStyle(on ? palette.ink : palette.muted)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(on ? palette.panel : .clear, in: Capsule())
            .overlay(Capsule().stroke(palette.line2))
            .opacity(on ? 1 : 0.7)
        }
        .buttonStyle(.plain)
        .help(on ? "Hide \(label.lowercased())" : "Show \(label.lowercased())")
    }
}

/// The ⚙ of the Canvas, and its Settings tab: the layout, what is behind it,
/// where the minimap is, and what each layout adds.
struct CanvasOptions: View {
    @AppStorage(SettingsKey.canvasLayout) private var layout = "braid"
    @AppStorage(SettingsKey.canvasBackground) private var background = "dots"
    @AppStorage(SettingsKey.canvasMinimap) private var minimap = "left"
    @AppStorage(SettingsKey.canvasLegend) private var legend = true
    @AppStorage(SettingsKey.canvasNotes) private var resultNotes = true
    @AppStorage(SettingsKey.scoreScale) private var scoreScale = 1.8
    @AppStorage(SettingsKey.scoreFiles) private var scoreFiles = true

    var body: some View {
        Form {
            Picker("Layout", selection: $layout) {
                Text("Braid").tag("braid")
                Text("Score").tag("score")
            }
            Text(layout == "score" ? "Time runs left to right; rows are who was working." : "Reading order, top to bottom; results feed the next step.")
                .font(.footnote).foregroundStyle(.secondary)
            Picker("Background", selection: $background) {
                Text("Dots").tag("dots")
                Text("Lines").tag("lines")
                Text("Grid").tag("grid")
                Text("Blank").tag("blank")
            }
            Picker("Minimap", selection: $minimap) {
                Text("Left").tag("left")
                Text("Right").tag("right")
                Text("Off").tag("off")
            }
            Toggle("Legend", isOn: $legend)
            if layout == "score" {
                Picker("Time scale", selection: $scoreScale) {
                    Text("Tight").tag(1.0)
                    Text("Normal").tag(1.8)
                    Text("Wide").tag(3.2)
                }
                Toggle("Rows for files that kept coming back", isOn: $scoreFiles)
            } else {
                Toggle("What came back, on the arrows", isOn: $resultNotes)
            }
        }
    }
}

private struct Legend: View {
    @Environment(\.palette) private var palette
    var score = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if score {
                row(palette.ink, "prompt: where a turn began")
                row(palette.accent, "action: solid = the model working, light = its tools running")
                row(palette.tool, "tool call, one lane for each that ran at the same time")
                row(palette.warn, "subagent, with its steps; arrows = spawn and hand-back")
                row(palette.ctx, "background command, from launch to where it was read", dashed: true)
                row(palette.ink2, "file touched; filled = written")
            } else {
                row(palette.accent, "the chain: results feed the next step")
                row(palette.warn, "spawn → subagent strand → hand-back")
                row(palette.ctx, "background command and where it was read", dashed: true)
                row(palette.tool, "chips: several tool calls in one step; dashed = still running after it")
            }
        }
        .font(.system(size: 11)).foregroundStyle(palette.ink2)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background { Panel(shadow: palette.shadow.opacity(0.5), radius: 8, y: 4) }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func row(_ color: Color, _ text: String, dashed: Bool = false) -> some View {
        HStack(spacing: 7) {
            if dashed {
                Rectangle().fill(.clear).frame(width: 14, height: 2).overlay { Line().stroke(color, style: StrokeStyle(lineWidth: 2, dash: [3, 3])) }
            } else {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 14, height: 8)
            }
            Text(text)
        }
    }

    // Nonisolated for the same reason as the Ledger's Hatch: Swift 6.4 and a Shape's path.
    nonisolated private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}

/// The whole canvas in a corner, the part on screen framed. A click or a drag
/// moves the camera there.
private struct Minimap: View {
    struct Mark {
        var rect: CGRect
        var color: Color
    }

    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var bounds: CGRect
    var marks: [Mark]

    var body: some View {
        let canvas = window.canvas
        // The map takes the shape of what it shows: the Braid is tall, the Score long.
        let aspect = bounds.width / max(1, bounds.height)
        let size = aspect > 1.6 ? CGSize(width: 240, height: max(60, min(130, 240 / aspect))) : aspect > 0.6 ? CGSize(width: 200, height: 200 / aspect) : CGSize(width: 120, height: 220)
        let scale = min(size.width / max(1, bounds.width), size.height / max(1, bounds.height))
        let origin = CGPoint(x: (size.width - bounds.width * scale) / 2 - bounds.minX * scale, y: (size.height - bounds.height * scale) / 2 - bounds.minY * scale)
        Canvas { context, _ in
            for mark in marks {
                let rect = CGRect(x: origin.x + mark.rect.minX * scale, y: origin.y + mark.rect.minY * scale,
                                  width: max(1.5, mark.rect.width * scale), height: max(1.5, mark.rect.height * scale))
                context.fill(Path(rect), with: .color(mark.color.opacity(0.85)))
            }
            let visible = canvas.camera.visible(in: canvas.viewSize)
            let frame = CGRect(x: origin.x + visible.minX * scale, y: origin.y + visible.minY * scale,
                               width: max(6, visible.width * scale), height: max(6, visible.height * scale))
            context.fill(Path(roundedRect: frame, cornerRadius: 3), with: .color(palette.accent.opacity(0.14)))
            context.stroke(Path(roundedRect: frame, cornerRadius: 3), with: .color(palette.accent), lineWidth: 1)
        }
        .frame(width: size.width, height: size.height)
        .background { Panel(shadow: palette.shadow.opacity(0.5), radius: 8, y: 4) }
        .clipShape(RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            // The point under the pointer becomes the middle of the view.
            let x = (value.location.x - origin.x) / scale, y = (value.location.y - origin.y) / scale
            canvas.camera.x = canvas.viewSize.width / 2 - x * canvas.camera.scale
            canvas.camera.y = canvas.viewSize.height / 2 - y * canvas.camera.scale
        })
        .help("Click or drag to move")
        .accessibilityHidden(true)
    }
}

/// The drawing view inside SwiftUI.
private struct BraidCanvasHost: NSViewRepresentable {
    var model: SessionModel
    var content: BraidContent?
    var layout: CanvasLayout?
    var palette: Palette
    var camera: Camera
    var selection: NodeKey?
    var focus: NodeKey?
    var matches: Set<NodeKey>
    var background: String
    var onCamera: (Camera) -> Void
    var onSize: (CGSize) -> Void
    var onSelect: (CanvasHit?) -> Void
    var onDoubleClick: (CanvasHit) -> Void
    var onKey: (NSEvent) -> Bool
    var menuItems: (CanvasHit) -> [(title: String, action: () -> Void)]

    final class Coordinator {
        /// What the view was last given, to tell a new layout from the same one.
        var contentFor = ""
        var layoutStamp = 0
        var palette: Palette?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> BraidCanvasNSView {
        let view = BraidCanvasNSView()
        view.allowedTouchTypes = [.indirect]
        return view
    }

    func updateNSView(_ view: BraidCanvasNSView, context: Context) {
        // The content and the layout are large values: hand them over only when they are new.
        let stamp = model.doc.id + "\(model.doc.actions.count)" + (content == nil ? "-" : "+")
        if context.coordinator.contentFor != stamp {
            context.coordinator.contentFor = stamp
            // Another session's layout can have the same counts: never keep one across sessions.
            context.coordinator.layoutStamp = .min
            view.content = content
        }
        let layoutStamp = (layout?.nodes.count ?? -1) &* 31 &+ Int(layout?.bounds.height ?? 0) &* 7 &+ (layout?.edges.count ?? 0) &+ (layout?.notes.count ?? 0) &* 13
        if context.coordinator.layoutStamp != layoutStamp || view.layout == nil {
            context.coordinator.layoutStamp = layoutStamp
            view.layout = layout
        }
        // The colours are converted when the appearance changes, not on every frame of a pan.
        if context.coordinator.palette != palette {
            context.coordinator.palette = palette
            view.colors = CanvasColors(palette)
        }
        view.camera = camera
        view.selection = selection
        view.focus = focus
        view.matches = matches
        if view.backgroundStyle != background { view.backgroundStyle = background }
        view.onCamera = onCamera
        view.onSize = onSize
        view.onSelect = onSelect
        view.onDoubleClick = onDoubleClick
        view.onKey = onKey
        view.menuItems = menuItems
    }
}

/// The Score's drawing view inside SwiftUI.
private struct ScoreCanvasHost: NSViewRepresentable {
    var layout: ScoreLayout?
    var palette: Palette
    var camera: Camera
    var selection: NodeKey?
    var focus: NodeKey?
    var matches: Set<NodeKey>
    var background: String
    var onCamera: (Camera) -> Void
    var onSize: (CGSize) -> Void
    var onSelect: (CanvasHit?) -> Void
    var onKey: (NSEvent) -> Bool
    var menuItems: (CanvasHit) -> [(title: String, action: () -> Void)]

    final class Coordinator {
        var stamp = Int.min
        var palette: Palette?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ScoreCanvasNSView {
        let view = ScoreCanvasNSView()
        view.allowedTouchTypes = [.indirect]
        return view
    }

    func updateNSView(_ view: ScoreCanvasNSView, context: Context) {
        // The layout is a large value: hand it over only when it is another one.
        let stamp = layout.map { ($0.nodes.count &* 31 &+ Int($0.axis.width)) &* 17 &+ $0.start.hashValue &+ Int($0.height) } ?? -1
        if context.coordinator.stamp != stamp {
            context.coordinator.stamp = stamp
            view.layout = layout
        }
        if context.coordinator.palette != palette {
            context.coordinator.palette = palette
            view.colors = CanvasColors(palette)
        }
        view.camera = camera
        view.selection = selection
        view.focus = focus
        view.matches = matches
        if view.backgroundStyle != background { view.backgroundStyle = background }
        view.onCamera = onCamera
        view.onSize = onSize
        view.onSelect = onSelect
        view.onKey = onKey
        view.menuItems = menuItems
    }
}
