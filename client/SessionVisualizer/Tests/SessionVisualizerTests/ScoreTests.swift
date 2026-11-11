import CoreGraphics
import Foundation
import SkitKit
import SkitTestSupport
import Testing
@testable import SessionVisualizer

/// The Score: rows for who was working, bars where time puts them. The
/// drawing is checked with snapshots; these are the rules a picture cannot
/// show to be broken. The fixture: turn 0 has four actions, the third spawns a
/// subagent that hands back into the fourth; turn 1 starts a minute in.
@Suite struct ScoreTests {
    static func score(_ options: ScoreOptions = ScoreOptions()) throws -> (SessionModel, ScoreLayout) {
        let model = try ModelTests.model()
        return (model, ScoreLayout(model: model, options: options))
    }

    static func nodes(_ layout: ScoreLayout, where kind: (ScoreLayout.Kind) -> Bool) -> [ScoreLayout.Node] {
        layout.nodes.filter { kind($0.kind) }
    }

    @Test func everyActorHasItsRow() throws {
        let (model, layout) = try Self.score()
        // You, the agent, the one subagent; no background command and no file touched three times.
        #expect(layout.rows.count == 3 && layout.rows.allSatisfy { !$0.file })
        let prompts = Self.nodes(layout) { if case .prompt = $0 { true } else { false } }
        let actions = Self.nodes(layout) { if case .action = $0 { true } else { false } }
        let tools = Self.nodes(layout) { if case .tool = $0 { true } else { false } }
        let strands = Self.nodes(layout) { $0 == .strand }
        #expect(prompts.map(\.key) == [.turn(0), .turn(1)])
        #expect(actions.map(\.key) == (0..<6).map { .action($0) })
        #expect(tools.count == model.doc.toolCalls.count && strands.count == 1)
        // Rows do not share height: prompts above actions above tool calls above the strand.
        #expect(prompts[0].rect.maxY <= actions[0].rect.minY)
        #expect(actions[0].rect.maxY <= tools[0].rect.minY)
        #expect(tools.map(\.rect.maxY).max()! <= strands[0].rect.minY)
        #expect(layout.bounds.contains(strands[0].rect) && layout.height > strands[0].rect.maxY)
    }

