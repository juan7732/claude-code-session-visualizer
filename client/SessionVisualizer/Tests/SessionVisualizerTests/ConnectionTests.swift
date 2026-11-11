import Foundation
import Observation
import SkitKit
import SkitTestSupport
import Testing
@testable import SessionVisualizer

/// A value a stub's thread and the test both touch.
nonisolated final class Shared<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

/// The store and its engine over time: connecting once, staying up through a bad poll, one loop for every window.
@Suite struct ConnectionTests {
    private static func executable() throws -> String {
        let path = NSTemporaryDirectory() + "sk-bin-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private nonisolated static func agent() throws -> ServiceStatus {
        try JSONDecoder.skit().decode(ServiceStatus.self, from: Fixtures.data("service-status.json"))
    }

    private static func requests(_ server: StubServer, _ prefix: String) -> Int {
        server.requests.filter { $0.hasPrefix(prefix) }.count
    }

    @Test func twoWindowsConnectingInstallTheAgentOnce() async throws {
        let path = StubServer.freshPath()
        let binary = try Self.executable()
        defer { try? FileManager.default.removeItem(atPath: binary) }
        let installs = Shared(0)
        let started = Shared<StubServer?>(nil)
        let store = AppStore(locator: EngineLocator(environment: ["SKIT_BIN": binary], homeDirectory: "/nonexistent", trustsOnlyItsHelper: false),
                             socketPath: path, managesEngine: true, bundledVersion: nil)
        store.installAgent = { _ in
            installs.update { $0 += 1 }
            // Long enough for the second window to ask while the first install is under way.
            Thread.sleep(forTimeInterval: 0.15)
            if started.value == nil { started.value = try Fake.engine(path: path) }
            return try Self.agent()
        }
        async let first: Void = store.connect()
        async let second: Void = store.connect()
        _ = await (first, second)
        #expect(installs.value == 1, "the second window waits for the first one's connect")
        #expect(store.engine == .ready)
        // Restart goes through the same door.
        async let again: Void = store.restartAgent()
        async let also: Void = store.restartAgent()
        _ = await (again, also)
        #expect(installs.value == 2 && store.engine == .ready)
    }

    @Test func aSlowPollLeavesTheWindowsUp() async throws {
        let slow = Shared(false)
        let answer = Fake.responder()
        let server = try StubServer(concurrent: true) { request in
            if slow.value { Thread.sleep(forTimeInterval: 0.5) }
            return answer(request)
        }
        let store = AppStore(locator: EngineLocator(environment: [:], homeDirectory: "/nonexistent"), socketPath: server.path, managesEngine: false, pollTimeout: 0.1)
        await store.connect()
        #expect(store.engine == .ready)

        slow.value = true
        await store.refresh(polling: true)
        #expect(store.engine == .ready, "a poll that timed out is not an engine that is gone")
        #expect(store.sessions.count == 3)
        #expect(store.notice?.hasPrefix("skit is slow to answer") == true)

        slow.value = false
        store.notice = nil
        await store.refresh(polling: true)
        #expect(store.engine == .ready && store.notice == nil)
    }

    @Test func anEngineThatIsGoneSendsTheWindowsBackToConnecting() async throws {
        let server = try Fake.engine()
        let store = StoreTests.store(server)
        store.reattachPause = .milliseconds(20)
        await store.connect()
        #expect(store.engine == .ready)
        server.stop()
        await store.refresh(polling: true)
        // Attach-only here, so connecting again ends on why; the app proper starts the agent again.
        #expect(store.engine == .failed("Nothing is serving on \(server.path)."))
    }

    @Test func anAgentThatIsRestartingIsWaitedFor() async throws {
        let server = try Fake.engine()
        let store = StoreTests.store(server)
        store.reattachPause = .milliseconds(400)
        await store.connect()
        server.stop()
        let back = Shared<StubServer?>(nil)
        let path = server.path
        let restart = Task.detached {
            try await Task.sleep(for: .milliseconds(80))
            back.value = try Fake.engine(path: path)
        }
        await store.refresh(polling: true)
        try await restart.value
        #expect(store.engine == .ready, "nothing listening for a moment is an agent restarting")
        #expect(store.sessions.count == 3)
    }

