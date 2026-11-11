import CoreGraphics
import Foundation
import SkitKit
import SkitTestSupport
import Testing
@testable import SessionVisualizer

/// The Braid: what each node says, where the layout puts it, and what the
/// camera does. The drawing itself is checked with snapshots; these are the
/// rules a picture cannot show to be broken.
@Suite struct CanvasTests {
    static func braid(closed: Set<Int> = [], options: BraidOptions = BraidOptions()) throws -> (SessionModel, BraidContent, CanvasLayout) {
        let model = try ModelTests.model()
        let content = BraidContent(model: model)
        return (model, content, CanvasLayout(content: content, closed: closed, options: options))
    }

    @Test func everyTurnHasItsCardAndItsChain() throws {
        let (model, content, layout) = try Self.braid()
        #expect(content.turns.map(\.index) == [0, 1])
        #expect(content.turns[0].steps.map(\.index) == [0, 1, 2, 3] && content.turns[1].steps.map(\.index) == [4, 5])
        // Two prompt cards, six steps, one strand.
        #expect(layout.nodes.map(\.key) == [
            .turn(0), .action(0), .action(1), .action(2), .subagent("a1b2c3d4e5f607182"), .action(3),
            .turn(1), .action(4), .action(5),
        ])
        // The geometry of the mock: prompt at the left, chain beside it, strand beside the chain.
        let rect = { (key: NodeKey) in layout.nodes[layout.index[key]!].rect }
        #expect(rect(.turn(0)).minX == 0 && rect(.turn(0)).width == BR.promptWidth)
        #expect(rect(.action(0)).minX == BR.chainX && rect(.action(0)).width == BR.cardWidth)
        #expect(rect(.subagent("a1b2c3d4e5f607182")).minX == BR.strandX)
        #expect(rect(.action(0)).minY == rect(.turn(0)).minY, "the first step starts level with its prompt")

        // A chain never overlaps itself, and a turn starts below the one before.
        let chain = layout.nodes.filter { if case .step = $0.kind { true } else { false } }.map(\.rect)
        for (above, below) in zip(chain, chain.dropFirst()) { #expect(below.minY >= above.maxY + BR.gap - 0.01) }
        #expect(layout.turnSpans[1].lowerBound >= layout.turnSpans[0].upperBound + BR.turnGap - 0.01)
        #expect(layout.bounds.contains(rect(.action(5))))
        #expect(model.doc.actions.count == chain.count)
    }

    @Test func theChainWaitsForTheHandBack() throws {
        let (_, content, layout) = try Self.braid()
        let strand = layout.nodes[layout.index[.subagent("a1b2c3d4e5f607182")]!].rect
        let spawner = layout.nodes[layout.index[.action(2)]!].rect
        let receiver = layout.nodes[layout.index[.action(3)]!].rect
        #expect(content.handbacks[3] == ["a1b2c3d4e5f607182"])
        #expect(strand.minY == spawner.minY, "the strand starts beside the step that spawned it")
        #expect(receiver.minY >= strand.maxY + BR.gap - 0.01, "the step that received the hand-back sits below the strand")
        #expect(layout.edges.filter { $0.kind == .spawn }.count == 1 && layout.edges.filter { $0.kind == .handback }.count == 1)
        let back = try #require(layout.edges.first { $0.kind == .handback })
        #expect(back.to.x == BR.chainX + BR.cardWidth && abs(back.to.y - (receiver.minY + 14)) < 0.01)

        // With subagents hidden there is no strand and nothing to wait for.
        let (_, _, plain) = try Self.braid(options: BraidOptions(subagents: false))
        #expect(plain.index[.subagent("a1b2c3d4e5f607182")] == nil)
        #expect(plain.nodes[plain.index[.action(3)]!].rect.minY < receiver.minY)
        #expect(!plain.edges.contains { $0.kind == .spawn || $0.kind == .handback })
    }

    @Test func whatCameBackIsWrittenOnTheArrow() throws {
        let (_, content, layout) = try Self.braid()
        // Action 0 called one tool: the note is the first line of its result and leads to the call.
        #expect(content.turns[0].steps[0].note?.key == .tool("toolu_01"))
        let notes = layout.notes.filter { if case .result = $0.kind { true } else { false } }
        // Under steps 0 and 2 of turn 0. Step 1 read an image: nothing came back in words, so its arrow says nothing.
        #expect(notes.count == 2)
        #expect(content.turns[0].steps[1].note == nil)
        let first = layout.nodes[layout.index[.action(0)]!].rect, second = layout.nodes[layout.index[.action(1)]!].rect
        #expect(notes[0].rect.minY > first.maxY && notes[0].rect.maxY < second.minY, "the note sits in the gap it made room for")
        let (_, _, bare) = try Self.braid(options: BraidOptions(resultNotes: false))
        #expect(bare.notes.isEmpty)
        #expect(bare.nodes[bare.index[.action(1)]!].rect.minY < second.minY, "without notes the chain closes up")
        // The compaction between the two turns is a pill that selects it.
        #expect(layout.pills.contains { $0.kind == .compaction && $0.key == .compaction(0) })
    }

    @Test func aCollapsedTurnIsOnePill() throws {
        let (model, _, open) = try Self.braid()
        let (_, _, layout) = try Self.braid(closed: [0])
        #expect(layout.nodes.map(\.key) == [.turn(0), .turn(0), .turn(1), .action(4), .action(5)])
        #expect(layout.nodes[1].kind == .summary(turn: 0))
        #expect(layout.index[.turn(0)] == 0, "the turn's key leads to its card, not to the pill")
        #expect(layout.bounds.height < open.bounds.height)
        // What is inside a collapsed turn is found at the turn.
        let card = layout.nodes[0].rect
        #expect(layout.rect(for: .action(2), model: model) == card)
        #expect(layout.rect(for: .tool("toolu_03"), model: model) == card)
        #expect(layout.rect(for: .subagent("a1b2c3d4e5f607182"), model: model) == card)
        #expect(layout.rect(for: .step(agent: "a1b2c3d4e5f607182", index: 1), model: model) == card)
        #expect(open.rect(for: .tool("toolu_03"), model: model) == open.nodes[open.index[.action(2)]!].rect)
        #expect(open.rect(for: .compaction(0), model: model) != nil)
    }

    @Test func onlyTheTurnsInViewAreDrawn() throws {
        let (_, _, layout) = try Self.braid()
        let second = layout.turnSpans[1]
        let lower = CGRect(x: -50, y: second.lowerBound + 30, width: 1200, height: 40)
        #expect(layout.nodes(in: lower).map(\.key) == [.turn(1), .action(4), .action(5)])
        #expect(layout.nodes(in: CGRect(x: 0, y: -500, width: 1200, height: 100)).isEmpty)
        #expect(layout.nodes(in: layout.bounds).count == layout.nodes.count)
    }

    @Test func theLayoutIsTheSameEveryTime() throws {
        let (_, _, a) = try Self.braid()
        let (_, _, b) = try Self.braid()
        #expect(a.nodes.map(\.rect) == b.nodes.map(\.rect) && a.bounds == b.bounds)
        #expect(a.edges.map(\.from) == b.edges.map(\.from) && a.edges.map(\.to) == b.edges.map(\.to))
    }

    @Test func textIsBrokenIntoLinesOnce() {
        let short = LaidText("Two words", font: CanvasFont.text, width: 300)
        #expect(short.lines.count == 1 && short.width < 80 && short.height == short.lineHeight)
        let long = LaidText(String(repeating: "word ", count: 200), font: CanvasFont.text, width: 200, maxLines: 2, lineHeight: 17)
        #expect(long.lines.count == 2 && long.height == 34 && long.width <= 200)
        // Line breaks are spaces on a card; an empty text has no lines and no height.
        #expect(LaidText("a\n\n  b", font: CanvasFont.text, width: 300).lines.count == 1)
        #expect(LaidText("   ", font: CanvasFont.text, width: 300).isEmpty && LaidText.empty.height == 0)
        // A pasted file does not get typeset to show its first three lines.
        #expect(LaidText(String(repeating: "x", count: 2_000_000), font: CanvasFont.prompt, width: 248, maxLines: 3).lines.count == 3)
    }

    @Test func theCameraKeepsThePointUnderThePointer() {
        var camera = Camera(x: 60, y: 40, scale: 0.8)
        let pointer = CGPoint(x: 500, y: 300)
        let before = CGPoint(x: (pointer.x - camera.x) / camera.scale, y: (pointer.y - camera.y) / camera.scale)
        camera.zoom(by: 2, at: pointer)
        #expect(abs(camera.scale - 1.6) < 1e-9)
        #expect(abs((pointer.x - camera.x) / camera.scale - before.x) < 1e-6 && abs((pointer.y - camera.y) / camera.scale - before.y) < 1e-6)
        camera.zoom(by: 1000, at: pointer)
        #expect(camera.scale == Camera.scales.upperBound)
        camera.zoom(by: 0.000001, at: pointer)
        #expect(camera.scale == Camera.scales.lowerBound)
        #expect(Camera(scale: 0.3).detail == .far && Camera(scale: 0.5).detail == .mid && Camera(scale: 0.62).detail == .near)
    }

    @Test func fitAndCentreShowWhatTheyShould() {
        let bounds = CGRect(x: -20, y: -20, width: 1100, height: 9000)
        let size = CGSize(width: 1400, height: 800)
        var camera = Camera()
        camera.fitWidth(bounds, in: size)
        #expect(camera.scale == 1.2, "a canvas narrower than the window is not blown up past 120 %")
        #expect(abs(camera.visible(in: size).minY - (bounds.minY - 40 / camera.scale + 20 / camera.scale)) < 30)
        camera.fitAll(bounds, in: size)
        #expect(camera.visible(in: size).contains(bounds))

        // Centring keeps the whole width in view when it fits, and brings a far camera in to read.
        var far = Camera(x: 0, y: 0, scale: 0.1)
        let node = CGRect(x: 312, y: 5000, width: 330, height: 60)
        far.center(on: node, in: size, bounds: bounds)
        #expect(far.scale == 0.8)
        #expect(far.visible(in: size).minX <= bounds.minX && far.visible(in: size).maxX >= bounds.maxX)
        #expect(far.shows(node, in: size))
        #expect(!Camera(x: 0, y: 0, scale: 1).shows(node, in: size))

        // A pan cannot leave the canvas behind.
        var lost = Camera(x: 50_000, y: -900_000, scale: 1)
        lost.clamp(to: bounds, in: size)
        #expect(lost.visible(in: size).intersects(bounds))
    }

    @Test func theSummarysMapTiesTurnsToWhatTheyTouched() throws {
        let model = try ModelTests.model()
        let map = ArcsLayout(model: model)
        #expect(map.turns.map(\.index) == [0, 1])
        #expect(map.turns[1].center.y - map.turns[0].center.y == ArcsLayout.step)
        // The file turn 0 wrote is a hub at that turn's height, tied to it by a thick strand; the subagent is a pill on the label's side.
        let file = try #require(map.hubs.first { $0.key == .file("/xxx/y.go") })
        #expect(file.rect.minX == ArcsLayout.hubX && file.written == [0])
        #expect(map.arcs.contains { map.hubs[$0.hub].key == .file("/xxx/y.go") && $0.turn == 0 && $0.write })
        let pill = try #require(map.hubs.first { $0.subagent })
        #expect(pill.key == .subagent("a1b2c3d4e5f607182") && pill.rect.maxX == ArcsLayout.labelRight)
        #expect(map.cuts.count == 1 && map.cuts[0].center.y == ArcsLayout.step / 2, "the compaction sits between the two turns")
        // No two hubs on the right overlap.
        let right = map.hubs.filter { !$0.subagent }.map(\.rect).sorted { $0.minY < $1.minY }
        for (a, b) in zip(right, right.dropFirst()) { #expect(b.minY >= a.maxY) }
        // A click: a hub is its node, a turn's label or square is the turn, the empty right is nothing.
        #expect(map.hit(at: CGPoint(x: file.rect.midX, y: file.rect.midY)) == .file("/xxx/y.go"))
        #expect(map.hit(at: CGPoint(x: -200, y: ArcsLayout.step)) == .turn(1))
        #expect(map.hit(at: CGPoint(x: 200, y: 400)) == nil)
        #expect(map.bounds.contains(file.rect) && map.bounds.contains(pill.rect))

        let outside = ArcsLayout(model: try SummaryTests.outsideModel())
        #expect(outside.hubs.contains { $0.key == .outside("web:docs.example.com") && $0.outside })
    }

    @Test func aLinkCanPointAtTheCanvas() throws {
        let url = try #require(SessionLink.url(session: "s1", view: .canvas, key: .action(60)))
        #expect(url.absoluteString == "skit-visualizer://session/s1?view=canvas&action=60")
        #expect(SessionLink.parse(url) == SessionLink.Target(session: "s1", view: .canvas, key: .action(60)))
    }
}
