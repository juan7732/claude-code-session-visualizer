import os
import SkitKit
import SwiftUI

/// One window: the rail, the page, the toolbar over both.
struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var palette
    @State var window = WindowState()
    @AppStorage(SettingsKey.sidebar) private var sidebar = true
    @AppStorage(SettingsKey.inspector) private var inspector = true
    /// Opens the window on a session (Open in New Window).
    var initialSession: String?
    /// Opens the window on a page and a view (snapshots).
    var initialPage: Page?
    var initialView: SessionView?

    private static let links = Logger(subsystem: "dev.sessionkit.SessionVisualizer", category: "links")

    var body: some View {
        HStack(spacing: 0) {
            if sidebar { Rail().zIndex(1).transition(.move(edge: .leading)) }
            page.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.bg)
        .focusedSceneValue(\.windowState, window)
        .navigationTitle(title)
        .toolbar { toolbar }
        .overlay(alignment: .bottom) { notice }
        .overlay { if window.paletteShown, store.engine == .ready { PaletteView() } }
        .animation(.easeOut(duration: 0.1), value: window.paletteShown)
        // A link from a note or a pull request: skit-visualizer://session/<id>?view=…&action=…
        .onOpenURL { url in
            guard let target = SessionLink.parse(url) else {
                // The log is readable by other processes of this user: it gets the kind of link, never the link.
                Self.links.error("not a session link (scheme \(url.scheme ?? "none", privacy: .public)): \(url.absoluteString, privacy: .private)")
                store.notice = "Not a session link: \(url.absoluteString)"
                return
            }
            Self.links.info("opening session \(Format.shortID(target.session), privacy: .public), view \(target.view?.rawValue ?? "default", privacy: .public), node \(target.key?.kindLabel ?? "none", privacy: .public)")
            window.open(session: target.session, at: target.key, select: true, view: target.view ?? .transcript)
        }
        .task {
            if let initialSession, window.page == .sessions { window.page = .session(initialSession) }
            if let initialPage { window.page = initialPage }
            if let initialView { window.sessionView = initialView }
            if store.engine != .ready { await store.connect() }
            await Exercise.run(window, store)
        }
        // The store keeps the lists current while a window is open, and keeps loaded what this one shows.
        .task { await store.attend(window) }
        .frame(minWidth: 760, minHeight: 480)
        // Last, so the toolbar's own views (the find field) see the window's state too.
        .environment(window)
    }

    /// The session in front has moved on since its document was read.
    private var behind: Bool { window.sessionID.map { store.isBehind($0) } ?? false }

    @ViewBuilder private var page: some View {
        if store.engine != .ready {
            EngineStateView()
        } else {
            switch window.page {
            case .sessions: SessionsView()
            case .session(let id): SessionPage(id: id)
            case .search: SearchPage()
            case .stats: StatsPage()
            case .claude: ClaudePage()
            case .now: NowPage()
            case .primitives: PrimitivesPage()
            case .compare: ComparePage()
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
        case .now: "Now"
        case .primitives: "Primitives"
        case .compare: "Compare"
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
            // Two plain buttons: a ControlGroup here is moved to the trailing edge.
            Button {
                window.goBack()
            } label: {
                Label("Back", systemImage: "chevron.backward")
            }
            .disabled(!window.canGoBack)
            .help(Self.backHelp(window))
            Button {
                window.goForward()
            } label: {
                Label("Forward", systemImage: "chevron.forward")
            }
            .disabled(!window.canGoForward)
            .help("Forward (⌘])")
            // The app reads a session once. Refresh reads it again; the dot says there is something new to read.
            Button {
                AppActions.refresh(window, store)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .overlay(alignment: .topTrailing) {
                        if behind { Circle().fill(palette.accent).frame(width: 6, height: 6).offset(x: 3, y: -2) }
                    }
            }
            .disabled(store.reloading)
            .help(behind ? "This session has moved on since it was read. Refresh (⌘R)" : "Refresh (⌘R)")
        }
        if let id = window.sessionID {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: Binding(get: { window.sessionView }, set: { window.sessionView = $0 })) {
                    ForEach(SessionView.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            if window.sessionView == .transcript || window.sessionView == .canvas || window.sessionView == .timeline {
                ToolbarItem(placement: .primaryAction) { FindField(sessionID: id) }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    inspector.toggle()
                } label: {
                    Label(inspector ? "Hide Inspector" : "Show Inspector", systemImage: "rectangle.bottomthird.inset.filled")
                }
                .help(inspector ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
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

    /// "Back to the Summary", "Back to Search": where the button leads.
    static func backHelp(_ window: WindowState) -> String {
        let target = window.backTarget
        let place: String = switch target.page {
        case .sessions: "Sessions"
        case .search: "Search"
        case .stats: "Stats"
        case .claude: "Claude"
        case .now: "Now"
        case .primitives: "Primitives"
        case .compare: "Compare"
        case .session(let id): id == window.sessionID ? "the \(target.view.title)" : "the session you came from"
        }
        return "Back to \(place) (⌘[)"
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

/// Find in this session (⌘F): the engine's search over prompts, replies,
/// thinking, tool inputs and tool results, stepped through in reading order.
struct FindField: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var sessionID: String
    @FocusState private var focused: Bool
    @State private var searching = false
    /// The query the current hits belong to.
    @State private var searched = ""

    private var needle: String { window.transcript.query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        let state = window.transcript
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(palette.muted)
            TextField("Find in this session", text: Binding(get: { state.query }, set: { state.query = $0 }))
                .textFieldStyle(.plain).font(.system(size: 12.5)).frame(width: state.query.isEmpty && !focused ? 120 : 190)
                .focused($focused)
                .onSubmit {
                    // Return does not wait for the pause after typing.
                    if searched == needle { step(1) } else { Task { await search(state.query, wait: false) } }
                }
                .onKeyPress(.escape) {
                    state.query = ""
                    focused = false
                    return .handled
                }
            if state.query.trimmingCharacters(in: .whitespaces).count >= 2 {
                Text(searching ? "…" : state.hits.isEmpty ? "none" : "\(state.hitIndex + 1) of \(state.hits.count)")
                    .font(.system(size: 11)).foregroundStyle(palette.muted).monospacedDigit().fixedSize()
                Button { step(-1) } label: { Image(systemName: "chevron.up") }.disabled(state.hits.isEmpty).help("Previous match")
                Button { step(1) } label: { Image(systemName: "chevron.down") }.disabled(state.hits.isEmpty).help("Next match (Return)")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8).padding(.vertical, 4)
        // Again when the session arrives: a hit opened from the Search page asks before it has loaded.
        .task(id: state.query + (store.model(sessionID) == nil ? "\n…" : "")) { await search(state.query) }
        .onChange(of: state.findRequests) { focused = true }
        .help("Find in this session (⌘F)")
    }

    /// Searches once the typing has paused: every keystroke would otherwise
    /// search for a half-word and move the transcript under the typist.
    private func search(_ query: String, wait: Bool = true) async {
        let state = window.transcript
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else {
            state.hits = []
            searched = ""
            return
        }
        if needle == searched { return }
        if wait {
            try? await Task.sleep(for: .milliseconds(650))
            if Task.isCancelled { return }
        }
        searching = true
        defer { searching = false }
        let found = await store.find(needle, in: sessionID)
        guard !Task.isCancelled, let model = store.model(sessionID) else { return }
        // A hit names a turn or an action; subagent text belongs to the subagent's strand.
        var keys = Set<NodeKey>()
        for hit in found {
            if let agent = hit.agent, !agent.isEmpty {
                keys.insert(.subagent(agent))
            } else if hit.action >= 0 {
                keys.insert(.action(hit.action))
            } else if hit.turn >= 0 {
                keys.insert(.turn(hit.turn))
            }
        }
        // Reading order, whatever is folded: every turn, action and strand has a place in the unfolded order.
        let order = model.focusOrder(folded: [])
        state.hits = order.filter(keys.contains)
        // A hit opened from the Summary or the Search page starts on that hit.
        state.hitIndex = state.startAt.flatMap { state.hits.firstIndex(of: $0) } ?? 0
        state.startAt = nil
        searched = needle
        show()
    }

    private func step(_ by: Int) {
        let state = window.transcript
        guard !state.hits.isEmpty else { return }
        state.hitIndex = (state.hitIndex + by + state.hits.count) % state.hits.count
        show()
    }

    private func show() {
        let state = window.transcript
        guard state.hits.indices.contains(state.hitIndex), let model = store.model(sessionID) else { return }
        let key = state.hits[state.hitIndex]
        // A match inside folded tool calls shows them again.
        if let turn = model.turnIndex(of: key), state.folded.contains(turn), model.isHiddenWhenFolded(key) {
            window.setFolded(turn, false, in: model)
        }
        state.focus = key
        if case .subagent(let id) = key, let tool = model.subagent(id)?.toolUseId { state.open.insert(.tool(tool)) }
        state.scrollTarget = model.itemID(for: key)
        if window.selection != nil { window.selection = key }
    }
}

/// What can be done to a session, shared by the toolbar's More menu and the Session menu.
struct SessionActions: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.openWindow) private var openWindow
    var id: String

    var body: some View {
        // A session that is running: back to the window or the terminal it runs in.
        if let host = store.nowSession(id)?.host {
            Button(HostContent.title(host)) { HostOpener.open(host) }
            Divider()
        }
        Button(store.annotation(id).pinned ? "Unpin" : "Pin") { Task { await store.togglePin(id) } }
        Button("Open in New Window") { openWindow(value: id) }
        Divider()
        Button("Copy Link") { AppActions.copyLink(window, store) }
        Button("Copy Session ID") { Exporter.copy(id) }
        Button("Export as Markdown…") { if let session = store.session(id) { Exporter.saveSession(session, store: store) } }
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
