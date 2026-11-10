import SkitKit
import SwiftUI

/// Home: every session on this Mac, newest first, pinned ones on top
/// (mock: `#/sessions`).
struct SessionsView: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    @AppStorage(SettingsKey.sessionSort) private var sort = SessionSort.newest
    /// The clock the page was drawn at; a fixed one makes a snapshot repeatable.
    var now = Date()

    var body: some View {
        let rows = window.rows(in: store, sort: sort)
        let projects = window.projects(in: store)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hello
                chips(projects)
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        SessionRow(session: row, now: now)
                    }
                }
                if rows.isEmpty {
                    Text(store.sessions.isEmpty ? "No sessions yet. Start Claude Code in any directory and it will appear here." : "No session matches this filter.")
                        .foregroundStyle(palette.muted).padding(.vertical, 24).padding(.horizontal, 12)
                }
                Text(footline(rows.count, projects.count))
                    .font(.label()).foregroundStyle(palette.muted)
                    .frame(maxWidth: .infinity).padding(.top, 22)
            }
            .frame(maxWidth: Metric.column)
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 60)
            .frame(maxWidth: .infinity)
        }
        .background(palette.bg)
    }

    private var hello: some View {
        HStack(alignment: .bottom, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Format.greeting(hour: Calendar.current.component(.hour, from: now))), \(firstName)")
                    .font(.display(30)).tracking(-0.3)
                Text(runningLine).foregroundStyle(palette.muted)
            }
            Spacer()
            Text(now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()).uppercased())
                .font(.caps).tracking(1.1).foregroundStyle(palette.muted)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: Metric.radius, style: .continuous).stroke(palette.line2, lineWidth: 1.5))
                .rotationEffect(.degrees(-2))
                .accessibilityHidden(true)
        }
        .padding(.top, 44).padding(.bottom, 18)
    }

    private var firstName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName()
    }

    private var runningLine: String {
        let live = store.liveCount
        let scope = window.filterProject.map { Format.homeRelative($0) + " · " } ?? ""
        switch live {
        case 0: return scope + "Nothing is running right now."
        case 1: return scope + "1 session is running right now."
        default: return scope + "\(live) sessions are running right now."
        }
    }

    private func chips(_ projects: [(cwd: String, count: Int)]) -> some View {
        HStack(alignment: .center, spacing: 6) {
            FlowLayout(spacing: 6) {
                Chip(title: "All projects", on: window.filterProject == nil) { window.filterProject = nil }
                ForEach(projects, id: \.cwd) { project in
                    Chip(title: Format.projectName(cwd: project.cwd, slug: nil), on: window.filterProject == project.cwd) {
                        window.filterProject = window.filterProject == project.cwd ? nil : project.cwd
                    }
                    .help(project.cwd)
                }
                ForEach(store.allTags, id: \.self) { tag in
                    Chip(title: "#" + tag, on: window.filterTag == tag) {
                        window.filterTag = window.filterTag == tag ? nil : tag
                    }
                }
            }
            Spacer(minLength: 12)
            Menu {
                Picker("Order", selection: $sort) {
                    ForEach(SessionSort.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline).labelsHidden()
            } label: {
                Text(sort.label).font(.system(size: 11)).foregroundStyle(palette.muted)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Order of the list")
        }
        .padding(.top, 6).padding(.bottom, 10)
    }

    private func footline(_ count: Int, _ projects: Int) -> String {
        let sessions = count == 1 ? "1 session" : "\(count) sessions"
        return window.filterProject == nil && window.filterTag == nil ? "\(sessions) in \(projects) project\(projects == 1 ? "" : "s")" : sessions
    }
}

private struct Chip: View {
    @Environment(\.palette) private var palette
    var title: String
    var on: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).lineLimit(1)
                .foregroundStyle(on ? palette.bg : palette.ink2)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(on ? palette.ink : palette.panel, in: Capsule())
                .overlay(Capsule().stroke(on ? palette.ink : palette.line2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// One session: pin, title, where it ran, when it was last active. Its size
/// appears on hover; a click opens it.
private struct SessionRow: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    @Environment(\.openWindow) private var openWindow
    var session: SessionSummary
    var now: Date
    @State private var hover = false

    var body: some View {
        let note = store.annotation(session.id)
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Button {
                        Task { await store.togglePin(session.id) }
                    } label: {
                        Image(systemName: note.pinned ? "star.fill" : "star").font(.system(size: 11))
                            .foregroundStyle(note.pinned ? palette.warn : palette.muted)
                    }
                    .buttonStyle(.plain)
                    .help(note.pinned ? "Unpin" : "Pin")
                    Text(session.title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                }
                HStack(spacing: 6) {
                    if store.isLive(session.id) {
                        Circle().fill(palette.ok).frame(width: 7, height: 7)
                        Text("Live")
                        Text("·")
                    }
                    Text(Format.middleEllipsis(Format.homeRelative(session.cwd ?? session.project ?? ""), max: 44)).help(session.cwd ?? "")
                    if session.archivedOnly == true {
                        Text("·")
                        Text("archived; source gone")
                    }
                    ForEach(note.tags, id: \.self) { tag in
                        Text("#" + tag).padding(.horizontal, 6).background(palette.line, in: Capsule())
                    }
                }
                .font(.system(size: 11.5)).foregroundStyle(palette.muted)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Format.ago(session.lastAt, now: now))
                    .help("\(Format.dateTime(session.firstAt)) → \(Format.dateTime(session.lastAt))")
                Text(size).opacity(hover ? 1 : 0)
            }
            .font(.label()).foregroundStyle(palette.muted)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(hover ? palette.panel : .clear, in: RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        // Resting on a row is a good sign it is about to be opened: have the session ready.
        .task(id: hover) {
            guard hover else { return }
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { await store.loadModel(session.id) }
        }
        .onTapGesture { window.page = .session(session.id) }
        .contextMenu {
            Button("Open") { window.page = .session(session.id) }
            Button("Open in New Window") { openWindow(value: session.id) }
            Divider()
            Button(note.pinned ? "Unpin" : "Pin") { Task { await store.togglePin(session.id) } }
            Button("Archive Now") { Task { await store.archiveNow(session.id) } }
            Divider()
            Button("Copy Session ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.id, forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { window.page = .session(session.id) }
    }

    private var size: String {
        var parts = [session.duration, "\(session.turns) turn\(session.turns == 1 ? "" : "s")", "\(session.requests) actions", Format.tokens(session.usage.outputTokens) + " out"]
        if let cost = session.claudeCodeCostUsd { parts.append(Format.money(cost)) }
        return parts.joined(separator: " · ")
    }
}

/// Lays children out left to right and wraps them, like the chips row of the mock.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        place(subviews, in: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, origin) in zip(subviews, place(subviews, in: bounds.width).origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func place(_ subviews: Subviews, in width: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), origins)
    }
}
