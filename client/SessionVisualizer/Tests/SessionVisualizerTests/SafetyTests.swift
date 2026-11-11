import AppKit
import Foundation
import SkitKit
import Testing
import UniformTypeIdentifiers
@testable import SessionVisualizer

/// What a transcript can make the app do: a transcript is whatever a model, a tool or a web page
/// wrote, so a link in it opens the web and nothing else, and a file it names is never run.
@Suite struct SafetyTests {
    private static func links(_ markdown: String) -> [URL] {
        InlineText(palette: .light).attributed(markdown).runs.compactMap(\.link)
    }

    private static func words(_ markdown: String) -> String {
        String(InlineText(palette: .light).attributed(markdown).characters)
    }

    @Test func onlyWebLinksStayLinks() {
        for source in ["[a](file:///x)", "[a](smb://h/s)", "[a](javascript:1)", "[a](src/a.go)", "[a](skit-visualizer://session/x)", "[a](http:nohost)"] {
            #expect(Self.links(source).isEmpty, "\(source) must not be clickable")
            #expect(Self.words(source) == "a", "\(source) keeps its words")
        }
        #expect(Self.links("[a](https://example.com)") == [URL(string: "https://example.com")!])
        #expect(Self.links("before [a](file:///x) and [b](http://example.com/p) after") == [URL(string: "http://example.com/p")!])
    }

    @Test func aWebLinkSaysWhereItGoes() {
        // A label that is not the address gets the host after it; one that is, does not.
        #expect(Self.words("see [the docs](https://example.com/guide) now") == "see the docs (example.com) now")
        #expect(Self.words("see https://example.com/guide now") == "see https://example.com/guide now")
        #expect(Self.words("[example.com/guide](https://example.com/guide)") == "example.com/guide")
        // A label that names another site than the one the link leads to is answered with the real one.
        #expect(Self.words("[https://good.com/login](https://evil.org/login)") == "https://good.com/login (evil.org)")
        #expect(Self.words("[good.com](https://good.com@evil.org/)") == "good.com (evil.org)")
        #expect(Self.words("[good.co](https://good.com/)") == "good.co (good.com)")
        // The host is not part of the link, and plain text is left alone.
        let text = InlineText(palette: .light).attributed("[the docs](https://example.com)")
        #expect(text.runs.filter { $0.link != nil }.map { String(text[$0.range].characters) } == ["the docs"])
        #expect(Self.words("no link here, `code` and **bold**") == "no link here, code and bold")
        #expect(String(InlineText(palette: .light).attributed("[a](file:///x)", markdown: false).characters) == "[a](file:///x)")
    }

    @Test func theWindowOpensOnlyTheWeb() {
        #expect(LinkPolicy.opens(URL(string: "https://example.com/a?b=c")!))
        #expect(LinkPolicy.opens(URL(string: "HTTP://EXAMPLE.COM")!))
        for refused in ["file:///Applications/Calculator.app", "smb://host/share", "javascript:alert(1)", "vscode://file/x", "skit-visualizer://session/x", "x-apple.systempreferences:", "mailto:a@b.c", "relative/path", "https:///nohost"] {
            #expect(!LinkPolicy.opens(URL(string: refused)!), "\(refused) must not open from text")
        }
    }

    /// A folder of files the way a session might leave them.
    private static func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sk-open-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func file(_ name: String, in dir: URL, mode: Int = 0o644) throws -> String {
        let url = dir.appendingPathComponent(name)
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url.path
    }

    @Test func openNeverRunsWhatASessionTouched() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        func handoff(_ path: String) -> FileOpener.Handoff { FileOpener.handoff(application: nil, facts: FileOpener.facts(at: path)) }

        // Terminal runs a .command file, and a program with no extension; an application is launched.
        #expect(handoff(try Self.file("setup.command", in: dir, mode: 0o755)) == .reveal)
        #expect(handoff(try Self.file("quiet.command", in: dir)) == .reveal, "with or without the executable bit")
        #expect(handoff(try Self.file("tool", in: dir, mode: 0o755)) == .reveal)
        let app = dir.appendingPathComponent("Thing.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        #expect(handoff(app.path) == .reveal)
        #expect(handoff(dir.path) == .reveal, "a folder")
        #expect(handoff(dir.appendingPathComponent("gone.txt").path) == .reveal, "nothing there")
        // Source that can be executed is not handed over either; the same file without the bit is.
        #expect(handoff(try Self.file("run.sh", in: dir, mode: 0o755)) == .reveal)
        #expect(handoff(try Self.file("lib.sh", in: dir)) == .defaultApplication)
        // What an application only shows.
        #expect(handoff(try Self.file("a.swift", in: dir)) == .defaultApplication)
        #expect(handoff(try Self.file("notes.md", in: dir)) == .defaultApplication)
        #expect(handoff(try Self.file("data.json", in: dir)) == .defaultApplication)
        #expect(handoff(try Self.file("shot.png", in: dir)) == .defaultApplication)
        #expect(handoff(try Self.file("paper.pdf", in: dir)) == .defaultApplication)
        // What a browser would open can carry a script.
        #expect(handoff(try Self.file("page.html", in: dir)) == .reveal)
        #expect(handoff(try Self.file("drawing.svg", in: dir)) == .reveal)
        // A link is judged by what it names.
        let link = dir.appendingPathComponent("readme.txt").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: dir.appendingPathComponent("setup.command").path)
        #expect(handoff(link) == .reveal)
    }

    @Test func aChosenApplicationOpensAndTheButtonSaysWhatHappens() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try Self.file("setup.command", in: dir, mode: 0o755)
        let source = try Self.file("a.swift", in: dir)
        // TextEdit is on every Mac: the application chosen in Settings is the one that opens, whatever the file.
        let textEdit = try #require(FileOpener.application("com.apple.TextEdit"))
        #expect(FileOpener.handoff(script, with: "com.apple.TextEdit") == .application(textEdit))
        #expect(FileOpener.title("com.apple.TextEdit", for: script) == "Open in TextEdit")
        // With none chosen, or one that is gone, the title says which of the two it will be.
        #expect(FileOpener.title("", for: source) == "Open")
        #expect(FileOpener.title("", for: script) == "Show in Finder")
        #expect(FileOpener.title("com.example.not-installed", for: script) == "Show in Finder")
        #expect(FileOpener.title("/Applications/Nowhere.app", for: source) == "Open")
        // The rule itself, without a disk.
        #expect(!FileOpener.opensByDefault(.init(isDirectory: false, isExecutable: true, type: .swiftSource)))
        #expect(!FileOpener.opensByDefault(.init(isDirectory: true, isExecutable: false, type: .folder)))
        #expect(!FileOpener.opensByDefault(.init(type: .unixExecutable)) && !FileOpener.opensByDefault(.init(type: nil)))
        #expect(!FileOpener.opensByDefault(.init(type: .data)), "a type nobody knows is not text")
        #expect(FileOpener.opensByDefault(.init(type: .swiftSource)) && FileOpener.opensByDefault(.init(type: .png)))
    }

    @Test func theLightboxDecodesNoMoreThanItsCap() throws {
        // A strip wider than the cap: what comes out is no longer than the cap on its long side.
        let width = Pictures.fullSide + 808
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(data: nil, width: width, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: 4))
        let strip = try #require(context.makeImage())
        let data = try #require(NSBitmapImageRep(cgImage: strip).representation(using: .png, properties: [:]))
        let shown = try #require(Pictures.decode(data, maxSide: Pictures.fullSide))
        #expect(Int(shown.size.width) == Pictures.fullSide)
    }
}
