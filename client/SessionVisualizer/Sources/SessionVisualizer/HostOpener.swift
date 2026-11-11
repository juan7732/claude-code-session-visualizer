import AppKit
import SkitKit

/// Back to where a running session lives (M21): its editor's window, or its
/// terminal. The engine says which application and what to open with it; an
/// editor that is asked to open a workspace it already has open brings that
/// window to the front instead of making another (checked with Visual Studio
/// Code and two windows, 2026-11-11).
enum HostOpener {
    /// Known applications when the engine saw no bundle in the process tree.
    private static let bundles = ["Visual Studio Code": "com.microsoft.VSCode", "Visual Studio Code - Insiders": "com.microsoft.VSCodeInsiders",
                                  "Cursor": "com.todesktop.230313mzl4w4u92", "Windsurf": "com.exafunction.windsurf", "VSCodium": "com.vscodium"]

    static func application(_ host: NowReport.Host) -> URL? {
        if let path = host.appPath, FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        return bundles[host.app].flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    /// Brings the session's window forward. False when the application could not be found.
    @discardableResult
    static func open(_ host: NowReport.Host) -> Bool {
        guard let app = application(host) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let target = HostContent.target(host) {
            NSWorkspace.shared.open([URL(fileURLWithPath: target)], withApplicationAt: app, configuration: configuration)
        } else {
            NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        }
        return true
    }
}

/// What the app says about a session's host, and what it opens.
nonisolated enum HostContent {
    /// "VS Code" for the long name; any other application by its own.
    static func short(_ app: String) -> String {
        switch app {
        case "Visual Studio Code": "VS Code"
        case "Visual Studio Code - Insiders": "VS Code Insiders"
        default: app
        }
    }

    /// What is opened with the application: the window's workspace or folder for an editor, nothing for a terminal.
    static func target(_ host: NowReport.Host) -> String? {
        guard host.kind == "editor", let open = host.open, !open.isEmpty else { return nil }
        return open
    }

    /// The button: "Open in VS Code", "Show Terminal".
    static func title(_ host: NowReport.Host) -> String {
        host.kind == "editor" ? "Open in " + short(host.app) : "Show " + short(host.app)
    }

    /// What the button will do, and how sure the engine is of the window.
    static func help(_ host: NowReport.Host) -> String {
        let name = short(host.app)
        guard host.kind == "editor" else {
            return "Brings \(name) to the front. Which of its windows or tabs runs the session cannot be told from outside."
        }
        guard let target = target(host) else {
            return "Brings \(name) to the front. The session's window is on several folders and no workspace file names it, so it cannot be raised by itself."
        }
        let window = (target as NSString).lastPathComponent
        if host.sure { return "Brings the \(name) window that runs this session to the front (\(window))." }
        return "Brings a \(name) window that has this session's folder open to the front (\(window)). The session's own process did not say which window it is in."
    }
}