    @Test func timePutsThingsWhereTheyHappened() throws {
        let (model, layout) = try Self.score()
        let x = layout.axis.x
        let rect = { (key: NodeKey) in layout.nodes[layout.index[key]!].rect }
        // An action's bar starts where the model began on it, and the bars of a turn follow each other.
        for span in model.relations.spans { #expect(rect(.action(span.action)).minX == x(span.start)) }
        #expect(rect(.action(1)).minX >= rect(.action(0)).maxX)
        // A tool call starts inside its action's bar: after the model wrote it.
        let call = try #require(model.toolsByID["toolu_01"])
        #expect(rect(.tool("toolu_01")).minX == x(call.at) && rect(.tool("toolu_01")).minX > rect(.action(0)).minX)
        // A prompt's chip is where its turn began; turn 1 is right of everything in turn 0.
        #expect(rect(.turn(0)).minX == x(model.doc.turns[0].startAt))
        #expect(rect(.turn(1)).minX > rect(.action(3)).maxX)
        // The same moment is at the same x on every row: a strand starts where its own first record is,
        // never before the call that spawned it.
        let run = try #require(model.subagent("a1b2c3d4e5f607182")?.session)
        let strand = rect(.subagent("a1b2c3d4e5f607182")), spawn = rect(.tool("toolu_03"))
        #expect(strand.minX == x(run.firstAt) && strand.minX >= spawn.minX)
    }

    @Test func theAxisSpreadsCloseMomentsAndCutsIdleOnes() throws {
        let (_, layout) = try Self.score()
        let knots = layout.axis.knots
        // No two moments closer than 14 points, however close in time.
        #expect(zip(knots, knots.dropFirst()).allSatisfy { $1.x - $0.x >= SC.minStep - 0.001 })
        #expect(layout.bands.isEmpty, "50 s between the turns is under the 90 s that counts as idle")
        // A wider time scale never draws anything earlier.
        let wide = try Self.score(ScoreOptions(pointsPerSecond: 3.2)).1
        #expect(wide.axis.width >= layout.axis.width)
    }

    @Test func anActionsBarIsTheModelThenItsTools() throws {
        let (model, layout) = try Self.score()
        let x = layout.axis.x
        for node in Self.nodes(layout, where: { if case .action = $0 { true } else { false } }) {
            guard case .action(let working, let running, let said) = node.kind, case .action(let n) = node.key, let span = model.spans[n] else { continue }
            #expect(working >= 2 && working + running <= node.rect.width + 0.001)
            #expect(said == (span.said == true))
            if span.toolsEnd > span.genEnd, node.rect.width > 8 { #expect(abs(running - min(node.rect.width - working, x(span.toolsEnd) - x(span.genEnd))) < 0.001) }
        }
        // What a bar says.
        let bash = layout.nodes[layout.index[.action(0)]!]
        #expect(bash.symbol == "terminal" && bash.tip.hasPrefix("Action 0 · Bash"))
        let spoke = try #require(model.action(4))
        #expect(ScoreLayout.look(spoke, [], said: true).symbol == "text.bubble")
    }

    @Test func aSubagentIsTiedToItsSpawnAndItsHandBack() throws {
        let (_, layout) = try Self.score()
        let spawn = try #require(layout.edges.first { $0.kind == .spawn })
        let back = try #require(layout.edges.first { $0.kind == .handback })
        let strand = layout.nodes[layout.index[.subagent("a1b2c3d4e5f607182")]!].rect
        let call = layout.nodes[layout.index[.tool("toolu_03")]!].rect
        let receiver = layout.nodes[layout.index[.action(3)]!].rect
        #expect(spawn.from.y == call.maxY && spawn.to.y == strand.minY, "from under the call to the top of the strand")
        #expect(back.from.y == strand.minY && back.to.y == receiver.maxY && back.to.x > receiver.minX, "from the strand's end into the action that used it")
        // Its steps sit inside it, in time.
        let steps = Self.nodes(layout) { if case .step = $0 { true } else { false } }
        #expect(steps.count == 2 && steps.allSatisfy { $0.rect.minY > strand.minY && $0.rect.maxY < strand.maxY })
        #expect(steps[0].key == .step(agent: "a1b2c3d4e5f607182", index: 0))
        // Hidden with the Subagents pill: no strand, no row, no arrows.
        let without = try Self.score(ScoreOptions(subagents: false)).1
        #expect(without.index[.subagent("a1b2c3d4e5f607182")] == nil && without.edges.isEmpty && without.rows.count == 2)
    }

    @Test func aKeyLeadsToTheNodeThatStandsForIt() throws {
        let (model, layout) = try Self.score()
        // A turn's key is its prompt chip, not the bar that stands for it from far away.
        #expect(layout.nodes[layout.index[.turn(0)]!].kind == .prompt(human: true))
        #expect(layout.nodes.contains { $0.key == .turn(0) && $0.kind == .turn })
        #expect(layout.rect(for: .step(agent: "a1b2c3d4e5f607182", index: 1), model: model) != nil)
        #expect(layout.rect(for: .work(0), model: model) == layout.rect(for: .action(0), model: model))
        let cut = try #require(layout.rect(for: .compaction(0), model: model))
        #expect(cut.minX == layout.axis.x(model.doc.compactions[0].at))
        #expect(layout.rect(for: .file("/nowhere"), model: model) == nil)
    }

    @Test func lanesHoldWhatOverlaps() {
        let t = { (s: Double) in Date(timeIntervalSinceReferenceDate: s) }
        // Three calls at once take three lanes; one after them takes the first again.
        let laned = ScoreLayout.laned([("a", t(0), t(10)), ("b", t(1), t(4)), ("c", t(2), t(9)), ("d", t(5), t(8)), ("e", t(10), t(11))])
        #expect(laned.count == 3)
        #expect(laned.lanes == ["a": 0, "b": 1, "c": 2, "d": 1, "e": 0])
        #expect(ScoreLayout.laned([]).count == 1)
    }

    @Test func theRulerSaysHowFarIn() {
        #expect(ScoreLayout.offset(0) == "+0m" && ScoreLayout.offset(26 * 60 + 40) == "+26m")
        #expect(ScoreLayout.offset(3600 + 4 * 60) == "+1h 04m")
        #expect(ScoreLayout.offset(2 * 86_400 + 3 * 3600 + 59) == "+2d 3h")
    }

    @Test func theCameraFitsTheRowsAndShowsANode() throws {
        let (_, layout) = try Self.score()
        var camera = Camera()
        let size = CGSize(width: 1400, height: 700)
        camera.fitRows(layout.bounds, in: size)
        // Every row in the height, the session's start past the row names, under the ruler.
        #expect(camera.scale <= 1.3 && camera.scale >= 0.3)
        #expect(layout.bounds.height * camera.scale <= size.height - 100 || camera.scale == 0.3)
        #expect(camera.x + layout.bounds.minX * camera.scale > SC.gutter && camera.y + layout.bounds.minY * camera.scale > SC.ruler)
        // Showing a node far to the right moves time, not the rows.
        let y = camera.y
        let rect = layout.nodes[layout.index[.turn(1)]!].rect
        camera.show(rect, in: size, readable: false)
        #expect(camera.y == y)
        let onScreen = rect.minX * camera.scale + camera.x
        #expect(onScreen > SC.gutter && onScreen < size.width / 2)
    }
}
