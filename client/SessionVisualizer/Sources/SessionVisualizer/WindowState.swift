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
        case .summary, .transcript: nil
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

/// The tabs of the drawer.
enum InspectorTab: String, CaseIterable, Identifiable {
    case details, io, note
    var id: String { rawValue }
    var title: String {
        switch self {
        case .details: "Details"
        case .io: "Input and result"
        case .note: "Note"
        }
    }
}

/// What the Transcript of one session remembers while the window shows it:
/// what is open, where the keyboard is, what is being looked for.
@Observable
final class TranscriptState {
    /// Turns whose tool calls are folded into one line per run.
    var folded: Set<Int> = []
    /// Tool rows, subagent strands and long prompts that are open.
    var open: Set<NodeKey> = []
    /// Actions whose thinking is unfolded.
    var openThoughts: Set<Int> = []
    /// Where j and k are.
    var focus: NodeKey?
    var query = ""
    /// The nodes that match the query, in reading order, and the one being shown.
    var hits: [NodeKey] = []
    var hitIndex = 0
    /// Rows on screen now (for the scroll map).
    var visible: Set<String> = []
    /// A row to bring into view; the view clears it once it has scrolled.
    var scrollTarget: String?
    var helpShown = false
    /// The "fold by default" setting has been applied to this session once.
    var foldApplied = false
    /// Bumped to move the keyboard into the find field (⌘F, /).
    var findRequests = 0
}

/// What one window is looking at. Windows share the store and nothing else.
@Observable
final class WindowState {
    var page: Page = .sessions {
        didSet {
            if page != oldValue {
                selection = nil
                transcript = TranscriptState()
            }
        }
    }
    var sessionView: SessionView = .summary
    /// The selected node of the open session, shared by its views and shown in the drawer.
    var selection: NodeKey?
    var inspectorTab = InspectorTab.details
    var transcript = TranscriptState()

    /// Folds or unfolds a turn's tool calls, keeping the keyboard and the
    /// selection on something that is still on screen.
    func setFolded(_ turn: Int, _ folded: Bool, in model: SessionModel) {
        func moved(_ key: NodeKey?) -> NodeKey? {
            guard let key, model.turnIndex(of: key) == turn else { return key }
            if folded, model.isHiddenWhenFolded(key) {
                let action: Int? = switch key {
                case .action(let n): n
                case .tool(let id): model.toolsByID[id]?.action
                case .subagent(let id): model.subagent(id)?.toolUseId.flatMap { model.toolsByID[$0] }?.action
                default: nil
                }
                return action.flatMap { model.runOfAction[$0] }.map { .work($0) } ?? .turn(turn)
            }
            if !folded, case .work(let first) = key { return .action(first) }
            return key
        }
        if folded { transcript.folded.insert(turn) } else { transcript.folded.remove(turn) }
        transcript.focus = moved(transcript.focus)
        selection = moved(selection)
    }

    /// → on a node: open what it holds. Returns the actions whose full results
    /// are now on screen and need loading.
    @discardableResult
    func expand(_ key: NodeKey, in model: SessionModel) -> [Int] {
        switch key {
        case .work(let first):
            if let turn = model.action(first)?.turn { setFolded(turn, false, in: model) }
        case .tool(let id):
            transcript.open.insert(key)
            return model.toolsByID[id].map { [$0.action] } ?? []
        case .subagent(let id):
            if let tool = model.subagent(id)?.toolUseId { transcript.open.insert(.tool(tool)) }
        case .turn(let turn):
            // The whole turn: its long prompt, and its tool calls shown again.
            transcript.open.insert(key)
            if transcript.folded.contains(turn) { setFolded(turn, false, in: model) }
        case .action(let n):
            // The action's children: its thinking and each of its tool calls.
            transcript.openThoughts.insert(n)
            let calls = model.action(n).map { model.tools(of: $0) } ?? []
            for call in calls { transcript.open.insert(.tool(call.id)) }
            return calls.isEmpty ? [] : [n]
        case .compaction:
            break
        }
        return []
    }

    /// ← on a node: close what it has open. When nothing of it is open, fold
    /// the tool calls of its turn into one line per run, the way ← in an
    /// outline goes from a closed row to its parent.
    func collapse(_ key: NodeKey, in model: SessionModel) {
        var closed = false
        switch key {
        case .tool:
            closed = transcript.open.remove(key) != nil
        case .subagent(let id):
            if let tool = model.subagent(id)?.toolUseId { closed = transcript.open.remove(.tool(tool)) != nil }
        case .turn:
            closed = transcript.open.remove(key) != nil
        case .action(let n):
            closed = transcript.openThoughts.remove(n) != nil
            for call in model.action(n).map({ model.tools(of: $0) }) ?? [] {
                if transcript.open.remove(.tool(call.id)) != nil { closed = true }
            }
        case .work, .compaction:
            return
        }
        guard !closed, let turn = model.turnIndex(of: key), !transcript.folded.contains(turn),
              (model.turn(turn)?.toolCalls ?? 0) > 0
        else { return }
        setFolded(turn, true, in: model)
    }

    /// Selects a node, opens what hides it and brings its row into view.
    func select(_ key: NodeKey?, in model: SessionModel? = nil, scroll: Bool = true) {
        selection = key
        guard let key, let model else { return }
        if let turn = model.turnIndex(of: key), transcript.folded.contains(turn), model.isHiddenWhenFolded(key) {
            transcript.folded.remove(turn)
        }
        transcript.focus = key
        if case .subagent(let id) = key, let tool = model.subagent(id)?.toolUseId { transcript.open.insert(.tool(tool)) }
        if scroll { transcript.scrollTarget = model.itemID(for: key) }
    }

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
