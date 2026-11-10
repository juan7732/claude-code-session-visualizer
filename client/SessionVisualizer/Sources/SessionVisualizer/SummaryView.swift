import SkitKit
import SwiftUI

/// What a session was about, at a glance (mock: `?view=summary`, the
/// Dashboard): cards over the numbers, then the turns one line each, then the
/// hours it was alive. Every row that names a node selects it, and the drawer
/// under the page shows it.
struct SummaryView: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    @AppStorage(SettingsKey.summaryDigest) private var showDigest = true
    @AppStorage(SettingsKey.summaryHours) private var showHours = true
    var session: SessionSummary

    var body: some View {
        let model = store.model(session.id)
        // The numbers of the open session come from /stats, which is computed
        // from the transcript as it is now; the list row may be a little older.
        let stats: SessionSummary = { if case .loaded(let s) = store.stats[session.id] { s } else { session } }()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SummaryHead(session: session)
                VStack(spacing: 12) {
                    row {
                        AboutCard(title: "What it is about", text: model?.firstPrompt?.text, model: model, target: model?.firstPrompt.flatMap { p in model?.doc.turns.first { $0.promptIndex == p.index } }.map { .turn($0.index) })
                        AboutCard(title: "Where it ended", text: model?.ending?.text, model: model, target: model?.ending.map { .action($0.index) })
                    }
                    row {
                        SizeCard(stats: stats)
                        OutcomeCard(stats: stats, model: model)
                        ProblemsCard(stats: stats, model: model)
                    }
                    row {
                        ContextCard(sessionID: session.id, live: store.isLive(session.id), model: model)
                        ParallelCard(model: model)
                        OutsideCard(model: model)
                    }
                    row {
                        WhereCard(stats: stats, model: model)
                        HowCard(stats: stats, model: model)
                    }
                }
                .padding(.top, 18)
                if let model {
                    SessionSearchBox(model: model).padding(.top, 22)
                    if showDigest { Digest(model: model).padding(.top, 22) }
                    if showHours, let grid = HoursGrid(turns: model.doc.turns) { HoursCard(model: model, grid: grid).padding(.top, 18) }
                } else if case .failed(let why) = store.models[session.id] {
                    Text("Could not read the session: \(why)").font(.system(size: 12)).foregroundStyle(palette.err).padding(.top, 18)
                }
                SessionNote(sessionID: session.id).padding(.top, 18)
            }
            .frame(maxWidth: Metric.wideColumn, alignment: .leading)
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 60)
            .frame(maxWidth: .infinity)
        }
        .background(palette.bg)
    }

    /// Cards side by side, as wide as each other and as tall as the tallest.
    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) { content() }.fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Head

/// Title, when and where, pin and tags.
private struct SummaryHead: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var palette
    var session: SessionSummary
    @State private var newTag = ""

    var body: some View {
        let note = store.annotation(session.id)
        VStack(alignment: .leading, spacing: 0) {
            Text(session.title).font(.display(30)).tracking(-0.3).textSelection(.enabled)
            when.padding(.top, 6)
            tagRow(note).padding(.top, 10)
        }
    }

    private var when: some View {
        HStack(spacing: 8) {
            if store.isLive(session.id) {
                Circle().fill(palette.ok).frame(width: 7, height: 7)
                Text("Live")
            } else {
                Text(session.archivedOnly == true ? "Archived; source gone" : "Archived")
            }
            Text("·")
            Text("\(Format.dateTime(session.firstAt)) → \(Format.dateTime(session.lastAt))")
            Text("·")
            Text(session.duration)
            if let cwd = session.cwd {
                Text("·")
                Text(Format.middleEllipsis(Format.homeRelative(cwd), max: 40)).help(cwd)
            }
            if let cwds = session.cwds, cwds.count > 1 {
                Text("·")
                Text("\(cwds.count) directories").help(cwds.joined(separator: "\n"))
            }
        }
        .font(.label(12)).foregroundStyle(palette.muted).lineLimit(1)
    }

    private func tagRow(_ note: Annotation) -> some View {
        HStack(spacing: 8) {
            Button {
                Task { await store.togglePin(session.id) }
            } label: {
                Label(note.pinned ? "Pinned" : "Pin", systemImage: note.pinned ? "star.fill" : "star")
                    .font(.system(size: 12)).foregroundStyle(note.pinned ? palette.warn : palette.muted)
            }
            .buttonStyle(.plain)
            ForEach(note.tags, id: \.self) { tag in
                HStack(spacing: 4) {
                    Text("#" + tag)
                    Button {
                        Task { await store.removeTag(session.id, tag) }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain).help("Remove tag")
                }
                .font(.system(size: 11.5)).foregroundStyle(palette.ink2)
                .padding(.horizontal, 8).padding(.vertical, 2).background(palette.line, in: Capsule())
            }
            TextField("add a tag", text: $newTag)
                .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 90)
                .overlay(alignment: .bottom) { Rectangle().fill(palette.line2).frame(height: 1).offset(y: 3) }
                .onSubmit {
                    let tag = newTag
                    newTag = ""
                    Task { await store.addTag(session.id, tag) }
                }
            Spacer()
            Button("Export as Markdown…") { Exporter.saveSession(session, store: store) }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(palette.accent)
        }
    }
}

