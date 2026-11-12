import Foundation
import Observation
import SkitKit

/// The pages of the app.
enum Page: Hashable {
    case sessions
    case session(String)
    case search
    case stats
    case claude
    /// The sessions at work and what each is doing at this moment.
    case now
    /// What Claude Code is extended with: skills, agents, commands, connectors, hooks, memory.
    case primitives
    /// Two sessions side by side (File › Compare Sessions…).
    case compare
}

/// The views of one session, in menu order (⌘1 to ⌘5).
enum SessionView: String, CaseIterable, Identifiable {
    case summary, transcript, canvas, timeline, files
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
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
    /// The match to land on once the query has been searched (a hit opened from elsewhere).
    var startAt: NodeKey?
    /// The Summary's "search this session" box.
    var summaryQuery = ""
    var summaryKind = ""
}

/// The lists of the Claude page.
enum ClaudeTab: String, CaseIterable, Identifiable {
    case experiments, settings, flags, projects, memory, state
    var id: String { rawValue }
}

@Observable
final class ClaudeState {
    var tab = ClaudeTab.experiments
    var filter = ""
}

/// How far back the Primitives page counts uses.
enum PrimitivesPeriod: Int, CaseIterable, Identifiable {
    case all = 0, quarter = 90, month = 30, week = 7
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .all: "Every session kept"
        case .quarter: "The last 90 days"
        case .month: "The last 30 days"
        case .week: "The last 7 days"
        }
    }
    /// The engine's `days`: nil for everything.
    var days: Int? { self == .all ? nil : rawValue }
}

/// What the Primitives page of one window shows.
@Observable
final class PrimitivesState {
    /// The engine's kind: "skill", "agent", "command", "connector", "hook", "plugin", "instructions", "memory".
    var kind = "skill"
    var period = PrimitivesPeriod.all
    var filter = ""
    /// Only what is installed or on offer and was not used in the period.
    var unusedOnly = false
    /// The item open on the right, by kind.
    var selected: [String: String] = [:]
    /// The column the list is in order of, and which way.
    var sort = PrimitivesColumn.uses
    var ascending = false
}

/// The columns of the Primitives page's list. Size and lines are of the definition's own file, so only
/// the kinds that have one show them.
nonisolated enum PrimitivesColumn: String, CaseIterable, Identifiable, Sendable {
    case name, defined, size, lines, uses, failed, sessions, lastUsed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: "Name"
        case .defined: "Defined"
        case .size: "Size"
        case .lines: "Lines"
        case .uses: "Uses"
        case .failed: "Failed"
        case .sessions: "Sessions"
        case .lastUsed: "Last used"
        }
    }
    /// Words read from the start; numbers line up at the end.
    var numeric: Bool { self != .name && self != .defined }
    var width: CGFloat? {
        switch self {
        // Each fits its heading with the mark of the sort beside it; the name takes what is left.
        case .name: nil
        case .defined: 150
        case .size: 50
        case .lines: 48
        case .uses: 46
        case .failed: 54
        case .sessions: 70
        case .lastUsed: 108
        }
    }
    var help: String {
        switch self {
        case .size: "Sort by the size of the file that defines it (the one Claude Code takes, when there are several)"
        case .lines: "Sort by the lines of the file that defines it (the one Claude Code takes, when there are several)"
        default: "Sort by \(title.lowercased())"
        }
    }
}

/// The two sessions the Compare page holds side by side.
@Observable
final class CompareState {
    var first: String?
    var second: String?
}

/// What the Stats page of one window is narrowed to and sorted by.
@Observable
final class StatsState {
    /// The slug of the project every board is narrowed to; nil for all.
    var project: String?
    /// The day of the calendar whose numbers are shown ("2026-11-07").
    var day: String?
    var sort = StatsColumn.lastActive
    var ascending = false
}

/// The columns of the Stats page's table.
enum StatsColumn: String, CaseIterable, Identifiable {
    case session, project, lastActive, turns, actions, calls, failed, subagents, output, cache, cost
    var id: String { rawValue }
    var title: String {
        switch self {
        case .session: "Session"
        case .project: "Project"
        case .lastActive: "Last active"
        case .turns: "Turns"
        case .actions: "Actions"
        case .calls: "Calls"
        case .failed: "Failed"
        case .subagents: "Sub"
        case .output: "Output"
        case .cache: "Cache"
        case .cost: "Cost"
        }
    }
    /// Words read from the start; numbers line up at the end.
    var numeric: Bool { self != .session && self != .project }
}

