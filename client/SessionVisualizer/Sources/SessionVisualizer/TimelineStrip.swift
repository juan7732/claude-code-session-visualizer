import SkitKit
import SwiftUI

/// The rows of the strip and where each begins, top to bottom.
nonisolated struct StripMetrics: Equatable, Sendable {
    /// The column of row names at the left.
    static let gutter: CGFloat = 96
    /// Room at the right, so the last moment is not on the edge.
    static let trailing: CGFloat = 12
    static let ruler: CGFloat = 26
    static let row: CGFloat = 34

    var subagentLanes: Int
    var taskLanes: Int
    var hasContext: Bool

    init(content: TimelineContent, hasContext: Bool) {
        subagentLanes = content.subagents.isEmpty ? 0 : min(4, content.subagentLanes)
        taskLanes = content.tasks.isEmpty ? 0 : min(4, content.taskLanes)
        self.hasContext = hasContext
    }

    var you: CGFloat { Self.ruler }
    var agent: CGFloat { you + Self.row }
    var subagents: CGFloat { agent + Self.row }
    var subagentsHeight: CGFloat { subagentLanes == 0 ? 0 : max(Self.row, CGFloat(subagentLanes) * 12 + 14) }
    var tasks: CGFloat { subagents + subagentsHeight }
    var tasksHeight: CGFloat { taskLanes == 0 ? 0 : max(Self.row, CGFloat(taskLanes) * 12 + 14) }
    var context: CGFloat { tasks + tasksHeight }
    var contextHeight: CGFloat { hasContext ? 62 : 0 }
    var output: CGFloat { context + contextHeight }
    var outputHeight: CGFloat { hasContext ? 30 : 0 }
    var height: CGFloat { output + outputHeight + 4 }

    /// How wide a turn's mark is: 7 points, less when the turns would run together.
    static func markWidth(turns: Int, width: CGFloat) -> CGFloat {
        guard turns > 0 else { return 7 }
        return min(7, max(2, width / CGFloat(turns) * 0.45))
    }

    /// The top and the height of a bar on a lane of a row.
    func lane(_ lane: Int, of lanes: Int, rowTop: CGFloat, rowHeight: CGFloat) -> (y: CGFloat, height: CGFloat) {
        let lanes = max(1, lanes)
        let height = min(12, (rowHeight - 12) / CGFloat(lanes) - 2)
        let block = CGFloat(lanes) * (height + 2) - 2
        return (rowTop + (rowHeight - block) / 2 + CGFloat(min(lane, lanes - 1)) * (height + 2), height)
    }

    /// The node under a point of the strip: a turn's mark, a subagent's bar, a background command.
    func hit(_ point: CGPoint, content: TimelineContent, axis: TimeAxis) -> NodeKey? {
        let x = point.x - Self.gutter
        guard x >= -6 else { return nil }
        if point.y >= you, point.y < agent {
            let near = content.turns.min { abs(axis.x($0.at) - x) < abs(axis.x($1.at) - x) }
            if let near, abs(axis.x(near.at) - x) <= 7 { return .turn(near.turn) }
        }
        func bar(_ bars: [TimelineContent.Bar], minWidth: CGFloat) -> NodeKey? {
            bars.last { bar in
                let from = axis.x(bar.from)
                return x >= from - 2 && x <= max(from + minWidth, axis.x(bar.to)) + 2
            }?.key
        }
        if subagentLanes > 0, point.y >= subagents, point.y < tasks { return bar(content.subagents, minWidth: 3) }
        if taskLanes > 0, point.y >= tasks, point.y < context { return bar(content.tasks, minWidth: 6) }
        return nil
    }
}