// MARK: Cards

/// The first prompt, or the last thing the agent said: four lines, more on request.
private struct AboutCard: View {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var title: String
    var text: String?
    var model: SessionModel?
    /// Where the text is in the transcript.
    var target: NodeKey?
    @State private var expanded = false

    var body: some View {
        Card(title: title) {
            if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                Text(text).font(.system(size: 12.5)).lineSpacing(2).foregroundStyle(palette.ink2)
                    .lineLimit(expanded ? nil : 4).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 14) {
                    if text.count > 280 || text.contains("\n") {
                        Button(expanded ? "Show less" : "Show more") { expanded.toggle() }
                    }
                    if let target, let model {
                        Button("Read it in the Transcript") { window.reveal(target, in: model) }
                    }
                }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(palette.accent)
            } else {
                Text(model == nil ? "Reading the session…" : "Nothing was said.").font(.system(size: 12.5)).foregroundStyle(palette.muted)
            }
        }
    }
}

private struct SizeCard: View {
    var stats: SessionSummary

    var body: some View {
        Card(title: "Size") {
            Big("\(stats.prompts) prompt\(stats.prompts == 1 ? "" : "s")")
            Facts(rows: rows)
        }
    }

    private var rows: [(String, String)] {
        var rows: [(String, String)] = []
        let turns = stats.turns + stats.systemTurns
        rows.append(("Turns", stats.systemTurns > 0 ? "\(turns) · \(stats.systemTurns) by the system" : "\(turns)"))
        rows.append(("Actions", "\(stats.requests)"))
        rows.append(("Tool calls", "\(stats.toolCalls)"))
        rows.append(("Output", Format.tokens(stats.usage.outputTokens) + " tokens"))
        rows.append(("Wall", stats.duration))
        if let inTurns = stats.inTurns { rows.append(("In turns", inTurns)) }
        rows.append(("Cost", stats.claudeCodeCostUsd.map { Format.money($0) + " · Claude Code's figure" } ?? "not recorded"))
        if let actions = stats.rewoundActions, actions > 0 {
            rows.append(("Rewound", "\(stats.rewoundTurns ?? 0) turns · \(actions) actions, included above"))
        }
        return rows
    }
}

/// What the session left behind: the files it wrote and the commits it made.
private struct OutcomeCard: View {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var stats: SessionSummary
    var model: SessionModel?

    var body: some View {
        Card(title: "Outcome") {
            if let model {
                let written = model.relations.files.filter { $0.writes > 0 }
                Big("\(written.count) file\(written.count == 1 ? "" : "s") written")
                VStack(spacing: 0) {
                    ForEach(written.prefix(5)) { file in
                        ItemRow(symbol: "doc", color: palette.ink2, label: Self.shortPath(file.path), trailing: "\(file.writes)w", truncation: .middle, help: file.path) {
                            window.select(.file(file.path), in: model, scroll: false)
                        }
                    }
                    if written.count > 5 {
                        ItemRow(symbol: "ellipsis", color: palette.muted, label: "\(written.count - 5) more", trailing: nil) {
                            window.select(.file(written[5].path), in: model, scroll: false)
                        }
                    }
                    if let last = model.relations.commits.last {
                        let n = model.relations.commits.count
                        ItemRow(symbol: "point.topleft.down.to.point.bottomright.curvepath", color: palette.ok,
                                label: "\(n) commit\(n == 1 ? "" : "s") · " + (last.subject.isEmpty ? (last.sha ?? "no message read") : last.subject), trailing: last.sha,
                                help: "Each `git commit` the agent ran that did not fail. The last one is shown.") {
                            window.select(.tool(last.call.toolId), in: model, scroll: false)
                        }
                    }
                }
                if (stats.linesAdded ?? 0) + (stats.linesRemoved ?? 0) > 0 {
                    Text("+\(stats.linesAdded ?? 0) −\(stats.linesRemoved ?? 0) lines · Claude Code's figure").font(.system(size: 11.5)).foregroundStyle(palette.muted)
                }
            } else {
                Waiting()
            }
        }
    }

