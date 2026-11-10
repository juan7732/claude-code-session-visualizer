import Foundation
import SkitKit
import SkitTestSupport
import Testing
@testable import SessionVisualizer

/// The app's state without its windows: what the store holds after it
/// connects, and what a pin, a tag and a filter do to it.
@Suite struct StoreTests {
    static func store(_ server: StubServer) -> AppStore {
        AppStore(locator: EngineLocator(environment: [:], homeDirectory: "/nonexistent"), socketPath: server.path, managesEngine: false)
    }

    @Test func connectsAndLoadsWhatTheWindowShows() async throws {
        let server = try Fake.engine()
        let store = Self.store(server)
        await store.connect()
        #expect(store.engine == .ready)
        #expect(store.sessions.map(\.id) == ["aaa", "bbb", "ccc"])
        #expect(store.isLive("bbb") && !store.isLive("aaa"))
        #expect(store.liveCount == 1)
        #expect(store.session("ccc")?.tools.isEmpty == true)

        await store.loadStats("aaa")
        guard case .loaded(let stats) = store.stats["aaa"] else {
            Issue.record("stats for a known session should load: \(String(describing: store.stats["aaa"]))")
            return
        }
        #expect(stats.id == "aaa" && stats.turns == 2)
        await store.loadStats("zzz")
        #expect(store.stats["zzz"] == .failed("no route"))
    }

    @Test func nothingServingIsAFailureNotAHang() async {
        let store = AppStore(locator: EngineLocator(environment: [:], homeDirectory: "/nonexistent"), socketPath: StubServer.freshPath(), managesEngine: false)
        await store.connect()
        guard case .failed = store.engine else {
            Issue.record("expected failed, got \(store.engine)")
            return
        }
    }

    @Test func pinsAndTagsGoThroughTheEngine() async throws {
        let server = try Fake.engine()
        let store = Self.store(server)
        await store.connect()

        await store.togglePin("aaa")
        #expect(store.annotation("aaa").pinned)
        await store.addTag("aaa", " #keep ")
        await store.addTag("bbb", "later")
        await store.addTag("bbb", "   ")
        #expect(store.annotation("aaa").tags == ["keep"])
        #expect(store.allTags == ["keep", "later"])
        await store.removeTag("aaa", "keep")
        await store.togglePin("aaa")
        #expect(store.annotation("aaa") == Annotation())

        // What the engine refuses is said, and the store keeps what it had.
        await store.togglePin("ccc")
        #expect(!store.annotation("ccc").pinned)
        #expect(store.notice == "disk full")

        // A reload brings back what the engine holds, not what the store guessed.
        await store.refresh()
        #expect(store.annotation("bbb").tags == ["later"])
    }

    @Test func rowsArePinnedFirstThenOrdered() async throws {
        let server = try Fake.engine()
        let store = Self.store(server)
        await store.connect()
        let window = WindowState()

        #expect(window.rows(in: store, sort: .newest).map(\.id) == ["bbb", "ccc", "aaa"])
        #expect(window.rows(in: store, sort: .turns).map(\.id) == ["bbb", "ccc", "aaa"])
        #expect(window.rows(in: store, sort: .cost).map(\.id) == ["aaa", "ccc", "bbb"])

        await store.togglePin("aaa")
        #expect(window.rows(in: store, sort: .newest).map(\.id) == ["aaa", "bbb", "ccc"])

        window.filterProject = "/Users/me/work/alpha"
        #expect(window.rows(in: store, sort: .newest).map(\.id) == ["aaa", "ccc"])
        await store.addTag("aaa", "keep")
        window.filterTag = "keep"
        #expect(window.rows(in: store, sort: .newest).map(\.id) == ["aaa"])

        // Projects in the order their newest session was active.
        let projects = window.projects(in: store)
        #expect(projects.map(\.cwd) == ["/Users/me/work/beta", "/Users/me/work/alpha"])
        #expect(projects.map(\.count) == [1, 2])

        window.page = .session("bbb")
        #expect(window.sessionID == "bbb")
    }
}

