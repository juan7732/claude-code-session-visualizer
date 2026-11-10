import Foundation
import Observation
import SkitKit

/// The pages of the app. Search, Stats and Claude are on the rail from the
/// start; their pages arrive in M9 and M13.
enum Page: Hashable {
    case sessions
    case session(String)
    case search
    case stats
    case claude
}

/// The views of one session, in menu order (⌘1 to ⌘5).
enum SessionView: String, CaseIterable, Identifiable {
    case summary, transcript, canvas, timeline, files
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// The milestone that brings the view, for the ones not built yet.
    var arrives: String? {
        switch self {
        case .summary: nil
        case .transcript: "M8"
        case .canvas: "M10"
        case .timeline: "M11"
        case .files: "M13"
        }
    }
}

enum SessionSort: String, CaseIterable, Identifiable {
    case newest, turns, output, cost
    var id: String { rawValue }
    var label: String {
        switch self {
        case .newest: "Pinned first, then newest"
        case .turns: "Pinned first, then most turns"
        case .output: "Pinned first, then most output"
        case .cost: "Pinned first, then highest cost"
        }
    }
}

/// What one window is looking at. Windows share the store and nothing else.
@Observable
final class WindowState {
    var page: Page = .sessions
    var sessionView: SessionView = .summary
    /// The directory Claude Code was started in; nil shows every project.
    var filterProject: String?
    var filterTag: String?

    var sessionID: String? {
        if case .session(let id) = page { id } else { nil }
    }

    /// The rows of the Sessions page: filtered, pinned first, then by the chosen order.
    func rows(in store: AppStore, sort: SessionSort) -> [SessionSummary] {
        var rows = store.sessions
        if let filterProject { rows = rows.filter { $0.cwd == filterProject } }
        if let filterTag { rows = rows.filter { store.annotation($0.id).tags.contains(filterTag) } }
        func key(_ r: SessionSummary) -> Double {
            switch sort {
            case .newest: r.lastAt.timeIntervalSince1970
            case .turns: Double(r.turns)
            case .output: Double(r.usage.outputTokens)
            case .cost: r.claudeCodeCostUsd ?? -1
            }
        }
        return rows.sorted { a, b in
            let (pa, pb) = (store.annotation(a.id).pinned, store.annotation(b.id).pinned)
            if pa != pb { return pa }
            if key(a) != key(b) { return key(a) > key(b) }
            return a.lastAt > b.lastAt
        }
    }

    /// The distinct start directories, most sessions first.
    func projects(in store: AppStore) -> [(cwd: String, count: Int)] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for row in store.sessions.sorted(by: { $0.lastAt > $1.lastAt }) {
            guard let cwd = row.cwd else { continue }
            if counts[cwd] == nil { order.append(cwd) }
            counts[cwd, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
    }
}