    /// The last two components: enough to tell two files of the same name apart.
    static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.suffix(2).joined(separator: "/")
    }
}

private struct ProblemsCard: View {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var stats: SessionSummary
    var model: SessionModel?

    var body: some View {
        Card(title: "Problems") {
            let failed = stats.toolErrors
            Big(failed > 0 ? "\(failed) failed call\(failed == 1 ? "" : "s")" : "Nothing failed").foregroundStyle(failed > 0 ? palette.err : palette.ok)
            if let model {
                let calls = model.failedCalls
                VStack(spacing: 0) {
                    ForEach(calls.prefix(4)) { call in
                        ItemRow(symbol: call.family.symbol, color: palette.err,
                                label: "\(call.displayName) · turn \(call.turn) · " + (call.resultHead ?? ""),
                                trailing: model.retriedBy[call.id] != nil ? "retried" : nil) {
                            window.select(.tool(call.id), in: model, scroll: false)
                        }
                    }
                    if calls.count > 4 {
                        ItemRow(symbol: "ellipsis", color: palette.muted, label: "\(calls.count - 4) more", trailing: nil) {
                            window.select(.tool(calls[4].id), in: model, scroll: false)
                        }
                    }
                    if stats.apiErrors > 0 {
                        ItemRow(symbol: "exclamationmark.triangle", color: palette.err,
                                label: "\(stats.apiErrors) API error\(stats.apiErrors == 1 ? "" : "s"), retried by Claude Code", trailing: nil, action: nil)
                    }
                }
                if failed > calls.count {
                    Text("\(failed - calls.count) of the failed calls were inside subagents.").font(.system(size: 11.5)).foregroundStyle(palette.muted)
                }
            }
        }
    }
}

/// How full the context got, against the window set in Settings.
struct ContextCard: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    @AppStorage(SettingsKey.contextWindow) private var limit = 1_000_000
    var sessionID: String
    var live: Bool
    var model: SessionModel?

    var body: some View {
        Card(title: "Context") {
            switch store.stats[sessionID] {
            case .loaded(let stats):
                let peak = (stats.context ?? []).map(\.tokens).max() ?? 0
                let share = Double(peak) / Double(max(1, limit))
                Big("\(Format.tokens(peak)) peak")
                Gauge(share: share).help("\(peak) tokens of \(limit)")
                Text(Self.caption(share: share, limit: limit, live: live, compacted: stats.compactions > 0))
                    .font(.system(size: 11.5)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow {
                        Text("Compactions").foregroundStyle(palette.muted)
                        compactions(stats)
                    }
                    GridRow {
                        Text("Cache hit").foregroundStyle(palette.muted)
                        Text("\(Int((stats.cacheHitRatio * 100).rounded()))%")
                    }
                    GridRow {
                        Text("Models").foregroundStyle(palette.muted)
                        Text(stats.models.map { $0.name.replacingOccurrences(of: "claude-", with: "") }.joined(separator: ", "))
                    }
                    if stats.images > 0 {
                        GridRow {
                            Text("Images").foregroundStyle(palette.muted)
                            Text("\(stats.images)")
                        }
                    }
                }
                .font(.system(size: 12))
            case .failed(let why):
                Big("Could not load")
                Text(why).font(.system(size: 12)).foregroundStyle(palette.err).textSelection(.enabled)
            case .loading, nil:
                Big("…").foregroundStyle(palette.muted)
                Waiting()
            }
        }
    }

    /// "73% of a 1.0M window (your setting)". The transcript does not record
    /// the window, so the number it is measured against is the human's.
    static func caption(share: Double, limit: Int, live: Bool, compacted: Bool) -> String {
        let window = Format.tokens(limit)
        if share > 1 { return "More than the \(window) window in Settings: this session ran on a larger one." }
        return "\(Int((share * 100).rounded()))% of a \(window) window (your setting)" + (live && share > 0.6 && !compacted ? " · a compaction is getting close" : "")
    }

    @ViewBuilder private func compactions(_ stats: SessionSummary) -> some View {
        let list = stats.compactionList ?? []
        if list.isEmpty {
            Text("none")
        } else {
            HStack(spacing: 8) {
                ForEach(Array(list.enumerated()), id: \.offset) { index, cut in
                    Button("\(Format.tokens(cut.preTokens)) → \(Format.tokens(cut.postTokens))") {
                        if let model { window.select(.compaction(index), in: model, scroll: false) }
                    }
                    .buttonStyle(.plain).foregroundStyle(palette.accent).disabled(model == nil)
                }
            }
        }
    }
}