    @Test func oneLoopPollsWhileAWindowIsOpen() async throws {
        let server = try Fake.engine()
        let store = StoreTests.store(server)
        await store.connect()
        store.pollInterval = .milliseconds(40)
        let (one, two) = (WindowState(), WindowState())
        let before = Self.requests(server, "GET /v0/sessions ")

        store.register(one)
        store.register(two)
        try await Task.sleep(for: .milliseconds(400))
        let polled = Self.requests(server, "GET /v0/sessions ") - before
        #expect(polled >= 1, "the list is kept current while a window is open")
        #expect(polled <= 11, "two windows are one loop: 400 ms at 40 ms is ten polls, not twenty")

        // One window closes: the other still has its list kept current.
        store.unregister(one)
        let withOne = Self.requests(server, "GET /v0/sessions ")
        try await Task.sleep(for: .milliseconds(200))
        #expect(Self.requests(server, "GET /v0/sessions ") > withOne)

        // The last one closes: nothing is asked any more.
        store.unregister(two)
        try await Task.sleep(for: .milliseconds(120))
        let after = Self.requests(server, "GET /v0/sessions ")
        try await Task.sleep(for: .milliseconds(200))
        #expect(Self.requests(server, "GET /v0/sessions ") == after)
    }

    @Test func aPollThatFindsNothingNewWakesNoView() async throws {
        let server = try Fake.engine()
        let store = StoreTests.store(server)
        await store.connect()
        let woken = Shared(false)
        withObservationTracking {
            _ = store.sessions
            _ = store.sessionsByID
            _ = store.annotations
            _ = store.liveIDs
            _ = store.status
        } onChange: {
            woken.value = true
        }
        await store.refresh(polling: true)
        #expect(!woken.value, "the same rows are not assigned again")

        // Something did change: a pin. Then the views that read annotations are told.
        await store.togglePin("aaa")
        #expect(woken.value)
        #expect(store.session("bbb")?.id == "bbb" && store.session("nope") == nil)
        #expect(store.isLive("bbb") && store.liveIDs == ["bbb"])
    }

