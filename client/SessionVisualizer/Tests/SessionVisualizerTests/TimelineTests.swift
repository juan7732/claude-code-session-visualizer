import CoreGraphics
import Foundation
import SkitKit
import SkitTestSupport
import Testing
@testable import SessionVisualizer

/// The Timeline: the axis that cuts idle time, what the strip holds, what the
/// playhead says about a moment, and the ledger's rows. The fixture's clock is
/// known: turn 0 runs 10:00:00 to 10:00:09.5, turn 1 starts at 10:01:00.
@Suite struct TimelineTests {
    static func at(_ clock: String) -> Date { RFC3339.date("2026-11-08T\(clock)Z")! }

    // MARK: The axis

    @Test func theAxisFitsItsWidthAndCutsIdleTime() {
        // Ten seconds of work, an hour of nothing, ten seconds of work.
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let moments = [0, 4, 10, 3610, 3620].map { start.addingTimeInterval($0) }
        let axis = TimeAxis.fitted(moments: moments, width: 407)
        #expect(abs(axis.width - 407) < 0.001)
        #expect(axis.cuts.count == 1 && axis.cuts[0].width == 7 && axis.cuts[0].seconds == 3600)
        // The twenty working seconds share the 400 points the band leaves.
        #expect(abs(axis.x(start.addingTimeInterval(4)) - 80) < 0.001)
        #expect(abs(axis.x(start.addingTimeInterval(10)) - 200) < 0.001)
        #expect(abs(axis.x(start.addingTimeInterval(3610)) - 207) < 0.001)
        // A moment inside the hour is inside the band; before and after the ends, at the ends.
        let inside = axis.x(start.addingTimeInterval(1800))
        #expect(inside > 200 && inside < 207)
        #expect(axis.x(start.addingTimeInterval(-5)) == 0 && axis.x(start.addingTimeInterval(9999)) == axis.width)
        // Back from a point to its moment.
        for seconds in [0.0, 2, 7.5, 10, 3615, 3620] {
            let date = start.addingTimeInterval(seconds)
            #expect(abs(axis.date(at: axis.x(date)).timeIntervalSince(date)) < 0.001)
        }
        // Order is kept: a later moment is never drawn before an earlier one.
        let xs = stride(from: 0.0, through: 3620, by: 10).map { axis.x(start.addingTimeInterval($0)) }
        #expect(zip(xs, xs.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func manyGapsNarrowTheirBands() {
        // 200 turns a day apart: at 7 points a band they would need 1393 points of a 900-point strip.
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let moments = (0..<200).flatMap { [start.addingTimeInterval(Double($0) * 86_400), start.addingTimeInterval(Double($0) * 86_400 + 30)] }
        let axis = TimeAxis.fitted(moments: moments, width: 900)
        #expect(axis.cuts.count == 199)
        #expect(abs(axis.width - 900) < 0.01)
        #expect(abs(axis.cuts[0].width * 199 - 300) < 0.01, "the bands take a third of the width, no more")
        #expect(axis.x(moments[1]) - axis.x(moments[0]) > 2.9, "the work keeps the rest")
    }

