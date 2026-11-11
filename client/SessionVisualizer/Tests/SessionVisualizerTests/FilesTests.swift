import Foundation
import SkitKit
import SkitTestSupport
import Testing
@testable import SessionVisualizer

/// The Files view: what it lists and in which order, from what the engine served.
@Suite struct FilesTests {
    static func touched(_ path: String, writes: Int, touches: [(turn: Int, mode: String)]) throws -> Relations.FileTouched {
        let list = touches.map { #"{"tool_id":"t","action":0,"turn":\#($0.turn),"at":"2026-11-08T10:00:00Z","mode":"\#($0.mode)","tool":"Edit"}"# }.joined(separator: ",")
        return try JSONDecoder.skit().decode(Relations.FileTouched.self, from: Data(#"{"path":"\#(path)","writes":\#(writes),"turns":1,"touches":[\#(list)]}"#.utf8))
    }

    @Test func filesAreListedMostWrittenFirst() throws {
        let model = try ModelTests.model()
        let files = FilesContent.files(of: model, matching: "")
        #expect(files.count == model.relations.files.count)
        #expect(zip(files, files.dropFirst()).allSatisfy { $0.writes > $1.writes || ($0.writes == $1.writes && $0.touches.count >= $1.touches.count) })
        #expect(files.first?.path == "/xxx/y.go")
        // The filter is on the path, whatever its case.
        #expect(FilesContent.files(of: model, matching: " Y.GO ").map(\.path) == ["/xxx/y.go"])
        #expect(FilesContent.files(of: model, matching: "nowhere").isEmpty)
        #expect(FilesContent.name("/Users/me/work/agent/CLAUDE.md") == "agent/CLAUDE.md" && FilesContent.name("notes.md") == "notes.md")
    }

    @Test func theStripMarksTheTurnsThatTouched() throws {
        let file = try Self.touched("/a/b.go", writes: 1, touches: [(0, "read"), (2, "read"), (2, "write"), (2, "read"), (9, "write")])
        // A turn that wrote stays "wrote" whatever else it did; a turn past the session's end is ignored.
        #expect(FilesContent.strip(file, turns: 4) == [.read, .none, .wrote, .none])
        #expect(FilesContent.strip(file, turns: 0).isEmpty)
        #expect(FilesContent.facts(file) == "1 written · 5 touches · 1 turn")
    }

    @Test func aLongCommandIsShownAroundTheFile() {
        let long = String(repeating: "a", count: 3000) + " notes.md " + String(repeating: "b", count: 3000)
        let excerpt = FilesContent.excerpt(of: long, around: "notes.md", before: 20, after: 40)
        #expect(excerpt.hasPrefix("…") && excerpt.hasSuffix("…") && excerpt.contains("notes.md"))
        #expect(excerpt.count == 62)
        // A short one is shown whole; a long one that never names the file, from its start.
        #expect(FilesContent.excerpt(of: "cat notes.md", around: "notes.md") == "cat notes.md")
        #expect(FilesContent.excerpt(of: long, around: "other.md", before: 20, after: 40) == String(long.prefix(60)) + "…")
    }

    @Test func injectedBlocksAreNamedByTheirTag() throws {
        #expect(FilesContent.named("<system-reminder>\nBe brief.\n</system-reminder>", type: "text") == ("system reminder", "Be brief."))
        #expect(FilesContent.named("<ide_opened_file>The user opened x</ide_opened_file>", type: "text").kind == "ide opened file")
        // Not a tag: the block keeps its type and its text.
        #expect(FilesContent.named("a < b and b > c", type: "text") == ("text", "a < b and b > c"))
        #expect(FilesContent.named("<not a tag> hello", type: "text").kind == "text")
        let blocks = FilesContent.context(of: try ModelTests.model())
        #expect(blocks.map(\.id) == Array(blocks.indices))
        let kinds = FilesContent.kinds(blocks)
        #expect(kinds.map(\.count).reduce(0, +) == blocks.count)
        #expect(zip(kinds, kinds.dropFirst()).allSatisfy { $0.count >= $1.count })
    }

    @Test func sizesAndPlaces() throws {
        #expect(FilesContent.bytes(950) == "950 B" && FilesContent.bytes(75_423) == "75 kB" && FilesContent.bytes(1_300_000) == "1.3 MB")
        let images = try JSONDecoder.skit().decode([SessionImage].self, from: Fixtures.data("images.json"))
        let first = try #require(images.first)
        #expect(FilesContent.place(first) == (first.place == "prompt" ? "in your prompt" : "from a tool"))
    }
}
