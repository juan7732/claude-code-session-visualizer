import Foundation
import Testing
@testable import SkitKit

/// `skit` in the terminal: a link to the app's own, in a folder the shell searches.
@Suite struct CommandLineToolTests {
    /// A home with an app in it that holds a `skit`, and nothing else.
    private struct Place {
        let home: String
        let helper: String

        init() throws {
            home = NSTemporaryDirectory() + "sk-cli-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
            helper = try Place.app(in: home, named: "SessionVisualizer")
        }

        static func app(in home: String, named name: String) throws -> String {
            let helpers = "\(home)/Applications/\(name).app/Contents/Helpers"
            try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
            try executable(helpers + "/skit")
            return helpers + "/skit"
        }

        static func executable(_ path: String) throws {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }

        func tool(path: [String]? = nil, shell: String = "/bin/zsh") -> CommandLineTool {
            CommandLineTool(helper: helper, homeDirectory: home, searchPath: path, shell: shell)
        }

        var local: String { home + "/.local/bin" }
    }

    @Test func nothingIsThereAtFirst() throws {
        let place = try Place()
        let status = place.tool(path: ["/usr/bin", "/bin"]).status()
        #expect(status.link == nil)
        #expect(status.destination == place.local + "/skit")
        #expect(status.onPath == false)
        #expect(status.resolved == nil)
        #expect(!status.occupied && !status.works)
    }

    @Test func installLinksToTheAppsOwnSkit() throws {
        let place = try Place()
        let tool = place.tool(path: [place.local, "/usr/bin"])
        let path = try tool.install()
        #expect(path == place.local + "/skit")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path) == place.helper)
        let status = tool.status()
        #expect(status.link == path)
        #expect(status.onPath == true)
        #expect(status.works)
        #expect(status.shadowedBy == nil)
        // Again changes nothing and fails at nothing.
        #expect(try tool.install() == path)
    }

    /// A folder the shell already searches and the person can write to is used before ~/.local/bin.
    @Test func prefersAFolderTheShellSearches() throws {
        let place = try Place()
        try FileManager.default.createDirectory(atPath: place.home + "/bin", withIntermediateDirectories: true)
        let tool = place.tool(path: ["/usr/bin", place.home + "/bin"])
        #expect(tool.destination() == place.home + "/bin")
        #expect(try tool.install() == place.home + "/bin/skit")
        #expect(tool.status().works)
    }

    @Test func aFolderOffThePathGetsTheLineToAdd() throws {
        let place = try Place()
        let tool = place.tool(path: ["/usr/bin"])
        try tool.install()
        let status = tool.status()
        #expect(status.link == place.local + "/skit")
        #expect(status.onPath == false)
        #expect(!status.works)
        #expect(tool.hint(for: place.local) == .init(file: "~/.zshrc", line: "export PATH=\"$HOME/.local/bin:$PATH\""))
        #expect(place.tool(shell: "/bin/bash").hint(for: place.local).file == "~/.bash_profile")
        #expect(place.tool(shell: "/opt/homebrew/bin/fish").hint(for: place.local) == .init(file: "~/.config/fish/config.fish", line: "fish_add_path \"$HOME/.local/bin\""))
        #expect(place.tool().hint(for: "/usr/local/bin").line == "export PATH=\"/usr/local/bin:$PATH\"")
    }

    /// When the shell could not be asked, nothing is claimed either way.
    @Test func anUnknownPathIsNotGuessed() throws {
        let place = try Place()
        let tool = place.tool(path: nil)
        try tool.install()
        let status = tool.status()
        #expect(status.onPath == nil && status.resolved == nil && !status.works)
    }

    /// A skit somebody put there (`just install` copied to that folder, a script) is not replaced.
    @Test func somebodyElsesSkitIsLeftAlone() throws {
        let place = try Place()
        try Place.executable(place.local + "/skit")
        let tool = place.tool(path: [place.local])
        #expect(tool.status().occupied)
        #expect(throws: CommandLineTool.Failure.occupied(place.local + "/skit")) { try tool.install() }
        #expect(try tool.remove().isEmpty)
        #expect(FileManager.default.fileExists(atPath: place.local + "/skit"))

        // The same for a link that leads somewhere that is not an app's skit.
        let other = try Place()
        try Place.executable(other.home + "/go/bin/skit")
        try FileManager.default.createDirectory(atPath: other.local, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: other.local + "/skit", withDestinationPath: other.home + "/go/bin/skit")
        #expect(other.tool().status().occupied)
        #expect(throws: CommandLineTool.Failure.self) { try other.tool().install() }
    }

