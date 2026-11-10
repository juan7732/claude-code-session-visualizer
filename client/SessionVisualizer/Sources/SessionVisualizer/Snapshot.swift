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

enum Snapshot {
    static func run(_ request: SnapshotRequest) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Settings for this run only: the argument domain is never written to disk.
        UserDefaults.standard.setVolatileDomain([SettingsKey.oled: request.appearance == "oled", SettingsKey.sidebar: true],
                                                forName: UserDefaults.argumentDomain)

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
                    try? await Task.sleep(for: .milliseconds(900)) // scrolling, the drawer, the results
                }
            }
            if request.page == .search, let query = request.query {
                state.search.query = query
                // The search, then the preview's session.
                for _ in 0..<80 where state.search.searched.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(2500))
            }
            if request.palette {
                state.paletteShown = true
                try? await Task.sleep(for: .milliseconds(1200))
            }
            try? await Task.sleep(for: .milliseconds(600))
            let ok = write(window, to: request.output)
            if store.engine != .ready { FileHandle.standardError.write(Data("snapshot: engine state \(store.engine)\n".utf8)) }
            exit(ok ? 0 : 1)
        }
        app.run()
        exit(0)
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
private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
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
