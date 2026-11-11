import SkitKit
import SwiftUI

/// Claude Code on this Mac (mock: `#/claude`): what is set and where it comes
/// from, which experiments this install is in, the cached flags, the projects
/// it knows, memory files and skills. Read-only: the engine reads Claude
/// Code's own files and never copies the account, tokens or ids.
struct ClaudePage: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette

    var body: some View {
        let state = window.claude
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Claude Code on this Mac").font(.display(28))
                switch store.claude {
                case .loaded(let snapshot):
                    Text(Self.stamp(snapshot, readAt: store.claudeReadAt)).font(.system(size: 13)).foregroundStyle(palette.muted)
                    HStack(spacing: 12) {
                        Picker("Show", selection: Binding(get: { state.tab }, set: { state.tab = $0 })) {
                            Text("Experiments \(snapshot.experiments.count)").tag(ClaudeTab.experiments)
                            Text("Settings \(snapshot.effective.count)").tag(ClaudeTab.settings)
                            Text("Flags \(snapshot.flags.count)").tag(ClaudeTab.flags)
                            Text("Projects \(snapshot.projects.count)").tag(ClaudeTab.projects)
                            Text("Memory and skills").tag(ClaudeTab.memory)
                            Text("State").tag(ClaudeTab.state)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        Spacer()
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(palette.muted)
                            TextField("Filter by name, id or value", text: Binding(get: { state.filter }, set: { state.filter = $0 }))
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
            .frame(maxWidth: Metric.wideColumn, alignment: .leading)
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            if case .loaded(let snapshot) = store.claude {
                ScrollView {
                    // One lazy stack: the flags alone are over a thousand rows.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        list(snapshot, state)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background { Panel(shadow: palette.shadow.opacity(0.6), radius: 9, y: 6) }
                    .frame(maxWidth: Metric.wideColumn, alignment: .leading)
                    .padding(.horizontal, 28).padding(.bottom, 60)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.bg)
        .task { await store.loadClaude() }
    }

    static func stamp(_ snapshot: ClaudeSnapshot, readAt: Date?) -> String {
        var parts = ["What is set, where it comes from, and which experiments this install is in. Read-only"]
        if let readAt { parts.append("read " + Format.dateTime(readAt)) }
        if let flags = snapshot.flagsCachedAt { parts.append("flags cached " + Format.dateTime(flags)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func list(_ snapshot: ClaudeSnapshot, _ state: ClaudeState) -> some View {
        let needle = state.filter.trimmingCharacters(in: .whitespaces).lowercased()
        switch state.tab {
        case .experiments:
            let rows = snapshot.experiments.filter { ClaudeContent.matches(needle, $0.experimentId, $0.flag, $0.value.compact) }
            HStack {
                Heading("Experiment assignments")
                Spacer()
                Button("copy all as id=variation") { Exporter.copy(snapshot.experiments.map(ClaudeContent.assignment).joined(separator: "\n")) }
                    .buttonStyle(.plain).foregroundStyle(palette.accent).font(.system(size: 12))
            }
            Columns(cells: [("EXPERIMENT ID", nil), ("FLAG IT DRIVES", 260), ("VARIATION", 90), ("VALUE IN EFFECT", 330), ("", 40)], header: true)
            ForEach(Array(rows.enumerated()), id: \.element.experimentId) { index, row in
                Line(index: index) {
                    HStack(spacing: 8) {
                        Text(row.experimentId).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1).textSelection(.enabled)
                        if !ClaudeContent.sameName(row.experimentId, row.flag) { Badge(text: "different name", color: palette.warn) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(row.flag).font(.system(size: 12, design: .monospaced)).foregroundStyle(palette.ink2).lineLimit(1).frame(width: 260, alignment: .leading)
                    Text(row.variationId == 0 ? "0 · control" : "\(row.variationId)").font(.system(size: 12.5)).frame(width: 90, alignment: .trailing)
                    ValueText(value: row.value).frame(width: 330, alignment: .leading)
                    Button("copy") { Exporter.copy(ClaudeContent.assignment(row)) }.buttonStyle(.plain).foregroundStyle(palette.accent).font(.system(size: 12)).frame(width: 40, alignment: .trailing)
                }
            }
            Note("These are the assignments Claude Code cached in ~/.claude.json. Variation 0 is the control group. When a session misbehaves, the id and the variation here are what to quote in a report. The app only reads; it cannot change an assignment.")
        case .settings:
            let rows = snapshot.effective.filter { ClaudeContent.matches(needle, $0.key, $0.value.compact, $0.from) }
            Heading("Settings in effect")
            Columns(cells: [("KEY", 300), ("VALUE", nil), ("FROM", 150), ("OVERRIDES", 190)], header: true)
            ForEach(Array(rows.enumerated()), id: \.element.key) { index, row in
                Line(index: index) {
                    Text(row.key).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1).frame(width: 300, alignment: .leading).textSelection(.enabled)
                    ValueText(value: row.value).frame(maxWidth: .infinity, alignment: .leading)
                    Text(row.from).font(.system(size: 12.5)).foregroundStyle(palette.ink2).lineLimit(1).frame(width: 150, alignment: .leading)
                    Text(row.also.joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(palette.muted).lineLimit(1).frame(width: 190, alignment: .leading)
                }
            }
            Heading("Layers, lowest precedence first").padding(.top, 14)
            ForEach(Array(snapshot.layers.enumerated()), id: \.element.path) { index, layer in
                Line(index: index) {
                    Badge(text: layer.exists ? "present" : "absent", color: layer.exists ? palette.ok : palette.muted).frame(width: 80, alignment: .leading)
                    Text(layer.name).font(.system(size: 12.5, weight: .semibold)).frame(width: 190, alignment: .leading)
                    Text(Format.homeRelative(layer.path)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(palette.ink2).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    Text(layer.modified.map { Format.dateTime($0) } ?? "").font(.system(size: 12)).foregroundStyle(palette.muted).frame(width: 130, alignment: .trailing)
                }
            }
            Note("Managed policy and command-line flags cannot be read from here.")
        case .flags:
            let rows = snapshot.flags.filter { ClaudeContent.matches(needle, $0.key, $0.value.compact) }
            Heading(needle.isEmpty ? "Cached feature flags" : "\(rows.count) of \(snapshot.flags.count) flags")
            Columns(cells: [("FLAG", 420), ("VALUE", nil)], header: true)
            ForEach(Array(rows.enumerated()), id: \.element.key) { index, row in
                Line(index: index) {
                    HStack(spacing: 8) {
                        Text(row.key).font(.system(size: 12, design: .monospaced)).lineLimit(1).textSelection(.enabled)
                        if row.inExperiment == true { Badge(text: "experiment", color: palette.accent) }
                    }
                    .frame(width: 420, alignment: .leading)
                    ValueText(value: row.value).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .projects:
            let rows = snapshot.projects.filter { ClaudeContent.matches(needle, $0.path, $0.mcpServers.joined(separator: " ")) }
            Heading("Projects Claude Code knows")
            Columns(cells: [("DIRECTORY", nil), ("TRUSTED", 80), ("ALLOWED TOOLS", 110), ("CONNECTORS", 320)], header: true)
            ForEach(Array(rows.enumerated()), id: \.element.path) { index, row in
                Line(index: index) {
                    Text(Format.homeRelative(row.path)).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    Text(row.trusted ? "yes" : "no").font(.system(size: 12.5)).foregroundStyle(row.trusted ? palette.ink : palette.muted).frame(width: 80, alignment: .leading)
                    Text("\(row.allowedTools)").font(.system(size: 12.5)).monospacedDigit().frame(width: 110, alignment: .leading)
                    Text(row.mcpServers.joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(palette.ink2).lineLimit(1).frame(width: 320, alignment: .leading)
                }
            }
            if !snapshot.connectors.isEmpty {
                Note("Connectors seen across projects: " + snapshot.connectors.joined(separator: ", ") + ".")
            }
        case .memory:
            let files = snapshot.memory.filter { ClaudeContent.matches(needle, $0.path) }
            Heading("Memory files")
            Columns(cells: [("FILE", nil), ("LINES", 70), ("SIZE", 80), ("CHANGED", 130)], header: true)
            ForEach(Array(files.enumerated()), id: \.element.path) { index, file in
                Line(index: index) {
                    Text(Format.homeRelative(file.path)).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    Text("\(file.lines)").font(.system(size: 12.5)).monospacedDigit().frame(width: 70, alignment: .trailing)
                    Text(FilesContent.bytes(file.bytes)).font(.system(size: 12.5)).monospacedDigit().frame(width: 80, alignment: .trailing)
                    Text(Format.dateTime(file.modified)).font(.system(size: 12)).foregroundStyle(palette.muted).frame(width: 130, alignment: .trailing)
                }
            }
            let skills = snapshot.skills.filter { ClaudeContent.matches(needle, $0.name, $0.path ?? "") }
            Heading("Skills").padding(.top, 14)
            Columns(cells: [("SKILL", 280), ("WHERE", nil), ("USED", 70), ("ON DISK", 80)], header: true)
            ForEach(Array(skills.enumerated()), id: \.element.name) { index, skill in
                Line(index: index) {
                    Text(skill.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).frame(width: 280, alignment: .leading)
                    Text(skill.path.map { Format.homeRelative($0) } ?? "").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(palette.ink2).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    Text(skill.uses.map { "\($0)×" } ?? "").font(.system(size: 12.5)).monospacedDigit().frame(width: 70, alignment: .trailing)
                    Text(skill.onDisk ? "yes" : "no").font(.system(size: 12.5)).foregroundStyle(skill.onDisk ? palette.ink : palette.muted).frame(width: 80, alignment: .trailing)
                }
            }
        case .state:
            let keys = (snapshot.state ?? [:]).keys.sorted().filter { ClaudeContent.matches(needle, $0, snapshot.state?[$0]?.compact ?? "") }
            Heading("What Claude Code remembers about itself")
            Columns(cells: [("KEY", 340), ("VALUE", nil)], header: true)
            ForEach(Array(keys.enumerated()), id: \.element) { index, key in
                Line(index: index) {
                    Text(key).font(.system(size: 12, design: .monospaced)).lineLimit(1).frame(width: 340, alignment: .leading).textSelection(.enabled)
                    ValueText(value: snapshot.state?[key] ?? .null).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            let identity = (snapshot.identity ?? [:]).keys.sorted()
            if !identity.isEmpty {
                Heading("Identity").padding(.top, 14)
                ForEach(Array(identity.enumerated()), id: \.element) { index, key in
                    Line(index: index) {
                        Text(key).font(.system(size: 12, design: .monospaced)).frame(width: 340, alignment: .leading)
                        Text(snapshot.identity?[key] ?? "").font(.system(size: 12.5)).foregroundStyle(palette.ink2).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Note("The account, the tokens and the ids are never copied: the engine says only whether each is set.")
            }
        }
    }
}

/// What the Claude page matches and writes out.
nonisolated enum ClaudeContent {
    /// Whether any of the texts holds the filter (already lowercased); an empty filter matches everything.
    static func matches(_ needle: String, _ texts: String...) -> Bool {
        needle.isEmpty || texts.contains { $0.lowercased().contains(needle) }
    }

    /// "tengu_amber_prism=0": what to quote in a report.
    static func assignment(_ experiment: ClaudeSnapshot.Experiment) -> String {
        "\(experiment.experimentId)=\(experiment.variationId)"
    }

    /// An experiment usually carries its flag's name, sometimes with "_experiment" after it.
    /// One that does not is worth a mark: its id says nothing about what it drives.
    static func sameName(_ experiment: String, _ flag: String) -> Bool {
        experiment == flag || experiment == flag + "_experiment"
    }
}

private struct Heading: View {
    @Environment(\.palette) private var palette
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text.uppercased()).font(.caps).tracking(0.9).foregroundStyle(palette.muted).padding(.bottom, 8) }
}

private struct Note: View {
    @Environment(\.palette) private var palette
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
    }
}

/// The headings of a table: a width per column, nil for the one that takes what is left.
private struct Columns: View {
    @Environment(\.palette) private var palette
    var cells: [(String, CGFloat?)]
    var header: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                    Text(cell.0).font(.caps).tracking(0.7).foregroundStyle(palette.muted).lineLimit(1)
                        .frame(maxWidth: cell.1 == nil ? .infinity : nil, alignment: .leading)
                        .frame(width: cell.1, alignment: cell.0 == "VARIATION" || ["LINES", "SIZE", "CHANGED", "USED", "ON DISK"].contains(cell.0) ? .trailing : .leading)
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 6)
            Rectangle().fill(palette.line2).frame(height: 1)
        }
    }
}

private struct Line<Content: View>: View {
    @Environment(\.palette) private var palette
    var index: Int
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) { content }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(index.isMultiple(of: 2) ? palette.panel2.opacity(0.35) : .clear)
    }
}

/// A value as Claude Code holds it: on or off for a switch, the text or the number, compact JSON for anything larger.
private struct ValueText: View {
    @Environment(\.palette) private var palette
    var value: JSONValue

    var body: some View {
        if let flag = value.bool {
            Badge(text: flag ? "on" : "off", color: flag ? palette.ok : palette.muted)
        } else {
            Text(value.compact).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(palette.ink2).lineLimit(3).textSelection(.enabled)
        }
    }
}
