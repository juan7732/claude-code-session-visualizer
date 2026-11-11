import SkitKit
import SwiftUI

/// The Arcs weave, laid out (mock: `layoutArcs` as the Summary uses it): turns
/// down a spine with the prompt beside each, and to the right a hub for every
/// file that kept coming back and every outside service, each placed at the
/// mean height of the turns that touched it and tied to them.
nonisolated struct ArcsLayout: Sendable {
    static let step: CGFloat = 50
    static let spineWidth: CGFloat = 44
    static let labelRight: CGFloat = -70
    static let labelWidth: CGFloat = 280
    static let hubX: CGFloat = 330
    static let maxHubs = 14

    struct TurnMark: Sendable {
        var index: Int
        var human: Bool
        var center: CGPoint
        var size: CGFloat
        var label: String
        var time: String
        var actions: Int
        var failed: Bool

        var rect: CGRect { CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size) }
    }

    struct Hub: Sendable {
        var key: NodeKey
        var label: String
        var count: Int
        var outside: Bool
        var subagent: Bool
        var rect: CGRect
        /// The turns that touched it, and in which of them it was written.
        var turns: [Int: Int]
        var written: Set<Int>
    }

    struct Arc: Sendable {
        var hub: Int
        var turn: Int
        var from: CGPoint
        var to: CGPoint
        var width: CGFloat
        var write: Bool
    }

    /// A background command coming back: a dashed loop beside the spine.
    struct Loop: Sendable {
        var from: CGPoint
        var to: CGPoint
        var bulge: CGFloat
    }

    var turns: [TurnMark] = []
    var hubs: [Hub] = []
    var arcs: [Arc] = []
    var loops: [Loop] = []
    /// Compactions, each at the height between the turns it fell between.
    var cuts: [(index: Int, center: CGPoint, text: String)] = []
    var bounds = CGRect.zero

    init(model: SessionModel) {
        let doc = model.doc
        var yOf: [Int: CGFloat] = [:]
        for (i, turn) in doc.turns.enumerated() {
            let y = CGFloat(i) * Self.step
            yOf[turn.index] = y
            let prompt = model.prompt(ofTurn: turn.index)
            let calls = turn.actionIndexes.compactMap { model.action($0) }.flatMap { model.tools(of: $0) }
            let human = turn.isHuman && prompt != nil
            let offset = max(0, Int(turn.startAt.timeIntervalSince(doc.firstAt)))
            turns.append(TurnMark(
                index: turn.index, human: human, center: CGPoint(x: Self.spineWidth / 2, y: y), size: human ? 36 : 26,
                label: human ? SessionModel.firstLine(prompt?.text ?? "", max: 52) : SessionModel.originLabel(turn.origin).lowercased() + " · \(turn.actionIndexes.count) action\(turn.actionIndexes.count == 1 ? "" : "s")",
                time: String(format: "+%d:%02d:%02d", offset / 3600, offset % 3600 / 60, offset % 60),
                actions: turn.actionIndexes.count, failed: calls.contains(where: \.isError)))
        }
        for (n, cut) in doc.compactions.enumerated() {
            guard let after = doc.turns.firstIndex(where: { $0.startAt >= cut.at }), after > 0 else { continue }
            cuts.append((n, CGPoint(x: Self.spineWidth / 2 + 78, y: (CGFloat(after) - 0.5) * Self.step),
                         "compacted · \(Format.tokens(cut.metadata?.preTokens ?? 0)) → \(Format.tokens(cut.metadata?.postTokens ?? 0))"))
        }

        // Hubs: the files that were written or came back, most touched first, and every outside service.
        struct Draft { var key: NodeKey; var label: String; var count: Int; var outside: Bool; var turns: [Int: Int]; var written: Set<Int> }
        var drafts: [Draft] = []
        for file in model.relations.files.filter({ $0.writes > 0 || $0.touches.count >= 2 }).sorted(by: { $0.touches.count > $1.touches.count }).prefix(Self.maxHubs) {
            var per: [Int: Int] = [:]
            var written = Set<Int>()
            for touch in file.touches {
                per[touch.turn, default: 0] += 1
                if touch.mode == "write" { written.insert(touch.turn) }
            }
            drafts.append(Draft(key: .file(file.path), label: BraidContent.shortPath(file.path), count: file.touches.count, outside: false, turns: per, written: written))
        }
        for service in model.relations.outside {
            var per: [Int: Int] = [:]
            for call in service.calls { per[call.turn, default: 0] += 1 }
            drafts.append(Draft(key: .outside(service.id), label: service.name, count: service.calls.count, outside: true, turns: per, written: []))
        }
        func width(_ label: String) -> CGFloat { 30 + CGFloat(min(36, label.count)) * 6.6 + 26 }
        let placed = drafts.compactMap { draft -> (Draft, CGFloat)? in
            let ys = draft.turns.keys.compactMap { yOf[$0] }
            return ys.isEmpty ? nil : (draft, ys.reduce(0, +) / CGFloat(ys.count))
        }.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.count > $1.0.count }
        var last = -CGFloat.infinity
        for (draft, mean) in placed {
            // At the mean height of its turns, pushed down past the hub above.
            let y = max(mean, last + 28)
            last = y
            let hub = Hub(key: draft.key, label: draft.label, count: draft.count, outside: draft.outside, subagent: false,
                          rect: CGRect(x: Self.hubX, y: y - 11, width: width(draft.label), height: 22), turns: draft.turns, written: draft.written)
            for (turn, count) in draft.turns.sorted(by: { $0.key < $1.key }) {
                guard let y0 = yOf[turn] else { continue }
                arcs.append(Arc(hub: hubs.count, turn: turn, from: CGPoint(x: Self.spineWidth, y: y0), to: CGPoint(x: Self.hubX, y: y),
                                width: 0.8 + min(3, CGFloat(count) * 0.7), write: draft.written.contains(turn)))
            }
            hubs.append(hub)
        }
        // Subagents: amber pills under their turn, on the label's side.
        for sub in doc.subagents {
            guard let turn = model.turnIndex(of: .subagent(sub.agentId)), let y0 = yOf[turn] else { continue }
            let label = sub.meta?.description ?? sub.agentId
            let w = 30 + CGFloat(min(44, label.count)) * 6.4 + 26
            hubs.append(Hub(key: .subagent(sub.agentId), label: label, count: sub.session?.actions.count ?? 0, outside: false, subagent: true,
                            rect: CGRect(x: Self.labelRight - w, y: y0 + 22 - 11, width: w, height: 22), turns: [turn: 1], written: []))
        }
        for task in model.relations.tasks {
            guard let last = task.pickups.last ?? task.stop, let y0 = yOf[task.launch.turn], let y1 = yOf[last.turn] else { continue }
            loops.append(Loop(from: CGPoint(x: 0, y: y0 == y1 ? y0 - 10 : y0), to: CGPoint(x: 0, y: y0 == y1 ? y0 + 10 : y1), bulge: y0 == y1 ? 44 : 34 + abs(y1 - y0) * 0.12))
        }
        let right = Self.hubX + max(120, hubs.filter { !$0.subagent }.map(\.rect.width).max() ?? 0) + 30
        let bottom = max(CGFloat(max(0, doc.turns.count - 1)) * Self.step, hubs.map(\.rect.midY).max() ?? 0) + 50
        bounds = CGRect(x: Self.labelRight - Self.labelWidth - 20, y: -40, width: right - (Self.labelRight - Self.labelWidth - 20), height: bottom + 40)
    }

    /// What a point of the map is on: a turn (its square or its label) or a hub.
    func hit(at point: CGPoint) -> NodeKey? {
        if let hub = hubs.first(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }) { return hub.key }
        if let turn = turns.first(where: { abs(point.y - $0.center.y) < Self.step / 2 && point.x >= Self.labelRight - Self.labelWidth && point.x <= Self.spineWidth + 6 }) {
            return .turn(turn.index)
        }
        return nil
    }
}

