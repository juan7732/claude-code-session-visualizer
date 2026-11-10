import SkitKit
import SwiftUI

/// Search every session (mock: `#/search`, the simplified Finder): hits on the
/// left grouped by session, with a strip of where in the session they fall; on
/// the right the text the selected hit sits in. ↑ and ↓ move, Return opens the
/// hit in its Transcript.
struct SearchPage: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    @AppStorage(SettingsKey.recentSearches) private var recent = ""
    @FocusState private var focused: Bool

    private var needle: String { window.search.query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        let state = window.search
        HStack(spacing: 0) {
            left(state).frame(width: 440)
            Rectangle().fill(palette.line).frame(width: 1)
            right(state).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.bg)
        .task(id: state.query + "\n" + state.kind) { await search(state) }
        .onAppear { focused = true }
        .onChange(of: state.focusRequests) { focused = true }
    }

    @ViewBuilder private func right(_ state: SearchState) -> some View {
        if state.hits.indices.contains(state.selected), needle.count >= 2 {
            let hit = state.hits[state.selected]
            HitPreview(hit: hit, query: needle) { open(hit) }.id(state.selected)
        } else {
            let waiting: String = needle.count < 2 ? "Type to search." : state.searching ? "Searching…" : "Pick a hit to read it in place."
            Text(waiting).foregroundStyle(palette.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: The list

    private func left(_ state: SearchState) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(palette.muted)
                TextField("Search all sessions", text: Binding(get: { state.query }, set: { state.query = $0 }))
                    .textFieldStyle(.plain).font(.system(size: 13)).focused($focused)
                    .onSubmit { if state.hits.indices.contains(state.selected) { open(state.hits[state.selected]) } }
                    .onKeyPress(.downArrow) { move(state, 1); return .handled }
                    .onKeyPress(.upArrow) { move(state, -1); return .handled }
                if state.searching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(palette.panel, in: RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metric.radius, style: .continuous).stroke(palette.line2))
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)

            if needle.count < 2 {
                idle(state)
            } else {
                scopeBar(state).padding(.horizontal, 12)
                Text(statusLine(state)).font(.system(size: 11.5)).foregroundStyle(state.failure == nil ? palette.muted : palette.err)
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2).textSelection(.enabled)
                hitList(state)
            }
            Spacer(minLength: 0)
        }
    }

    private func idle(_ state: SearchState) -> some View {
        let past = recent.split(separator: "\n").map(String.init)
        return VStack(alignment: .leading, spacing: 10) {
            if !past.isEmpty {
                FlowLayout(spacing: 6) {
                    Text("Recent:").font(.system(size: 12)).foregroundStyle(palette.muted)
                    ForEach(past, id: \.self) { query in
                        Chip(title: query, on: false) { state.query = query }
                    }
                    Button("Clear") { recent = "" }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(palette.accent)
                }
            }
            Text("Search every session on this Mac, archived ones included. Hits list here, the text they sit in on the right. ↑ and ↓ move, Return opens the hit in its Transcript.")
                .font(.system(size: 12)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.top, 4)
    }

    /// The kinds that have hits, each with its count: a scope bar under the field.
    private func scopeBar(_ state: SearchState) -> some View {
        var counts: [String: Int] = [:]
        for hit in state.all { counts[hit.kind, default: 0] += 1 }
        let kinds = SearchKind.scopes.map(\.kind).filter { !$0.isEmpty && counts[$0] != nil } + counts.keys.filter { kind in !SearchKind.scopes.contains { $0.kind == kind } }.sorted()
        return FlowLayout(spacing: 4) {
            Chip(title: "All \(state.all.count)", on: state.kind.isEmpty) { state.kind = "" }
            ForEach(kinds, id: \.self) { kind in
                Chip(title: "\(SearchKind.label(kind)) \(counts[kind] ?? 0)", on: state.kind == kind) { state.kind = kind }
            }
        }
    }

    private func statusLine(_ state: SearchState) -> String {
        if let failure = state.failure { return failure }
        if state.searched != needle + "\n" + state.kind { return "Searching…" }
        if state.hits.isEmpty { return "Nothing mentions “\(needle)”." }
        let sessions = Set(state.hits.map(\.session)).count
        return "\(sessions) session\(sessions == 1 ? "" : "s") mention\(sessions == 1 ? "s" : "") “\(needle)”"
            + (state.all.count >= Self.limit ? " · the first \(Self.limit) hits" : "")
    }

    private func hitList(_ state: SearchState) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Self.groups(state.hits)) { group in
                        SessionHeader(session: store.session(group.id), title: group.title, hits: group.hits, query: needle)
                        ForEach(group.rows, id: \.index) { row in
                            HitRow(hit: row.hit, current: row.index == state.selected)
                                .id(row.index)
                                .onTapGesture(count: 2) { open(row.hit) }
                                .onTapGesture { state.selected = row.index }
                        }
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 20)
            }
            .onChange(of: state.selected) { _, index in proxy.scrollTo(index) }
        }
    }

    struct Group: Identifiable {
        var id: String
        var title: String
        var hits: [SearchHit]
        /// Each hit with its place in the flat list, which is what the cursor counts in.
        var rows: [(index: Int, hit: SearchHit)]
    }

    /// The hits in list order, cut into runs of one session.
    nonisolated static func groups(_ hits: [SearchHit]) -> [Group] {
        var out: [Group] = []
        for (index, hit) in hits.enumerated() {
            if out.last?.id != hit.session { out.append(Group(id: hit.session, title: hit.title ?? Format.shortID(hit.session), hits: [], rows: [])) }
            out[out.count - 1].hits.append(hit)
            out[out.count - 1].rows.append((index, hit))
        }
        return out
    }

    /// Sessions with the most hits first; inside a session the engine's order
    /// stays, which is best match first.
    nonisolated static func ordered(_ hits: [SearchHit]) -> [SearchHit] {
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        for (i, hit) in hits.enumerated() {
            counts[hit.session, default: 0] += 1
            if firstSeen[hit.session] == nil { firstSeen[hit.session] = i }
        }
        return hits.enumerated().sorted { a, b in
            let (x, y) = (a.element.session, b.element.session)
            if x != y {
                let (cx, cy) = (counts[x] ?? 0, counts[y] ?? 0)
                return cx != cy ? cx > cy : (firstSeen[x] ?? 0) < (firstSeen[y] ?? 0)
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    // MARK: Doing

    static let limit = 400

    private func search(_ state: SearchState) async {
        let needle = self.needle, kind = state.kind
        guard needle.count >= 2 else {
            (state.all, state.hits, state.searched, state.failure, state.selected) = ([], [], "", nil, 0)
            return
        }
        let stamp = needle + "\n" + kind
        if state.searched == stamp { return }
        // Live as you type, after a short pause.
        try? await Task.sleep(for: .milliseconds(350))
        if Task.isCancelled { return }
        state.searching = true
        defer { state.searching = false }
        // Everything first, for the counts on the scope bar; then the chosen kind on its own.
        if !state.searched.hasPrefix(needle + "\n") || state.all.isEmpty {
            switch await store.search(needle) {
            case .success(let hits): state.all = hits
            case .failure(let error):
                (state.all, state.hits, state.failure, state.searched) = ([], [], "\(error)", stamp)
                return
            }
        }
        if Task.isCancelled { return }
        var hits = state.all
        if !kind.isEmpty {
            switch await store.search(needle, kind: kind) {
            case .success(let found): hits = found
            case .failure(let error):
                (state.hits, state.failure, state.searched) = ([], "\(error)", stamp)
                return
            }
        }
        if Task.isCancelled { return }
        (state.hits, state.failure, state.searched, state.selected) = (Self.ordered(hits), nil, stamp, 0)
    }

    private func move(_ state: SearchState, _ by: Int) {
        guard !state.hits.isEmpty else { return }
        state.selected = min(max(state.selected + by, 0), state.hits.count - 1)
    }

    private func open(_ hit: SearchHit) {
        remember(needle)
        window.open(session: hit.session, at: SessionModel.key(for: hit), query: needle)
    }

    /// The last six searches that led somewhere, newest first.
    private func remember(_ query: String) {
        guard query.count >= 2 else { return }
        let past = recent.split(separator: "\n").map(String.init).filter { $0 != query }
        recent = ([query] + past).prefix(6).joined(separator: "\n")
    }
}

/// A session's line above its hits: title, how many, where they fall.
private struct SessionHeader: View {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var session: SessionSummary?
    var title: String
    var hits: [SearchHit]
    var query: String

    var body: some View {
        let turns = Set(hits.map(\.turn).filter { $0 >= 0 })
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.display(12.5)).lineLimit(1)
                Spacer(minLength: 6)
                Text("\(hits.count) hit\(hits.count == 1 ? "" : "s") in \(turns.count) turn\(turns.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize()
            }
            if let session {
                strip(total: session.turns + session.systemTurns, hit: turns, sessionID: session.id)
                Text(Format.middleEllipsis(Format.homeRelative(session.cwd ?? ""), max: 36) + " · " + Format.ago(session.lastAt))
                    .font(.system(size: 11)).foregroundStyle(palette.muted)
            }
        }
        .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 6)
    }

    /// The session's turns left to right, the ones with a hit raised. Long
    /// sessions share cells: sixty at most.
    private func strip(total: Int, hit: Set<Int>, sessionID: String) -> some View {
        let cells = max(1, min(total, 60))
        let lit = Set(hit.map { min(cells - 1, $0 * cells / max(1, total)) })
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<cells, id: \.self) { cell in
                RoundedRectangle(cornerRadius: 2).fill(lit.contains(cell) ? palette.warn : palette.line2)
                    .frame(height: lit.contains(cell) ? 12 : 6)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // The first turn the cell stands for.
                        window.open(session: sessionID, at: .turn(cell * max(1, total) / cells), query: lit.contains(cell) ? query : nil)
                    }
            }
        }
        .frame(height: 12)
        .help("Where in the session the hits fall. Click to read from there.")
        .accessibilityHidden(true)
    }
}

