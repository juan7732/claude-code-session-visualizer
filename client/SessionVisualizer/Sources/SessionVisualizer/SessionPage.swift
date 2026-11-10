import SkitKit
import SwiftUI

/// One session. M7 brings the Summary's head and the two cards that /stats
/// alone can fill; the other views name the milestone that brings them.
struct SessionPage: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var id: String

    var body: some View {
        Group {
            if let session = store.session(id) {
                switch window.sessionView {
                case .summary: SummaryView(session: session)
                default: ComingPage(title: window.sessionView.title, milestone: window.sessionView.arrives ?? "")
                }
            } else {
                ComingPage(title: "No session \(Format.shortID(id))", detail: "It is neither on disk nor in the archive.")
            }
        }
        .task(id: id) { await store.loadStats(id) }
    }
}

struct SummaryView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var palette
    var session: SessionSummary
    @State private var newTag = ""

    var body: some View {
        let note = store.annotation(session.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(session.title).font(.display(30)).tracking(-0.3).textSelection(.enabled)
                when.padding(.top, 6)
                tagRow(note).padding(.top, 10)
                Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        sizeCard
                        contextCard
                    }
                }
                .padding(.top, 18)
                Text("What it is about, where it ended, outcome, problems and parallel work arrive with the full Summary (M9).")
                    .font(.system(size: 11.5)).foregroundStyle(palette.muted).padding(.top, 14)
            }
            .frame(maxWidth: Metric.wideColumn, alignment: .leading)
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 60)
            .frame(maxWidth: .infinity)
        }
        .background(palette.bg)
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
        }
    }

    private var sizeCard: some View {
        Card(title: "Size") {
            Text("\(session.prompts) prompt\(session.prompts == 1 ? "" : "s")").font(.display(24)).tracking(-0.2)
            Facts(rows: [
                ("Turns", "\(session.turns)" + (session.systemTurns > 0 ? " · \(session.systemTurns) by the system" : "")),
                ("Actions", "\(session.requests)"),
                ("Tool calls", "\(session.toolCalls)" + (session.toolErrors > 0 ? " · \(session.toolErrors) failed" : "")),
                ("Output", Format.tokens(session.usage.outputTokens) + " tokens"),
                ("Wall", session.duration),
                ("Cost", session.claudeCodeCostUsd.map { Format.money($0) + " · Claude Code's figure" } ?? "not recorded"),
            ] + rewound)
        }
    }

    private var rewound: [(String, String)] {
        guard let actions = session.rewoundActions, actions > 0 else { return [] }
        return [("Rewound", "\(session.rewoundTurns ?? 0) turns · \(actions) actions, included above")]
    }

    private var contextCard: some View {
        Card(title: "Context") {
            switch store.stats[session.id] {
            case .loaded(let stats):
                let peak = (stats.context ?? []).map(\.tokens).max() ?? 0
                Text("\(Format.tokens(peak)) peak").font(.display(24)).tracking(-0.2)
                Facts(rows: [
                    ("Compactions", compactions(stats)),
                    ("Cache hit", "\(Int((stats.cacheHitRatio * 100).rounded()))%"),
                    ("Models", stats.models.map { $0.name.replacingOccurrences(of: "claude-", with: "") }.joined(separator: ", ")),
                ] + (stats.images > 0 ? [("Images", "\(stats.images)")] : []))
            case .failed(let why):
                Text("Could not load").font(.display(24))
                Text(why).font(.system(size: 12)).foregroundStyle(palette.err).textSelection(.enabled)
            case .loading, nil:
                Text("…").font(.display(24)).foregroundStyle(palette.muted)
                Text("Reading the session").font(.system(size: 12)).foregroundStyle(palette.muted)
            }
        }
    }

    private func compactions(_ stats: SessionSummary) -> String {
        let list = stats.compactionList ?? []
        guard !list.isEmpty else { return "none" }
        return list.map { "\(Format.tokens($0.preTokens)) → \(Format.tokens($0.postTokens))" }.joined(separator: ", ")
    }
}

/// Label and value pairs, as in the mock's cards.
struct Facts: View {
    @Environment(\.palette) private var palette
    var rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0).foregroundStyle(palette.muted)
                    Text(row.1).textSelection(.enabled)
                }
            }
        }
        .font(.system(size: 12))
    }
}

/// A page or view that a later milestone brings.
struct ComingPage: View {
    @Environment(\.palette) private var palette
    var title: String
    var milestone = ""
    var detail: String?

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.display(22))
            Text(detail ?? "Not built yet. It arrives with \(milestone) of the plan.").foregroundStyle(palette.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.bg)
    }
}
