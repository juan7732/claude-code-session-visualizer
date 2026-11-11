import SkitKit
import SwiftUI

/// One thing the palette can do.
struct PaletteItem: Identifiable {
    var id: String
    var section: String
    var label: String
    var sub: String?
    var trailing: String?
    var run: () -> Void
}

/// ⌘K: go to a session, find a mention, or run a command, from one field
/// (mock: the palette; NOTES, "Global search is not a permanent bar").
struct PaletteView: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var cursor = 0
    /// What the engine found for the query, and the query it belongs to.
    @State private var mentions: [SearchHit] = []
    @State private var mentionsFor = ""
    @FocusState private var focused: Bool

    var body: some View {
        let items = self.items
        ZStack(alignment: .top) {
            Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { close() }
            VStack(spacing: 0) {
                TextField("Go to a session, search, or run a command", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 15)).focused($focused)
                    .padding(.horizontal, 16).padding(.vertical, 13)
                    .onSubmit { run(items) }
                    .onKeyPress(.downArrow) { cursor = min(cursor + 1, max(0, items.count - 1)); return .handled }
                    .onKeyPress(.upArrow) { cursor = max(cursor - 1, 0); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
                Rectangle().fill(palette.line).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                if index == 0 || items[index - 1].section != item.section {
                                    Text(item.section.uppercased()).font(.caps).tracking(0.9).foregroundStyle(palette.muted)
                                        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 3)
                                }
                                row(item, on: index == cursor)
                                    .id(index)
                                    .onTapGesture {
                                        cursor = index
                                        run(items)
                                    }
                            }
                            if items.isEmpty {
                                Text("Nothing matches.").font(.system(size: 13)).foregroundStyle(palette.muted).padding(12)
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: min(420, Self.height(of: items)))
                    .onChange(of: cursor) { _, index in proxy.scrollTo(index) }
                }
            }
            .frame(width: 600)
            .background { Panel(shadow: palette.shadow, radius: 24, y: 12) }
            .padding(.top, 90)
        }
        .onAppear { focused = true }
        .onChange(of: query) { cursor = 0 }
        .task(id: query) { await findMentions() }
        .transition(.opacity)
        .accessibilityAddTraits(.isModal)
    }

    /// How tall the list is, so the panel is no taller than what it holds.
    private static func height(of items: [PaletteItem]) -> CGFloat {
        guard !items.isEmpty else { return 56 }
        var height: CGFloat = 12
        for (index, item) in items.enumerated() {
            if index == 0 || items[index - 1].section != item.section { height += 26 }
            height += item.sub == nil ? 29 : 43
        }
        return height
    }

    private func row(_ item: PaletteItem, on: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label).font(.system(size: 13)).lineLimit(1)
                if let sub = item.sub {
                    Text(sub).font(.system(size: 11)).foregroundStyle(on ? palette.bg.opacity(0.75) : palette.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let trailing = item.trailing { Text(trailing).font(.system(size: 11)).opacity(0.65).fixedSize() }
        }
        .foregroundStyle(on ? palette.bg : palette.ink)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(on ? palette.accent : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
    }

    private func close() {
        window.paletteShown = false
    }

    private func run(_ items: [PaletteItem]) {
        guard items.indices.contains(cursor) else { return }
        close()
        items[cursor].run()
    }

    /// Mentions come from the engine, a moment after the typing stops.
    private func findMentions() async {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else {
            mentions = []
            mentionsFor = ""
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        if Task.isCancelled { return }
        if case .success(let hits) = await store.search(needle), !Task.isCancelled {
            mentions = hits
            mentionsFor = needle
        }
    }

    private var items: [PaletteItem] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let lower = needle.lowercased()
        var out: [PaletteItem] = []
        let current = window.sessionID.flatMap { store.session($0) }
        if needle.count >= 2 {
            if let current {
                out.append(PaletteItem(id: "find", section: "This session", label: "Find “\(needle)” in \(current.title)") {
                    window.sessionView = .transcript
                    window.transcript.query = needle
                })
            }
            out.append(PaletteItem(id: "everywhere", section: "Everywhere", label: "Search all sessions for “\(needle)”") {
                window.search.query = needle
                window.page = .search
            })
        }
        let sessions = store.sessions.sorted { $0.lastAt > $1.lastAt }
            .filter { lower.isEmpty || ($0.title + " " + ($0.cwd ?? "")).lowercased().contains(lower) }
        for session in sessions.prefix(lower.isEmpty ? 4 : 6) {
            out.append(PaletteItem(id: "s:" + session.id, section: "Sessions", label: session.title,
                                   sub: Format.middleEllipsis(Format.homeRelative(session.cwd ?? ""), max: 60), trailing: Format.ago(session.lastAt)) {
                window.open(session: session.id, view: .summary)
            })
        }
        if mentionsFor == needle, !mentions.isEmpty {
            for group in SearchPage.groups(SearchPage.ordered(mentions)).prefix(5) {
                guard let first = group.hits.first else { continue }
                out.append(PaletteItem(id: "m:" + group.id, section: "Mentions",
                                       label: "\(group.title) · \(group.hits.count) hit\(group.hits.count == 1 ? "" : "s")",
                                       sub: first.snippet.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: ""),
                                       trailing: first.turn >= 0 ? "turn \(first.turn)" : nil) {
                    window.open(session: group.id, at: SessionModel.key(for: first), query: needle)
                })
            }
        }
        for action in AppActions.all(window: window, store: store, openWindow: { openWindow(value: $0) }, openSettings: { openSettings() })
            where action.enabled && (lower.isEmpty || action.title.lowercased().contains(lower)) {
            out.append(PaletteItem(id: "c:" + action.title, section: "Commands", label: action.title, trailing: action.shortcut, run: action.run))
        }
        return out
    }
}