/// The share of the window that was in use at the peak.
private struct Gauge: View {
    @Environment(\.palette) private var palette
    var share: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.line)
                Capsule().fill(share > 0.85 ? palette.err : share > 0.6 ? palette.warn : palette.accent)
                    .frame(width: max(3, geo.size.width * min(1, max(0, share))))
            }
        }
        .frame(height: 6)
        .accessibilityLabel("\(Int((min(1, share) * 100).rounded())) percent of the context window")
    }
}

/// Subagents and background commands: what ran beside the main thread.
private struct ParallelCard: View {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var model: SessionModel?

    var body: some View {
        Card(title: "Parallel work") {
            if let model {
                let subs = model.doc.subagents, tasks = model.relations.tasks
                if subs.isEmpty && tasks.isEmpty {
                    Text("none").font(.system(size: 12)).foregroundStyle(palette.muted)
                } else {
                    VStack(spacing: 0) {
                        ForEach(subs.prefix(8)) { sub in
                            let steps = sub.session?.actions.count ?? 0
                            ItemRow(symbol: "person.2", color: palette.warn, label: "subagent · " + (sub.meta?.description ?? sub.agentId), trailing: "\(steps) step\(steps == 1 ? "" : "s")") {
                                window.select(.subagent(sub.agentId), in: model, scroll: false)
                            }
                        }
                        ForEach(tasks.prefix(max(0, 8 - subs.count))) { task in
                            ItemRow(symbol: "clock.arrow.circlepath", color: palette.ctx, label: "background · " + (task.label ?? task.id), trailing: task.pickups.isEmpty ? "never read" : "read") {
                                window.select(.tool(task.launch.toolId), in: model, scroll: false)
                            }
                        }
                    }
                    if subs.count + tasks.count > 8 {
                        Text("\(subs.count) subagent\(subs.count == 1 ? "" : "s") and \(tasks.count) background task\(tasks.count == 1 ? "" : "s") in all.")
                            .font(.system(size: 11.5)).foregroundStyle(palette.muted)
                    }
                }
            } else {
                Waiting()
            }
        }
    }
}

/// What the session reached beyond the machine.
private struct OutsideCard: View {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var model: SessionModel?

    var body: some View {
        Card(title: "Outside") {
            if let model {
                let services = model.relations.outside
                if services.isEmpty {
                    Text("none").font(.system(size: 12)).foregroundStyle(palette.muted)
                } else {
                    VStack(spacing: 0) {
                        ForEach(services.prefix(8)) { service in
                            ItemRow(symbol: Self.symbol(service.kind), color: palette.plug, label: service.name, trailing: "\(service.calls.count) call\(service.calls.count == 1 ? "" : "s")") {
                                window.select(.outside(service.id), in: model, scroll: false)
                            }
                        }
                        if services.count > 8 {
                            ItemRow(symbol: "ellipsis", color: palette.muted, label: "\(services.count - 8) more", trailing: nil) {
                                window.select(.outside(services[8].id), in: model, scroll: false)
                            }
                        }
                    }
                }
            } else {
                Waiting()
            }
        }
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "connector": "puzzlepiece.extension"
        case "skill": "sparkles"
        case "search": "magnifyingglass"
        default: "globe"
        }
    }
}

private struct WhereCard: View {
    @Environment(\.palette) private var palette
    var stats: SessionSummary
    var model: SessionModel?

