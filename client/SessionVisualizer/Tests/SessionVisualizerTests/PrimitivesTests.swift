import Foundation
import SkitKit
import SkitTestSupport
import Testing
@testable import SessionVisualizer

/// The Primitives page: what it lists, in what order, and what it says of each.
@Suite struct PrimitivesTests {
    private func report() throws -> PrimitivesReport {
        try JSONDecoder.skit().decode(PrimitivesReport.self, from: Fixtures.data("primitives.json"))
    }

    @Test func aKindIsListedMostUsedFirst() throws {
        let report = try report()
        let skills = PrimitivesContent.rows(report, kind: "skill", filter: "", unusedOnly: false)
        // Used; then what sessions had on offer (installed before not), by name; then what only a counter knows.
        #expect(skills.map(\.name) == ["deploy", "anthropic-skills:pdf", "tidy", "init", "old-skill"])
        #expect(PrimitivesContent.rows(report, kind: "skill", filter: "", unusedOnly: true).map(\.name) == ["anthropic-skills:pdf", "tidy", "init"])
        // The filter reads names, descriptions, places and paths.
        #expect(PrimitivesContent.rows(report, kind: "skill", filter: " TIDY up ", unusedOnly: false).map(\.name) == ["tidy"])
        #expect(PrimitivesContent.rows(report, kind: "skill", filter: "claude.ai", unusedOnly: false).map(\.name) == ["anthropic-skills:pdf"])
        #expect(PrimitivesContent.rows(report, kind: "skill", filter: "/proj/.claude", unusedOnly: false).map(\.name) == ["deploy"])
        #expect(PrimitivesContent.rows(report, kind: "plugin", filter: "", unusedOnly: false).isEmpty)
        #expect(PrimitivesContent.nothing(kind: "plugin", filtered: false).contains("No plugins are installed"))
        #expect(PrimitivesContent.summary(try #require(report.kinds.first)) == "3 installed · 1 used · 3 there and not used")
        #expect(PrimitivesContent.summary(try #require(report.kinds.first { $0.kind == "hook" })) == "1 installed · 1 used")
        #expect(PrimitivesContent.stamp(report).contains("sessions kept here") && PrimitivesContent.lookedIn(report).hasPrefix("Found in: "))
    }

