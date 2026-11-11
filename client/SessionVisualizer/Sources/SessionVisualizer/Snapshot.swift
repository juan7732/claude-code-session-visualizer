import AppKit
import SkitKit
import SwiftUI

/// `SessionVisualizer --snapshot out.png [--page sessions|session:<id>|search|stats|claude]
/// [--view summary|…] [--appearance light|dark|oled] [--size 1500x940] [--socket path] [--flyout]
/// [--select action:6|turn:0|tool:<id>|subagent:<id>|step:<agent>:<n>|compaction:0|work:1|file:<path>|outside:<kind:name>]
/// [--tab details|io|note] [--query text] [--palette]
/// [--open-calls] [--fold]`
///
/// Renders one state of the app to a PNG and exits, without showing a window:
/// the way a view is held against its mock (plan, "Judged against the mock").
/// It only attaches to an engine that is already serving; it never installs anything.
struct SnapshotRequest {
    var output: String
    var page: Page = .sessions
    var view: SessionView = .summary
    var appearance = "light"
    var size = CGSize(width: 1500, height: 940)
    var socket: String?
    var flyout = false
    /// A node to select (opens the drawer) and scroll to.
    var select: NodeKey?
    var tab: InspectorTab?
    var query: String?
    /// Opens every tool row of the selected node's turn.
    var openCalls = false
    /// Folds every turn's tool calls.
    var fold = false
    /// Opens the ⌘K palette, with `query` typed into it.
    var palette = false
    /// On the Search page: the scope chosen after the first results arrived.
    var kind: String?
    /// On the Search page: "meaning" searches by what the text says.
    var mode: String?
    /// On the Search page: every session's hits shown, whatever the setting.
    var unfold = false
    /// On the Canvas: the zoom (1 is 100 %), turns collapsed, and "all" or "width" to fit.
    var zoom: Double?
    var collapse = false
    var fit: String?

    init?(arguments: [String]) {
        guard let at = arguments.firstIndex(of: "--snapshot"), at + 1 < arguments.count else { return nil }
        output = arguments[at + 1]
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        if let page = value("--page") {
            switch page {
            case "search": self.page = .search
            case "stats": self.page = .stats
            case "claude": self.page = .claude
            case let s where s.hasPrefix("session:"): self.page = .session(String(s.dropFirst("session:".count)))
            default: self.page = .sessions
            }
        }
        if let view = value("--view").flatMap(SessionView.init(rawValue:)) { self.view = view }
        if let appearance = value("--appearance") { self.appearance = appearance }
        if let size = value("--size")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            self.size = CGSize(width: size[0], height: size[1])
        }
        socket = value("--socket")
        flyout = arguments.contains("--flyout")
        if let select = value("--select"), let colon = select.firstIndex(of: ":") {
            let id = String(select[select.index(after: colon)...])
            switch select[..<colon] {
            case "action": self.select = Int(id).map { .action($0) }
            case "turn": self.select = Int(id).map { .turn($0) }
            case "compaction": self.select = Int(id).map { .compaction($0) }
            case "work": self.select = Int(id).map { .work($0) }
            case "tool": self.select = .tool(id)
            case "subagent": self.select = .subagent(id)
            case "file": self.select = .file(id)
            case "outside": self.select = .outside(id)
            case "step":
                // step:<agent id>:<n>
                if let cut = id.lastIndex(of: ":"), let n = Int(id[id.index(after: cut)...]) { self.select = .step(agent: String(id[..<cut]), index: n) }
            default: break
            }
        }
        tab = value("--tab").flatMap(InspectorTab.init(rawValue:))
        query = value("--query")
        openCalls = arguments.contains("--open-calls")
        fold = arguments.contains("--fold")
        palette = arguments.contains("--palette")
        kind = value("--kind")
        mode = value("--mode")
        unfold = arguments.contains("--unfold")
        zoom = value("--zoom").flatMap(Double.init)
        collapse = arguments.contains("--collapse")
        fit = value("--fit")
    }
}