/// The whole session in one strip that fits the width (mock: `?view=timeline`,
/// the strip): idle gaps cut to hatched bands, a mark per turn, the agent's
/// time as the model working, tools running and waiting, subagents and
/// background commands on rows of their own, the context curve with its
/// compactions and the output of every request. Drag anywhere to move the
/// playhead; a click on a mark selects it.
struct TimelineStrip: View {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    @AppStorage(SettingsKey.timelineSpeed) private var speed = 30.0
    var model: SessionModel
    var content: TimelineContent
    var context: [ContextPoint]
    /// The playhead was dragged or played to a moment.
    var onMove: (Date) -> Void
    /// A drag or a play ended: the playhead rests.
    var onRest: () -> Void
    var onSelect: (NodeKey) -> Void
    @State private var grabbed: Grab?
    @State private var axes = AxisCache()

    private enum Grab: Equatable {
        case playhead
        case node(NodeKey)
    }

    /// The axis for a width, kept while neither changes.
    private final class AxisCache {
        var width: CGFloat = -1
        var moments = 0
        var axis: TimeAxis?

        func axis(for content: TimelineContent, width: CGFloat) -> TimeAxis {
            if let axis, self.width == width, moments == content.moments.count { return axis }
            let made = TimeAxis.fitted(moments: content.moments, width: width)
            (self.axis, self.width, moments) = (made, width, content.moments.count)
            return made
        }
    }

    var body: some View {
        let metrics = StripMetrics(content: content, hasContext: !context.isEmpty)
        let timeline = window.timeline
        GeometryReader { geo in
            let axis = axes.axis(for: content, width: max(120, geo.size.width - StripMetrics.gutter - StripMetrics.trailing))
            ZStack(alignment: .topLeading) {
                StripDrawing(content: content, context: context, axis: axis, metrics: metrics, palette: palette,
                             selection: window.selection, hits: window.transcript.hits)
                    .equatable()
                HoverLine(axis: axis, height: metrics.height)
                Playhead(axis: axis, height: metrics.height)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if grabbed == nil { grabbed = metrics.hit(value.startLocation, content: content, axis: axis).map { .node($0) } ?? .playhead }
                    guard grabbed == .playhead else { return }
                    timeline.playing = false
                    onMove(axis.date(at: min(max(0, value.location.x - StripMetrics.gutter), axis.width)))
                }
                .onEnded { _ in
                    if case .node(let key) = grabbed { onSelect(key) } else { onRest() }
                    grabbed = nil
                })
            .task(id: PlayKey(playing: timeline.playing, width: axis.width, speed: speed)) {
                // Playing moves along the strip, not along the clock: an idle night is one band wide.
                guard timeline.playing else { return }
                var last = ContinuousClock.now
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(33))
                    if Task.isCancelled { return }
                    let now = ContinuousClock.now
                    let passed = now - last
                    last = now
                    let seconds = Double(passed.components.seconds) + Double(passed.components.attoseconds) / 1e18
                    let x = axis.x(timeline.time ?? content.first) + CGFloat(speed * seconds)
                    if x >= axis.width {
                        onMove(content.last)
                        timeline.playing = false
                        onRest()
                        return
                    }
                    onMove(axis.date(at: x))
                }
            }
        }
        .frame(height: metrics.height)
        .background(palette.panel, in: RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
        .help("Drag to move the playhead. Click a turn's mark, a subagent or a background command to select it.")
        .accessibilityElement()
        .accessibilityLabel("The session over time")
        .accessibilityValue(window.timeline.time.map { Format.dateTime($0) } ?? "")
    }

    private struct PlayKey: Equatable {
        var playing: Bool
        var width: CGFloat
        var speed: Double
    }
}

/// The red line that says "now".
private struct Playhead: View {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var axis: TimeAxis
    var height: CGFloat

    var body: some View {
        if let time = window.timeline.time {
            let x = StripMetrics.gutter + axis.x(time)
            Path { path in
                path.addRect(CGRect(x: x - 0.75, y: 0, width: 1.5, height: height))
                path.move(to: CGPoint(x: x - 5.5, y: 0))
                path.addLine(to: CGPoint(x: x + 5.5, y: 0))
                path.addLine(to: CGPoint(x: x, y: 8))
                path.closeSubpath()
            }
            .fill(palette.err)
            .allowsHitTesting(false)
        }
    }
}

