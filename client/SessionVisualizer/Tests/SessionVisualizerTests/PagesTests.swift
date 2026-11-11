import Foundation
import SkitKit
import SkitTestSupport
import Testing
@testable import SessionVisualizer

/// Compare and Claude: what they lay side by side and what they match.
@Suite struct PagesTests {
    @Test func compareLaysTheSameMeasuresSideBySide() throws {
        let rows = try JSONDecoder.skit().decode([SessionSummary].self, from: Fixtures.data("sessions.json"))
        let a = try #require(rows.first { $0.id.hasPrefix("aaaaaaaa") }), b = try #require(rows.first { $0.id.hasPrefix("cccccccc") })
        let model = try ModelTests.model()
        // Before either session is read, what needs reading says so and the rest is already there.
        let waiting = CompareContent.measures(a, b, modelA: nil, modelB: nil, statsA: nil, statsB: nil)
        #expect(waiting.first { $0.label == "Files written" }?.a == "…" && waiting.first { $0.label == "Context peak" }?.b == "…")
        #expect(waiting.first { $0.label == "Actions" }?.a == "\(a.requests)" && waiting.first { $0.label == "Actions" }?.b == "\(b.requests)")
        #expect(waiting.first { $0.label == "Longest autonomous run" }?.a == "4 actions")
        // With the first one read.
        let read = CompareContent.measures(a, b, modelA: model, modelB: nil, statsA: a, statsB: nil)
        #expect(read.first { $0.label == "Files written" }?.a == "1" && read.first { $0.label == "Commits" }?.a == "0" && read.first { $0.label == "Commits" }?.b == "…")
        #expect(read.first { $0.label == "Context peak" }?.a == "—", "a row from the list carries no context curve")
        // The tools of both, the most called first; each named once.
        let tools = read.drop { $0.label != "Tools running" }.dropFirst().map(\.label)
        #expect(tools.first == "Bash" && Set(tools).count == tools.count && tools.count <= 8)
        // The strip: a block a turn, as heavy as its actions.
        let strip = CompareContent.turns(of: model)
        #expect(strip.map(\.weight) == [4, 2] && strip.allSatisfy(\.human))
    }

    @Test func theClaudePageFiltersAndQuotes() throws {
        #expect(ClaudeContent.matches("", "anything") && ClaudeContent.matches("prism", "tengu_amber_PRISM", "off"))
        #expect(!ClaudeContent.matches("prism", "tengu_flint", "off"))
        #expect(ClaudeContent.sameName("tengu_x", "tengu_x") && ClaudeContent.sameName("tengu_x_experiment", "tengu_x"))
        #expect(!ClaudeContent.sameName("tengu_x-public", "tengu_x") && !ClaudeContent.sameName("cai_giggly", "tengu_swift"))
        let experiment = try JSONDecoder.skit().decode(ClaudeSnapshot.Experiment.self, from: Data(#"{"flag":"f","experiment_id":"e","variation_id":2,"value":null}"#.utf8))
        #expect(ClaudeContent.assignment(experiment) == "e=2" && experiment.value.compact == "null")
    }

    @Test func valuesOnOneLine() {
        #expect(JSONValue.number(2).compact == "2" && JSONValue.number(-0.5).compact == "-0.5" && JSONValue.bool(false).compact == "false")
        #expect(JSONValue.string("plain").compact == "plain")
        #expect(JSONValue.array([.string("a"), .number(1), .null]).compact == #"["a", 1, null]"#)
        #expect(JSONValue.object(["z": .bool(true), "a": .string("q\"r")]).compact == #"{"a": "q\"r", "z": true}"#)
    }
}