/// `SessionVisualizer --measure <session id> [--socket path]`: how long opening a
/// session takes, step by step, without a window. "Measure before you tune."
enum Measure {
    static func run(arguments: [String]) -> Never? {
        guard let at = arguments.firstIndex(of: "--measure"), at + 1 < arguments.count else { return nil }
        let id = arguments[at + 1]
        let socket = arguments.firstIndex(of: "--socket").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        let http = UnixHTTP(socketPath: socket ?? EngineLocator().socketPath)
        func ms(_ start: Date) -> String { String(format: "%7.1f ms", Date().timeIntervalSince(start) * 1000) }
        do {
            for pass in ["first", "again"] {
                var t = Date()
                let raw = try http.send(method: "GET", path: "/v0/sessions/\(id)")
                print("\(pass): document fetched  \(ms(t))  \(raw.body.count / 1024) kB")
                t = Date()
                let doc = try JSONDecoder.skit().decode(SessionDocument.self, from: raw.body)
                print("\(pass): document decoded  \(ms(t))  \(doc.turns.count) turns, \(doc.actions.count) actions, \(doc.toolCalls.count) tool calls")
                t = Date()
                let rel = try http.send(method: "GET", path: "/v0/sessions/\(id)/relations")
                print("\(pass): relations fetched \(ms(t))  \(rel.body.count / 1024) kB")
                t = Date()
                let relations = try JSONDecoder.skit().decode(Relations.self, from: rel.body)
                print("\(pass): relations decoded \(ms(t))")
                t = Date()
                let model = SessionModel(doc: doc, relations: relations)
                print("\(pass): model built       \(ms(t))  \(model.items.count) rows")
            }
        } catch {
            print("measure: \(error)")
            exit(1)
        }
        exit(0)
    }
}

/// `SessionVisualizer --measure-canvas <session id> [--socket path] [--size 1500x900]`: what a
/// frame of the Canvas costs. Builds the Braid of the session, then draws it
/// offscreen along a pan at each level of detail and through a zoom, and prints
/// milliseconds per frame. A frame at 60 a second has 16.7 ms.
enum MeasureCanvas {
    static func run(arguments: [String]) -> Never? {
        guard let at = arguments.firstIndex(of: "--measure-canvas"), at + 1 < arguments.count else { return nil }
        let id = arguments[at + 1]
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } }
        var size = CGSize(width: 1500, height: 900)
        if let parts = value("--size")?.split(separator: "x").compactMap({ Double($0) }), parts.count == 2 { size = CGSize(width: parts[0], height: parts[1]) }
        let http = UnixHTTP(socketPath: value("--socket") ?? EngineLocator().socketPath)
        func ms(_ start: Date) -> Double { Date().timeIntervalSince(start) * 1000 }
        do {
            let doc = try JSONDecoder.skit().decode(SessionDocument.self, from: http.send(method: "GET", path: "/v0/sessions/\(id)").body)
            let relations = try JSONDecoder.skit().decode(Relations.self, from: http.send(method: "GET", path: "/v0/sessions/\(id)/relations").body)
            let model = SessionModel(doc: doc, relations: relations)
            var t = Date()
            let content = BraidContent(model: model)
            let contentMs = ms(t)
            t = Date()
            let layout = CanvasLayout(content: content)
            let layoutMs = ms(t)
            t = Date()
            let collapsed = CanvasLayout(content: content, closed: Set(doc.turns.map(\.index)))
            print(String(format: "%d turns, %d actions, %d tool calls, %d subagents", doc.turns.count, doc.actions.count, doc.toolCalls.count, doc.subagents.count))
            print(String(format: "content (every text broken into lines)  %7.1f ms", contentMs))
            print(String(format: "layout, every turn open                 %7.1f ms   %d nodes, %d edges, %d notes, %.0f × %.0f points", layoutMs, layout.nodes.count, layout.edges.count, layout.notes.count, layout.bounds.width, layout.bounds.height))
            print(String(format: "layout, every turn collapsed            %7.1f ms   %d nodes, %.0f points tall", ms(t), collapsed.nodes.count, collapsed.bounds.height))

            _ = NSApplication.shared
            let view = BraidCanvasNSView(frame: CGRect(origin: .zero, size: size))
            view.content = content
            view.layout = layout
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                print("measure: no bitmap")
                exit(1)
            }
            print(String(format: "drawing %d × %d pixels, light and dark:", bitmap.pixelsWide, bitmap.pixelsHigh))
            func run(_ name: String, frames: Int, camera: (Int) -> Camera) {
                var times: [Double] = []
                for frame in 0..<frames {
                    view.camera = camera(frame)
                    let start = Date()
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    times.append(ms(start))
                }
                times.sort()
                print(String(format: "  %@  median %5.1f ms   95th %5.1f ms   worst %5.1f ms", name.padding(toLength: 44, withPad: " ", startingAt: 0),
                             times[times.count / 2], times[min(times.count - 1, times.count * 95 / 100)], times[times.count - 1]))
            }
            let height = layout.bounds.height
            for palette in [Palette.light, Palette.dark] {
                view.colors = CanvasColors(palette)
                for (name, scale) in [("near, 100 %, a pan down the session", 1.0), ("near, 80 %", 0.8), ("mid, 50 %", 0.5), ("far, 25 %", 0.25), ("far, 10 %", 0.1)] {
                    run(name, frames: 180) { frame in
                        Camera(x: 60, y: 40 - (height * scale - size.height) * CGFloat(frame) / 179, scale: scale)
                    }
                }
                run("zoom from 6 % to 200 % at the middle", frames: 180) { frame in
                    var camera = Camera()
                    camera.fitAll(layout.bounds, in: size)
                    camera.zoom(by: pow(2.0 / 0.06, CGFloat(frame) / 179) * 0.06 / camera.scale, at: CGPoint(x: size.width / 2, y: size.height / 2))
                    return camera
                }
            }
        } catch {
            print("measure: \(error)")
            exit(1)
        }
        exit(0)
    }
}