    var body: some View {
        Card(title: "Where it worked") {
            let cwds = stats.cwds ?? stats.cwd.map { [$0] } ?? []
            if cwds.isEmpty {
                Text("not recorded").font(.system(size: 12)).foregroundStyle(palette.muted)
            } else {
                VStack(spacing: 0) {
                    ForEach(cwds, id: \.self) { cwd in
                        ItemRow(symbol: "folder", color: palette.ink2, label: Format.homeRelative(cwd), trailing: cwd == stats.cwd ? "started here" : nil, mono: true, truncation: .middle, help: cwd, action: nil)
                    }
                }
            }
        }
    }
}

private struct HowCard: View {
    var stats: SessionSummary
    var model: SessionModel?

    var body: some View {
        Card(title: "How it ran") { Facts(rows: rows) }
    }

    private var rows: [(String, String)] {
        let entry: String = model.map { $0.doc.entrypoints.isEmpty ? "—" : $0.doc.entrypoints.joined(separator: ", ") } ?? "…"
        let versions = stats.claudeCodeVersions ?? []
        let blocks = stats.injectedBlocks ?? 0, attachments = stats.attachments ?? 0
        return [
            ("Entry", entry),
            ("Claude Code", versions.isEmpty ? "—" : versions.joined(separator: ", ")),
            ("Branch", stats.gitBranch ?? "—"),
            ("Forks", stats.branches > 0 ? "\(stats.branches) branch point\(stats.branches == 1 ? "" : "s") in the transcript" : "none"),
            ("Injected", "\(blocks) context block\(blocks == 1 ? "" : "s") · \(attachments) attachment\(attachments == 1 ? "" : "s")"),
        ]
    }
}

// MARK: Search this session

/// "Did we talk about X here?" answered on the page: yes with where, or no
/// with a way to ask every session.
private struct SessionSearchBox: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var model: SessionModel
    @State private var hits: [SearchHit] = []
    @State private var searched = ""
    @State private var searching = false

    static let kinds: [(String, String)] = [("", "Everything"), ("prompt", "Prompts"), ("assistant", "Responses"), ("thinking", "Thinking"), ("tool_use", "Tool inputs"), ("tool_result", "Tool results")]

    var body: some View {
        let state = window.transcript
        let needle = state.summaryQuery.trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(palette.muted)
                TextField("Search this session", text: Binding(get: { state.summaryQuery }, set: { state.summaryQuery = $0 }))
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .onSubmit { Task { await search(wait: false) } }
                if searching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(palette.panel, in: RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metric.radius, style: .continuous).stroke(palette.line2))
            HStack(spacing: 6) {
                ForEach(Self.kinds, id: \.0) { kind, label in
                    Chip(title: label, on: state.summaryKind == kind) { state.summaryKind = kind }
                }
            }
            if needle.count >= 2, searched == needle + "\n" + state.summaryKind { answer(needle) }
        }
        .task(id: state.summaryQuery + "\n" + state.summaryKind) { await search(wait: true) }
    }

    private func search(wait: Bool) async {
        let state = window.transcript
        let needle = state.summaryQuery.trimmingCharacters(in: .whitespaces), kind = state.summaryKind
        guard needle.count >= 2 else {
            hits = []
            searched = ""
            return
        }
        if wait {
            try? await Task.sleep(for: .milliseconds(450))
            if Task.isCancelled { return }
        }
        searching = true
        defer { searching = false }
        let found = await store.find(needle, in: model.doc.id, kind: kind)
        if Task.isCancelled { return }
        hits = found.sorted { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }
        searched = needle + "\n" + kind
    }

    @ViewBuilder private func answer(_ needle: String) -> some View {
        if hits.isEmpty {
            HStack(spacing: 6) {
                (Text("No.").fontWeight(.semibold) + Text(" “\(needle)” does not appear in this session."))
                Button("Search all sessions") {
                    window.search.query = needle
                    window.page = .search
                }
                .buttonStyle(.plain).foregroundStyle(palette.accent)
            }
            .font(.system(size: 12.5)).foregroundStyle(palette.muted)
            .padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.panel, in: RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
        } else {
            let turns = Set(hits.map(\.turn)).count
            (Text("Yes.").fontWeight(.semibold) + Text(" “\(needle)” appears \(hits.count) time\(hits.count == 1 ? "" : "s") in \(turns) turn\(turns == 1 ? "" : "s")"
                + (hits.first?.at.map { ", first at \(Format.dateTime($0))." } ?? ".")))
                .font(.system(size: 12.5))
                .padding(.horizontal, 12).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.panel, in: RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Metric.radius, style: .continuous).stroke(palette.ok))
            VStack(spacing: 0) {
                ForEach(Array(hits.prefix(12).enumerated()), id: \.offset) { _, hit in
                    HitLine(hit: hit) {
                        if let key = SessionModel.key(for: hit) { window.reveal(key, in: model, query: needle) }
                    }
                }
            }
            if hits.count > 12 {
                Button("\(hits.count - 12) more in the Transcript") {
                    if let key = hits.first.flatMap(SessionModel.key(for:)) { window.reveal(key, in: model, query: needle) }
                }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(palette.accent).padding(.leading, 10)
            }
        }
    }
}

