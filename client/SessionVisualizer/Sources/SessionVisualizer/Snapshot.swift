import AppKit
import SkitKit
import SwiftUI

/// `SessionVisualizer --snapshot out.png [--page sessions|session:<id>|search|stats|claude]
/// [--view summary|…] [--appearance light|dark|oled] [--size 1500x940] [--socket path] [--flyout]`
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
        let root = Themed { RootView(initialPage: request.page, initialView: request.view) }
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
                // Wait for the numbers the page asks for.
                for _ in 0..<200 {
                    if case .loading = store.stats[id] ?? .loading { try? await Task.sleep(for: .milliseconds(100)) } else { break }
                }
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
