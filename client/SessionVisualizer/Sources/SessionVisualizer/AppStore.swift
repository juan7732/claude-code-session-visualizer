import Foundation
import Observation
import SkitKit

/// Whether the engine is there to talk to.
enum EngineState: Equatable {
    case connecting
    /// Installing or starting the background agent for the `skit` at this path.
    case starting(binary: String)
    case ready
    /// No `skit` anywhere it is looked for.
    case missing(lookedIn: [String])
    /// An engine answers, but it lacks routes this app calls.
    case incompatible(version: String, missing: [String])
    /// An engine answers, and this app cannot read what it says: the two were not built from the same commit.
    case unreadable(version: String, detail: String)
    /// Nothing is serving, and the app is somewhere the background agent must not be installed from.
    case misplaced(BundlePlace)
    case failed(String)
}

/// How saving a note went.
enum NoteSave: Equatable {
    /// Kept: the note as the engine holds it now.
    case saved(String)
    case failed(String)
}

/// A note in its editor: what is typed, what the engine holds, and how the last save went.
/// "Saved" is only ever what the engine answered with, never what was sent to it.
nonisolated struct NoteEdit: Equatable {
    var text = ""
    /// The note as the engine holds it.
    var saved = ""
    var saving = false
    /// Why the last save did not go through, while what it tried to save is still unsaved.
    var failure: String?

    init() {}

    /// Opens on what the engine holds, or on what was typed last time and could not be saved.
    init(saved: String, unsaved: String?) {
        self.saved = saved
        text = unsaved ?? saved
        if unsaved != nil, dirty { failure = "the engine did not take it" }
    }

    /// The engine trims a note, so text that differs only by the space around it is the saved note.
    var dirty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines) != saved }

    mutating func finish(_ result: NoteSave) {
        saving = false
        switch result {
        case .saved(let kept): (saved, failure) = (kept, nil)
        case .failed(let why): failure = why
        }
    }

    /// The line under the editor. `hint` is what an empty, untouched note says.
    func status(hint: String) -> String {
        if saving { return "Saving…" }
        if !dirty { return saved.isEmpty ? hint : "Saved." }
        if let failure { return "Not saved: \(failure)" }
        return "Not saved yet."
    }

    /// True when the line under the editor reports a failure.
    var failed: Bool { !saving && dirty && failure != nil }
}

/// A value that is loaded on demand.
enum Loadable<Value: Equatable>: Equatable {
    case loading
    case loaded(Value)
    case failed(String)
}

/// What every window shares: the engine connection, the sessions, what the
/// human added to them. One per process.
@Observable
final class AppStore {
    let locator: EngineLocator
    let client: SkitClient
    /// When false the app only attaches to an engine that is already serving:
    /// it never installs the agent (snapshots, tests).
    let managesEngine: Bool

