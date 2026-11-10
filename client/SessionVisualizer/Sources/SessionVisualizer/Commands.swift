import SwiftUI

/// The menu bar. Every command the app will have is here from the start, with
/// its shortcut; one whose view is not built yet is disabled, not missing
/// (NOTES, "Rules we adopt": toolbar and context menus are subsets of the menus).
struct AppCommands: Commands {
    var store: AppStore
    @FocusedValue(\.windowState) private var window
    @AppStorage(SettingsKey.sidebar) private var sidebar = true
    @Environment(\.openWindow) private var openWindow

    private var sessionID: String? { window?.sessionID }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Session…") {}.keyboardShortcut("o").disabled(true) // the ⌘K palette, M9
            Divider()
            Button("Export Session as Markdown…") {}.disabled(true) // M9
            Button("Compare Sessions…") {}.disabled(true) // M13
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find") {}.keyboardShortcut("f").disabled(true) // M8
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
            Button("Show Inspector") {}.keyboardShortcut("i", modifiers: [.command, .option]).disabled(true) // M8
            Divider()
            Button("Expand All") {}.disabled(true) // M8
            Button("Collapse All") {}.disabled(true)
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
            Button("Keyboard Shortcuts") {}.keyboardShortcut("/", modifiers: [.command, .shift]).disabled(true) // M8
        }
    }
}