private struct HitRow: View {
    @Environment(\.palette) private var palette
    var hit: SearchHit
    var current: Bool
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: SearchKind.symbol(hit.kind)).font(.system(size: 11)).foregroundStyle(SearchKind.color(hit.kind, palette)).frame(width: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Self.place(hit)).font(.system(size: 12, weight: .semibold)).fixedSize()
                    Text(SearchKind.label(hit.kind) + (hit.tool.map { $0.isEmpty ? "" : " · " + $0 } ?? "") + ((hit.agent ?? "").isEmpty ? "" : " · subagent"))
                        .font(.system(size: 12)).foregroundStyle(palette.muted).lineLimit(1)
                }
                Text(Snippet.attributed(hit.snippet, palette: palette)).font(.system(size: 12.5)).foregroundStyle(palette.ink2).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background {
            if current {
                Panel(shadow: palette.shadow.opacity(0.5), radius: 6, y: 3)
            } else if hover {
                RoundedRectangle(cornerRadius: Metric.radius, style: .continuous).fill(palette.panel)
            }
        }
        .overlay(alignment: .bottom) { if !current { Rectangle().fill(palette.line).frame(height: 1) } }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    static func place(_ hit: SearchHit) -> String {
        if hit.turn < 0 { return "session" }
        return "turn \(hit.turn)" + (hit.action >= 0 ? " · action \(hit.action)" : "")
    }
}

