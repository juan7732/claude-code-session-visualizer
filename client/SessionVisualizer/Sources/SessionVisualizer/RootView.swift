import SkitKit
import SwiftUI

/// One window: the rail, the page, the toolbar over both.
struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var palette
    @State private var window = WindowState()
    @AppStorage(SettingsKey.sidebar) private var sidebar = true
    /// Opens the window on a session (Open in New Window).
    var initialSession: String?
    /// Opens the window on a page and a view (snapshots).
    var initialPage: Page?
    var initialView: SessionView?

    var body: some View {
        HStack(spacing: 0) {
            if sidebar { Rail().zIndex(1).transition(.move(edge: .leading)) }
            page.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.bg)
        .environment(window)
        .focusedSceneValue(\.windowState, window)
        .navigationTitle(title)
        .toolbar { toolbar }
        .overlay(alignment: .bottom) { notice }
        .task {
            if let initialSession, window.page == .sessions { window.page = .session(initialSession) }
            if let initialPage { window.page = initialPage }
            if let initialView { window.sessionView = initialView }
            if store.engine != .ready { await store.connect() }
        }
        .task {
            // Sessions change while the app is open: keep the list current.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await store.refresh()
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    @ViewBuilder private var page: some View {
        if store.engine != .ready {
            EngineStateView()
        } else {
            switch window.page {
            case .sessions: SessionsView()
            case .session(let id): SessionPage(id: id)
            case .search: ComingPage(title: "Search", milestone: "M9")
            case .stats: ComingPage(title: "Stats", milestone: "M13")
            case .claude: ComingPage(title: "Claude", milestone: "M13")
            }
        }
    }

    private var title: String {
        switch window.page {
        case .sessions: window.filterProject.map { Format.projectName(cwd: $0, slug: nil) } ?? "Sessions"
        case .session(let id): store.session(id)?.title ?? Format.shortID(id)
        case .search: "Search"
        case .stats: "Stats"
        case .claude: "Claude"
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { sidebar.toggle() }
            } label: {
                Label(sidebar ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.leading")
            }
            .help(sidebar ? "Hide Sidebar (⌃⌘S)" : "Show Sidebar (⌃⌘S)")
            if window.sessionID != nil {
                Button {
                    window.page = .sessions
                } label: {
                    Label("Back to Sessions", systemImage: "chevron.backward")
                }
                .help("Back to Sessions")
            }
        }
        if let id = window.sessionID {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: Binding(get: { window.sessionView }, set: { window.sessionView = $0 })) {
                    ForEach(SessionView.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    SessionActions(id: id)
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .help("More")
            }
        }
    }

    @ViewBuilder private var notice: some View {
        if let text = store.notice {
            Text(text).font(.system(size: 12)).lineLimit(2)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background { Panel(shadow: palette.shadow, radius: 12, y: 6) }
                .padding(.bottom, 18)
                .onTapGesture { store.notice = nil }
                .task(id: text) {
                    try? await Task.sleep(for: .seconds(4))
                    if store.notice == text { store.notice = nil }
                }
                .transition(.opacity)
        }
    }
}

/// What can be done to a session, shared by the toolbar's More menu and the Session menu.
struct SessionActions: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    var id: String

    var body: some View {
        Button(store.annotation(id).pinned ? "Unpin" : "Pin") { Task { await store.togglePin(id) } }
        Button("Open in New Window") { openWindow(value: id) }
        Button("Copy Session ID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(id, forType: .string)
        }
        Divider()
        Button("Archive Now") { Task { await store.archiveNow(id) } }
    }
}

private struct WindowStateKey: FocusedValueKey {
    typealias Value = WindowState
}

extension FocusedValues {
    var windowState: WindowState? {
        get { self[WindowStateKey.self] }
        set { self[WindowStateKey.self] = newValue }
    }
}
