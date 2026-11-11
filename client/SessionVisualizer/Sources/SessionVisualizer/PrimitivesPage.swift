import SkitKit
import SwiftUI

/// What Claude Code is extended with on this Mac (M22; there is no mock for
/// it): skills, agents, slash commands, connectors, hooks, plugins, and the
/// instructions and memory files. A list by kind, with where each is defined
/// and how much the sessions kept here used it; the selected one on the right
/// with its definitions, its use by project and the sessions that used it.
/// Every figure is the engine's (`skit primitives`).
struct PrimitivesPage: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette

    var body: some View {
        let state = window.primitives
        let loaded = store.primitives[state.period.rawValue]
        VStack(alignment: .leading, spacing: 0) {
            header(loaded, state)
                .frame(maxWidth: Metric.wideColumn, alignment: .leading)
                .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 12)
                .frame(maxWidth: .infinity)
            if case .loaded(let report) = loaded {
                let rows = PrimitivesContent.rows(report, kind: state.kind, filter: state.filter, unusedOnly: state.unusedOnly)
                let selected = rows.first { $0.name == state.selected[state.kind] } ?? rows.first
                HStack(alignment: .top, spacing: 14) {
                    list(rows, report, state, selected: selected)
                    if let selected {
                        PrimitiveDetail(item: selected, days: state.period.days)
                            .frame(width: 390)
                            .id(selected.id)
                    }
                }
                .frame(maxWidth: Metric.wideColumn, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 28).padding(.bottom, 22)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.bg)
        .task(id: state.period) { await store.loadPrimitives(days: state.period.days) }
    }

    @ViewBuilder private func header(_ loaded: Loadable<PrimitivesReport>?, _ state: PrimitivesState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What Claude Code is extended with").font(.display(28))
            switch loaded {
            case .loaded(let report):
                Text(PrimitivesContent.stamp(report)).font(.system(size: 13)).foregroundStyle(palette.muted)
                HStack(spacing: 12) {
                    Picker("Kind", selection: Binding(get: { state.kind }, set: { state.kind = $0 })) {
                        ForEach(report.kinds, id: \.kind) { kind in
                            Text("\(PrimitivesContent.title(kind.kind)) \(kind.items)").tag(kind.kind)
                        }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                }
                HStack(spacing: 12) {
                    Picker("Counting", selection: Binding(get: { state.period }, set: { state.period = $0 })) {
                        ForEach(PrimitivesPeriod.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Toggle("Only what was not used", isOn: Binding(get: { state.unusedOnly }, set: { state.unusedOnly = $0 }))
                        .toggleStyle(.checkbox).font(.system(size: 12.5))
                        .disabled(!PrimitivesContent.countsUnused(state.kind))
                        .help(PrimitivesContent.countsUnused(state.kind) ? "Keep what is installed or was on offer to a session, and was not used in the period" : "Not told for this kind: a hook that runs quietly leaves no trace, and a plugin is used through what it brings")
                    if let count = report.kinds.first(where: { $0.kind == state.kind }) {
                        Text(PrimitivesContent.summary(count)).font(.system(size: 12.5)).foregroundStyle(palette.muted)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(palette.muted)
                        TextField("Filter by name, place or description", text: Binding(get: { state.filter }, set: { state.filter = $0 }))
                            .textFieldStyle(.plain).font(.system(size: 12.5))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6).frame(width: 260)
                    .background(palette.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            case .failed(let why):
                Text(why).foregroundStyle(palette.err)
            case .loading, nil:
                ProgressView().controlSize(.small)
            }
        }
    }

    private func list(_ rows: [PrimitivesReport.Item], _ report: PrimitivesReport, _ state: PrimitivesState, selected: PrimitivesReport.Item?) -> some View {
        ScrollView {
            // One lazy stack: memory files alone can be hundreds of rows.
            LazyVStack(alignment: .leading, spacing: 0) {
                ListHeader()
                if rows.isEmpty {
                    Text(PrimitivesContent.nothing(kind: state.kind, filtered: !state.filter.isEmpty || state.unusedOnly))
                        .font(.system(size: 12.5)).foregroundStyle(palette.muted).padding(.horizontal, 8).padding(.vertical, 14)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                    ListRow(item: item, index: index, selected: item.id == selected?.id) { state.selected[state.kind] = item.name }
                        .contextMenu { fileMenu(item.definitions.first?.path) }
                }
                Text(PrimitivesContent.lookedIn(report)).font(.system(size: 11.5)).foregroundStyle(palette.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8).padding(.top, 14)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .background { Panel(shadow: palette.shadow.opacity(0.6), radius: 9, y: 6) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Open, reveal, copy: what a definition's file can be asked for.
@ViewBuilder private func fileMenu(_ path: String?) -> some View {
    if let path, !path.isEmpty {
        FileOpener.buttons(path, with: FileOpener.setting)
        Button("Copy Path") { Exporter.copy(path) }
    }
}

private struct ListHeader: View {
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                cell("NAME", nil, .leading)
                cell("DEFINED", 170, .leading)
                cell("USES", 56, .trailing)
                cell("FAILED", 52, .trailing)
                cell("SESSIONS", 64, .trailing)
                cell("LAST USED", 118, .trailing)
            }
            .padding(.horizontal, 8).padding(.bottom, 6)
            Rectangle().fill(palette.line2).frame(height: 1)
        }
    }

    private func cell(_ text: String, _ width: CGFloat?, _ alignment: Alignment) -> some View {
        Text(text).font(.caps).tracking(0.7).foregroundStyle(palette.muted).lineLimit(1)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
            .frame(width: width, alignment: alignment)
    }
}

private struct ListRow: View {
    @Environment(\.palette) private var palette
    var item: PrimitivesReport.Item
    var index: Int
    var selected: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        let used = item.usage.calls > 0
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(spacing: 7) {
                    // A path is told apart by its end, a name by its start.
                    Text(PrimitivesContent.name(item)).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(item.kind == "instructions" ? .head : .tail)
                        .foregroundStyle(used || !PrimitivesContent.countsUnused(item.kind) ? palette.ink : palette.ink2)
                    if item.definitions.count > 1 { Badge(text: "\(item.definitions.count) places", color: palette.accent) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(PrimitivesContent.place(item)).font(.system(size: 12)).foregroundStyle(item.installed ? palette.ink2 : palette.muted)
                    .lineLimit(1).truncationMode(.middle).frame(width: 170, alignment: .leading)
                Text(used ? "\(item.usage.calls)" : "").font(.system(size: 12.5)).monospacedDigit().frame(width: 56, alignment: .trailing)
                Text(item.usage.errors > 0 ? "\(item.usage.errors)" : "").font(.system(size: 12.5)).monospacedDigit().foregroundStyle(palette.err).frame(width: 52, alignment: .trailing)
                Text(used ? "\(item.usage.sessions)" : "").font(.system(size: 12.5)).monospacedDigit().frame(width: 64, alignment: .trailing)
                Text(PrimitivesContent.lastUsed(item)).font(.system(size: 12)).foregroundStyle(palette.muted).lineLimit(1).frame(width: 118, alignment: .trailing)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(selected ? palette.accentSoft : hover ? palette.panel2.opacity(0.6) : index.isMultiple(of: 2) ? palette.panel2.opacity(0.35) : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(item.kind == "instructions" || item.kind == "memory" ? item.name : (item.description ?? item.name))
    }
}

/// One primitive, on the right: what it is, where it is defined, how it was used and by which sessions.
private struct PrimitiveDetail: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var item: PrimitivesReport.Item
    var days: Int?

    var body: some View {
        let key = AppStore.primitiveKey(kind: item.kind, name: item.name, days: days)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                title
                if let description = item.description, !description.isEmpty {
                    Text(description).font(.system(size: 12.5)).foregroundStyle(palette.ink2).lineLimit(9).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                use
                definitions
                if !item.usage.projects.isEmpty { projects }
                sessions(store.primitiveDetails[key])
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background { Panel(shadow: palette.shadow.opacity(0.6), radius: 9, y: 6) }
        .frame(maxHeight: .infinity, alignment: .top)
        .task(id: key) {
            // Only what was used has sessions to list.
            if item.usage.calls > 0 { await store.loadPrimitive(kind: item.kind, name: item.name, days: days) }
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(PrimitivesContent.name(item)).font(.display(19)).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
            HStack(spacing: 6) {
                Badge(text: PrimitivesContent.singular(item.kind), color: palette.accent)
                if item.builtIn == true { Badge(text: "built in", color: palette.muted) }
                if !item.installed && item.builtIn != true { Badge(text: "not on disk", color: palette.muted) }
                if PrimitivesContent.unused(item) { Badge(text: item.lastUsedAt == nil ? "never used" : "not used in this period", color: palette.muted) }
                if item.title != nil { Text(item.name).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.muted).lineLimit(1) }
            }
        }
    }

    @ViewBuilder private var use: some View {
        let usage = item.usage
        VStack(alignment: .leading, spacing: 8) {
            Caps("Use")
            let figures = PrimitivesContent.figures(item)
            if !figures.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: 3), alignment: .leading, spacing: 10) {
                    ForEach(figures, id: \.label) { figure in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(figure.value).font(.system(size: 17, weight: .semibold)).monospacedDigit().foregroundStyle(figure.bad ? palette.err : palette.ink).lineLimit(1).minimumScaleFactor(0.7)
                            Text(figure.label.uppercased()).font(.caps).tracking(0.6).foregroundStyle(palette.muted).lineLimit(1)
                        }
                    }
                }
            }
            if usage.days.count > 1 {
                let bars = PrimitivesContent.bars(usage.days)
                DayBars(values: bars.values).frame(height: 34)
                Text("\(bars.from) to \(bars.to), \(bars.weekly ? "a bar a week" : "a bar a day")").font(.system(size: 11)).foregroundStyle(palette.muted)
            }
            ForEach(PrimitivesContent.notes(item), id: \.self) { note in
                Text(note).font(.system(size: 11.5)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var definitions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caps(item.definitions.count > 1 ? "Defined in \(item.definitions.count) places" : "Defined")
            if item.definitions.isEmpty {
                Text(PrimitivesContent.undefined(item)).font(.system(size: 12)).foregroundStyle(palette.ink2).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(item.definitions.enumerated()), id: \.offset) { index, definition in
                DefinitionRow(item: item, definition: definition, first: index == 0)
            }
            if let order = PrimitivesContent.orderNote(item) {
                Text(order).font(.system(size: 11.5)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var projects: some View {
        VStack(alignment: .leading, spacing: 4) {
            Caps("By project")
            ForEach(item.usage.projects, id: \.project) { project in
                HStack(spacing: 8) {
                    Text(Format.projectName(cwd: project.cwd, slug: project.project)).font(.system(size: 12.5)).lineLimit(1).truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading).help(project.cwd ?? project.project)
                    Text(PrimitivesContent.count(project.sessions, "session")).font(.system(size: 12)).foregroundStyle(palette.muted)
                    Text(PrimitivesContent.count(project.calls, PrimitivesContent.noun(item.kind))).font(.system(size: 12.5)).monospacedDigit().frame(width: 70, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder private func sessions(_ loaded: Loadable<PrimitivesReport.Item>?) -> some View {
        if item.usage.calls > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Caps("Sessions that used it · \(item.usage.sessions)")
                switch loaded {
                case .loaded(let detail):
                    ForEach(detail.sessions) { session in
                        SessionRow(use: session, kind: item.kind) {
                            // The turn of the first use; a use outside any turn opens the session where it starts.
                            window.open(session: session.session, at: session.turn >= 0 ? .turn(session.turn) : nil, view: .transcript)
                        }
                    }
                case .failed(let why):
                    Text(why).font(.system(size: 12)).foregroundStyle(palette.err)
                case .loading, nil:
                    ProgressView().controlSize(.small)
                }
            }
        }
    }
}

private struct Caps: View {
    @Environment(\.palette) private var palette
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text.uppercased()).font(.caps).tracking(0.9).foregroundStyle(palette.muted) }
}

private struct DefinitionRow: View {
    @Environment(\.palette) private var palette
    var item: PrimitivesReport.Item
    var definition: PrimitivesReport.Definition
    var first: Bool
    @State private var hover = false

    var body: some View {
        let path = definition.path ?? ""
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(PrimitivesContent.scope(definition, kind: item.kind)).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                if item.definitions.count > 1, first, item.order != "merged" { Badge(text: "comes first", color: palette.ok) }
                Spacer(minLength: 4)
                if let calls = definition.calls, calls > 0 {
                    Text(PrimitivesContent.count(calls, "use") + " of this one").font(.system(size: 11.5)).foregroundStyle(palette.muted)
                }
            }
            if !path.isEmpty {
                Text(Format.homeRelative(path)).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.ink2).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            ForEach(PrimitivesContent.details(definition), id: \.self) { line in
                Text(line).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(palette.muted).lineLimit(3).textSelection(.enabled)
            }
            if let modified = definition.modified, PrimitivesContent.ownFile(item.kind) {
                Text("changed " + Format.dateTime(modified) + (definition.bytes.map { " · " + FilesContent.bytes($0) } ?? "")).font(.system(size: 11)).foregroundStyle(palette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(hover && !path.isEmpty ? palette.panel2.opacity(0.7) : palette.panel2.opacity(0.4), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { if !path.isEmpty { FileOpener.open(path, with: FileOpener.setting) } }
        .contextMenu { fileMenu(definition.path) }
        .help(path.isEmpty ? "" : "Double-click to open in the application chosen in Settings; right-click for more")
    }
}

private struct SessionRow: View {
    @Environment(\.palette) private var palette
    var use: PrimitivesReport.SessionUse
    var kind: String
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(use.title.isEmpty ? Format.shortID(use.session) : use.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                Text(PrimitivesContent.line(use, kind: kind)).font(.system(size: 11.5)).foregroundStyle(palette.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(hover ? palette.panel2.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(use.turn >= 0 ? "Open the session at the turn that first used it" : "Open the session")
    }
}

/// Uses over time: a bar a day (or a week), the tallest the busiest.
private struct DayBars: View {
    @Environment(\.palette) private var palette
    var values: [Int]

    var body: some View {
        Canvas { g, size in
            guard let most = values.max(), most > 0, !values.isEmpty else { return }
            let step = size.width / CGFloat(values.count)
            let width = max(1, min(12, step - 1))
            var bars = Path(), floor = Path()
            for (i, value) in values.enumerated() {
                let x = CGFloat(i) * step
                if value == 0 {
                    floor.addRect(CGRect(x: x, y: size.height - 1, width: width, height: 1))
                } else {
                    let tall = max(2, CGFloat(value) / CGFloat(most) * size.height)
                    bars.addRect(CGRect(x: x, y: size.height - tall, width: width, height: tall))
                }
            }
            g.fill(floor, with: .color(palette.line2))
            g.fill(bars, with: .color(palette.accent.opacity(0.85)))
        }
        .accessibilityHidden(true)
    }
}

/// What the Primitives page lists, in what order, and the words it uses.
nonisolated enum PrimitivesContent {
    static func title(_ kind: String) -> String {
        switch kind {
        case "skill": "Skills"
        case "agent": "Agents"
        case "command": "Commands"
        case "connector": "Connectors"
        case "hook": "Hooks"
        case "plugin": "Plugins"
        case "instructions": "Instructions"
        case "memory": "Memory"
        default: kind.capitalized
        }
    }

    static func singular(_ kind: String) -> String {
        switch kind {
        case "instructions": "instructions"
        case "memory": "memory note"
        default: kind
        }
    }

    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// What one use is called: a memory file is loaded some number of times, anything else is used.
    static func noun(_ kind: String) -> String { kind == "instructions" || kind == "memory" ? "time" : "use" }

    /// The engine does not say "unused" of a hook (a quiet one leaves no trace) or of a plugin.
    static func countsUnused(_ kind: String) -> Bool { kind != "hook" && kind != "plugin" }

    /// Kinds whose definition is a file of its own, so its date and size say something.
    static func ownFile(_ kind: String) -> Bool { ["skill", "agent", "command", "instructions", "memory"].contains(kind) }

    /// There to be used (installed, or on offer to a session) and not used in the period.
    static func unused(_ item: PrimitivesReport.Item) -> Bool {
        countsUnused(item.kind) && (item.installed || item.usage.offeredSessions > 0) && item.usage.calls == 0
    }

    /// The items of a kind: the most used first, then what more sessions had on offer, then by name.
    static func rows(_ report: PrimitivesReport, kind: String, filter: String, unusedOnly: Bool) -> [PrimitivesReport.Item] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return report.items
            .filter { $0.kind == kind && (!unusedOnly || unused($0)) }
            .filter { item in
                needle.isEmpty || ([item.name, item.title ?? "", item.description ?? "", place(item)] + item.definitions.compactMap(\.path)).contains { $0.lowercased().contains(needle) }
            }
            .sorted { a, b in
                if a.usage.calls != b.usage.calls { return a.usage.calls > b.usage.calls }
                if a.usage.offeredSessions != b.usage.offeredSessions { return a.usage.offeredSessions > b.usage.offeredSessions }
                if a.installed != b.installed { return a.installed }
                return name(a).localizedCaseInsensitiveCompare(name(b)) == .orderedAscending
            }
    }

    static func stamp(_ report: PrimitivesReport) -> String {
        let sessions = PrimitivesContent.count(report.sessions, "session")
        let period = report.since.map { "active since " + Format.dateTime($0) } ?? "kept here"
        return "Where each skill, agent, command, connector, hook and memory file is defined, and how much the \(sessions) \(period) used it. Read-only."
    }

    /// "19 installed · 4 used · 33 there and not used".
    static func summary(_ count: PrimitivesReport.KindCount) -> String {
        var parts = ["\(count.installed) installed", "\(count.used) used"]
        if countsUnused(count.kind) { parts.append("\(count.unused) there and not used") }
        return parts.joined(separator: " · ")
    }

    static func nothing(kind: String, filtered: Bool) -> String {
        if filtered { return "Nothing matches." }
        return "No \(title(kind).lowercased()) are installed, and no session kept here used or was offered any."
    }

    static func lookedIn(_ report: PrimitivesReport) -> String {
        guard !report.lookedIn.isEmpty else { return "Nothing was found on disk." }
        return "Found in: " + report.lookedIn.map { Format.homeRelative($0) }.joined(separator: ", ")
            + ". The projects are the ones sessions started in and the ones Claude Code remembers, with the folders up to two levels below them. Use is counted from archived sessions."
    }

    /// The name to show: a connector as a person wrote it, a memory file by its path or its file name.
    static func name(_ item: PrimitivesReport.Item) -> String {
        switch item.kind {
        case "instructions": Format.homeRelative(item.name)
        case "memory": item.name.split(separator: "/").last.map(String.init) ?? item.name
        default: item.title ?? item.name
        }
    }

    /// Where an item is defined, in a few words; "+1" when in more than one place.
    static func place(_ item: PrimitivesReport.Item) -> String {
        guard let first = item.definitions.first else { return item.builtIn == true ? "Built into Claude Code" : "Not on disk" }
        return scope(first, kind: item.kind) + (item.definitions.count > 1 ? " +\(item.definitions.count - 1)" : "")
    }

    /// Whose a definition is.
    static func scope(_ definition: PrimitivesReport.Definition, kind: String) -> String {
        let place = definition.where ?? ""
        // A memory note's project is the slug Claude Code files it under; a directory otherwise.
        let project = place.hasPrefix("/") ? (place.split(separator: "/").last.map(String.init) ?? place) : ClaudeContent.projectName(place)
        switch definition.scope {
        case "user": return "You, in every project"
        case "account": return "Your claude.ai account"
        case "managed": return "Your organisation"
        case "plugin": return "Plugin " + place
        case "project": return "Project " + project
        case "local": return "You, in " + project
        default: return definition.scope
        }
    }

    /// What is particular to a definition, a line each: "runs gofmt -l .", "stdio · notes-mcp".
    static func details(_ definition: PrimitivesReport.Definition) -> [String] {
        guard let detail = definition.detail else { return [] }
        var out: [String] = []
        if let command = detail["command"] { out.append("runs " + command) }
        let reach = [detail["transport"], detail["host"], detail["program"]].compactMap { $0 }
        if !reach.isEmpty { out.append(reach.joined(separator: " · ")) }
        let plugin = [detail["version"].map { "version " + $0 }, detail["enabled"].map { $0 == "yes" ? "enabled" : "disabled" }].compactMap { $0 }
        if !plugin.isEmpty { out.append(plugin.joined(separator: " · ")) }
        return out
    }

    /// When no definition was found.
    static func undefined(_ item: PrimitivesReport.Item) -> String {
        if item.builtIn == true { return "Built into Claude Code: there is no file for it." }
        switch item.kind {
        case "command": return "No file defines it. Claude Code's own commands (/compact, /model) have none; a command of yours would be gone from where it was."
        case "connector": return "No configuration names it. An editor's own connector has none; one of yours would have been removed."
        case "hook": return "It ran, and no settings file here configures it: an editor or a plugin added it."
        case "instructions", "memory": return "A session loaded it, and it is not there any more."
        default: return "No definition was found. It comes with Claude Code, or it was defined somewhere that is gone."
        }
    }

    /// How Claude Code chooses, when an item is defined more than once.
    static func orderNote(_ item: PrimitivesReport.Item) -> String? {
        guard item.definitions.count > 1 else { return nil }
        switch item.order {
        case "user-first": return "Where more than one applies, Claude Code takes the first: your organisation's, then yours, then the project's."
        case "project-first": return "Where more than one applies, Claude Code takes the first: your organisation's, then the project's, then yours, then a plugin's."
        case "local-first": return "Where more than one applies, Claude Code takes the first: yours for that project, then the project's, then yours, then a plugin's, then your account's."
        default: return "All of them apply together."
        }
    }

    struct Figure: Equatable {
        var label: String
        var value: String
        var bad = false
    }

    /// The numbers of an item's use that say something for its kind.
    static func figures(_ item: PrimitivesReport.Item) -> [Figure] {
        let usage = item.usage
        var out: [Figure] = []
        if usage.calls > 0 {
            out.append(Figure(label: item.kind == "instructions" || item.kind == "memory" ? "times loaded" : "uses", value: "\(usage.calls)"))
            out.append(Figure(label: "sessions", value: "\(usage.sessions)"))
            if item.kind == "skill" || item.kind == "command" {
                out.append(Figure(label: "typed by you", value: "\(usage.byUser)"))
                if item.kind == "skill" { out.append(Figure(label: "by the model", value: "\(usage.calls - usage.byUser)")) }
            }
            if usage.errors > 0 { out.append(Figure(label: "failed", value: "\(usage.errors)", bad: true)) }
            if usage.seconds >= 1 { out.append(Figure(label: item.kind == "agent" ? "running" : "waiting", value: duration(usage.seconds))) }
            if usage.outputTokens > 0 { out.append(Figure(label: "output tokens", value: Format.tokens(usage.outputTokens))) }
        }
        if usage.offeredSessions > 0 { out.append(Figure(label: "sessions offered", value: "\(usage.offeredSessions)")) }
        return out
    }

    /// What the figures cannot say by themselves.
    static func notes(_ item: PrimitivesReport.Item) -> [String] {
        var out: [String] = []
        let usage = item.usage
        if usage.calls == 0 {
            if let last = item.lastUsedAt {
                out.append("Not used in this period. Last used \(Format.dateTime(last)).")
            } else if item.kind == "hook" {
                out.append("No session recorded it. A hook leaves a trace only when it says something back.")
            } else if item.kind == "plugin" {
                out.append("A plugin is used through the skills, agents, commands, hooks and connectors it brings: look for its name under those.")
            } else if usage.offeredSessions > 0 {
                out.append("On offer and never used in the sessions kept here.")
            } else if item.installed {
                out.append(item.kind == "memory" ? "No session kept here read it back." : "No session kept here used it or had it on offer.")
            }
        }
        if let counter = item.counter {
            var line = "Claude Code's own counter says \(counter.uses)"
            if let last = counter.lastUsedAt { line += ", last on \(Format.dateTime(last))" }
            line += ". It counts on this Mac since it began counting, sessions no longer kept included, so the two can differ."
            out.append(line)
        }
        if item.kind == "memory", usage.calls > 0 { out.append("A note counts when a session loaded it or read it back.") }
        return out
    }

    /// "never", "before this period", or the moment.
    static func lastUsed(_ item: PrimitivesReport.Item) -> String {
        if let last = item.usage.lastAt { return Format.dateTime(last) }
        if item.lastUsedAt != nil { return "before this period" }
        return countsUnused(item.kind) ? "never" : ""
    }

    /// "Nov 9, 9:00 AM · 2 uses · 1 typed · 1 failed".
    static func line(_ use: PrimitivesReport.SessionUse, kind: String) -> String {
        var parts = [Format.dateTime(use.lastAt), count(use.calls, noun(kind))]
        if use.byUser > 0 { parts.append("\(use.byUser) typed") }
        if use.errors > 0 { parts.append("\(use.errors) failed") }
        return parts.joined(separator: " · ")
    }

    /// 45s, 3m 56s, 2h 05m.
    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(String(format: "%02d", s % 3600 / 60))m"
    }

    /// The days of use as bars from the first to the last, empty days included; a bar a week when that is more than 120 days.
    static func bars(_ days: [PrimitivesReport.DayUse]) -> (values: [Int], from: String, to: String, weekly: Bool) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let format = DateFormatter()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd"
        let dated = days.compactMap { day in format.date(from: day.day).map { ($0, day.calls) } }.sorted { $0.0 < $1.0 }
        guard let first = dated.first?.0, let last = dated.last?.0 else { return ([], "", "", false) }
        let span = (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
        let weekly = span > 120
        var values = [Int](repeating: 0, count: weekly ? (span + 6) / 7 : span)
        for (date, calls) in dated {
            let offset = calendar.dateComponents([.day], from: first, to: date).day ?? 0
            values[weekly ? offset / 7 : offset] += calls
        }
        return (values, days.map(\.day).min() ?? "", days.map(\.day).max() ?? "", weekly)
    }
}
