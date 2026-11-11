import Foundation
import SkitKit
import SkitTestSupport
import Testing
@testable import SessionVisualizer

/// The Now page: what a card says, in what order the cards stand, when a reminder is due,
/// and how the app learns that an open session has moved on.
@Suite struct NowTests {
    private static func report(_ json: String) throws -> NowReport { try JSONDecoder.skit().decode(NowReport.self, from: Data(json.utf8)) }

    /// One session of each state, at 12:00:00.
    private static let all = #"""
    {"at":"2026-11-10T12:00:00Z","window_minutes":60,"running_outside_window":2,"sessions":[
     {"id":"tool","project":"-Users-me-work","cwd":"/Users/me/work","title":"Fixing the build","running":true,"name":"work-3","entrypoint":"claude-vscode","pid":30,"process_status":"busy",
      "state":"tool","since":"2026-11-10T11:59:48Z","tools":[{"id":"t1","name":"Bash","summary":"Run the tests","since":"2026-11-10T11:59:48Z"}],"last_prompt":"Fix the build","last_at":"2026-11-10T11:59:48Z",
      "cache":{"read_tokens":900,"written_tokens":90,"uncached_tokens":10,"hit_ratio":0.9,"context_tokens":412000,"ttl_seconds":3600,"last_request_at":"2026-11-10T11:59:40Z","expires_at":"2026-11-10T12:59:40Z","seconds_left":3580}},
     {"id":"model","project":"-Users-me-work","running":true,"pid":10,"entrypoint":"cli","state":"model","since":"2026-11-10T11:59:20Z","last_at":"2026-11-10T11:59:20Z"},
     {"id":"you","project":"-Users-me-other","cwd":"/Users/me/other","title":"Notes","running":true,"pid":20,"state":"you","since":"2026-11-10T11:55:52Z","said":"See [the plan](docs/plan.md) and `make test`.","last_at":"2026-11-10T11:55:52Z",
      "cache":{"read_tokens":1,"written_tokens":1,"uncached_tokens":1,"hit_ratio":0.5,"context_tokens":3000,"ttl_seconds":300,"last_request_at":"2026-11-10T11:55:50Z","expires_at":"2026-11-10T12:00:50Z","seconds_left":50}},
     {"id":"blocked","project":"-Users-me-work","running":true,"pid":40,"state":"blocked","since":"2026-11-10T11:59:00Z","waiting_for":"approve Bash","tools":[{"id":"t2","name":"Bash","since":"2026-11-10T11:58:59Z"}],"last_at":"2026-11-10T11:58:59Z"},
     {"id":"background","project":"-Users-me-work","running":true,"pid":50,"state":"background","since":"2026-11-10T11:57:00Z","subagents_running":2,"said":"Two reviewers are at it.","last_at":"2026-11-10T11:57:00Z"},
     {"id":"closed-old","project":"-Users-me-work","running":false,"state":"closed","since":"2026-11-10T11:10:00Z","last_at":"2026-11-10T11:10:00Z",
      "cache":{"read_tokens":1,"written_tokens":1,"uncached_tokens":1,"hit_ratio":1,"context_tokens":513000,"ttl_seconds":300,"last_request_at":"2026-11-10T11:09:50Z","expires_at":"2026-11-10T11:14:50Z","seconds_left":0}},
     {"id":"closed-new","project":"-Users-me-work","running":false,"state":"closed","since":"2026-11-10T11:40:00Z","last_at":"2026-11-10T11:40:00Z"},
     {"id":"later","project":"-Users-me-work","running":true,"pid":60,"state":"compacting","since":"2026-11-10T11:59:00Z","last_at":"2026-11-10T11:59:00Z",
      "cache":{"read_tokens":0,"written_tokens":0,"uncached_tokens":5,"hit_ratio":0,"context_tokens":5,"ttl_seconds":0,"last_request_at":"2026-11-10T11:59:00Z","seconds_left":0}}]}
    """#

    @Test func whatACardSays() throws {
        let report = try Self.report(Self.all)
        func session(_ id: String) throws -> NowReport.Session { try #require(report.sessions.first { $0.id == id }) }
        let tool = try session("tool"), model = try session("model"), you = try session("you"), blocked = try session("blocked")
        let background = try session("background"), closed = try session("closed-new"), later = try session("later")
        #expect(NowContent.headline(tool) == "Running Bash" && NowContent.detail(tool) == "Bash  Run the tests")
        #expect(NowContent.headline(model) == "The model is working" && NowContent.detail(model) == nil)
        // What it last said, without Markdown's marks.
        #expect(NowContent.headline(you) == "Waiting for you" && NowContent.detail(you) == "See the plan and make test.")
        #expect(NowContent.headline(blocked) == "Needs you: approve Bash" && NowContent.detail(blocked) == "Bash")
        #expect(NowContent.headline(background) == "Waiting for 2 subagents" && NowContent.detail(background) == "Two reviewers are at it.")
        #expect(NowContent.headline(closed) == "Closed" && NowContent.detail(closed) == "Nothing has been asked in it yet.")
        // A state from a newer engine is shown, not refused.
        #expect(later.state == .unknown && NowContent.headline(later) == "At work")
        var agents = tool
        agents.tools[0].name = "Agent"
        #expect(NowContent.headline(agents) == "A subagent is running")
        agents.tools.append(agents.tools[0])
        #expect(NowContent.headline(agents) == "Running 2 tools")
        #expect(NowContent.toolName("mcp__claude_ai_Google_Slides__update") == "Google Slides · update")

        #expect(NowContent.title(tool) == "Fixing the build" && NowContent.title(model) == "model" && NowContent.place(tool) == "work · VS Code" && NowContent.place(model).hasSuffix("terminal"))
        #expect(NowContent.place(closed) == Format.projectName(cwd: nil, slug: "-Users-me-work"))
        #expect(NowContent.stamp(report) == "8 sessions at work in the last hour: 1 needs you inside a turn, 1 waiting for you, 3 working, 2 closed. 2 more are open and quiet for longer.")
        #expect(NowContent.needsYou(.loaded(report)) == 2 && NowContent.needsYou(nil) == 0 && NowContent.needsYou(.loading) == 0)
        let empty = try Self.report(#"{"at":"2026-11-10T12:00:00Z","window_minutes":240,"running_outside_window":1,"sessions":[]}"#)
        #expect(NowContent.stamp(empty) == "Nothing was at work in the last 4 hours." && NowContent.nothing(empty).contains("1 session is open in Claude Code"))
        #expect(NowContent.span(1440) == "the last day" && NowContent.span(45) == "the last 45 minutes")
    }

    @Test func cardsKeepTheirPlaces() throws {
        // Running ones in the order their processes started, whatever moved last; then the closed ones, the latest first.
        let ordered = NowContent.ordered(try Self.report(Self.all).sessions).map(\.id)
        #expect(ordered == ["model", "you", "tool", "blocked", "background", "later", "closed-new", "closed-old"])
    }

    @Test func clocksAndTheCache() throws {
        let report = try Self.report(Self.all)
        let now = report.at
        #expect(NowContent.elapsed(from: now.addingTimeInterval(-12), to: now) == "12s")
        #expect(NowContent.elapsed(from: now.addingTimeInterval(-248), to: now) == "4m 08s")
        #expect(NowContent.elapsed(from: now.addingTimeInterval(-11280), to: now) == "3h 08m")
        #expect(NowContent.elapsed(from: now.addingTimeInterval(-190800), to: now) == "2d 5h")
        #expect(NowContent.elapsed(from: now.addingTimeInterval(5), to: now) == "0s")

        func cache(_ id: String) throws -> NowReport.Cache { try #require(report.sessions.first { $0.id == id }?.cache) }
        let toolCache = try cache("tool"), youCache = try cache("you"), oldCache = try cache("closed-old"), laterCache = try cache("later")
        let warm = NowContent.cache(toolCache, now: now, lead: 5)
        #expect(warm.level == .warm && warm.text == "Warm for 59m 40s" && warm.note == "90% from cache · 412k context" && abs(warm.fraction - 3580.0 / 3600) < 0.001)
        // Inside the last minutes; and the same cache a little later.
        let soon = NowContent.cache(youCache, now: now, lead: 5)
        #expect(soon.level == .soon && soon.text == "Warm for 50s" && abs(soon.fraction - 50.0 / 300) < 0.001)
        #expect(NowContent.cache(youCache, now: now.addingTimeInterval(60), lead: 5).level == .cold)
        let cold = NowContent.cache(oldCache, now: now, lead: 5)
        #expect(cold.level == .cold && cold.fraction == 0 && cold.text == "Cache expired 45m 10s ago" && cold.note == "the next prompt pays for 513k")
        let unknown = NowContent.cache(laterCache, now: now, lead: 5)
        #expect(unknown.level == .unknown && unknown.text == "Cache: lifetime not known")
        #expect(NowContent.cacheHelp(toolCache).contains("live an hour") && NowContent.cacheHelp(youCache).contains("five minutes") && NowContent.cacheHelp(laterCache).contains("not known"))
    }

    @Test func aReminderIsDueBeforeTheEnd() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ahead = CacheReminders.plan(expires: now.addingTimeInterval(3600), lead: 5, now: now)
        #expect(ahead.state == .ahead && ahead.fire == now.addingTimeInterval(3300))
        #expect(CacheReminders.plan(expires: now.addingTimeInterval(200), lead: 5, now: now).state == .due)
        #expect(CacheReminders.plan(expires: now, lead: 5, now: now).state == .gone)
        #expect(CacheReminders.plan(expires: now.addingTimeInterval(601), lead: 10, now: now).state == .ahead)
        #expect(CacheReminders.identifier("abc") == "cache-abc")

        let all = try Self.report(Self.all)
        let session = try #require(all.sessions.first { $0.id == "tool" })
        let expires = try #require(session.cache?.expiresAt)
        let words = CacheReminders.words(session, expires: expires, lead: 5, early: false)
        #expect(words.title == "Prompt cache expires in 5 minutes" && words.subtitle == "Fixing the build" && words.body.contains("412k tokens"))
        #expect(CacheReminders.words(session, expires: now, lead: 5, early: true).title.hasPrefix("Prompt cache expires at "))
        #expect(NowContent.reminderHelp(on: false, lead: 5, available: true, denied: false).contains("5 minutes left"))
        #expect(NowContent.reminderHelp(on: true, lead: 5, available: false, denied: false).contains("installed app"))
        #expect(NowContent.reminderHelp(on: true, lead: 5, available: true, denied: true).contains("System Settings"))

        // The bell is kept per session, and a session that left the window takes its bell with it.
        // (No notification is asked of the system here: tests have no application bundle.)
        let reminders = CacheReminders()
        #expect(!CacheReminders.available && !reminders.isOn("tool"))
        reminders.toggle(session, now: all.at)
        #expect(reminders.isOn("tool") && reminders.scheduled["tool"] == expires.addingTimeInterval(-300))
        let none = try Self.report(#"{"at":"2026-11-10T13:30:00Z","window_minutes":60,"running_outside_window":0,"sessions":[]}"#)
        reminders.sync(none)
        #expect(!reminders.isOn("tool") && reminders.scheduled.isEmpty)
    }

    @Test func backToWhereASessionRuns() throws {
        func host(_ json: String) throws -> NowReport.Host { try JSONDecoder.skit().decode(NowReport.Host.self, from: Data(json.utf8)) }
        let window = try host(#"{"kind":"editor","app":"Visual Studio Code","app_path":"/Applications/Visual Studio Code.app","open":"/w/pair.code-workspace","folders":["/w/a","/w/b"],"sure":true}"#)
        #expect(HostContent.title(window) == "Open in VS Code" && HostContent.target(window) == "/w/pair.code-workspace")
        #expect(HostContent.help(window) == "Brings the VS Code window that runs this session to the front (pair.code-workspace).")
        // Chosen by its folder: said so.
        let guessed = try host(#"{"kind":"editor","app":"Cursor","open":"/w/a","folders":["/w/a"],"sure":false}"#)
        #expect(HostContent.title(guessed) == "Open in Cursor" && HostContent.help(guessed).contains("did not say which window"))
        // A window on several folders that no workspace file names: the application is all that can be raised.
        let unnamed = try host(#"{"kind":"editor","app":"Visual Studio Code","folders":["/w/a","/w/b"],"sure":true}"#)
        #expect(HostContent.target(unnamed) == nil && HostContent.help(unnamed).contains("cannot be raised by itself"))
        // A terminal: its application comes forward; a folder is never opened in it.
        let terminal = try host(#"{"kind":"terminal","app":"Terminal","app_path":"/System/Applications/Utilities/Terminal.app","open":"/w/a","sure":true}"#)
        #expect(HostContent.title(terminal) == "Show Terminal" && HostContent.target(terminal) == nil && HostContent.help(terminal).contains("cannot be told from outside"))
        #expect(terminal.folders.isEmpty && HostContent.short("Visual Studio Code - Insiders") == "VS Code Insiders" && HostContent.short("iTerm2") == "iTerm2")
        // An application that is not on this Mac is not opened.
        let missing = try host(#"{"kind":"terminal","app":"No Such Terminal","app_path":"/Applications/No Such Terminal.app","sure":true}"#)
        #expect(HostOpener.application(missing) == nil && !HostOpener.open(missing))
    }

    /// The app reads a session once; the engine's look at what is at work says when it has moved on, and Refresh reads it again.
    @Test func anOpenSessionThatMovedOnIsNoticedAndReadAgain() async throws {
        let moved = Counter()
        let server = try StubServer { request in
            let line = request.prefix { $0 != "\r" }
            func json(_ text: String) -> Data { StubServer.http(200, Data(text.utf8)) }
            if line.hasPrefix("GET /v0 ") { return json(Fake.routes) }
            if line.hasPrefix("GET /v0/status ") { return json(Fake.status) }
            if line.hasPrefix("GET /v0/sessions ") { return json(Fake.sessions) }
            if line.hasPrefix("GET /v0/annotations ") { return json("{}") }
            if line.hasPrefix("GET /v0/sessions/aaa/relations ") { return StubServer.http(200, (try? Fixtures.data("relations.json")) ?? Data()) }
            if line.hasPrefix("GET /v0/sessions/aaa ") {
                moved.documents += 1
                return StubServer.http(200, (try? Fixtures.data("document.json")) ?? Data())
            }
            if line.hasPrefix("GET /v0/now") {
                // The fixture's document ends at 10:01:04; the session is said to have gone on a minute later.
                let last = moved.documents > 1 ? "2026-11-08T10:01:04Z" : "2026-11-08T10:02:04Z"
                return json(#"{"at":"2026-11-08T10:03:00Z","window_minutes":60,"running_outside_window":0,"sessions":[{"id":"aaa","project":"p","running":true,"pid":7,"state":"model","since":"\#(last)","last_at":"\#(last)"}]}"#)
            }
            return StubServer.http(404, Data(#"{"error":"no route"}"#.utf8))
        }
        let store = StoreTests.store(server)
        await store.connect()
        await store.loadModel("aaa")
        #expect(!store.isBehind("aaa"), "nothing is known of what is at work yet")
        await store.loadNow()
        #expect(store.isBehind("aaa") && store.nowSession("aaa")?.state == .model && !store.isBehind("bbb"))

        await store.reload(page: .session("aaa"))
        #expect(moved.documents == 2 && store.model("aaa") != nil && !store.isBehind("aaa") && !store.reloading)
        // Any other page: the list and what is at work are read again, no session is.
        await store.reload(page: .now)
        #expect(moved.documents == 2)
    }
}

/// Counts what the stub was asked, from its own thread.
nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var documents: Int {
        get { lock.withLock { count } }
        set { lock.withLock { count = newValue } }
    }
}