/// A faint line under the pointer, with the clock time it stands on.
private struct HoverLine: View {
    @Environment(\.palette) private var palette
    var axis: TimeAxis
    var height: CGFloat
    @State private var x: CGFloat?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point): x = point.x >= StripMetrics.gutter && point.x <= StripMetrics.gutter + axis.width ? point.x : nil
                case .ended: x = nil
                }
            }
            .overlay(alignment: .topLeading) {
                if let x {
                    Rectangle().fill(palette.ink.opacity(0.25)).frame(width: 1, height: height - StripMetrics.ruler)
                        .offset(x: x, y: StripMetrics.ruler)
                    Text(axis.date(at: x - StripMetrics.gutter).formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.ink)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(palette.panel2, in: Capsule())
                        .fixedSize()
                        .offset(x: min(max(StripMetrics.gutter, x - 30), StripMetrics.gutter + axis.width - 62), y: 5)
                }
            }
            .allowsHitTesting(true)
            .accessibilityHidden(true)
    }
}

/// The strip itself, drawn once for a width; the playhead moves over it.
private struct StripDrawing: View, Equatable {
    var content: TimelineContent
    var context: [ContextPoint]
    var axis: TimeAxis
    var metrics: StripMetrics
    var palette: Palette
    var selection: NodeKey?
    var hits: [NodeKey]

    static func == (a: StripDrawing, b: StripDrawing) -> Bool {
        a.content == b.content && a.context.count == b.context.count && a.axis == b.axis && a.metrics == b.metrics
            && a.palette == b.palette && a.selection == b.selection && a.hits == b.hits
    }