    private(set) var engine: EngineState = .connecting
    private(set) var status: EngineStatus?
    /// The version the engine that answered gave for itself (`GET /v0`).
    private(set) var engineVersion: String?
    private(set) var sessions: [SessionSummary] = []
    /// The same rows by id: `session(_:)` is asked for one row from every corner of every page.
    private(set) var sessionsByID: [String: SessionSummary] = [:]
    /// The sessions a Claude Code process has open now. Kept apart from `status`, whose uptime changes with every poll.
    private(set) var liveIDs: Set<String> = []
    private(set) var annotations: [String: Annotation] = [:]
    /// Notes typed whose save failed, by `noteDraftKey`: the editor opens on them again, so the words are not lost with the view.
    private(set) var unsavedNotes: [String: String] = [:]
    private(set) var stats: [String: Loadable<SessionSummary>] = [:]
    /// Sessions opened in this run, ready to draw. A few are kept; a document is megabytes.
    private(set) var models: [String: Loadable<SessionModel>] = [:]
    /// The loaded sessions, the one used longest ago first. Not observed: no view draws from the order.
    @ObservationIgnored private var modelOrder: [String] = []
    /// The reads under way, by session: a second asker waits for the first read.
    @ObservationIgnored private var modelLoads: [String: Task<Void, Never>] = [:]
    /// Bumped when a session's document is replaced or dropped, so that what was asked about the old one is not kept for the new.
    @ObservationIgnored private var generations: [String: Int] = [:]
    /// How many sessions stay loaded. The ones on show stay whatever the count (`evict`).
    @ObservationIgnored var modelLimit = 3
    /// The full results of an action's tool calls, fetched when a row or the drawer shows them.
    private(set) var actionDetails: [String: [Int: Loadable<ActionDetail>]] = [:]
    /// The same for a subagent's steps, by `stepKey`.
    private(set) var stepDetails: [String: [String: Loadable<ActionDetail>]] = [:]
    /// What each compaction did, fetched when the drawer shows one.
    private(set) var compactionDetails: [String: [Int: Loadable<CompactionDetail>]] = [:]
    /// Where each opened session's time went (`skit time`), fetched when the Timeline shows it.
    private(set) var times: [String: Loadable<SessionTime>] = [:]
    /// Claude Code's own configuration, read when the Claude page shows.
    private(set) var claude: Loadable<ClaudeSnapshot>?
    private(set) var claudeReadAt: Date?
    /// The sessions at work and what each is doing, asked again every few seconds while it is shown.
    private(set) var now: Loadable<NowReport>?
    /// How far back "at work" reaches, in minutes. Every window shares it.
    var nowMinutes = 60
    /// The reminders before a session's prompt cache expires.
    let reminders = CacheReminders()
    /// A reload the person asked for is under way.
    private(set) var reloading = false
    /// What Claude Code is extended with and its use, by the days counted (0 for every session kept).
    private(set) var primitives: [Int: Loadable<PrimitivesReport>] = [:]
    /// One primitive with the sessions that used it, by `primitiveKey`.
    private(set) var primitiveDetails: [String: Loadable<PrimitivesReport.Item>] = [:]
    /// Every session added up, by the project it is narrowed to ("" for all).
    private(set) var overviews: [String: Loadable<Overview>] = [:]
    /// The images of each opened session, as a list. Their pictures are kept by the view that draws them (`Pictures`).
    private(set) var images: [String: Loadable<[SessionImage]>] = [:]
    /// The last thing that went wrong after the engine was ready (a failed pin, a failed refresh).
    var notice: String?

    /// The commit the `skit` inside the app was built from (`SkitCommit` in Info.plist; build.sh gives
    /// the helper the same string as its version). Nil when the app runs without a bundle.
    let bundledVersion: String?
    /// How the agent is asked about and installed; tests put their own in.
    @ObservationIgnored var agentStatus: @Sendable (String) throws -> ServiceStatus = { try SkitCommand(binary: $0, timeout: 10).serviceStatus() }
    @ObservationIgnored var installAgent: @Sendable (String) throws -> ServiceStatus = { try SkitCommand(binary: $0).installService() }
    /// How often the lists are read again while a window is open, and how long a vanished engine is given to come back.
    @ObservationIgnored var pollInterval: Duration = .seconds(10)
    @ObservationIgnored var reattachPause: Duration = .seconds(1)
    /// The same engine, asked with a short patience: for the polls.
    private let poller: SkitClient
    /// The connect or restart under way; whoever asks meanwhile waits for it.
    @ObservationIgnored private var connecting: Task<Void, Never>?
    /// The windows that are open. They are asked what they show (`shownSessions`); the store does not keep them alive.
    @ObservationIgnored private var windows: [WeakWindow] = []
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var advised = false

    private struct WeakWindow {
        weak var window: WindowState?
    }