    @Test func whereAThingIsDefinedAndWhichComesFirst() throws {
        let report = try report()
        func item(_ kind: String, _ name: String) throws -> PrimitivesReport.Item { try #require(report.items.first { $0.kind == kind && $0.name == name }) }
        let deploy = try item("skill", "deploy")
        #expect(PrimitivesContent.place(deploy) == "You, in every project +1")
        #expect(deploy.definitions.map { PrimitivesContent.scope($0, kind: "skill") } == ["You, in every project", "Project proj"])
        #expect(PrimitivesContent.orderNote(deploy)?.contains("then yours, then the project's") == true)
        let tidy = try item("skill", "tidy")
        #expect(PrimitivesContent.orderNote(tidy) == nil)
        let bundled = try item("skill", "init"), explore = try item("agent", "Explore"), compact = try item("command", "compact")
        #expect(PrimitivesContent.place(bundled) == "Not on disk" && PrimitivesContent.place(explore) == "Built into Claude Code")
        #expect(PrimitivesContent.undefined(explore).hasPrefix("Built into Claude Code") && PrimitivesContent.undefined(compact).contains("/compact"))
        // A connector by the name a person gave it; a memory note by its file and the project it is for.
        let gmail = try item("connector", "claude_ai_Gmail")
        #expect(PrimitivesContent.name(gmail) == "claude.ai Gmail" && PrimitivesContent.place(gmail) == "Your claude.ai account")
        let notes = try item("connector", "notes")
        #expect(PrimitivesContent.details(try #require(notes.definitions.first)) == ["stdio · notes-mcp"])
        let hook = try item("hook", "PostToolUse:Edit|Write")
        #expect(PrimitivesContent.details(try #require(hook.definitions.first)) == ["runs gofmt -l ."])
        let note = try #require(report.items.first { $0.kind == "memory" && $0.name.hasSuffix("a-note.md") })
        #expect(PrimitivesContent.name(note) == "a-note.md" && PrimitivesContent.place(note) == "Project fixture-proj")
        var local = try #require(deploy.definitions.last)
        local.scope = "local"
        #expect(PrimitivesContent.scope(local, kind: "hook") == "You, in proj")
    }

    @Test func whatItsUseSays() throws {
        let report = try report()
        func item(_ kind: String, _ name: String) throws -> PrimitivesReport.Item { try #require(report.items.first { $0.kind == kind && $0.name == name }) }
        let deploy = try item("skill", "deploy")
        #expect(PrimitivesContent.figures(deploy).map { "\($0.value) \($0.label)" } == ["2 uses", "1 sessions", "1 typed by you", "1 by the model", "1 on offer in"])
        #expect(!PrimitivesContent.unused(deploy) && PrimitivesContent.lastUsed(deploy) != "never")
        #expect(PrimitivesContent.notes(deploy).first?.hasPrefix("Claude Code's own counter says 5") == true)
        let tidy = try item("skill", "tidy")
        #expect(PrimitivesContent.unused(tidy) && PrimitivesContent.lastUsed(tidy) == "never")
        #expect(PrimitivesContent.notes(tidy) == ["On offer and never used in the sessions kept here."])
        #expect(PrimitivesContent.figures(tidy).map(\.label) == ["on offer in"])
        // Only Claude Code's counter knows it: neither used nor unused here.
        let old = try item("skill", "old-skill")
        #expect(!PrimitivesContent.unused(old) && PrimitivesContent.figures(old).isEmpty && PrimitivesContent.notes(old).count == 1)
        let explore = try item("agent", "Explore")
        #expect(PrimitivesContent.figures(explore).contains(.init(label: "running", value: "30s")))
        let notes = try item("connector", "notes")
        #expect(PrimitivesContent.figures(notes).contains(.init(label: "failed", value: "1", bad: true)))
        // A hook is never called unused: a quiet one leaves no trace.
        var hook = try item("hook", "PostToolUse:Edit|Write")
        hook.usage.calls = 0
        hook.usage.lastAt = nil
        hook.lastUsedAt = nil
        #expect(!PrimitivesContent.unused(hook) && PrimitivesContent.lastUsed(hook) == "" && PrimitivesContent.notes(hook).first?.contains("leaves a trace only") == true)
        // Out of the period, and known to have been used before it.
        var before = deploy
        before.usage.calls = 0
        before.usage.lastAt = nil
        #expect(PrimitivesContent.lastUsed(before) == "before this period" && PrimitivesContent.notes(before).first?.hasPrefix("Not used in this period") == true)

        let one = try #require(try JSONDecoder.skit().decode(PrimitivesReport.self, from: Fixtures.data("primitive.json")).items.first?.sessions.first)
        #expect(PrimitivesContent.line(one, kind: "skill").hasSuffix("2 uses · 1 typed") && PrimitivesContent.line(one, kind: "memory").contains("2 times"))
        #expect(PrimitivesContent.duration(45) == "45s" && PrimitivesContent.duration(236) == "3m 56s" && PrimitivesContent.duration(7500) == "2h 05m")
    }

    @Test func daysOfUseBecomeBars() throws {
        func days(_ json: String) throws -> [PrimitivesReport.DayUse] { try JSONDecoder.skit().decode([PrimitivesReport.DayUse].self, from: Data(json.utf8)) }
        let week = PrimitivesContent.bars(try days(#"[{"day":"2026-11-03","calls":2},{"day":"2026-11-01","calls":1},{"day":"2026-11-07","calls":4}]"#))
        #expect(week.values == [1, 0, 2, 0, 0, 0, 4] && week.from == "2026-11-01" && week.to == "2026-11-07" && !week.weekly)
        // More than 120 days: a bar a week.
        let long = PrimitivesContent.bars(try days(#"[{"day":"2026-01-01","calls":1},{"day":"2026-01-05","calls":2},{"day":"2026-01-08","calls":3},{"day":"2026-06-30","calls":5}]"#))
        #expect(long.weekly && long.values.count == 26 && long.values[0] == 3 && long.values[1] == 3 && long.values.last == 5)
        #expect(PrimitivesContent.bars([]).values.isEmpty)
        #expect(PrimitivesPeriod.all.days == nil && PrimitivesPeriod.month.days == 30)
        #expect(AppStore.primitiveKey(kind: "skill", name: "a", days: nil) != AppStore.primitiveKey(kind: "skill", name: "a", days: 7))
    }
}
