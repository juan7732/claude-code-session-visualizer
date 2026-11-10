import SkitKit
import SwiftUI

/// A command by its name: what the menu bar and the ⌘K palette both run.
struct AppAction: Identifiable {
    var title: String
    /// The shortcut as the menu shows it, for the palette's right column.
    var shortcut: String?
    var enabled = true
    var run: () -> Void
    var id: String { title }
}

/// Every command of the app, for the window they act on. The menu bar draws
/// them with real key equivalents; the palette lists the enabled ones.
enum AppActions {
    static func all(window: WindowState, store: AppStore, openWindow: @escaping (String) -> Void, openSettings: @escaping () -> Void) -> [AppAction] {
        let id = window.sessionID
        let session = id.flatMap { store.session($0) }
        let model = id.flatMap { store.model($0) }
        let inTranscript = id != nil && window.sessionView == .transcript
        let defaults = UserDefaults.standard
        let sidebar = defaults.object(forKey: SettingsKey.sidebar) as? Bool ?? true
        let inspector = defaults.object(forKey: SettingsKey.inspector) as? Bool ?? true
        var out: [AppAction] = []
        for (index, view) in SessionView.allCases.enumerated() where view.arrives == nil {
            out.append(AppAction(title: view.title, shortcut: "⌘\(index + 1)", enabled: id != nil) { window.sessionView = view })
        }
        out.append(AppAction(title: "Go to Sessions", shortcut: "⌘[") { window.page = .sessions })
        out.append(AppAction(title: "Go to Search", shortcut: "⇧⌘F") { showSearch(window) })
        out.append(AppAction(title: "Find in This Session", shortcut: "⌘F", enabled: id != nil) { find(window) })
        out.append(AppAction(title: "Export Session as Markdown…", shortcut: "⇧⌘E", enabled: session != nil) {
            if let session { Exporter.saveSession(session, store: store) }
        })
        out.append(AppAction(title: "Copy Turn as Markdown", enabled: currentTurn(window, model) != nil) {
            if let id, let turn = currentTurn(window, model) { Exporter.copyTurn(turn, of: id, store: store) }
        })
        out.append(AppAction(title: "Copy Link", shortcut: "⇧⌘C", enabled: id != nil) { copyLink(window, store) })
        out.append(AppAction(title: sidebar ? "Hide Sidebar" : "Show Sidebar", shortcut: "⌃⌘S") { defaults.set(!sidebar, forKey: SettingsKey.sidebar) })
        out.append(AppAction(title: inspector ? "Hide Inspector" : "Show Inspector", shortcut: "⌥⌘I", enabled: id != nil) { defaults.set(!inspector, forKey: SettingsKey.inspector) })
        out.append(AppAction(title: "Show All Tool Calls", shortcut: "⌥⌘→", enabled: inTranscript) { setAllFolded(false, window, model) })
        out.append(AppAction(title: "Fold All Tool Calls", shortcut: "⌥⌘←", enabled: inTranscript) { setAllFolded(true, window, model) })
        out.append(AppAction(title: "Open in New Window", enabled: id != nil) { if let id { openWindow(id) } })
        out.append(AppAction(title: id.map { store.annotation($0).pinned } == true ? "Unpin" : "Pin", enabled: id != nil) {
            if let id { Task { await store.togglePin(id) } }
        })
        out.append(AppAction(title: "Archive Now", enabled: id != nil) { if let id { Task { await store.archiveNow(id) } } })
        out.append(AppAction(title: "Settings…", shortcut: "⌘,", run: openSettings))
        return out
    }

    static func showSearch(_ window: WindowState) {
        window.page = .search
        window.search.focusRequests += 1
    }

    static func find(_ window: WindowState) {
        window.sessionView = .transcript
        window.transcript.findRequests += 1
    }

    /// The turn a "this turn" command means: the selection's, else the keyboard's.
    static func currentTurn(_ window: WindowState, _ model: SessionModel?) -> Int? {
        guard let model, let key = window.selection ?? window.transcript.focus else { return nil }
        return model.turnIndex(of: key)
    }

    /// A link to the selected node, or to the session as it is being looked at.
    static func copyLink(_ window: WindowState, _ store: AppStore) {
        guard let id = window.sessionID, let url = SessionLink.url(session: id, view: window.sessionView, key: window.selection) else { return }
        Exporter.copy(url.absoluteString)
        store.notice = "Link copied." + (Bundle.main.bundleURL.pathExtension == "app" ? "" : " It opens in the installed app.")
    }

