import AppKit
import Foundation
import SkitKit
import SkitTestSupport
import Testing
@testable import SessionVisualizer

/// The file viewer: what it colours, what it says about a file, and what Open opens.
@Suite struct FileViewerTests {
    static func kinds(_ text: String, _ path: String) throws -> [(String, Highlighter.Kind)] {
        let language = try #require(Highlighter.language(for: path))
        return Highlighter.spans(text, language: language).map { ((text as NSString).substring(with: $0.range), $0.kind) }
    }

    @Test func goIsColoured() throws {
        let found = try Self.kinds("package a // note\nfunc f() string { return \"x\\\"y\" + `raw\nline` } /* b\nc */ var n = 42", "/w/a.go")
        #expect(found.map(\.0) == ["package", "// note", "func", "return", "\"x\\\"y\"", "`raw\nline`", "/* b\nc */", "var", "42"])
        #expect(found.map(\.1) == [.keyword, .comment, .keyword, .keyword, .string, .string, .comment, .keyword, .number])
    }

    @Test func otherLanguagesByTheirExtension() throws {
        // Python: # comments and triple quotes.
        let py = try Self.kinds("def f():\n    \"\"\"doc\nmore\"\"\"\n    return None  # why", "x.py")
        #expect(py.map(\.0) == ["def", "\"\"\"doc\nmore\"\"\"", "return", "None", "# why"])
        // JSON: keys and values are strings, the three words are keywords.
        let json = try Self.kinds(#"{"a": true, "n": -1.5}"#, "x.json")
        #expect(json.map(\.0) == ["\"a\"", "true", "\"n\"", "1.5"])
        // Markdown: headings and `code`.
        let md = try Self.kinds("# Title\ntext with `code` in it\n## Next", "README.md")
        #expect(md.map(\.0) == ["# Title", "`code`", "## Next"] && md.map(\.1) == [.keyword, .string, .keyword])
        // A shell script, a justfile by its name, and a file nobody has a language for.
        #expect(try Self.kinds("echo \"hi\" # say", "run.sh").map(\.0) == ["echo", "\"hi\"", "# say"])
        #expect(Highlighter.language(for: "/repo/justfile") != nil && Highlighter.language(for: "/repo/Makefile") != nil)
        #expect(Highlighter.language(for: "/repo/notes.txt") == nil && Highlighter.language(for: "/repo/LICENSE") == nil)
    }

    @Test func rangesAreTheTextViews() throws {
        // An emoji is two UTF-16 units: what follows it is still found where the text view will look.
        let text = "// 🙂 ok\nlet x = 1"
        let language = try #require(Highlighter.language(for: "a.swift"))
        let spans = Highlighter.spans(text, language: language)
        #expect((text as NSString).substring(with: spans[1].range) == "let" && spans[0].range.length == 8)
        // An unclosed quote does not swallow the rest of the file.
        #expect(try Self.kinds("a = \"open\nb = 2", "x.py").map(\.0) == ["\"open", "2"])
    }

    @Test func aLongOrUnknownFileStaysPlain() {
        let colors = CodeColors(Palette.light)
        let plain = Highlighter.attributed("let x = 1", path: "notes.txt", colors: colors)
        #expect(plain.string == "let x = 1")
        var different = false
        Highlighter.attributed("let x = 1", path: "a.swift", colors: colors).enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: 9)) { value, range, _ in
            if range.location == 0, range.length == 3, (value as? NSColor) == colors.keyword { different = true }
        }
        #expect(different, "`let` takes the keyword colour")
        let long = String(repeating: "let x = 1\n", count: Highlighter.limit / 10 + 1)
        var runs = 0
        Highlighter.attributed(long, path: "a.swift", colors: colors).enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: 100)) { _, _, _ in runs += 1 }
        #expect(runs == 1, "past the limit the text is one colour")
    }

    @Test func whatTheViewerSaysAboutAFile() throws {
        let gone = try JSONDecoder.skit().decode(FileView.self, from: Fixtures.data("file.json"))
        #expect(!gone.exists && gone.reason == "deleted" && gone.text == nil && gone.sessions.count == 1)
        #expect(FilePane.state(gone).hasPrefix("Not found at /xxx/y.go"))
        #expect(FilePane.counts(try #require(gone.sessions.first)) == "1 written")
        let there = try JSONDecoder.skit().decode(FileView.self, from: Data(#"""
        {"path":"/w/a.go","exists":true,"bytes":31000,"modified":"2026-11-10T19:50:00Z","text":"package a","truncated":true,
         "sessions":[{"session":"s","title":"t","project":"p","raw":"a.go","reads":13,"writes":0,"first_at":"2026-11-08T10:00:00Z","last_at":"2026-11-09T10:00:00Z"}]}
        """#.utf8))
        #expect(FilePane.state(there).hasPrefix("As it is now · 31 kB · changed ") && FilePane.state(there).hasSuffix("the first 2 MB are shown"))
        #expect(FilePane.counts(there.sessions[0]) == "13 read")
    }

    @Test func openNamesTheApplication() {
        #expect(FileOpener.title("") == "Open")
        #expect(FileOpener.title("com.example.not-installed") == "Open", "an application that is not there falls back to the default")
        #expect(FileOpener.title("/Applications/Nowhere.app") == "Open")
        // TextEdit is on every Mac.
        #expect(FileOpener.title("com.apple.TextEdit") == "Open in TextEdit")
        #expect(FileOpener.installed().contains { $0.id == "com.apple.TextEdit" })
        #expect(FileOpener.application("/System/Applications/TextEdit.app") != nil && FileOpener.name("/System/Applications/TextEdit.app") == "TextEdit")
    }
}