/// The selected hit, read in place: the text it sits in, with the words marked.
private struct HitPreview: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var hit: SearchHit
    var query: String
    var open: () -> Void

    var body: some View {
        let session = store.session(hit.session)
        let marks = self.marks
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(hit.title ?? Format.shortID(hit.session)).font(.display(18)).lineLimit(1)
                    Text(Format.middleEllipsis(Format.homeRelative(session?.cwd ?? ""), max: 40)).font(.system(size: 12)).foregroundStyle(palette.muted)
                }
                Text([HitRow.place(hit), SearchKind.label(hit.kind), hit.tool, hit.at.map { Format.dateTime($0) }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(palette.muted).padding(.top, 4).padding(.bottom, 14)
                Text(Snippet.painted(text ?? hit.snippet.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: ""), marks: marks, palette: palette))
                    .font(.system(size: 12, design: .monospaced)).lineSpacing(3).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background { Panel(shadow: palette.shadow.opacity(0.6), radius: 9, y: 6) }
                if text == nil {
                    Text(loadingNote).font(.system(size: 11.5)).foregroundStyle(palette.muted).padding(.top, 6)
                }
                HStack(spacing: 8) {
                    Button("Open in Transcript", action: open).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    Button("Session Summary") { window.open(session: hit.session, at: nil, view: .summary) }
                }
                .padding(.top, 14)
            }
            .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 60)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: hit.session + "\(hit.turn)/\(hit.action)") {
            // Reading a whole session for a preview is only worth it once the cursor rests.
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            await store.loadModel(hit.session)
            guard hit.kind == "tool_result", hit.action >= 0 else { return }
            if let agent = hit.agent, !agent.isEmpty {
                await store.loadStep(hit.session, agent: agent, index: hit.action)
            } else {
                await store.loadAction(hit.session, hit.action)
            }
        }
    }

    /// The words to paint and to centre on: the ones the engine marked, else the query's.
    private var marks: [String] {
        let marked = Snippet.marks(hit.snippet)
        return marked.isEmpty ? query.lowercased().split(separator: " ").map(String.init).filter { $0.count >= 2 } : marked
    }

    private var loadingNote: String {
        switch store.models[hit.session] {
        case .failed(let why): "Could not read the session: \(why)"
        case .loaded: "The engine's excerpt; the full text of this piece is not in the session document."
        case .loading, nil: "Reading the session for the text around it…"
        }
    }

    /// The text of the piece the hit is in, cut to a window around the first marked word.
    private var text: String? {
        guard let model = store.model(hit.session) else { return nil }
        let marks = self.marks
        let agent = (hit.agent ?? "").isEmpty ? nil : hit.agent
        // A subagent's hit counts actions in the subagent's own transcript.
        let run = agent.flatMap { model.subagent($0)?.session }
        let action: Action? = agent != nil ? run.flatMap { $0.actions.indices.contains(hit.action) ? $0.actions[hit.action] : nil } : model.action(hit.action)
        let calls: [ToolCall] = agent.map { model.tools(ofStep: hit.action, agent: $0) } ?? action.map { model.tools(of: $0) } ?? []
        func mentions(_ text: String) -> Bool { marks.contains { text.range(of: $0, options: .caseInsensitive) != nil } }
        var full: String?
        switch hit.kind {
        case "prompt": full = model.prompt(ofTurn: hit.turn)?.text
        case "assistant": full = action?.text
        case "thinking": full = action?.thinking
        case "tool_use": full = calls.map(\.inputText).first(where: mentions) ?? calls.first { $0.name == hit.tool }?.inputText
        case "tool_result":
            let detail: Loadable<ActionDetail>? = agent.map { store.stepDetails[hit.session]?[AppStore.stepKey(agent: $0, index: hit.action)] } ?? store.actionDetails[hit.session]?[hit.action]
            if case .loaded(let loaded) = detail {
                full = loaded.toolCalls.compactMap(\.result).first(where: mentions)
            }
        case "summary": full = model.doc.compactions.compactMap(\.summary).first(where: mentions)
        default: full = nil
        }
        guard let full, !full.isEmpty else { return nil }
        return Snippet.window(full, marks: marks)
    }
}