/// The three lists of the Files view.
enum FilesTab: String, CaseIterable, Identifiable {
    case files, context, images
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// What the Files view of one session remembers while the window shows it.
@Observable
final class FilesState {
    var tab = FilesTab.files
    var filter = ""
    /// The file whose touches are shown; the first of the list when nil.
    var selected: String?
    /// The kind of injected block the Context gallery is narrowed to.
    var contextKind: String?
    /// The image shown large over the view.
    var lightbox: Int?
    /// For the chosen file: the file as it is now, or each touch the session made.
    var showsTouches = false
}

/// What the Timeline of one session remembers while the window shows it.
@Observable
final class TimelineState {
    /// Where the playhead is; nil until the session's strip has been laid out.
    var time: Date?
    /// The action the model had begun on at the playhead: the ledger row that is lit.
    var current: Int?
    var playing = false
    /// The "Where the time went" panel is open.
    var whereShown = false
    /// A ledger row to bring into view; the ledger clears it once it has scrolled.
    var scrollTarget: String?
    /// The session the playhead was placed for.
    var placedFor: String?
    /// The node this view itself just put the keyboard or the selection on, so
    /// that it does not answer its own move as if it came from elsewhere.
    @ObservationIgnored var own: NodeKey?
}

/// The Search page of one window: what is asked, what came back, where the cursor is.
@Observable
final class SearchState {
    var query = ""
    /// "" for everything, else prompt | assistant | thinking | tool_use | tool_result.
    var kind = ""
    /// "" for keyword, "meaning" for what the text says, "hybrid" for both (meaning first).
    var mode = ""
    /// Every hit for the query, and the ones of the chosen kind.
    var all: [SearchHit] = []
    var hits: [SearchHit] = []
    /// The mode and query `all` belongs to.
    var allFor = ""
    /// The stamp of the search the hits belong to.
    var searched = ""
    /// The hit the cursor is on; for a folded session, its first.
    var selected = 0
    /// Sessions folded to their one line.
    var folded: Set<String> = []
    var searching = false
    /// Counts the searches started, so that an overtaken one can tell it is no longer the newest.
    @ObservationIgnored var run = 0
    var failure: String?
    /// Bumped to move the keyboard into the field.
    var focusRequests = 0

    /// What is being asked for now: a search is current when `searched` equals it.
    var stamp: String { mode + "\n" + query.trimmingCharacters(in: .whitespaces) + "\n" + kind }

    /// Folds every session to its line, or shows every hit. The cursor stays on its session.
    func setAllFolded(_ fold: Bool) {
        folded = fold ? Set(hits.map(\.session)) : []
        if fold, hits.indices.contains(selected) {
            let session = hits[selected].session
            selected = hits.firstIndex { $0.session == session } ?? selected
        }
    }
}

/// What one window is looking at. Windows share the store and nothing else.
@Observable
final class WindowState {
    var page: Page = .sessions {
        didSet {
            if page != oldValue {
                if !travelling { remember(Place(page: oldValue, view: sessionView)) }
                selection = nil
                transcript = TranscriptState()
                canvas = CanvasState()
                timeline = TimelineState()
                files = FilesState()
            }
        }
    }
    var sessionView: SessionView = .summary {
        didSet {
            // Inside a session, the view is part of where you are: Back from the Transcript is the Summary.
            if sessionView != oldValue, !travelling, sessionID != nil { remember(Place(page: page, view: oldValue)) }
        }
    }

    // MARK: Where the window has been

    /// A place the window can be: a page, and inside a session the view of it.
    struct Place: Equatable {
        var page: Page
        var view: SessionView
    }

    private(set) var backStack: [Place] = []
    private(set) var forwardStack: [Place] = []
    /// Set while Back, Forward or `go` moves the window, so the move is not itself remembered twice.
    @ObservationIgnored private var travelling = false

    var place: Place { Place(page: page, view: sessionView) }
    /// With nowhere remembered, Back still leads out of a page to Sessions.
    var canGoBack: Bool { !backStack.isEmpty || page != .sessions }
    var canGoForward: Bool { !forwardStack.isEmpty }
    /// Where Back leads.
    var backTarget: Place { backStack.last ?? Place(page: .sessions, view: sessionView) }

    private func remember(_ place: Place) {
        if backStack.last != place { backStack.append(place) }
        if backStack.count > 100 { backStack.removeFirst(backStack.count - 100) }
        forwardStack.removeAll()
    }

    private func travel(to place: Place) {
        travelling = true
        page = place.page
        sessionView = place.view
        travelling = false
    }

    /// Moves to a page and a view of it as one step of the history.
    func go(to page: Page, view: SessionView? = nil) {
        let from = place
        travelling = true
        self.page = page
        if let view { sessionView = view }
        travelling = false
        if place != from { remember(from) }
    }

    /// Back to where the window was before: the Summary a Transcript was opened
    /// from, the Search a hit was opened from, the list a session was opened from.
    func goBack() {
        guard canGoBack else { return }
        let from = place
        let target = backStack.popLast() ?? Place(page: .sessions, view: sessionView)
        forwardStack.append(from)
        travel(to: target)
    }