/// What the stand-in engine answers. Outside the main actor: the stub server calls it from its own thread.
nonisolated enum Fake {
    /// Three sessions in two projects; the middle one is live.
    static func row(_ id: String, cwd: String, last: String, turns: Int, cost: Double? = nil) -> String {
        """
        {"id":"\(id)","project":"p","title":"Session \(id)","cwd":"\(cwd)","first_at":"2026-11-01T10:00:00Z","last_at":"\(last)",
         "duration":"1h 00m","prompts":\(turns),"turns":\(turns),"system_turns":0,"requests":\(turns * 3),"tool_calls":4,"tool_errors":0,
         "images":0,"compactions":0,"api_errors":0,"subagents":0,"branches":0,
         "usage":{"input_tokens":1,"output_tokens":\(turns * 1000),"cache_creation_input_tokens":0,"cache_read_input_tokens":0},
         "cache_hit_ratio":0.5,"models":[],"tools":null\(cost.map { ",\"claude_code_cost_usd\":\($0)" } ?? "")}
        """
    }

    static let sessions = "[" + [
        row("aaa", cwd: "/Users/me/work/alpha", last: "2026-11-03T10:00:00Z", turns: 2, cost: 9.5),
        row("bbb", cwd: "/Users/me/work/beta", last: "2026-11-05T10:00:00Z", turns: 9),
        row("ccc", cwd: "/Users/me/work/alpha", last: "2026-11-04T10:00:00Z", turns: 5, cost: 1.25),
    ].joined(separator: ",") + "]"

    /// A fake that is never too old: it lists whatever this build of the client requires.
    static let routes = #"{"version":"t","routes":["# + SkitClient.requiredRoutes.map { "\"\($0)\"" }.joined(separator: ",") + "]}"
    static let status = #"{"version":"t","uptime":"1s","claude_dir":"/c","skit_home":"/s","index":{"sessions":3,"archived":3,"segments":9,"bytes":10},"live":[{"pid":7,"sessionId":"bbb","cwd":"/Users/me/work/beta","name":"beta-1","status":"busy","version":"2"}],"sessions_on_disk":3,"cached_sessions":0}"#

    /// A stand-in for `skit serve` that remembers pins and tags like the real one.
    static func engine() throws -> StubServer {
        let state = Annotations()
        return try StubServer { request in
            let line = request.prefix { $0 != "\r" }
            func json(_ text: String) -> Data { StubServer.http(200, Data(text.utf8)) }
            if line.hasPrefix("GET /v0 ") { return json(routes) }
            if line.hasPrefix("GET /v0/status ") { return json(status) }
            if line.hasPrefix("GET /v0/sessions ") { return json(sessions) }
            if line.hasPrefix("GET /v0/annotations ") { return json(state.all()) }
            if line.hasPrefix("PATCH /v0/sessions/") {
                let id = String(line.split(separator: "/")[3])
                if id == "ccc" { return StubServer.http(500, Data(#"{"error":"disk full"}"#.utf8)) }
                let body = request.range(of: "\r\n\r\n").map { String(request[$0.upperBound...]) } ?? "{}"
                return json(state.apply(id, body))
            }
            if line.hasPrefix("GET /v0/sessions/aaa/stats ") { return json(row("aaa", cwd: "/Users/me/work/alpha", last: "2026-11-03T10:00:00Z", turns: 2)) }
            // The session itself is the recorded synthetic fixture.
            if line.hasPrefix("GET /v0/sessions/aaa/relations ") { return StubServer.http(200, (try? Fixtures.data("relations.json")) ?? Data()) }
            if line.hasPrefix("GET /v0/sessions/aaa/actions/3 ") { return StubServer.http(200, (try? Fixtures.data("action.json")) ?? Data()) }
            if line.hasPrefix("GET /v0/sessions/aaa/actions/0?agent=") { return StubServer.http(200, (try? Fixtures.data("subagent-action.json")) ?? Data()) }
            if line.hasPrefix("GET /v0/sessions/aaa/compactions/0 ") { return StubServer.http(200, (try? Fixtures.data("compaction.json")) ?? Data()) }
            if line.hasPrefix("GET /v0/sessions/aaa/export?format=markdown&turn=0 ") { return StubServer.http(200, (try? Fixtures.data("export-turn.md")) ?? Data()) }
            if line.hasPrefix("GET /v0/search?q=xxxx") { return StubServer.http(200, (try? Fixtures.data("search-prompts.json")) ?? Data()) }
            if line.hasPrefix("GET /v0/search?") { return json("[]") }
            if line.hasPrefix("GET /v0/sessions/aaa ") { return StubServer.http(200, (try? Fixtures.data("document.json")) ?? Data()) }
            return StubServer.http(404, Data(#"{"error":"no route"}"#.utf8))
        }
    }
}

/// The stub's memory of pins and tags.
nonisolated final class Annotations: @unchecked Sendable {
    private let lock = NSLock()
    private var byID: [String: Annotation] = [:]

    func all() -> String {
        lock.withLock { String(decoding: try! JSONEncoder().encode(byID), as: UTF8.self) }
    }

    func apply(_ id: String, _ body: String) -> String {
        lock.withLock {
            let patch = (try? JSONDecoder().decode(AnnotationPatch.self, from: Data(body.utf8))) ?? AnnotationPatch()
            var note = byID[id] ?? Annotation()
            if let pinned = patch.pinned { note.pinned = pinned }
            note.tags = (note.tags + (patch.addTags ?? [])).filter { !(patch.removeTags ?? []).contains($0) }
            for (key, text) in patch.notes ?? [:] { note.notes[key] = text.isEmpty ? nil : text }
            byID[id] = note
            return String(decoding: try! JSONEncoder().encode(note), as: UTF8.self)
        }
    }
}
