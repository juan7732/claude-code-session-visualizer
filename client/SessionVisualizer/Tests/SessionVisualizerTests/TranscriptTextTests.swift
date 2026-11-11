import AppKit
import Foundation
import SkitKit
import SkitTestSupport
import Testing
@testable import SessionVisualizer

/// What a transcript row draws is made once: when the model is built, or the first time a text is asked for.
@Suite struct TranscriptTextTests {
    @Test func whatAnActionWroteIsReadWhenTheModelIsBuilt() throws {
        let model = try ModelTests.model()
        for action in model.doc.actions {
            let prose = try #require(model.prose(action.index))
            #expect(prose.blocks == MarkdownBlock.parse(action.text))
            #expect(prose.length == action.text.count && prose.calls == action.toolUseIDs.count)
            #expect(prose.hasWords == SessionModel.hasProse(action))
            #expect(prose.thinking == action.thinking && prose.thinkingLine == SessionModel.firstLine(action.thinking, max: 160))
        }
        #expect(model.prose(-1) == nil && model.prose(model.doc.actions.count) == nil)
        for turn in model.doc.turns {
            #expect(model.promptLength(ofTurn: turn.index) == (model.prompt(ofTurn: turn.index)?.text.count ?? 0))
        }
        #expect(model.promptLength(ofTurn: 99) == 0)
    }

    @Test func anAttributedTextIsMadeOnce() {
        let inline = InlineText(palette: .light)
        // A text of its own, so that no other test has asked for it.
        let source = "a **bold** word and `code` \(UInt32.random(in: 0...UInt32.max))"
        let before = InlineText.keptCount
        let first = inline.attributed(source)
        #expect(InlineText.keptCount == before + 1)
        #expect(inline.attributed(source) == first)
        #expect(InlineText.keptCount == before + 1, "the same text, query and palette is not parsed again")

        // Everything the result depends on is part of what it is kept under.
        #expect(String(inline.attributed(source, markdown: false).characters) == source)
        let marked = InlineText(palette: .light, query: "bold").attributed(source)
        #expect(marked != first && marked.runs.contains { $0.backgroundColor == Palette.light.warn.opacity(0.35) })
        #expect(InlineText(palette: .dark).attributed(source) != first)
        #expect(InlineText.keptCount == before + 4)
        // One letter is not a query: it marks nothing, and is not another text to keep.
        #expect(InlineText(palette: .light, query: "b").attributed(source) == first && InlineText.keptCount == before + 4)

        // A very long text is made and not kept.
        let long = String(repeating: "x", count: InlineText.keptEntryBytes + 1)
        _ = inline.attributed(long, markdown: false)
        #expect(InlineText.keptCount == before + 4)
    }

    @Test func aLongResultIsCutAndGoesToATextView() {
        #expect(Pre.cut("short", limit: 6000) == "short")
        let long = String(repeating: "é", count: 7000)
        let cut = Pre.cut(long, limit: 6000)
        #expect(cut.hasPrefix(String(repeating: "é", count: 6000) + "\n") && cut.hasSuffix("… 1000 more characters"))
        // More bytes than the limit and no more characters: nothing is cut.
        #expect(Pre.cut(String(repeating: "é", count: 5000), limit: 6000).count == 5000)
        // What a transcript row shows stays under the line; what the inspector shows of a large result is over it.
        #expect(Pre.cut(String(repeating: "x", count: 1_000_000), limit: 6000).utf8.count < Pre.longAbove)
        #expect(Pre.cut(String(repeating: "x", count: 1_000_000), limit: 200_000).utf8.count > Pre.longAbove)

        // The text view's text: monospaced, and the find query marked wherever it is, whatever its case.
        let styled = Pre.styled("Error: no such file\nerror again", query: "error", palette: .light)
        #expect(styled.string == "Error: no such file\nerror again")
        var marks: [NSRange] = []
        styled.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: styled.length)) { value, range, _ in
            if value != nil { marks.append(range) }
        }
        #expect(marks == [NSRange(location: 0, length: 5), NSRange(location: 20, length: 5)])
        #expect((styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.isFixedPitch == true)
        var unmarked = 0
        Pre.styled("plain", query: "", palette: .light).enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: 5)) { value, _, _ in
            if value != nil { unmarked += 1 }
        }
        #expect(unmarked == 0)
    }
}