    /// The app was moved or there is a second copy: the link of the old one is pointed at this one.
    @Test func aLinkToAnotherCopyOfTheAppIsRepointed() throws {
        let place = try Place()
        let old = try Place.app(in: place.home, named: "Downloads/SessionVisualizer")
        try FileManager.default.createDirectory(atPath: place.home + "/bin", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: place.home + "/bin/skit", withDestinationPath: old)
        let tool = place.tool(path: [place.home + "/bin"])
        let before = tool.status()
        #expect(before.link == nil && before.stale == old && !before.occupied)
        // Where the old link is, not a second one beside it.
        #expect(try tool.install() == place.home + "/bin/skit")
        #expect(tool.status().works)
        #expect(!FileManager.default.fileExists(atPath: place.local + "/skit"))

        // A link whose app is gone altogether counts the same.
        let gone = try Place()
        try FileManager.default.createDirectory(atPath: gone.local, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: gone.local + "/skit", withDestinationPath: "/Applications/Gone.app/Contents/Helpers/skit")
        #expect(gone.tool().status().stale == "/Applications/Gone.app/Contents/Helpers/skit")
        #expect(try gone.tool().install() == gone.local + "/skit")
    }

    /// Another skit earlier on the PATH is the one a terminal runs, and that is said.
    @Test func anEarlierSkitShadowsTheLink() throws {
        let place = try Place()
        try Place.executable(place.home + "/go/bin/skit")
        let tool = place.tool(path: [place.home + "/go/bin", place.local])
        #expect(tool.status().resolved == place.home + "/go/bin/skit")
        try tool.install()
        let status = tool.status()
        #expect(status.link == place.local + "/skit")
        #expect(status.onPath == true)
        #expect(!status.works)
        #expect(status.shadowedBy == place.home + "/go/bin/skit")
    }

    @Test func removeTakesOnlyTheLinkAway() throws {
        let place = try Place()
        let tool = place.tool(path: [place.local])
        try tool.install()
        #expect(try tool.remove() == [place.local + "/skit"])
        #expect(tool.status().link == nil)
        #expect(FileManager.default.fileExists(atPath: place.helper))
        #expect(try tool.remove().isEmpty)
    }

    /// An app run from a disk image or from where it was downloaded is not linked to: the path does not last.
    @Test func anAppThatWillMoveIsNotLinked() throws {
        let place = try Place()
        let tool = CommandLineTool(helper: "/Volumes/SessionVisualizer/SessionVisualizer.app/Contents/Helpers/skit", homeDirectory: place.home)
        #expect(tool.status().place == .volume)
        #expect(throws: CommandLineTool.Failure.unstable(.volume)) { try tool.install() }
    }

    @Test func readsThePathTheShellPrints() {
        #expect(CommandLineTool.parse("Last login: today\n__SKIT_PATH__/opt/homebrew/bin:/usr/bin:relative:/bin\n") == ["/opt/homebrew/bin", "/usr/bin", "/bin"])
        // A profile that prints a line of its own with the marker's look does not win over the last one.
        #expect(CommandLineTool.parse("__SKIT_PATH__/first\nnoise\n__SKIT_PATH__/second:/third") == ["/second", "/third"])
        #expect(CommandLineTool.parse("no such line") == nil)
        #expect(CommandLineTool.parse("__SKIT_PATH__") == nil)
    }

    /// The real thing, with a shell every Mac has: it answers with folders, and `/usr/bin` is among them.
    @Test func asksARealShell() async {
        let path = await CommandLineTool.shellSearchPath(shell: "/bin/sh", timeout: 10)
        #expect(path?.contains("/usr/bin") == true)
        #expect(await CommandLineTool.shellSearchPath(shell: "/nonexistent/shell") == nil)
    }
}