/// "What happened, when, and what it touched": the Summary's map. A click on a
/// turn reads it in the Transcript; a click on a file or a service lights the
/// turns that touched it and opens the drawer on it.
struct ArcsMap: View {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var model: SessionModel
    var layout: ArcsLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WHAT HAPPENED, WHEN, AND WHAT IT TOUCHED").font(.caps).tracking(0.9).foregroundStyle(palette.muted)
            GeometryReader { geo in
                let scale = min(1, geo.size.width / layout.bounds.width)
                Canvas { context, _ in
                    context.scaleBy(x: scale, y: scale)
                    context.translateBy(x: -layout.bounds.minX, y: -layout.bounds.minY)
                    draw(&context)
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { tap in
                    let point = CGPoint(x: tap.location.x / scale + layout.bounds.minX, y: tap.location.y / scale + layout.bounds.minY)
                    click(layout.hit(at: point))
                })
            }
            .aspectRatio(layout.bounds.width / layout.bounds.height, contentMode: .fit)
            .frame(maxWidth: layout.bounds.width)
            Text("Turns down the spine, what the agent touched on the right: thick strands are writes, thin are reads. Dashed loops are background commands coming back; amber pills are subagents. Click a turn to read it, a file or a service to see where it came up.")
                .font(.system(size: 11.5)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func click(_ key: NodeKey?) {
        switch key {
        case .turn(let n): window.reveal(.turn(n), in: model)
        case .subagent(let id):
            // A subagent is read on the Canvas, where its strand is.
            window.sessionView = .canvas
            window.select(.subagent(id), in: model)
        case .some(let key): window.select(window.selection == key ? nil : key, in: model, scroll: false)
        case nil: if window.selection != nil { window.selection = nil }
        }
    }

    private func draw(_ context: inout GraphicsContext) {
        let selectedHub = layout.hubs.firstIndex { !$0.subagent && $0.key == window.selection }
        let related = selectedHub.map { Set(layout.hubs[$0].turns.keys) }

        // The spine.
        for (above, below) in zip(layout.turns, layout.turns.dropFirst()) {
            var path = Path()
            path.move(to: CGPoint(x: above.center.x, y: above.center.y + above.size / 2))
            path.addLine(to: CGPoint(x: below.center.x, y: below.center.y - below.size / 2))
            context.stroke(path, with: .color(palette.line2), lineWidth: 1.5)
        }
        for arc in layout.arcs {
            let hub = layout.hubs[arc.hub]
            var path = Path()
            let mid = (arc.from.x + arc.to.x) / 2
            path.move(to: arc.from)
            path.addCurve(to: arc.to, control1: CGPoint(x: mid, y: arc.from.y), control2: CGPoint(x: mid, y: arc.to.y))
            let lit = selectedHub == arc.hub
            let color = lit ? palette.accent : hub.outside ? palette.plug : palette.ink2
            let opacity = lit ? 0.95 : selectedHub != nil ? 0.08 : arc.write ? 0.7 : 0.28
            context.stroke(path, with: .color(color.opacity(opacity)), lineWidth: arc.width)
        }
        for loop in layout.loops {
            var path = Path()
            path.move(to: loop.from)
            path.addCurve(to: loop.to, control1: CGPoint(x: -loop.bulge, y: loop.from.y), control2: CGPoint(x: -loop.bulge, y: loop.to.y))
            context.stroke(path, with: .color(palette.ctx), style: StrokeStyle(lineWidth: 1.2, dash: [3, 4]))
        }
        for turn in layout.turns {
            let rect = turn.rect
            let shape = Path(roundedRect: rect, cornerRadius: turn.human ? 10 : 7)
            let faded = related.map { !$0.contains(turn.index) } ?? false
            context.opacity = faded ? 0.35 : 1
            context.fill(shape, with: .color(turn.human ? palette.panel : palette.panel2))
            context.stroke(shape, with: .color(related?.contains(turn.index) == true ? palette.accent : palette.line2),
                           style: StrokeStyle(lineWidth: related?.contains(turn.index) == true ? 2 : 1, dash: turn.human ? [] : [3, 3]))
            context.draw(Text("\(turn.index)").font(.display(turn.human ? 13 : 10)).foregroundStyle(turn.human ? palette.ink : palette.muted), at: turn.center)
            if turn.human {
                // How many actions the turn took, at its corner.
                let badge = context.resolve(Text("\(turn.actions)").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white))
                let size = badge.measure(in: CGSize(width: 60, height: 20))
                let pill = CGRect(x: rect.maxX - (size.width + 8) + 5, y: rect.maxY - 9, width: size.width + 8, height: 14)
                context.fill(Path(roundedRect: pill, cornerRadius: 7), with: .color(palette.accent))
                context.draw(badge, at: CGPoint(x: pill.midX, y: pill.midY))
            }
            if turn.failed {
                context.fill(Path(ellipseIn: CGRect(x: rect.maxX - 5, y: rect.minY - 4, width: 9, height: 9)), with: .color(palette.err))
            }
            // The time ends at the label's right edge; the words take what is left of the width before it.
            let time = context.resolve(Text(turn.time).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(palette.muted))
            let timeWidth = time.measure(in: CGSize(width: 200, height: 30)).width
            context.draw(time, at: CGPoint(x: ArcsLayout.labelRight, y: turn.center.y), anchor: .trailing)
            let label = context.resolve(Text(turn.label).font(.system(size: turn.human ? 12 : 11)).foregroundStyle(turn.human ? palette.ink : palette.muted))
            let room = ArcsLayout.labelWidth - timeWidth - 8
            let width = min(room, label.measure(in: CGSize(width: 2000, height: 30)).width)
            context.draw(label, in: CGRect(x: ArcsLayout.labelRight - timeWidth - 8 - width, y: turn.center.y - 9, width: width + 1, height: 18))
            context.opacity = 1
        }
        for cut in layout.cuts {
            let text = context.resolve(Text(cut.text).font(.system(size: 11)).foregroundStyle(palette.warn))
            let size = text.measure(in: CGSize(width: 400, height: 20))
            let pill = CGRect(x: cut.center.x - size.width / 2 - 9, y: cut.center.y - 9, width: size.width + 18, height: 18)
            context.fill(Path(roundedRect: pill, cornerRadius: 9), with: .color(palette.bg))
            context.stroke(Path(roundedRect: pill, cornerRadius: 9), with: .color(palette.warn), lineWidth: 1)
            context.draw(text, at: cut.center)
        }
        for (i, hub) in layout.hubs.enumerated() {
            let hot = hub.key == window.selection
            let shape = Path(roundedRect: hub.rect, cornerRadius: 7)
            context.opacity = selectedHub != nil && selectedHub != i && !hub.subagent ? 0.4 : 1
            context.fill(shape, with: .color(palette.panel))
            context.stroke(shape, with: .color(hot ? palette.accent : hub.subagent ? palette.warn.opacity(0.6) : palette.line2), lineWidth: hot ? 2 : 1)
            let tint = hub.subagent ? palette.warn : hub.outside ? palette.plug : palette.ink2
            var glyph = context.resolve(Image(systemName: hub.subagent ? "person.2" : hub.outside ? "globe" : "doc"))
            glyph.shading = .color(tint)
            // Fitted, not stretched: glyphs are not square.
            let fit = min(12 / glyph.size.width, 11 / glyph.size.height)
            context.draw(glyph, in: CGRect(x: hub.rect.minX + 14 - glyph.size.width * fit / 2, y: hub.rect.midY - glyph.size.height * fit / 2,
                                           width: glyph.size.width * fit, height: glyph.size.height * fit))
            let name = String(hub.label.prefix(hub.subagent ? 44 : 36))
            context.draw(Text(name).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(palette.ink),
                         at: CGPoint(x: hub.rect.minX + 25, y: hub.rect.midY), anchor: .leading)
            context.draw(Text("\(hub.count)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(palette.muted),
                         at: CGPoint(x: hub.rect.maxX - 8, y: hub.rect.midY), anchor: .trailing)
            context.opacity = 1
        }
    }
}