/// One match: where, what kind, the words around it.
private struct HitLine: View {
    @Environment(\.palette) private var palette
    var hit: SearchHit
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Text(hit.turn >= 0 ? "turn \(hit.turn)" + (hit.action >= 0 ? " · a\(hit.action)" : "") : "session")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.muted).frame(width: 96, alignment: .leading)
            Badge(text: SearchKind.label(hit.kind), color: SearchKind.color(hit.kind, palette)).frame(width: 84, alignment: .leading)
            Text(Snippet.attributed(hit.snippet, palette: palette)).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 6)
            if let at = hit.at {
                Text(at.formatted(date: .omitted, time: .shortened)).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.muted)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(hover ? palette.panel : .clear, in: RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
    }
}

// MARK: What happened, when

/// One row per turn: what was asked, what the agent said when it stopped, what it wrote.
struct Digest: View {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var model: SessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WHAT HAPPENED, WHEN").font(.caps).tracking(0.9).foregroundStyle(palette.muted)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Self.lines(model)) { line in
                    switch line {
                    case .gap(_, let seconds):
                        Text("\(SessionModel.duration(seconds)) later").font(.label(11)).foregroundStyle(palette.muted)
                            .padding(.leading, 92).padding(.vertical, 2)
                    case .compaction(let index):
                        let cut = model.doc.compactions[index]
                        Label("context compacted · \(Format.tokens(cut.metadata?.preTokens ?? 0)) → \(Format.tokens(cut.metadata?.postTokens ?? 0))", systemImage: "scissors")
                            .font(.label(11)).foregroundStyle(palette.warn)
                            .padding(.leading, 92).padding(.vertical, 2)
                            .contentShape(Rectangle())
                            .onTapGesture { window.select(.compaction(index), in: model, scroll: false) }
                    case .turn(let index):
                        DigestRow(model: model, index: index)
                    }
                }
            }
            .padding(4)
            .background { Panel(shadow: palette.shadow.opacity(0.6), radius: 9, y: 6) }
        }
    }

    enum Line: Identifiable, Hashable {
        case gap(beforeTurn: Int, seconds: TimeInterval)
        case compaction(Int)
        case turn(Int)

        var id: String {
            switch self {
            case .gap(let turn, _): "g\(turn)"
            case .compaction(let n): "c\(n)"
            case .turn(let n): "t\(n)"
            }
        }
    }

    /// The turns in order, with a line where more than an hour passed and one where the context was cut.
    nonisolated static func lines(_ model: SessionModel) -> [Line] {
        var out: [Line] = []
        var nextCompaction = 0
        let cuts = model.doc.compactions
        for (i, turn) in model.doc.turns.enumerated() {
            if i > 0 {
                let gap = turn.startAt.timeIntervalSince(model.doc.turns[i - 1].endAt)
                if gap > 3600 { out.append(.gap(beforeTurn: turn.index, seconds: gap)) }
            }
            while nextCompaction < cuts.count, cuts[nextCompaction].at <= turn.startAt {
                out.append(.compaction(nextCompaction))
                nextCompaction += 1
            }
            out.append(.turn(turn.index))
        }
        while nextCompaction < cuts.count {
            out.append(.compaction(nextCompaction))
            nextCompaction += 1
        }
        return out
    }
}

private struct DigestRow: View {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var model: SessionModel
    var index: Int
    @State private var hover = false

