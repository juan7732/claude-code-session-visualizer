import AppKit
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

    @Test func memoryFilesSayWhoseTheyAre() {
        #expect(ClaudeContent.projectName(nil) == "every project" && ClaudeContent.projectName("") == "every project")
        #expect(ClaudeContent.projectName("/Users/me/work/tools") == "~/work/tools")
        #expect(ClaudeContent.projectName("-Users-me-ergo-workspaces-parce-exploration") == "parce-exploration")
    }

    @Test func aPictureBecomesAThumbnailOnce() throws {
        // A 1200 × 600 picture: the thumbnail is no longer than 640 on its long side and keeps its shape.
        let big = NSImage(size: NSSize(width: 1200, height: 600), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        let cg = try #require(big.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let data = try #require(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]))
        let thumb = try #require(Pictures.decode(data, maxSide: Pictures.thumbnailSide))
        #expect(max(thumb.size.width, thumb.size.height) == 640 && abs(thumb.size.width / thumb.size.height - 2) < 0.02)
        // The lightbox's own cap leaves a picture smaller than it as it is.
        let whole = try #require(Pictures.decode(data, maxSide: Pictures.fullSide))
        #expect(whole.size.width >= 1200)
        #expect(Pictures.decode(Data("not a picture".utf8), maxSide: 640) == nil)
        #expect(Pictures.key("s", 3, full: false) != Pictures.key("s", 3, full: true))
    }

    @Test func valuesOnOneLine() {
        #expect(JSONValue.number(2).compact == "2" && JSONValue.number(-0.5).compact == "-0.5" && JSONValue.bool(false).compact == "false")
        #expect(JSONValue.string("plain").compact == "plain")
        #expect(JSONValue.array([.string("a"), .number(1), .null]).compact == #"["a", 1, null]"#)
        #expect(JSONValue.object(["z": .bool(true), "a": .string("q\"r")]).compact == #"{"a": "q\"r", "z": true}"#)
    }
}

/// What the app keeps about what a person did, and the one way text gets onto the pasteboard.
@Suite struct KeptTests {
    @Test func recentSearchesAreKeptOnlyWhenAskedTo() {
        var recent = ""
        for query in ["alpha", "beta", "alpha", "x", "gamma"] { recent = RecentSearches.adding(query, to: recent, keeping: true) }
        // Newest first, each once, and one letter is not a search.
        #expect(recent == "gamma\nalpha\nbeta")
        for n in 0..<10 { recent = RecentSearches.adding("query \(n)", to: recent, keeping: true) }
        #expect(recent.split(separator: "\n").count == RecentSearches.limit && recent.hasPrefix("query 9\nquery 8\n"))
        // Turned off in Settings: nothing is added, and what was there goes.
        #expect(RecentSearches.adding("secret project", to: recent, keeping: false).isEmpty)
        #expect(RecentSearches.adding("secret project", to: "", keeping: false).isEmpty)
    }

    @Test func copyingPutsTheTextOnThePasteboardAlone() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("sk-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("what was there", forType: .string)
        Exporter.copy("0198c5d2-session-id", to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "0198c5d2-session-id")
        #expect(pasteboard.pasteboardItems?.count == 1)
    }
}
