import Foundation
import SkitKit
import Testing
@testable import SessionVisualizer

/// The first run: what it counts before anything is installed, and what its one decision shows.
@Suite struct OnboardingTests {
    @Test func countsWhatClaudeCodeHoldsFromDoctor() throws {
        // `skit doctor --json`, cut down: two projects, a subagent's bytes, a file that is not a session's main transcript.
        let doctor = #"""
        {"claude_dir":"/Users/me/.claude","exists":true,"retention":{"cleanup_period_days":14,"source":"/Users/me/.claude/settings.json"},
         "projects":[
          {"slug":"-a","dir":"/x","sessions":[
            {"id":"1","kind":"main","bytes":1000,"mod_time":"2026-11-02T19:20:30.647549211-06:00","subagents":2,"subagent_bytes":500},
            {"id":"2","kind":"main","bytes":3000,"mod_time":"2026-10-01T08:00:00Z","subagents":0,"subagent_bytes":0},
            {"id":"3","kind":"orphaned","bytes":9999,"mod_time":"2026-01-01T00:00:00Z"}]},
          {"slug":"-b","dir":"/y","sessions":[{"id":"4","kind":"main","bytes":20,"mod_time":"2026-11-10T00:00:00Z"}]},
          {"slug":"-empty","dir":"/z","sessions":[]}],
         "live":[],"totals":{"sessions":3}}
        """#
        let facts = try #require(OnboardingFacts.parse(Data(doctor.utf8)))
        #expect(facts.sessions == 3 && facts.projects == 2 && facts.bytes == 4520 && facts.retentionDays == 14)
        #expect(facts.oldest == ISO8601DateFormatter().date(from: "2026-10-01T08:00:00Z"))
        #expect(OnboardingFacts.parse(Data("not json".utf8)) == nil)
        // A home with nothing in it is still an answer.
        let empty = try #require(OnboardingFacts.parse(Data(#"{"exists":false,"projects":null}"#.utf8)))
        #expect(empty.sessions == 0 && empty.oldest == nil && empty.retentionDays == 30)

        #expect(OnboardingContent.retention(facts).contains("14 days after it was last used"))
        #expect(OnboardingContent.retention(nil).contains("after 30 days unless told otherwise"))
        var kept = facts
        kept.retentionDays = 0
        #expect(OnboardingContent.retention(kept).contains("set to keep them"))
    }

    @Test func theArchiverIsStartedByThePersonOrNotAtAll() {
        func line(serving: String? = nil, engine: EngineState = .connecting, starting: Bool = false, firstRun: Bool = true, looked: Bool = true) -> (mark: OnboardingContent.Mark, text: String, offersStart: Bool) {
            OnboardingContent.archiver(serving: serving, engine: engine, starting: starting, firstRun: firstRun, looked: looked)
        }
        // A new Mac: nothing runs, nothing was installed, the button is the way on.
        let new = line()
        #expect(new.mark == .none && new.offersStart && new.text.contains("Nothing has been installed"))
        // Still looking: no button yet, or it would install over an archiver that is about to answer.
        #expect(!line(looked: false).offersStart && line(looked: false).mark == .working)
        // One is running already (a developer's install, an earlier copy of the app): nothing to install.
        let already = line(serving: "1.0.0")
        #expect(already.mark == .ok && !already.offersStart && already.text.contains("skit 1.0.0"))
        // Pressed: working, then running.
        #expect(line(starting: true).mark == .working && !line(starting: true).offersStart)
        #expect(line(engine: .starting(binary: "/x/skit")).mark == .working)
        #expect(line(engine: .ready).mark == .ok && !line(engine: .ready).offersStart)
        // It failed: said, and the button is there again.
        let failed = line(engine: .failed("launchctl said no"))
        #expect(failed.mark == .trouble && failed.offersStart && failed.text.contains("launchctl said no"))
        // What the window behind explains better is passed on to it.
        #expect(!line(engine: .missing(lookedIn: [])).offersStart && !line(engine: .incompatible(version: "0.1", missing: [])).offersStart)
        #expect(line(engine: .misplaced(.translocated)).text.contains("Applications"))
        // Shown again from Help, it starts nothing.
        #expect(!line(firstRun: false).offersStart)
    }

    @Test func fiveStepsAndTheWholeRail() {
        #expect(OnboardingContent.steps.map(\.id) == [.welcome, .archive, .archiver, .search, .tour])
        #expect(OnboardingContent.places.map(\.title) == ["Sessions", "Now", "Search", "Stats", "Primitives", "Claude"])
        #expect(OnboardingContent.promises.count == 3 && OnboardingContent.keys.map(\.keys) == ["⌘K", "⌘R", "⌘F", "⌥⌘E"])
        #expect(Onboarding.version >= 1 && SettingsKey.onboardingSeen == "onboarding.seen")
    }
}
