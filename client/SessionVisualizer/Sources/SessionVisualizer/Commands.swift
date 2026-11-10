import SwiftUI

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
    private var inTranscript: Bool { sessionID != nil && window?.sessionView == .transcript }

    /// Folds every turn's tool calls into one line per run, or shows them all again.
    private func setAllFolded(_ folded: Bool) {
        guard let window, let model = sessionID.flatMap({ store.model($0) }) else { return }
        for turn in model.doc.turns where turn.toolCalls > 0 { window.setFolded(turn.index, folded, in: model) }
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Session…") {}.keyboardShortcut("o").disabled(true) // the ⌘K palette, M9
            Divider()
            Button("Export Session as Markdown…") {}.disabled(true) // M9
            Button("Compare Sessions…") {}.disabled(true) // M13
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find") {
                window?.sessionView = .transcript
                window?.transcript.findRequests += 1
            }
            .keyboardShortcut("f").disabled(sessionID == nil)
            Button("Copy Link") {}.keyboardShortcut("c", modifiers: [.command, .shift]).disabled(true) // M8
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
            Button("Show All Tool Calls") { setAllFolded(false) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option]).disabled(!inTranscript)
            Button("Fold All Tool Calls") { setAllFolded(true) }
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