enum Snapshot {
    /// This process renders one picture and exits: it reads and writes none of
    /// what a person's own windows remember (where a canvas was left).
    static let active = CommandLine.arguments.contains("--snapshot")

    static func run(_ request: SnapshotRequest) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Settings for this run only: the argument domain is never written to disk.
        var settings: [String: Any] = [SettingsKey.oled: request.appearance == "oled", SettingsKey.sidebar: true]
        // --set summary.digest=false: a setting for this picture only.
        var arguments = CommandLine.arguments[...]
        while let at = arguments.firstIndex(of: "--set"), at + 1 < arguments.endIndex {
            let pair = arguments[at + 1].split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 {
                let value: Any = pair[1] == "true" ? true : pair[1] == "false" ? false : Int(pair[1]).map { $0 as Any } ?? pair[1]
                settings[pair[0]] = value
            }
            arguments = arguments[(at + 2)...]
        }
        UserDefaults.standard.setVolatileDomain(settings, forName: UserDefaults.argumentDomain)

        let store = AppStore(socketPath: request.socket, managesEngine: false)
        let state = WindowState()
        let root = Themed { RootView(window: state, initialPage: request.page, initialView: request.view) }
            .environment(store)
            .environment(\.snapshotFlyout, request.flyout)
        let window = OffscreenWindow(contentRect: CGRect(origin: .zero, size: request.size),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        let appearance = NSAppearance(named: request.appearance == "light" ? .aqua : .darkAqua)
        app.appearance = appearance
        window.appearance = appearance
        window.toolbarStyle = .unified
        window.contentView = NSHostingView(rootView: root)
        window.setFrame(CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: request.size), display: true)
        window.orderFrontRegardless()