    var body: some View {
        Canvas { g, size in
            let gutter = StripMetrics.gutter
            func x(_ date: Date) -> CGFloat { gutter + axis.x(date) }
            let bottom = metrics.height

            // The gutter and the lines between rows.
            g.fill(Path(CGRect(x: 0, y: 0, width: gutter, height: bottom)), with: .color(palette.panel2.opacity(0.45)))
            var rules = Path()
            for y in [metrics.you, metrics.agent, metrics.subagents, metrics.tasks, metrics.context, metrics.output] {
                rules.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
            }
            g.fill(rules, with: .color(palette.line))
            label("YOU", y: metrics.you, height: StripMetrics.row, in: &g)
            label("AGENT", y: metrics.agent, height: StripMetrics.row, in: &g)
            if metrics.subagentLanes > 0 { label("SUBAGENTS", y: metrics.subagents, height: metrics.subagentsHeight, in: &g) }
            if metrics.taskLanes > 0 { label("BACKGROUND", y: metrics.tasks, height: metrics.tasksHeight, in: &g) }

            // Idle gaps: bands the same width however long, hatched when there is room.
            for cut in axis.cuts {
                let band = CGRect(x: gutter + cut.x, y: StripMetrics.ruler, width: cut.width, height: bottom - StripMetrics.ruler)
                g.fill(Path(band), with: .color(palette.bg.opacity(0.75)))
                guard cut.width >= 4 else { continue }
                var hatch = g
                hatch.clip(to: Path(band))
                var lines = Path()
                var offset: CGFloat = -band.height
                while offset < band.width {
                    lines.move(to: CGPoint(x: band.minX + offset, y: band.maxY))
                    lines.addLine(to: CGPoint(x: band.minX + offset + band.height, y: band.minY))
                    offset += 5
                }
                hatch.stroke(lines, with: .color(palette.line2), lineWidth: 1)
            }

            // The ruler: a number per turn, where there is room for it.
            var lastX: CGFloat = -.greatestFiniteMagnitude
            for turn in content.turns {
                let at = x(turn.at)
                guard at - lastX >= 26 else { continue }
                lastX = at
                let text = g.resolve(Text("\(turn.turn)").font(.system(size: 10, weight: .bold)).foregroundStyle(palette.ink))
                let width = max(18, text.measure(in: CGSize(width: 60, height: 20)).width + 10)
                let pill = CGRect(x: min(max(gutter + 1, at - width / 2), size.width - width - 1), y: 5, width: width, height: 16)
                g.fill(Path(roundedRect: pill, cornerRadius: 8), with: .color(palette.panel2))
                g.draw(text, at: CGPoint(x: pill.midX, y: pill.midY), anchor: .center)
            }

            // You: a mark where each turn began.
            // In a session of many short turns the marks narrow, so each still stands apart.
            let wide = StripMetrics.markWidth(turns: content.turns.count, width: axis.width)
            for turn in content.turns {
                let mark = CGRect(x: x(turn.at) - wide / 2, y: metrics.you + 8, width: wide, height: 18)
                g.fill(Path(roundedRect: mark, cornerRadius: min(2.5, wide / 2)), with: .color(turn.human ? palette.ink : palette.muted))
                if selection == .turn(turn.turn) {
                    g.stroke(Path(roundedRect: mark.insetBy(dx: -3, dy: -3), cornerRadius: 5), with: .color(palette.accent), lineWidth: 2)
                }
            }

            // Agent: the model working, tools running, waiting to be brought back.
            let top = metrics.agent + 10
            var working = Path(), tools = Path(), waiting = Path()
            for stretch in content.stretches {
                let from = x(stretch.from), to = x(stretch.to)
                switch stretch.phase {
                case .model: working.addRect(CGRect(x: from, y: top, width: max(1.5, to - from), height: 14))
                case .tools: tools.addRect(CGRect(x: from, y: top, width: max(1, to - from), height: 14))
                case .waiting: waiting.addRect(CGRect(x: from, y: top + 4, width: max(1, to - from), height: 6))
                }
            }
            g.fill(waiting, with: .color(palette.ctx.opacity(0.55)))
            g.fill(working, with: .color(palette.accent))
            g.fill(tools, with: .color(palette.tool))
            var spoke = Path()
            let tick: CGFloat = wide < 5 ? 1 : 2
            for mark in content.said { spoke.addRect(CGRect(x: x(mark.from) - tick / 2, y: top - 3, width: tick, height: 20)) }
            g.fill(spoke, with: .color(palette.ink.opacity(wide < 5 ? 0.7 : 1)))
            if case .action(let n) = selection {
                let own = content.stretches.filter { $0.action == n && $0.phase != .waiting }
                if let from = own.map(\.from).min(), let to = own.map(\.to).max() {
                    let ring = CGRect(x: x(from) - 2.5, y: top - 3.5, width: max(6, x(to) - x(from) + 5), height: 21)
                    g.stroke(Path(roundedRect: ring, cornerRadius: 4), with: .color(palette.accent), lineWidth: 2)
                }
            }

            bars(content.subagents, lanes: metrics.subagentLanes, top: metrics.subagents, height: metrics.subagentsHeight, minWidth: 3, x: x, in: &g) { rect, g in
                g.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(palette.warn))
            }
            bars(content.tasks, lanes: metrics.taskLanes, top: metrics.tasks, height: metrics.tasksHeight, minWidth: 6, x: x, in: &g) { rect, g in
                g.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(palette.ctx.opacity(0.18)))
                g.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2.5), with: .color(palette.ctx), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }

            // What find matched: a dot over the agent's row.
            if !hits.isEmpty {
                var dots = Path()
                let starts = Dictionary(content.starts.map { ($0.action, $0.at) }, uniquingKeysWith: { a, _ in a })
                for hit in hits {
                    let at: Date? = switch hit {
                    case .action(let n): starts[n]
                    case .turn(let n): content.turns.first { $0.turn == n }?.at
                    case .subagent: content.subagents.first { $0.key == hit }?.from
                    default: nil
                    }
                    if let at { dots.addEllipse(in: CGRect(x: x(at) - 2.5, y: metrics.agent + 1.5, width: 5, height: 5)) }
                }
                g.fill(dots, with: .color(palette.warn))
            }

            guard metrics.hasContext, let peak = context.map(\.tokens).max(), peak > 0 else { return }
            // Context: how full the window was at every request; a compaction cuts it.
            label("CONTEXT", y: metrics.context, height: metrics.contextHeight, detail: "PEAK " + Format.tokens(peak).uppercased(), in: &g)
            let floor = metrics.context + metrics.contextHeight - 4
            func y(_ tokens: Int) -> CGFloat { floor - CGFloat(tokens) / CGFloat(peak) * (metrics.contextHeight - 14) }
            var line = Path(), area = Path()
            for (i, point) in context.enumerated() {
                let p = CGPoint(x: x(point.at), y: y(point.tokens))
                if i == 0 {
                    line.move(to: p)
                    area.move(to: CGPoint(x: p.x, y: floor))
                    area.addLine(to: p)
                } else {
                    line.addLine(to: p)
                    area.addLine(to: p)
                }
            }
            if let lastPoint = context.last {
                area.addLine(to: CGPoint(x: x(lastPoint.at), y: floor))
                area.closeSubpath()
            }
            g.fill(area, with: .color(palette.accent.opacity(0.15)))
            g.stroke(line, with: .color(palette.accent), lineWidth: 1.5)
            for cut in content.compactions {
                let at = x(cut.at)
                g.fill(Path(CGRect(x: at - 0.75, y: metrics.context + 6, width: 1.5, height: metrics.contextHeight - 10)), with: .color(palette.warn))
                let dot = CGRect(x: at - 3.5, y: metrics.context + 3, width: 7, height: 7)
                g.fill(Path(ellipseIn: dot), with: .color(palette.warn))
                if selection == .compaction(cut.index) {
                    g.stroke(Path(ellipseIn: dot.insetBy(dx: -3, dy: -3)), with: .color(palette.accent), lineWidth: 2)
                }
            }

            // Output: what each request wrote.
            let most = max(1, context.map(\.output).max() ?? 1)
            label("OUTPUT", y: metrics.output, height: metrics.outputHeight, detail: "MOST " + Format.tokens(most).uppercased(), in: &g)
            var wrote = Path()
            let base = metrics.output + metrics.outputHeight - 3
            for point in context where point.output > 0 {
                let tall = max(1.5, CGFloat(point.output) / CGFloat(most) * (metrics.outputHeight - 9))
                wrote.addRect(CGRect(x: x(point.at) - 1, y: base - tall, width: 2, height: tall))
            }
            g.fill(wrote, with: .color(palette.ink2.opacity(0.8)))
        }
        .accessibilityHidden(true)
    }

    private func label(_ text: String, y: CGFloat, height: CGFloat, detail: String? = nil, in g: inout GraphicsContext) {
        let font = Font.custom("Avenir Next", size: 9.5).weight(.semibold)
        let name = Text(text).font(font).tracking(0.9).foregroundStyle(palette.muted)
        guard let detail else {
            g.draw(name, at: CGPoint(x: 12, y: y + height / 2), anchor: .leading)
            return
        }
        g.draw(name, at: CGPoint(x: 12, y: y + height / 2 - 6), anchor: .leading)
        g.draw(Text(detail).font(font).tracking(0.6).foregroundStyle(palette.muted2), at: CGPoint(x: 12, y: y + height / 2 + 7), anchor: .leading)
    }

    private func bars(_ bars: [TimelineContent.Bar], lanes: Int, top: CGFloat, height: CGFloat, minWidth: CGFloat, x: (Date) -> CGFloat,
                      in g: inout GraphicsContext, draw: (CGRect, inout GraphicsContext) -> Void) {
        guard lanes > 0 else { return }
        for bar in bars {
            let lane = metrics.lane(bar.lane, of: lanes, rowTop: top, rowHeight: height)
            let from = x(bar.from)
            let rect = CGRect(x: from, y: lane.y, width: max(minWidth, x(bar.to) - from), height: lane.height)
            draw(rect, &g)
            if selection == bar.key {
                g.stroke(Path(roundedRect: rect.insetBy(dx: -3, dy: -3), cornerRadius: 5), with: .color(palette.accent), lineWidth: 2)
            }
        }
    }
}