    @Test func anAxisAtAScaleKeepsItsSteps() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let axis = TimeAxis(moments: [0, 1, 2, 200, 201].map { start.addingTimeInterval($0) }, pointsPerSecond: 2, band: 64, minStep: 14, maxStep: 700)
        // A second is two points, but no step is under 14; the gap is its band.
        #expect(axis.knots.map(\.x) == [0, 14, 28, 92, 106])
        #expect(TimeAxis(moments: [], pointsPerSecond: 1, band: 7).width == 0)
    }

    // MARK: What the strip holds

    @Test func theStripHoldsTheThreeStretches() throws {
        let model = try ModelTests.model()
        let content = TimelineContent(model: model)
        #expect(content.first == Self.at("10:00:00") && content.turns.map(\.turn) == [0, 1])
        // Action 0: the model from the prompt until its tool call, then the tool.
        let own = content.stretches.filter { $0.action == 0 }
        #expect(own.map(\.phase) == [.model, .tools])
        #expect(own[0].from == Self.at("10:00:00") && own[0].to == Self.at("10:00:02.2") && own[1].to == Self.at("10:00:03"))
        // Action 1 starts when action 0's tool finished: the wait for the model is the model's.
        #expect(content.stretches.first { $0.action == 1 }?.from == Self.at("10:00:03"))
        // Action 4 spoke, and half a second passed before the next record of its turn.
        #expect(content.said.map(\.action) == [4])
        #expect(content.stretches.last { $0.action == 4 }?.phase == .waiting)
        #expect(content.subagents.count == 1 && content.subagents[0].key == .subagent("a1b2c3d4e5f607182") && content.subagentLanes == 1)
        #expect(content.compactions.count == model.doc.compactions.count)
        // The gap between the two turns is the one cut of the axis.
        let axis = TimeAxis.fitted(moments: content.moments, width: 1000)
        #expect(axis.cuts.isEmpty, "50 s is under the 90 s that counts as idle")
        #expect(TimeAxis.fitted(moments: content.moments, width: 1000, gap: 30).cuts.count == 1)
    }

    @Test func theMomentUnderThePlayhead() throws {
        let model = try ModelTests.model()
        let content = TimelineContent(model: model)
        let thinking = content.moment(at: Self.at("10:00:01"))
        #expect(thinking.doing == .model && thinking.turn == 0 && thinking.action == 0)
        let running = content.moment(at: Self.at("10:00:02.5"))
        #expect(running.doing == .tools && running.action == 0)
        #expect(content.moment(at: Self.at("10:00:04")).action == 1, "the model has begun on the next action")
        let between = content.moment(at: Self.at("10:00:30"))
        #expect(between.doing == .betweenTurns(after: 0, forYou: true) && between.action == nil)
        #expect(content.moment(at: Self.at("10:01:03.2")).doing == .waiting)
        // The subagent ran while action 2's call waited for it.
        let sub = try #require(content.subagents.first)
        #expect(content.moment(at: sub.from).subagents == [sub.key])
        #expect(content.action(at: Self.at("09:59:00")) == nil)
        // Where a selected node puts the playhead.
        #expect(content.date(of: .turn(1), in: model) == Self.at("10:01:00"))
        #expect(content.date(of: .action(1), in: model) == Self.at("10:00:03"))
        #expect(content.date(of: .tool("toolu_01"), in: model) == Self.at("10:00:02.2"))
        #expect(content.date(of: .file("/xxx/y.go"), in: model) == nil)
    }

    // MARK: The ledger

    @Test func theLedgerIsTheTranscriptsRowsWithItsWaits() throws {
        let model = try ModelTests.model()
        let rows = LedgerItem.rows(of: model)
        // Every turn and action once, in order; the Transcript's ids, so one lookup finds a row in both.
        #expect(rows.compactMap { if case .turn(let n) = $0 { n } else { nil } } == [0, 1])
        #expect(rows.compactMap { if case .action(let n) = $0 { n } else { nil } } == [0, 1, 2, 3, 4, 5])
        #expect(rows.contains(.compaction(0)))
        for key in [NodeKey.turn(1), .action(3), .compaction(0)] {
            #expect(rows.contains { $0.id == model.itemID(for: key) })
        }
        // 50.5 s between the turns is under a minute: no gap row; the half second after "said" is no wait row.
        #expect(!rows.contains { if case .gap = $0 { true } else { false } })
        #expect(!rows.contains { if case .waited = $0 { true } else { false } })
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test func barsGrowWithTheLogarithmOfTheirTime() throws {
        let scale = LedgerScale(model: try ModelTests.model(), time: nil)
        #expect(scale.longestTurn == 9.5)
        #expect(scale.turn(9.5) == LedgerScale.width && scale.turn(0) == 0)
        #expect(scale.turn(1) > LedgerScale.width * 0.25, "a second is still a readable bar beside ten")
        #expect(LedgerScale.length(0.001, of: 3600) == 2)
    }

    @Test func parallelCallsAreNamedOnce() throws {
        let model = try ModelTests.model()
        let calls = model.doc.toolCalls
        #expect(ActionRowText.names([calls[0], calls[0], calls[1]]) == "Bash ×2, Read")
        #expect(ActionRowText.result([calls[0]])?.text.hasPrefix("→ ") == true)
        #expect(ActionRowText.result([]) == nil)
        let said = try #require(model.action(4))
        #expect(ActionRowText.verb(said, [], said: true) == "Said")
    }

    // MARK: The strip's geometry

    @Test func aClickOnAMarkFindsItsNode() throws {
        let model = try ModelTests.model()
        let content = TimelineContent(model: model)
        let metrics = StripMetrics(content: content, hasContext: true)
        let axis = TimeAxis.fitted(moments: content.moments, width: 1000)
        let x = { (date: Date) in StripMetrics.gutter + axis.x(date) }
        #expect(metrics.hit(CGPoint(x: x(Self.at("10:01:00")) + 3, y: metrics.you + 12), content: content, axis: axis) == .turn(1))
        #expect(metrics.hit(CGPoint(x: x(Self.at("10:00:30")), y: metrics.you + 12), content: content, axis: axis) == nil, "between two marks is the playhead's")
        let sub = try #require(content.subagents.first)
        #expect(metrics.hit(CGPoint(x: x(sub.from) + 1, y: metrics.subagents + 10), content: content, axis: axis) == sub.key)
        #expect(metrics.hit(CGPoint(x: x(sub.from) + 1, y: metrics.agent + 10), content: content, axis: axis) == nil)
        // No background command in this session: no row for one.
        #expect(metrics.taskLanes == 0 && metrics.tasksHeight == 0 && metrics.context == metrics.tasks)
        #expect(StripMetrics.markWidth(turns: 20, width: 1200) == 7 && StripMetrics.markWidth(turns: 400, width: 1200) == 2)
    }

    // MARK: Words and numbers

    @Test func sharesAreWrittenHonestly() {
        #expect(WherePanel.percent(71.4, of: 100) == "71%")
        #expect(WherePanel.percent(0.2, of: 100) == "<1%", "there, but it rounds to nothing")
        #expect(WherePanel.percent(0, of: 100) == "0%" && WherePanel.percent(5, of: 0) == "0%")
    }

    @Test func theOffsetIntoTheSession() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        #expect(NowLine.offset(start.addingTimeInterval(252), from: start) == "+0:04:12")
        #expect(NowLine.offset(start.addingTimeInterval(26 * 3600 + 27 * 60 + 12), from: start) == "+26:27:12")
        #expect(NowLine.offset(start.addingTimeInterval(6 * 86_400 + 22 * 3600 + 47 * 60 + 16), from: start) == "+6d 22:47:16")
        #expect(NowLine.offset(start.addingTimeInterval(-9), from: start) == "+0:00:00")
    }

    @Test func theSplitDecodesAndAddsUp() throws {
        let time = try JSONDecoder.skit().decode(SessionTime.self, from: Fixtures.data("time.json"))
        #expect(time.turns.map(\.turn) == [0, 1])
        #expect(time.turns.allSatisfy { abs($0.seconds - ($0.model + $0.tools + $0.subagents + $0.waiting)) < 0.002 })
    }
}