        Task {
            await store.connect()
            if case .session(let id) = request.page {
                // Wait for what the page asks for: the numbers, and for the Transcript the document.
                for _ in 0..<300 {
                    let statsReady: Bool = if case .loading = store.stats[id] ?? .loading { false } else { true }
                    let modelReady: Bool = if case .loading = store.models[id] ?? .loading { false } else { true }
                    if statsReady && modelReady { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if let model = store.model(id) {
                    if let query = request.query {
                        if request.view == .summary { state.transcript.summaryQuery = query } else { state.transcript.query = query }
                    }
                    if request.fold { for turn in model.doc.turns where turn.toolCalls > 0 { state.setFolded(turn.index, true, in: model) } }
                    if let key = request.select {
                        if let tab = request.tab { state.inspectorTab = tab }
                        state.select(key, in: model)
                        if request.openCalls, let turn = model.turnIndex(of: key).flatMap({ model.turn($0) }) {
                            for call in turn.actionIndexes.compactMap({ model.action($0) }).flatMap({ model.tools(of: $0) }) {
                                state.transcript.open.insert(.tool(call.id))
                            }
                        }
                    }
                    if request.view == .canvas {
                        // The canvas lays its text out off the main thread, then takes its first camera.
                        for _ in 0..<100 where state.canvas.cameraFor == nil { try? await Task.sleep(for: .milliseconds(50)) }
                        if request.collapse { state.canvas.closed = Set(model.doc.turns.filter { !$0.actionIndexes.isEmpty }.map(\.index)) }
                        try? await Task.sleep(for: .milliseconds(200))
                        if let zoom = request.zoom { state.canvas.zoom(by: zoom / state.canvas.camera.scale) }
                        if request.fit == "all" { state.canvas.fitAll() } else if request.fit == "width" { state.canvas.fitWidth() }
                        if request.select != nil, request.fit == nil { state.canvas.focusRequests += 1 }
                    }
                    try? await Task.sleep(for: .milliseconds(900)) // scrolling, the drawer, the results
                }
            }
            if request.page == .search, let query = request.query {
                if let mode = request.mode { state.search.mode = mode }
                state.search.query = query
                // The search, then the preview's session.
                for _ in 0..<80 where state.search.searched.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(2500))
                if let kind = request.kind {
                    // The way a person does it: results first, then a click on a scope.
                    state.search.kind = kind
                    try? await Task.sleep(for: .milliseconds(2500))
                }
                if request.unfold { state.search.setAllFolded(false) }
            }
            if request.palette {
                state.paletteShown = true
                try? await Task.sleep(for: .milliseconds(1200))
            }
            if CommandLine.arguments.contains("--scroll-through") { await scrollThrough(window) }
            try? await Task.sleep(for: .milliseconds(600))
            let ok = write(window, to: request.output)
            if store.engine != .ready { FileHandle.standardError.write(Data("snapshot: engine state \(store.engine)\n".utf8)) }
            exit(ok ? 0 : 1)
        }
        app.run()
        exit(0)
    }

    /// `--scroll-through`: scrolls the page's scroll view from top to bottom the
    /// way a hand would, a notch a frame, and says where it is on stderr. A
    /// view that locks up while being scrolled stops the count, and the
    /// process can be sampled from outside.
    static func scrollThrough(_ window: NSWindow) async {
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollViews)
        }
        guard let root = window.contentView,
              let scroll = scrollViews(root).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) })
        else {
            FileHandle.standardError.write(Data("scroll-through: no scroll view\n".utf8))
            return
        }
        var y: CGFloat = 0
        var steps = 0
        let hover = ProcessInfo.processInfo.environment["SKIT_EXERCISE_HOVER"] != nil
        while steps < 4000 {
            let height = scroll.documentView?.frame.height ?? 0
            let limit = max(0, height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            if hover {
                // A pointer resting on the page while it scrolls under it: rows enter and leave it.
                let point = CGPoint(x: window.frame.width * 0.45, y: window.frame.height * 0.4)
                if let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: steps, clickCount: 0, pressure: 0) {
                    window.sendEvent(event)
                }
            }
            if steps % 10 == 0 { FileHandle.standardError.write(Data(String(format: "scroll-through: y %.0f of %.0f\n", y, limit).utf8)) }
            if y >= limit { break }
            y = min(limit, y + 90)
            steps += 1
            try? await Task.sleep(for: .milliseconds(16))
        }
        FileHandle.standardError.write(Data("scroll-through: reached the end after \(steps) steps\n".utf8))
    }

    private static func write(_ window: NSWindow, to path: String) -> Bool {
        // The frame view holds the title bar and toolbar as well as the content.
        guard let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}

/// A window that may sit off every screen: AppKit otherwise pulls it back on.
/// It never takes the keyboard: a snapshot with a focused field would otherwise
/// receive what the person is typing elsewhere.
private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct SnapshotFlyoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Snapshots cannot hover: this opens the rail's flyout for them.
    var snapshotFlyout: Bool {
        get { self[SnapshotFlyoutKey.self] }
        set { self[SnapshotFlyoutKey.self] = newValue }
    }
}