    func goForward() {
        guard let target = forwardStack.popLast() else { return }
        backStack.append(place)
        travel(to: target)
    }
    /// The selected node of the open session, shared by its views and shown in the drawer.
    var selection: NodeKey?
    var inspectorTab = InspectorTab.details
    var transcript = TranscriptState()
    var canvas = CanvasState()
    var timeline = TimelineState()
    var files = FilesState()
    var stats = StatsState()
    var compare = CompareState()
    var claude = ClaudeState()
    var primitives = PrimitivesState()
    var search = SearchState()
    /// The ⌘K palette is open.
    var paletteShown = false
    /// The sheet that links `skit` into the terminal (SessionVisualizer › Install Command Line Tool…).
    var commandLineToolShown = false
    /// A node to select once the session it belongs to has loaded (a link, a search hit).
    var pending: Pending?

    struct Pending: Equatable {
        var session: String
        var key: NodeKey
        var query: String?
        /// Select it (the drawer opens), or only bring it into view.
        var select = false
    }

    /// Opens the Compare page: the session in front (or the given one) against
    /// the most recent other one, unless a pair is already chosen.
    func showCompare(_ id: String? = nil, in store: AppStore) {
        let recent = store.sessions.sorted { $0.lastAt > $1.lastAt }.filter { $0.requests > 0 }.map(\.id)
        if let first = id ?? sessionID { compare.first = first }
        if compare.first == nil { compare.first = recent.first }
        if compare.second == nil || compare.second == compare.first { compare.second = recent.first { $0 != compare.first } }
        go(to: .compare)
    }

    /// Opens a session, on a node of it when one is given: the session loads
    /// first, then `applyPending` lands on the node. A session opened from a
    /// list starts on its Summary; a hit or a link says which view it means.
    func open(session id: String, at key: NodeKey? = nil, query: String? = nil, select: Bool = false, view: SessionView = .transcript) {
        go(to: .session(id), view: view)
        if let query { transcript.query = query }
        pending = key.map { Pending(session: id, key: $0, query: query, select: select) }
    }

    /// Lands on the pending node, now that its session is there to look in.
    func applyPending(in model: SessionModel) {
        guard let pending, pending.session == model.doc.id else { return }
        self.pending = nil
        if pending.select {
            select(pending.key, in: model)
        } else {
            reveal(pending.key, in: model, query: pending.query, view: sessionView)
        }
    }

    /// Shows a node in the Transcript without selecting it: the keyboard is on
    /// it and its row is in view, and the drawer stays as it was. With a query,
    /// find-in-session carries it and starts on this node.
    func reveal(_ key: NodeKey, in model: SessionModel, query: String? = nil, view: SessionView = .transcript) {
        sessionView = view
        if let turn = model.turnIndex(of: key), transcript.folded.contains(turn), model.isHiddenWhenFolded(key) {
            setFolded(turn, false, in: model)
        }
        if let query {
            transcript.query = query
            transcript.startAt = key
        }
        transcript.focus = key
        switch key {
        case .subagent(let id), .step(let id, _):
            if let tool = model.subagent(id)?.toolUseId { transcript.open.insert(.tool(tool)) }
        default: break
        }
        transcript.scrollTarget = model.itemID(for: key)
    }

    /// Folds or unfolds a turn's tool calls, keeping the keyboard and the
    /// selection on something that is still on screen.
    func setFolded(_ turn: Int, _ folded: Bool, in model: SessionModel) {
        func moved(_ key: NodeKey?) -> NodeKey? {
            guard let key, model.turnIndex(of: key) == turn else { return key }
            if folded, model.isHiddenWhenFolded(key) {
                let action: Int? = switch key {
                case .action(let n): n
                case .tool(let id): model.toolsByID[id]?.action
                case .subagent(let id), .step(let id, _): model.subagent(id)?.toolUseId.flatMap { model.toolsByID[$0] }?.action
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
        case .subagent(let id), .step(let id, _):
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
        case .compaction, .file, .outside:
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
        case .subagent(let id), .step(let id, _):
            if let tool = model.subagent(id)?.toolUseId { closed = transcript.open.remove(.tool(tool)) != nil }
        case .turn:
            closed = transcript.open.remove(key) != nil
        case .action(let n):
            closed = transcript.openThoughts.remove(n) != nil
            for call in model.action(n).map({ model.tools(of: $0) }) ?? [] {
                if transcript.open.remove(.tool(call.id)) != nil { closed = true }
            }
        case .work, .compaction, .file, .outside:
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
        switch key {
        case .subagent(let id), .step(let id, _):
            if let tool = model.subagent(id)?.toolUseId { transcript.open.insert(.tool(tool)) }
        default: break
        }
        if scroll { transcript.scrollTarget = model.itemID(for: key) }
    }

    /// The directory Claude Code was started in; nil shows every project.
    var filterProject: String?
    var filterTag: String?

    var sessionID: String? {
        if case .session(let id) = page { id } else { nil }
    }

    /// The sessions whose documents this window draws from now: the store keeps those loaded.
    var shownSessions: [String] {
        switch page {
        case .session(let id): [id]
        case .compare: [compare.first, compare.second].compactMap { $0 }
        // The preview beside the hits reads the session of the hit the cursor is on.
        case .search: search.hits.indices.contains(search.selected) ? [search.hits[search.selected].session] : []
        case .sessions, .stats, .claude, .now, .primitives: []
        }
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