    @Test func aCoreAnswerThisAppCannotReadOffersTheRestart() async throws {
        let server = try StubServer { request in
            let line = request.prefix { $0 != "\r" }
            if line.hasPrefix("GET /v0 ") { return StubServer.http(200, Data(Fake.routes.utf8)) }
            // The route is there by name; what it says is another build's.
            if line.hasPrefix("GET /v0/status ") { return StubServer.http(200, Data(#"{"version":1}"#.utf8)) }
            if line.hasPrefix("GET /v0/sessions ") { return StubServer.http(200, Data(Fake.sessions.utf8)) }
            return StubServer.http(200, Data("{}".utf8))
        }
        let store = AppStore(locator: EngineLocator(environment: [:], homeDirectory: "/nonexistent"), socketPath: server.path, managesEngine: false, bundledVersion: "v9")
        await store.connect()
        guard case .unreadable(let version, let detail) = store.engine else {
            Issue.record("expected unreadable, got \(store.engine)")
            return
        }
        #expect(version == "t" && detail.hasPrefix("/v0/status: "))
        #expect(store.versionMismatch?.running == "t" && store.versionMismatch?.bundled == "v9")
    }

    @Test func anEngineReplacedByOneThisAppCannotReadStopsThePolls() async throws {
        let replaced = Shared(false)
        let answer = Fake.responder()
        let server = try StubServer { request in
            if replaced.value, request.hasPrefix("GET /v0/sessions ") { return StubServer.http(200, Data(#"[{"id":7}]"#.utf8)) }
            return answer(request)
        }
        let store = StoreTests.store(server)
        await store.connect()
        #expect(store.engine == .ready)
        replaced.value = true
        await store.refresh(polling: true)
        guard case .unreadable(let version, let detail) = store.engine else {
            Issue.record("expected unreadable, got \(store.engine)")
            return
        }
        #expect(version == "t" && detail.hasPrefix("/v0/sessions: "))
    }

    @Test func anEngineOfAnotherBuildIsSaidOnce() async throws {
        let server = try Fake.engine()
        func store(_ bundled: String?) -> AppStore {
            AppStore(locator: EngineLocator(environment: [:], homeDirectory: "/nonexistent"), socketPath: server.path, managesEngine: false, bundledVersion: bundled)
        }
        let other = store("v9")
        await other.connect()
        #expect(other.engine == .ready, "an engine that serves every route is used, whatever its version")
        #expect(other.engineVersion == "t" && other.versionMismatch?.bundled == "v9")
        #expect(other.notice == "The background agent runs skit t; this app carries v9. Settings › Engine restarts it with the app's own.")
        other.notice = nil
        await other.connect()
        #expect(other.notice == nil, "said once a run")

        let same = store("t")
        await same.connect()
        #expect(same.versionMismatch == nil && same.notice == nil)
        // Without a bundle (`swift run`) there is no version to hold the engine to.
        let unbundled = store(nil)
        await unbundled.connect()
        #expect(unbundled.versionMismatch == nil && unbundled.notice == nil)
    }

    @Test func nothingIsInstalledFromACopyThatGoesAway() async throws {
        let root = NSTemporaryDirectory() + "sk-bundle-\(getpid())-\(UInt32.random(in: 0...UInt32.max))/AppTranslocation/6F1B/d"
        let helpers = root + "/SessionVisualizer.app/Contents/Helpers"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: helpers + "/skit"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helpers + "/skit")
        let locator = EngineLocator(environment: [:], homeDirectory: root, helpersDirectory: helpers, trustsOnlyItsHelper: true)
        let installs = Shared(0)

        // Nothing serving: the window asks for the app to be moved, and installs nothing.
        let alone = AppStore(locator: locator, socketPath: StubServer.freshPath(), managesEngine: true, bundledVersion: nil)
        alone.installAgent = { _ in
            installs.update { $0 += 1 }
            return try Self.agent()
        }
        #expect(alone.installRefusal == .translocated)
        await alone.connect()
        #expect(alone.engine == .misplaced(.translocated))
        await alone.restartAgent()
        #expect(installs.value == 0 && alone.notice == AppStore.moveAdvice(.translocated))

        // An agent already serving: the app works for this run, and says to move it.
        let server = try Fake.engine()
        let attached = AppStore(locator: locator, socketPath: server.path, managesEngine: true, bundledVersion: nil)
        attached.installAgent = alone.installAgent
        await attached.connect()
        #expect(attached.engine == .ready && attached.notice == AppStore.moveAdvice(.translocated))
        await attached.restartAgent()
        #expect(installs.value == 0 && attached.engine == .ready)
        #expect(AppStore.moveAdvice(.volume).contains("disk image") && AppStore.moveAdvice(.translocated).contains("Applications"))
    }
}

/// The sessions the store keeps loaded: which, for how long, and what is kept about them.
@Suite struct ModelCacheTests {
    /// An engine with any number of sessions: every id answers with the fixture's document. `slowAction` holds an action's answer back.
    static func engine(slowAction: Shared<TimeInterval> = Shared(0)) throws -> StubServer {
        let answer = Fake.responder()
        return try StubServer(concurrent: true) { request in
            let line = request.prefix { $0 != "\r" }
            if line.hasPrefix("GET /v0/sessions/"), !line.hasPrefix("GET /v0/sessions/aaa") {
                if line.contains("/relations ") { return StubServer.http(200, (try? Fixtures.data("relations.json")) ?? Data()) }
                if line.contains("/actions/") {
                    let wait = slowAction.value
                    if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                    return StubServer.http(200, (try? Fixtures.data("action.json")) ?? Data())
                }
                return StubServer.http(200, (try? Fixtures.data("document.json")) ?? Data())
            }
            return answer(request)
        }
    }

    private static func loaded(_ store: AppStore) -> Set<String> {
        Set(store.models.compactMap { if case .loaded = $0.value { $0.key } else { nil } })
    }

    @Test func aSessionAWindowShowsIsNeverDropped() async throws {
        let server = try Self.engine()
        let store = StoreTests.store(server)
        await store.connect()
        store.modelLimit = 2
        let (reader, browser) = (WindowState(), WindowState())
        store.register(reader)
        store.register(browser)
        defer {
            store.unregister(reader)
            store.unregister(browser)
        }

        // One window stays on s1 while the other opens session after session.
        reader.page = .session("s1")
        await store.loadModel("s1")
        for id in ["s2", "s3", "s4", "s5"] {
            browser.page = .session(id)
            await store.loadModel(id)
            #expect(store.model("s1") != nil, "s1 is on show in the other window while \(id) loads")
        }
        #expect(Self.loaded(store) == ["s1", "s5"])

        // The reader closes: s1 is now only the session used longest ago.
        store.unregister(reader)
        browser.page = .session("s6")
        await store.loadModel("s6")
        #expect(Self.loaded(store) == ["s5", "s6"])

        // More on show than the limit: all of them stay.
        let (third, fourth) = (WindowState(), WindowState())
        store.register(third)
        store.register(fourth)
        defer {
            store.unregister(third)
            store.unregister(fourth)
        }
        third.page = .session("s7")
        await store.loadModel("s7")
        fourth.page = .compare
        fourth.compare.first = "s8"
        fourth.compare.second = "s9"
        await store.loadModel("s8")
        await store.loadModel("s9")
        #expect(Self.loaded(store) == ["s6", "s7", "s8", "s9"])
    }

    @Test func whatAWindowShows() {
        let window = WindowState()
        #expect(window.shownSessions.isEmpty)
        window.page = .session("s1")
        #expect(window.shownSessions == ["s1"])
        window.compare.first = "a"
        window.page = .compare
        #expect(window.shownSessions == ["a"])
        window.compare.second = "b"
        #expect(window.shownSessions == ["a", "b"])
        window.page = .stats
        #expect(window.shownSessions.isEmpty)
    }

    @Test func theSessionUsedLongestAgoGoesFirst() async throws {
        let server = try Self.engine()
        let store = StoreTests.store(server)
        await store.connect()
        store.modelLimit = 2
        await store.loadModel("s1")
        await store.loadModel("s2")
        // s1 is opened again: a use, though nothing is read.
        let documents = server.requests.count
        await store.loadModel("s1")
        #expect(server.requests.count == documents)
        await store.loadModel("s3")
        #expect(Self.loaded(store) == ["s1", "s3"], "s2 was used longest ago, not s1")
    }

    @Test func aSessionBeingReadIsNotReadTwice() async throws {
        let server = try Self.engine()
        let store = StoreTests.store(server)
        await store.connect()
        // Resting on a row starts the read; the click that follows asks again while it is under way.
        async let hover: Void = store.loadModel("s1")
        async let click: Void = store.loadModel("s1")
        _ = await (hover, click)
        #expect(store.model("s1") != nil)
        #expect(server.requests.filter { $0.hasPrefix("GET /v0/sessions/s1 ") }.count == 1)
        #expect(server.requests.filter { $0.hasPrefix("GET /v0/sessions/s1/relations ") }.count == 1)
    }

    @Test func whatArrivesForADroppedSessionIsNotKept() async throws {
        let slow = Shared<TimeInterval>(0.4)
        let server = try Self.engine(slowAction: slow)
        let store = StoreTests.store(server)
        await store.connect()
        store.modelLimit = 1
        await store.loadModel("s1")
        let late = Task { await store.loadAction("s1", 3) }
        try await Task.sleep(for: .milliseconds(80))
        #expect(store.actionDetails["s1"]?[3] == .loading)
        // Another session takes s1's place while the action's result is on its way.
        await store.loadModel("s2")
        #expect(store.model("s1") == nil)
        await late.value
        #expect(store.actionDetails["s1"] == nil, "a result for a session that is no longer loaded has nowhere to go")
        #expect(store.times["s1"] == nil && store.images["s1"] == nil)
    }

    @Test func whatWasAskedOfTheOldDocumentIsAskedAgainAfterAReload() async throws {
        let slow = Shared<TimeInterval>(0.4)
        let server = try Self.engine(slowAction: slow)
        let store = StoreTests.store(server)
        await store.connect()
        await store.loadModel("s1")
        let late = Task { await store.loadAction("s1", 3) }
        try await Task.sleep(for: .milliseconds(80))
        slow.value = 0
        // The session is read again while the result is on its way: the result that arrives was asked of the old one.
        await store.reloadModel("s1")
        await late.value
        guard case .loaded = store.actionDetails["s1"]?[3] else {
            Issue.record("the row that asked once still gets its result: \(String(describing: store.actionDetails["s1"]?[3]))")
            return
        }
        #expect(server.requests.filter { $0.hasPrefix("GET /v0/sessions/s1/actions/3 ") }.count == 2)
    }

    @Test func aReloadThatChangedOnlyTheRelationsIsAnotherModel() throws {
        let decoder = JSONDecoder.skit()
        let doc = try decoder.decode(SessionDocument.self, from: Fixtures.data("document.json"))
        var relations = try decoder.decode(Relations.self, from: Fixtures.data("relations.json"))
        let before = SessionModel(doc: doc, relations: relations)
        #expect(before == SessionModel(doc: doc, relations: relations))
        // The same transcript, one more file known to have been touched.
        let file = try #require(relations.files.first)
        relations.files.append(file)
        #expect(before != SessionModel(doc: doc, relations: relations))
    }

    @Test func camerasOfSessionsThatAreGoneAreForgotten() throws {
        let keys = ["canvas.camera.aaa", "canvas.camera.score.aaa", "canvas.camera.gone", "canvas.camera.score.gone", "canvas.background", "search.recent", "canvas.camera.score.bbb"]
        #expect(CanvasMemory.stale(keys, keeping: ["aaa", "bbb"]).sorted() == ["canvas.camera.gone", "canvas.camera.score.gone"])

        let suite = "sk-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in keys { defaults.set(Data([1]), forKey: key) }
        // An empty list forgets nothing: it is more likely an engine that has not looked yet.
        CanvasMemory.prune(keeping: [], in: defaults)
        #expect(defaults.data(forKey: "canvas.camera.gone") != nil)
        CanvasMemory.prune(keeping: ["aaa", "bbb"], in: defaults)
        #expect(defaults.data(forKey: "canvas.camera.gone") == nil && defaults.data(forKey: "canvas.camera.score.gone") == nil)
        #expect(defaults.data(forKey: SettingsKey.canvasCamera("aaa")) != nil && defaults.data(forKey: SettingsKey.canvasCamera("bbb", score: true)) != nil)
        #expect(defaults.data(forKey: "canvas.background") != nil && defaults.data(forKey: "search.recent") != nil)
    }
}

/// A note is saved when the engine says so, and what could not be saved is not lost.
@Suite struct NoteTests {
    @Test func aNoteIsSavedWhenTheEngineSaysSo() async throws {
        let server = try Fake.engine()
        let store = StoreTests.store(server)
        await store.connect()

        // The stand-in refuses every change to "ccc".
        let refused = await store.setNote("ccc", key: "session", "  keep this  ")
        #expect(refused == .failed("disk full"))
        #expect(store.annotation("ccc").notes.isEmpty, "what the engine did not take is not shown as held")
        #expect(store.unsavedNote("ccc", key: "session") == "  keep this  ", "the words are kept for the editor to open on")
        #expect(store.notice == "The note was not saved: disk full")

        let kept = await store.setNote("aaa", key: "turn:0", "  check this  ")
        #expect(kept == .saved("check this") && store.unsavedNote("aaa", key: "turn:0") == nil)
        #expect(store.annotation("aaa").notes == ["turn:0": "check this"])
    }

    @Test func theEditorSaysSavedOnlyAfterTheAnswer() {
        let hint = "Add a note."
        var edit = NoteEdit(saved: "", unsaved: nil)
        #expect(!edit.dirty && edit.status(hint: hint) == hint)
        edit.text = "keep this "
        #expect(edit.dirty && edit.status(hint: hint) == "Not saved yet." && !edit.failed)

        // Sent, not answered: not "Saved." yet.
        edit.saving = true
        #expect(edit.status(hint: hint) == "Saving…")
        edit.finish(.failed("disk full"))
        #expect(edit.dirty && edit.failed && edit.status(hint: hint) == "Not saved: disk full")
        #expect(edit.saved.isEmpty && edit.text == "keep this ", "the editor keeps what was typed")

        // The second try goes through: saved is what the engine answered with.
        edit.saving = true
        edit.finish(.saved("keep this"))
        #expect(!edit.dirty && !edit.failed && edit.status(hint: hint) == "Saved.")
        // Typing on after a save is unsaved again, without the old failure.
        edit.text += "and more"
        #expect(edit.status(hint: hint) == "Not saved yet.")

        // Opened again after a save that failed while the editor was closing: the words are back, and it says so.
        let reopened = NoteEdit(saved: "old", unsaved: "new words")
        #expect(reopened.text == "new words" && reopened.saved == "old" && reopened.dirty && reopened.failed)
        #expect(NoteEdit(saved: "old", unsaved: nil).status(hint: hint) == "Saved.")
    }
}