    init(locator: EngineLocator = EngineLocator(helpersDirectory: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers").path),
         socketPath: String? = nil, managesEngine: Bool = true,
         bundledVersion: String? = Bundle.main.object(forInfoDictionaryKey: "SkitCommit") as? String,
         pollTimeout: TimeInterval = 5) {
        self.locator = locator
        self.client = SkitClient(socketPath: socketPath ?? locator.socketPath)
        // DECISION: five seconds for a poll, against thirty for what a person asked for. A poll comes
        // round again in ten; an answer later than that is no use, and a stuck engine should not
        // hold a thread and a refresh for half a minute.
        self.poller = client.quick(timeout: pollTimeout)
        self.managesEngine = managesEngine
        self.bundledVersion = bundledVersion
    }

    // MARK: Engine

    private var connector: EngineConnector {
        EngineConnector(client: client, locator: locator, managesEngine: managesEngine, install: installAgent, status: agentStatus)
    }

    /// Reaches the engine: attach to the one that is serving, else have the
    /// `skit` we can find install its background agent and wait for it.
    ///
    /// DECISION: one connect at a time, whoever asks. Every window asks when it opens, and two
    /// connects side by side meant two `skit service install` at once, one of which could fail
    /// while the agent it raced was serving.
    func connect() async {
        await exclusively { await $0.establish(restart: false) }
    }

    /// Reinstalls the background agent for the `skit` this app would start (its
    /// own helper when it has one) and connects again: what brings an agent
    /// left over from an older build up to date.
    func restartAgent() async {
        await exclusively { await $0.establish(restart: true) }
    }

    private func exclusively(_ work: @escaping (AppStore) async -> Void) async {
        if let connecting { return await connecting.value }
        let task = Task {
            await work(self)
            self.connecting = nil
        }
        connecting = task
        await task.value
    }

    /// Where the app is, when that is somewhere the agent must not be installed from: a path App
    /// Translocation made up, or a disk image. Both are gone later, and the agent with them.
    var installRefusal: BundlePlace? {
        guard let helper = locator.bundledHelper, locator.findBinary() == helper else { return nil }
        let place = BundlePlace.of(helper)
        return place == .stable ? nil : place
    }

    /// The running engine and the one inside the app, when they say they are different builds.
    var versionMismatch: (running: String, bundled: String)? {
        guard let bundled = bundledVersion, let running = engineVersion, running != bundled else { return nil }
        return (running, bundled)
    }

    nonisolated static func moveAdvice(_ place: BundlePlace) -> String {
        switch place {
        case .translocated: "macOS is running this copy of SessionVisualizer from a temporary place, because it was opened from where it was downloaded. Move it to the Applications folder and open it again, so the background agent that archives your sessions can be installed."
        case .volume: "This copy of SessionVisualizer runs from a disk image. Move it to the Applications folder and open it from there, so the background agent that archives your sessions can be installed."
        case .stable: ""
        }
    }

    private func establish(restart: Bool) async {
        if restart {
            guard let binary = locator.findBinary() else {
                engine = .missing(lookedIn: locator.binaryCandidates)
                return
            }
            if let place = installRefusal {
                notice = Self.moveAdvice(place)
                return
            }
            engine = .starting(binary: binary)
            do {
                let install = installAgent
                _ = try await Blocking.run { try install(binary) }
            } catch {
                engine = .failed("skit service install: \(error)")
                return
            }
            // The old process is on its way out; give the new one a moment to listen.
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(300))
                if let list = try? await client.routes(), SkitClient.missingRoutes(in: list.routes).isEmpty { break }
            }
        }
        engine = .connecting
        let outcome = await connector.connect { binary in
            await MainActor.run { self.engine = .starting(binary: binary) }
        }
        switch outcome {
        case .ready(let list):
            engineVersion = list.version
            do {
                try await load(client)
                engine = .ready
                advise()
            } catch let SkitError.undecodable(path, detail) {
                // The routes are there by name and what they say is not what this build reads.
                engine = .unreadable(version: list.version, detail: "\(path): \(detail)")
            } catch {
                engine = .failed("\(error)")
            }
        case .missing(let lookedIn): engine = .missing(lookedIn: lookedIn)
        case .incompatible(let version, let missing):
            engineVersion = version
            engine = .incompatible(version: version, missing: missing)
        case .misplaced(let place): engine = .misplaced(place)
        case .failed(let why): engine = .failed(why)
        }
    }

    /// Said once a run, when the engine is reached: what the person should know and nothing stops for.
    private func advise() {
        guard !advised else { return }
        advised = true
        if let place = installRefusal {
            notice = Self.moveAdvice(place)
        } else if let mismatch = versionMismatch {
            notice = "The background agent runs skit \(mismatch.running); this app carries \(mismatch.bundled). Settings › Engine restarts it with the app's own."
        }
    }

    private func load(_ client: SkitClient) async throws {
        async let status = client.status()
        async let sessions = client.sessions()
        async let annotations = client.annotations()
        let (now, rows, notes) = try await (status, sessions, annotations)
        // DECISION: only what changed is assigned. An assignment wakes every view that reads the
        // property, and most polls find the same sessions they found ten seconds before.
        if self.status != now { self.status = now }
        let live = Set(now.live.compactMap(\.sessionId))
        if liveIDs != live { liveIDs = live }
        if self.sessions != rows {
            let known = Set(sessionsByID.keys)
            self.sessions = rows
            sessionsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            // A session the engine no longer lists has no canvas to come back to. Not for a snapshot or
            // another SKIT_HOME: those list other sessions than the ones the cameras were kept for.
            if Set(sessionsByID.keys) != known, !Snapshot.keepsNothing, (locator.environment["SKIT_HOME"] ?? "").isEmpty {
                CanvasMemory.prune(keeping: Set(sessionsByID.keys))
            }
        }
        if self.annotations != notes { self.annotations = notes }
    }

    /// Reloads the list while the app is open; sessions keep changing under it.
    ///
    /// DECISION: once the windows are up, a poll that fails leaves them up. A slow or broken answer
    /// is said in a notice and asked for again at the next poll; only an engine that is confirmed
    /// gone (nothing listening, twice) sends the windows back to the connecting page, where the
    /// agent is started again. `polling` asks with the short patience of the ten-second loop.
    func refresh(polling: Bool = false) async {
        guard engine == .ready else { return }
        do {
            try await load(polling ? poller : client)
        } catch SkitError.unreachable {
            await reattach()
        } catch SkitError.timedOut {
            notice = "skit is slow to answer. What is on screen may be behind; asking again shortly."
        } catch SkitError.transport(let why) {
            notice = "The answer from skit did not arrive whole (\(why)). Asking again shortly."
        } catch let SkitError.undecodable(path, detail) {
            // Not a passing fault: the engine was replaced by a build this app cannot read. The page that offers the restart.
            engine = .unreadable(version: engineVersion ?? "unknown", detail: "\(path): \(detail)")
        } catch {
            notice = "\(error)"
        }
    }

    /// Nothing was listening. An agent that is being restarted is away for a moment, so look once
    /// more before giving the windows up.
    private func reattach() async {
        try? await Task.sleep(for: reattachPause)
        guard engine == .ready else { return }
        do {
            let list = try await poller.routes()
            // What came back may be another build.
            guard SkitClient.missingRoutes(in: list.routes).isEmpty else { return await connect() }
            engineVersion = list.version
            try await load(poller)
        } catch SkitError.unreachable {
            await connect()
        } catch {
            notice = "skit is not answering (\(error)). Asking again shortly."
        }
    }

    // MARK: Windows

    /// Counts a window in for as long as the calling task lives (the window's own `.task`): the
    /// lists are polled while some window is open, by one loop whatever the number of windows.
    func attend(_ window: WindowState) async {
        register(window)
        defer { unregister(window) }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
    }

    func register(_ window: WindowState) {
        windows.removeAll { $0.window == nil || $0.window === window }
        windows.append(WeakWindow(window: window))
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.pollInterval else { return }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                // Sessions change while the app is open: keep the list current.
                await self.refresh(polling: true)
                // Cheap (the engine reads only what changed): keeps the rail's count, the reminders and "moved on" current.
                await self.loadNow()
            }
        }
    }

    func unregister(_ window: WindowState) {
        windows.removeAll { $0.window == nil || $0.window === window }
        if windows.isEmpty {
            poll?.cancel()
            poll = nil
        }
    }

    /// The sessions some window is drawing from at this moment.
    private func shownSessions() -> Set<String> {
        Set(windows.compactMap(\.window).flatMap(\.shownSessions))
    }

    // MARK: Sessions

    func session(_ id: String) -> SessionSummary? { sessionsByID[id] }

    func isLive(_ id: String) -> Bool { liveIDs.contains(id) }

    var liveCount: Int { sessions.filter { liveIDs.contains($0.id) }.count }

    func annotation(_ id: String) -> Annotation { annotations[id] ?? Annotation() }

    /// Every tag in use, in alphabetical order.
    var allTags: [String] { Array(Set(annotations.values.flatMap(\.tags))).sorted() }

    func loadStats(_ id: String) async {
        if case .loaded = stats[id] {} else { stats[id] = .loading }
        do {
            stats[id] = .loaded(try await client.stats(session: id))
        } catch {
            stats[id] = .failed("\(error)")
        }
    }

    /// Loads the session document and its relations and builds the model the
    /// views draw from. Decoding and indexing happen off the main actor.
    ///
    /// A session that is loaded is not read again, and one that is being read is not read twice:
    /// resting on a row starts the read and the click that follows waits for that same read.
    func loadModel(_ id: String) async {
        if case .loaded = models[id] { return used(id) }
        if let running = modelLoads[id] { return await running.value }
        let task = Task {
            await self.readModel(id)
            self.modelLoads[id] = nil
        }
        modelLoads[id] = task
        await task.value
    }

    private func readModel(_ id: String) async {
        models[id] = .loading
        do {
            models[id] = .loaded(try await build(id))
            used(id)
            evict()
        } catch {
            models[id] = .failed("\(error)")
        }
    }

    private func build(_ id: String) async throws -> SessionModel {
        let client = self.client
        return try await Task.detached(priority: .userInitiated) {
            async let doc = client.document(session: id)
            async let relations = client.relations(session: id)
            return SessionModel(doc: try await doc, relations: try await relations)
        }.value
    }

    /// Moves a session to the recently used end of the order.
    private func used(_ id: String) {
        modelOrder.removeAll { $0 == id }
        modelOrder.append(id)
    }

    /// Drops the sessions used longest ago, down to `modelLimit`.
    ///
    /// DECISION: never one a window is showing, whatever the count. A page reads its session once,
    /// when it opens; taking the document from under it left the page on "Reading the session" for
    /// good. With more windows than the limit, more stay loaded.
    private func evict() {
        let shown = shownSessions()
        while modelOrder.count > modelLimit, let old = modelOrder.first(where: { !shown.contains($0) }) {
            modelOrder.removeAll { $0 == old }
            generations[old, default: 0] += 1
            models[old] = nil
            actionDetails[old] = nil
            stepDetails[old] = nil
            compactionDetails[old] = nil
            times[old] = nil
            images[old] = nil
        }
    }

    func model(_ id: String) -> SessionModel? {
        if case .loaded(let model) = models[id] { model } else { nil }
    }

    /// Fetches one thing about an opened session and keeps it under `key`.
    ///
    /// What arrives after the session was dropped is not kept (it would stay for good, for a
    /// session nobody shows). What arrives after the session was read again was asked of the old
    /// document: it is asked for once more, since the view that wanted it asks only once.
    private func keep<Key: Hashable, Value: Equatable>(_ path: ReferenceWritableKeyPath<AppStore, [String: [Key: Loadable<Value>]]>,
                                                        _ id: String, _ key: Key, fetch: () async throws -> Value) async {
        if self[keyPath: path][id]?[key] != nil { return }
        for _ in 0..<3 {
            let generation = generations[id, default: 0]
            self[keyPath: path][id, default: [:]][key] = .loading
            let result: Loadable<Value>
            do {
                result = .loaded(try await fetch())
            } catch {
                result = .failed("\(error)")
            }
            if generations[id, default: 0] == generation {
                self[keyPath: path][id, default: [:]][key] = result
                return
            }
            guard case .loaded = models[id] else { return }
        }
    }

    func loadAction(_ id: String, _ index: Int) async {
        let client = self.client
        await keep(\.actionDetails, id, index) { try await client.action(session: id, index) }
    }

    static func stepKey(agent: String, index: Int) -> String { "\(agent)/\(index)" }

    /// The full results of one step of a subagent.
    func loadStep(_ id: String, agent: String, index: Int) async {
        let client = self.client
        await keep(\.stepDetails, id, Self.stepKey(agent: agent, index: index)) { try await client.action(session: id, index, agent: agent) }
    }

    func loadCompaction(_ id: String, _ index: Int) async {
        let client = self.client
        await keep(\.compactionDetails, id, index) { try await client.compaction(session: id, index) }
    }

    /// The overview is asked for again each time the Stats page shows: sessions keep changing.
    func loadOverview(project slug: String?) async {
        let key = slug ?? ""
        if overviews[key] == nil { overviews[key] = .loading }
        do {
            overviews[key] = .loaded(try await client.overview(project: slug))
        } catch {
            overviews[key] = .failed("\(error)")
        }
    }

    /// What the sessions at work are doing now. A failure keeps what was last read on screen.
    func loadNow() async {
        if now == nil { now = .loading }
        do {
            let report = try await poller.now(minutes: nowMinutes == 60 ? nil : nowMinutes)
            if now != .loaded(report) { now = .loaded(report) }
            reminders.sync(report)
        } catch {
            if case .loaded = now {} else { now = .failed("\(error)") }
        }
    }

    /// The session at work with this id, when the last look saw it.
    func nowSession(_ id: String) -> NowReport.Session? {
        if case .loaded(let report) = now { report.sessions.first { $0.id == id } } else { nil }
    }

    /// True when the session has moved on since its document was read here.
    func isBehind(_ id: String) -> Bool {
        guard let model = model(id), let live = nowSession(id) else { return false }
        return live.lastAt.timeIntervalSince(model.doc.lastAt) > 1
    }

    /// Reads a session again and swaps it in when it has arrived, so the page keeps showing the
    /// old one meanwhile. What was fetched for the old one (results, time, images) is dropped.
    func reloadModel(_ id: String) async {
        guard case .loaded = models[id] else { return await loadModel(id) }
        do {
            let model = try await build(id)
            // Dropped while it was being read again: nobody shows it any more.
            guard case .loaded = models[id] else { return }
            // What a view had asked for is asked for again: a view asks once, when it appears.
            let hadTime = times[id] != nil, hadImages = images[id] != nil, hadStats = stats[id] != nil
            generations[id, default: 0] += 1
            models[id] = .loaded(model)
            used(id)
            actionDetails[id] = nil
            stepDetails[id] = nil
            compactionDetails[id] = nil
            times[id] = nil
            images[id] = nil
            if hadTime { await loadTime(id) }
            if hadImages { await loadImages(id) }
            if hadStats { await loadStats(id) }
        } catch {
            notice = "\(error)"
        }
    }

    /// Refresh (⌘R): the sessions, and whatever the page in front shows.
    func reload(page: Page, compare: [String] = []) async {
        guard !reloading else { return }
        reloading = true
        defer { reloading = false }
        await refresh()
        switch page {
        case .session(let id):
            await reloadModel(id)
        case .compare:
            for id in compare { await reloadModel(id) }
        case .stats:
            for key in overviews.keys { await loadOverview(project: key.isEmpty ? nil : key) }
        case .primitives:
            for key in primitives.keys { await loadPrimitives(days: key == 0 ? nil : key) }
        case .claude:
            await loadClaude()
        case .sessions, .search, .now:
            break
        }
        // Last, so "moved on since it was read" is judged against what was just read.
        await loadNow()
    }

    /// Reads the list again each time the page shows: what is on disk changes without the app knowing.
    func loadPrimitives(days: Int?) async {
        let key = days ?? 0
        if primitives[key] == nil { primitives[key] = .loading }
        do {
            let report = try await client.primitives(days: days)
            if primitives[key] != .loaded(report) {
                primitives[key] = .loaded(report)
                // Its items' sessions may have changed with it.
                primitiveDetails = primitiveDetails.filter { !$0.key.hasPrefix("\(key)\n") }
            }
        } catch {
            primitives[key] = .failed("\(error)")
        }
    }

    nonisolated static func primitiveKey(kind: String, name: String, days: Int?) -> String { "\(days ?? 0)\n\(kind)\n\(name)" }

    func loadPrimitive(kind: String, name: String, days: Int?) async {
        let key = Self.primitiveKey(kind: kind, name: name, days: days)
        if case .loaded = primitiveDetails[key] { return }
        primitiveDetails[key] = .loading
        do {
            if let item = try await client.primitive(kind: kind, name: name, days: days) {
                primitiveDetails[key] = .loaded(item)
            } else {
                primitiveDetails[key] = .failed("The engine knows nothing by that name any more.")
            }
        } catch {
            primitiveDetails[key] = .failed("\(error)")
        }
    }

    func loadClaude() async {
        if claude == nil { claude = .loading }
        do {
            claude = .loaded(try await client.claude())
            claudeReadAt = Date()
        } catch {
            claude = .failed("\(error)")
        }
    }

    /// The images and the time below are kept only when the session is still the document they were
    /// asked of: after it was dropped they have nowhere to go, and after it was read again
    /// `reloadModel` has asked for them anew.
    func loadImages(_ id: String) async {
        if case .loaded = images[id] { return }
        let generation = generations[id, default: 0]
        images[id] = .loading
        let result: Loadable<[SessionImage]>
        do {
            result = .loaded(try await client.images(session: id))
        } catch {
            result = .failed("\(error)")
        }
        if generations[id, default: 0] == generation { images[id] = result }
    }

    func loadTime(_ id: String) async {
        if case .loaded = times[id] { return }
        let generation = generations[id, default: 0]
        times[id] = .loading
        let result: Loadable<SessionTime>
        do {
            result = .loaded(try await client.time(session: id, top: 8))
        } catch {
            result = .failed("\(error)")
        }
        if generations[id, default: 0] == generation { times[id] = result }
    }

    /// Keyword search inside one session: the nodes that match, in reading order.
    func find(_ query: String, in id: String, kind: String? = nil) async -> [SearchHit] {
        (try? await client.search(query, session: id, kind: kind, limit: 500)) ?? []
    }

    /// Search across every archived session. A failure is its reason, in words.
    func search(_ query: String, kind: String? = nil, mode: String? = nil) async -> Result<[SearchHit], SkitError> {
        do {
            return .success(try await client.search(query, kind: kind, mode: mode, limit: 400))
        } catch let error as SkitError {
            return .failure(error)
        } catch {
            return .failure(.unreachable("\(error)"))
        }
    }

    /// The session, or one turn of it, as Markdown; nil (and a notice) when the engine cannot write it.
    func markdown(_ id: String, turn: Int? = nil) async -> String? {
        do {
            return try await client.markdown(session: id, turn: turn)
        } catch {
            notice = "\(error)"
            return nil
        }
    }

    // MARK: What the human adds

    /// Sets or, with empty text, removes the note on a node (or on the session: key "session").
    /// The answer is what the engine holds afterwards. A note that could not be saved is kept in
    /// `unsavedNotes` (and said in a notice), so its editor opens on it again.
    @discardableResult
    func setNote(_ id: String, key: String, _ text: String) async -> NoteSave {
        let draft = Self.noteDraftKey(id, key)
        do {
            let kept = try await client.annotate(session: id, AnnotationPatch(notes: [key: text.trimmingCharacters(in: .whitespacesAndNewlines)]))
            annotations[id] = kept
            unsavedNotes[draft] = nil
            return .saved(kept.notes[key] ?? "")
        } catch {
            unsavedNotes[draft] = text
            notice = "The note was not saved: \(error)"
            return .failed("\(error)")
        }
    }

    nonisolated static func noteDraftKey(_ id: String, _ key: String) -> String { id + "\n" + key }

    /// What was typed for this note and could not be saved, if anything.
    func unsavedNote(_ id: String, key: String) -> String? { unsavedNotes[Self.noteDraftKey(id, key)] }

    func togglePin(_ id: String) async {
        await annotate(id, AnnotationPatch(pinned: !annotation(id).pinned))
    }

    func addTag(_ id: String, _ tag: String) async {
        let tag = tag.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !tag.isEmpty else { return }
        await annotate(id, AnnotationPatch(addTags: [tag]))
    }

    func removeTag(_ id: String, _ tag: String) async {
        await annotate(id, AnnotationPatch(removeTags: [tag]))
    }

    private func annotate(_ id: String, _ patch: AnnotationPatch) async {
        do {
            annotations[id] = try await client.annotate(session: id, patch)
        } catch {
            notice = "\(error)"
        }
    }

    func archiveNow(_ id: String) async {
        do {
            let results = try await client.archive(ids: [id])
            notice = results.first.map { "Archive: \($0.action), \($0.records) records." }
        } catch {
            notice = "\(error)"
        }
    }
}