    /// Folds every turn's tool calls into one line per run, or shows them all again.
    static func setAllFolded(_ folded: Bool, _ window: WindowState, _ model: SessionModel?) {
        guard let model else { return }
        for turn in model.doc.turns where turn.toolCalls > 0 { window.setFolded(turn.index, folded, in: model) }
    }
}

/// The menu bar. Every command the app will have is here from the start, with
/// its shortcut; one whose view is not built yet is disabled, not missing
/// (NOTES, "Rules we adopt": toolbar and context menus are subsets of the menus).
struct AppCommands: Commands {
    var store: AppStore
    @FocusedValue(\.windowState) private var window
    @AppStorage(SettingsKey.sidebar) private var sidebar = true
    @AppStorage(SettingsKey.inspector) private var inspector = true
    @Environment(\.openWindow) private var openWindow

    private var sessionID: String? { window?.sessionID }
    private var session: SessionSummary? { sessionID.flatMap { store.session($0) } }
    private var model: SessionModel? { sessionID.flatMap { store.model($0) } }
    private var inTranscript: Bool { sessionID != nil && window?.sessionView == .transcript }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Session…") { window?.paletteShown = true }.keyboardShortcut("o").disabled(window == nil)
            Divider()
            Button("Export Session as Markdown…") { if let session { Exporter.saveSession(session, store: store) } }
                .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(session == nil)
            Button("Compare Sessions…") {}.disabled(true) // M13
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find") { if let window { AppActions.find(window) } }
                .keyboardShortcut("f").disabled(sessionID == nil)
            Button("Search All Sessions") { if let window { AppActions.showSearch(window) } }
                .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(window == nil)
            Button("Go to Anything…") { window?.paletteShown.toggle() }
                .keyboardShortcut("k").disabled(window == nil)
            Divider()
            Button("Copy Link") { if let window { AppActions.copyLink(window, store) } }
                .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(sessionID == nil)
            Button("Copy Turn as Markdown") {
                if let window, let sessionID, let turn = AppActions.currentTurn(window, model) { Exporter.copyTurn(turn, of: sessionID, store: store) }
            }
            .disabled(window.flatMap { AppActions.currentTurn($0, model) } == nil)
        }
        CommandGroup(before: .sidebar) {
            ForEach(Array(SessionView.allCases.enumerated()), id: \.element) { index, view in
                Button(view.title) { window?.sessionView = view }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                    .disabled(sessionID == nil)
            }
            Divider()
            Button(sidebar ? "Hide Sidebar" : "Show Sidebar") { sidebar.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Button(inspector ? "Hide Inspector" : "Show Inspector") { inspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button("Show All Tool Calls") { if let window { AppActions.setAllFolded(false, window, model) } }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option]).disabled(!inTranscript)
            Button("Fold All Tool Calls") { if let window { AppActions.setAllFolded(true, window, model) } }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option]).disabled(!inTranscript)
            Divider()
            Button("Zoom In") {}.keyboardShortcut("+").disabled(true) // M10
            Button("Zoom Out") {}.keyboardShortcut("-").disabled(true)
            Button("Actual Size") {}.keyboardShortcut("0").disabled(true)
            Button("Zoom to Fit") {}.keyboardShortcut("0", modifiers: [.command, .shift]).disabled(true)
            Divider()
        }
        CommandMenu("Session") {
            Button("Continue in Claude") {}.disabled(true) // not scheduled
            Button("Fork from Here…") {}.disabled(true)
            Divider()
            Button("Open in New Window") { if let sessionID { openWindow(value: sessionID) } }.disabled(sessionID == nil)
            Button(sessionID.map { store.annotation($0).pinned } == true ? "Unpin" : "Pin") {
                if let sessionID { Task { await store.togglePin(sessionID) } }
            }
            .disabled(sessionID == nil)
            Divider()
            Button("Archive Now") { if let sessionID { Task { await store.archiveNow(sessionID) } } }.disabled(sessionID == nil)
            Divider()
            Button("Back to Sessions") { window?.page = .sessions }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(sessionID == nil)
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { window?.transcript.helpShown.toggle() }
                .keyboardShortcut("/", modifiers: [.command, .shift]).disabled(!inTranscript)
        }
    }
}