    var body: some View {
        if let turn = model.turn(index) {
            let said = model.lastSaid(inTurn: index).map { SessionModel.firstLine($0.text, max: 170) } ?? ""
            HStack(alignment: .top, spacing: 12) {
                Text(turn.startAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.muted).frame(width: 70, alignment: .leading).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    if let prompt = model.prompt(ofTurn: index), turn.isHuman {
                        (Text("\(index)  ").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.muted)
                            + Text(SessionModel.firstLine(prompt.text, max: 130)).font(.system(size: 13)))
                            .lineLimit(1)
                        if !said.isEmpty { got(said) }
                        arts(turn)
                    } else {
                        Label(SessionModel.originLabel(turn.origin).lowercased() + (said.isEmpty ? "" : ": " + said), systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 12)).foregroundStyle(palette.muted).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(turn.actionIndexes.count) action\(turn.actionIndexes.count == 1 ? "" : "s")" + (turn.isHuman ? " · \(turn.toolCalls) call\(turn.toolCalls == 1 ? "" : "s")" : ""))
                    if turn.isHuman {
                        Text(SessionModel.duration(turn.duration))
                        if turn.rewound { Text("rewound") }
                    }
                }
                .font(.label(11)).foregroundStyle(palette.muted).frame(width: 150, alignment: .trailing)
            }
            .padding(.horizontal, 10).padding(.vertical, turn.isHuman ? 9 : 4)
            .background(hover ? palette.panel2 : .clear, in: RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { window.reveal(.turn(index), in: model) }
            .help("Read turn \(index) in the Transcript")
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
        }
    }

    private func got(_ said: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "text.bubble").font(.system(size: 10)).foregroundStyle(palette.ink)
            Text(said).font(.system(size: 12.5)).foregroundStyle(palette.ink2).lineLimit(1)
        }
    }

    /// The files the turn wrote, and how many of its calls failed.
    @ViewBuilder private func arts(_ turn: Turn) -> some View {
        let files = model.writtenByTurn[turn.index] ?? []
        let failed = turn.actionIndexes.compactMap { model.action($0) }.flatMap { model.tools(of: $0) }.filter(\.isError).count
        if !files.isEmpty || failed > 0 {
            HStack(spacing: 4) {
                ForEach(files.prefix(5), id: \.self) { path in
                    Text((path as NSString).lastPathComponent).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(palette.ink2)
                        .padding(.horizontal, 6).background(palette.panel2, in: RoundedRectangle(cornerRadius: 4))
                        .help(path)
                        .onTapGesture { window.select(.file(path), in: model, scroll: false) }
                }
                if files.count > 5 { chip("+\(files.count - 5)", palette.ink2) }
                if failed > 0 { chip("\(failed) failed", palette.err) }
            }
            .lineLimit(1).padding(.top, 2)
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(color)
            .padding(.horizontal, 6).background(palette.panel2, in: RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: When this session was alive

/// The minutes the agent was working, by day and hour of the day, in local time.
nonisolated struct HoursGrid: Equatable, Sendable {
    struct Day: Equatable, Sendable, Identifiable {
        var start: Date
        /// Minutes inside turns, by hour of the day.
        var minutes: [Int: Double] = [:]
        /// The turns that started in each hour.
        var turns: [Int: [Int]] = [:]
        var id: Date { start }
        var activeMinutes: Int { Int(minutes.values.reduce(0, +).rounded()) }
        var turnCount: Int { turns.values.reduce(0) { $0 + $1.count } }
    }

    var days: [Day]
    /// The hours shown: from an hour before the first active one to an hour after the last.
    var hours: ClosedRange<Int>

    init?(turns: [Turn], calendar: Calendar = .current) {
        var days: [Date: Day] = [:]
        for turn in turns {
            let day = calendar.startOfDay(for: turn.startAt)
            days[day, default: Day(start: day)].turns[calendar.component(.hour, from: turn.startAt), default: []].append(turn.index)
            // Walk the turn hour by hour: a long one is spread over the hours it covered.
            var at = turn.startAt
            while at < turn.endAt {
                let hourStart = calendar.dateInterval(of: .hour, for: at)?.end ?? at.addingTimeInterval(3600)
                let until = min(turn.endAt, hourStart)
                let key = calendar.startOfDay(for: at)
                days[key, default: Day(start: key)].minutes[calendar.component(.hour, from: at), default: 0] += until.timeIntervalSince(at) / 60
                at = until
            }
        }
        let used = days.values.flatMap { Array($0.minutes.keys) + Array($0.turns.keys) }
        guard let first = used.min(), let last = used.max() else { return nil }
        self.days = days.values.sorted { $0.start < $1.start }
        self.hours = max(0, first - 1)...min(23, last + 1)
    }
}

private struct HoursCard: View {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var model: SessionModel
    var grid: HoursGrid

    var body: some View {
        Card(title: "When this session was alive") {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(grid.days) { day in
                    (Text(day.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())).foregroundStyle(palette.ink2)
                        + Text(" · \(day.activeMinutes) min · \(day.turnCount) turn\(day.turnCount == 1 ? "" : "s")").foregroundStyle(palette.muted))
                        .font(.system(size: 11.5)).padding(.top, 6)
                    HStack(spacing: 3) {
                        ForEach(Array(grid.hours), id: \.self) { hour in cell(day, hour) }
                    }
                }
                HStack(spacing: 3) {
                    ForEach(Array(grid.hours), id: \.self) { hour in
                        Text(hour % 3 == 0 ? String(format: "%02d", hour) : " ").font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func cell(_ day: HoursGrid.Day, _ hour: Int) -> some View {
        let minutes = day.minutes[hour] ?? 0
        let turns = day.turns[hour] ?? []
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(palette.panel2)
            .overlay { RoundedRectangle(cornerRadius: 4, style: .continuous).fill(palette.accent.opacity(minutes > 0 ? min(1, minutes / 60 + 0.1) : 0)) }
            .overlay(alignment: .leading) {
                HStack(spacing: 2) {
                    ForEach(0..<min(3, turns.count), id: \.self) { _ in Circle().fill(palette.ink).frame(width: 5, height: 5) }
                }
                .padding(.leading, 3)
            }
            .frame(maxWidth: .infinity).frame(height: 18)
            .contentShape(Rectangle())
            .onTapGesture { if let first = turns.first { window.reveal(.turn(first), in: model) } }
            .help(String(format: "%02d:00 · %d active minute%@ · %d turn%@ started", hour, Int(minutes.rounded()), Int(minutes.rounded()) == 1 ? "" : "s", turns.count, turns.count == 1 ? "" : "s"))
    }
}

// MARK: Note

/// A note on the session as a whole, kept by the engine.
private struct SessionNote: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var palette
    var sessionID: String
    @State private var text = ""
    @State private var saved = ""

    var body: some View {
        Card(title: "Note") {
            TextField("Add a note on this session", text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...8)
                .onSubmit { save() }
            if text != saved {
                Button("Save") { save() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(palette.accent)
            }
        }
        .onAppear {
            saved = store.annotation(sessionID).notes["session"] ?? ""
            text = saved
        }
        .onDisappear { if text != saved { save() } }
    }

    private func save() {
        let (id, value) = (sessionID, text)
        saved = value
        Task { await store.setNote(id, key: "session", value) }
    }
}

// MARK: Parts

/// The large figure at the top of a card.
private struct Big: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.display(24)).tracking(-0.2).lineLimit(1).minimumScaleFactor(0.7) }
}

private struct Waiting: View {
    @Environment(\.palette) private var palette
    var body: some View { Text("Reading the session…").font(.system(size: 12)).foregroundStyle(palette.muted) }
}

/// A row of a card's list: an icon, a label, a figure at the right. With an
/// action it is a way to the node it names.
private struct ItemRow: View {
    @Environment(\.palette) private var palette
    var symbol: String
    var color: Color
    var label: String
    var trailing: String?
    var mono = false
    /// A path keeps both ends; a sentence keeps its start.
    var truncation = Text.TruncationMode.tail
    var help: String?
    var action: (() -> Void)?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(color).frame(width: 14)
            Text(label).font(.system(size: 12, design: mono ? .monospaced : .default)).foregroundStyle(palette.ink2).lineLimit(1).truncationMode(truncation)
            Spacer(minLength: 6)
            if let trailing { Text(trailing).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(palette.muted).fixedSize() }
        }
        .padding(.vertical, 4.5)
        .background(hover && action != nil ? palette.panel2 : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { action?() }
        .help(help ?? label)
        .accessibilityAddTraits(action != nil ? .isButton : [])
    }
}
