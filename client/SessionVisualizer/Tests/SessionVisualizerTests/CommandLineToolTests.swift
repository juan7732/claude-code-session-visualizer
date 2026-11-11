import Foundation
import SkitKit
import Testing
@testable import SessionVisualizer

/// What the Install Command Line Tool sheet says for each state the link can be in.
@Suite struct CommandLineContentTests {
    private let link = NSHomeDirectory() + "/.local/bin/skit"

    private func status(link: String? = nil, onPath: Bool? = false, resolved: String? = nil, occupied: Bool = false,
                        stale: String? = nil, place: BundlePlace = .stable, external: Bool = false) -> CommandLineTool.Status {
        .init(link: link, destination: self.link, onPath: onPath, resolved: resolved, occupied: occupied, stale: stale, place: place, external: external)
    }

    /// Installed with Homebrew, the link is Homebrew's: it works, and Remove is not offered for it.
    @Test func aLinkHomebrewMadeIsNotOfferedForRemoval() {
        let brew = "/opt/homebrew/bin/skit"
        let words = CommandLineContent.words(status(link: brew, onPath: true, resolved: brew, external: true))
        #expect(words.tone == .ok && words.action == nil && !words.removable)
        #expect(words.detail.contains("Homebrew"))
    }

    @Test func offersTheLinkAndSaysWhereItGoes() {
        let words = CommandLineContent.words(status())
        #expect(words.action == "Install")
        #expect(!words.removable && !words.showsHint)
        #expect(words.detail.contains("`~/.local/bin/skit`"))
        // A skit that a terminal already finds is named before anything is done.
        let other = CommandLineContent.words(status(resolved: NSHomeDirectory() + "/go/bin/skit"))
        #expect(other.detail.contains("`~/go/bin/skit`"))
    }

    @Test func saysWhenATerminalFindsIt() {
        let words = CommandLineContent.words(status(link: link, onPath: true, resolved: link))
        #expect(words.tone == .ok)
        #expect(words.action == nil && words.removable && !words.showsHint)
    }

    /// Linked is not the same as found: each way it can still fail in a terminal is said.
    @Test func saysWhatIsStillInTheWay() {
        let off = CommandLineContent.words(status(link: link, onPath: false))
        #expect(off.tone == .warn && off.showsHint && off.removable)

        let unknown = CommandLineContent.words(status(link: link, onPath: nil))
        #expect(unknown.tone == .plain && unknown.showsHint)
        #expect(unknown.headline == "Linked")

        let shadowed = CommandLineContent.words(status(link: link, onPath: true, resolved: NSHomeDirectory() + "/go/bin/skit"))
        #expect(shadowed.tone == .warn && !shadowed.showsHint)
        #expect(shadowed.detail.contains("`~/go/bin/skit`"))
    }

    @Test func leavesWhatIsNotItsOwn() {
        let occupied = CommandLineContent.words(status(occupied: true))
        #expect(occupied.tone == .err && !occupied.removable)
        #expect(occupied.detail.contains("left alone"))

        let stale = CommandLineContent.words(status(stale: "/Applications/Old.app/Contents/Helpers/skit"))
        #expect(stale.action == "Link Again")
    }

    @Test func refusesAnAppThatWillMove() {
        for place in [BundlePlace.volume, .translocated] {
            let words = CommandLineContent.words(status(place: place))
            #expect(words.tone == .err && words.action == nil)
        }
    }

    @Test func withoutABundleThereIsNothingToLink() {
        let words = CommandLineContent.words(nil, noHelper: true)
        #expect(words.action == nil && words.detail.contains("just install"))
        #expect(CommandLineContent.words(nil).headline == "Looking")
    }
}
