import AppKit
import SkitKit
import SwiftUI

/// The Score, drawn: `ScoreLayout` says what is where; this paints the staves
/// under the camera and, over them, what stays put: the ruler with a pill per
/// turn and how far into the session each stretch is, and the rows' names.
final class ScoreCanvasNSView: CanvasNSView {
    var layout: ScoreLayout? { didSet { needsDisplay = true } }

    override var worldBounds: CGRect? { layout?.bounds }
    /// A bar is often too narrow for its words, however close: the pointer always says what it is on.
    override var tipsWhenNear: Bool { true }

    private var offsets: [String: LaidText] = [:]

    // MARK: The staves

    override func drawWorld(_ cg: CGContext, visible: CGRect, detail: Camera.Detail) {
        guard let layout else { return }
        let scale = camera.scale

        // Idle gaps: hatched bands with how long nothing happened. Every band's
        // lines go into one path: a clip and a stroke for each cost a third of the frame.
        let bands = layout.bands.filter { $0.rect.intersects(visible) }
        if !bands.isEmpty {
            cg.setFillColor(colors.bg)
            cg.setAlpha(0.55)
            cg.fill(bands.map(\.rect))
            cg.setAlpha(1)
            cg.setStrokeColor(colors.line2)
            cg.setLineWidth(1 / scale)
            if scale >= 0.22 {
                for band in bands {
                    // Diagonals rising to the right, cut to the band's sides.
                    let r = band.rect
                    var offset = -r.height
                    while offset < r.width {
                        let from = max(0, offset), to = min(r.width, offset + r.height)
                        cg.move(to: CGPoint(x: r.minX + from, y: r.maxY - (from - offset)))
                        cg.addLine(to: CGPoint(x: r.minX + to, y: r.maxY - (to - offset)))
                        offset += 12
                    }
                }
                cg.strokePath()
            }
            for band in bands {
                cg.move(to: CGPoint(x: band.rect.minX, y: band.rect.minY))
                cg.addLine(to: CGPoint(x: band.rect.minX, y: band.rect.maxY))
                cg.move(to: CGPoint(x: band.rect.maxX, y: band.rect.minY))
                cg.addLine(to: CGPoint(x: band.rect.maxX, y: band.rect.maxY))
            }
            // From far away a dash is less than a pixel, and costly for nothing: the sides are plain lines.
            if scale >= 0.3 { cg.setLineDash(phase: 0, lengths: [4, 4]) }
            cg.strokePath()
            cg.setLineDash(phase: 0, lengths: [])
            if detail != .far {
                for band in bands where !band.label.isEmpty {
                    let width = band.label.width + 8
                    let pill = CGRect(x: band.rect.midX - width / 2, y: band.rect.minY + 4, width: width, height: 15)
                    cg.addPath(CGPath(roundedRect: pill, cornerWidth: 4, cornerHeight: 4, transform: nil))
                    cg.setFillColor(colors.bg)
                    cg.fillPath()
                    cg.setFillColor(colors.muted)
                    band.label.draw(cg, x: pill.minX + 4, y: pill.minY + (15 - band.label.lineHeight) / 2)
                }
            }
        }

        // A rule where each turn began, through every row.
        cg.setStrokeColor(colors.line2)
        cg.setLineWidth(1 / scale)
        if scale >= 0.3 { cg.setLineDash(phase: 0, lengths: [2, 5]) } else { cg.setAlpha(0.5) }
        for turn in layout.turns where turn.x >= visible.minX && turn.x <= visible.maxX {
            cg.move(to: CGPoint(x: turn.x, y: 0))
            cg.addLine(to: CGPoint(x: turn.x, y: layout.height))
        }
        cg.strokePath()
        cg.setLineDash(phase: 0, lengths: [])
        cg.setAlpha(1)

        if detail != .far {
            cg.setStrokeColor(colors.line2)
            cg.setLineWidth(1)
            for line in layout.fileLines where line.to.x >= visible.minX && line.from.x <= visible.maxX {
                cg.move(to: line.from)
                cg.addLine(to: line.to)
            }
            cg.strokePath()
        }
        if scale >= 0.2 {
            for edge in layout.edges where edge.bounds.intersects(visible) { draw(edge, cg) }
        }

        let dimming = !matches.isEmpty
        for node in layout.nodes where node.rect.intersects(visible) && shows(node.kind, detail) {
            let plain = node.kind == .turn || { if case .touch = node.kind { true } else { false } }()
            let matched = matches.contains(node.key)
            let dim = dimming && !plain && !matched && !(node.parent.map(matches.contains) ?? false)
            if dim { beginDimmed(cg) }
            draw(node, cg, detail)
            if dim { endDimmed(cg) }
            if matched, !plain { ring(node.rect, cg, colors.warn, width: 2, radius: 5) }
        }
    }

    /// What is drawn at a distance: far away a turn is one bar; closer, its actions and their calls.
    private func shows(_ kind: ScoreLayout.Kind, _ detail: Camera.Detail) -> Bool {
        switch kind {
        case .turn: detail == .far
        case .action, .tool, .step, .touch: detail != .far
        case .prompt, .strand, .task: true
        }
    }

    private func draw(_ node: ScoreLayout.Node, _ cg: CGContext, _ detail: Camera.Detail) {
        let r = node.rect
        switch node.kind {
        case .prompt(let human):
            card(r, cg, fill: human ? colors.panel : colors.panel2, stroke: human ? colors.line : colors.line2, radius: 8, dashed: !human, shadow: human && detail == .near)
            badge(node.symbol, colors.color(node.tint), at: CGPoint(x: r.minX + 5, y: r.minY + 5), cg, detail: detail)
            if detail != .far, !node.text.isEmpty {
                cg.setFillColor(colors.ink)
                node.text.draw(cg, x: r.minX + 27, y: r.minY + (r.height - node.text.lineHeight) / 2)
            }
            marks(node.key, r, cg)

        case .turn:
            // From far away the bars are a few points tall: they need their colour.
            fill(r, cg, colors.accent, alpha: camera.scale < 0.22 ? 0.75 : 0.22, radius: 5)
            stroke(r, cg, colors.accent, alpha: 0.5, radius: 5)
            if camera.scale >= 0.22, !node.text.isEmpty {
                cg.setFillColor(colors.ink)
                node.text.draw(cg, x: r.minX + 6, y: r.minY + (r.height - node.text.lineHeight) / 2)
            }
            marks(node.key, r, cg, radius: 5)

        case .action(let working, let running, let said):
            // The bar: the model's part solid, its tools' part light, the wait after it spoke empty.
            let shape = CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil)
            cg.saveGState()
            cg.addPath(shape)
            cg.clip()
            cg.setFillColor(said ? colors.panel : colors.accent)
            cg.setAlpha(said ? 1 : 0.14)
            cg.fill(r)
            let head = CGRect(x: r.minX, y: r.minY, width: working, height: r.height)
            cg.setFillColor(said ? colors.ink : colors.accent)
            cg.setAlpha(said ? 0.85 : 0.8)
            cg.fill(head)
            if running > 0 {
                cg.setFillColor(colors.tool)
                cg.setAlpha(0.38)
                cg.fill(CGRect(x: head.maxX, y: r.minY, width: running, height: r.height))
            }
            cg.setAlpha(1)
            if detail == .near, r.width >= 44 {
                let box = CGRect(x: r.minX + 4, y: r.minY + 4, width: 14, height: 14)
                cg.addPath(CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4, transform: nil))
                cg.setFillColor(colors.color(node.tint))
                cg.fillPath()
                symbol(node.symbol, colors.panel, in: box.insetBy(dx: 2.5, dy: 2.5))
                if !node.text.isEmpty {
                    // Over the solid part the words are the panel's colour, over the rest the ink's.
                    // Most labels are wholly on one side: only one that straddles the edge is drawn twice.
                    let at = CGPoint(x: r.minX + 23, y: r.minY + (r.height - node.text.lineHeight) / 2)
                    let light = said ? colors.bg : colors.panel
                    if head.maxX <= at.x {
                        cg.setFillColor(colors.ink)
                        node.text.draw(cg, x: at.x, y: at.y)
                    } else if head.maxX >= at.x + node.text.width {
                        cg.setFillColor(light)
                        node.text.draw(cg, x: at.x, y: at.y)
                    } else {
                        cg.saveGState()
                        cg.clip(to: head)
                        cg.setFillColor(light)
                        node.text.draw(cg, x: at.x, y: at.y)
                        cg.restoreGState()
                        cg.saveGState()
                        cg.clip(to: CGRect(x: head.maxX, y: r.minY, width: max(0, r.maxX - head.maxX), height: r.height))
                        cg.setFillColor(colors.ink)
                        node.text.draw(cg, x: at.x, y: at.y)
                        cg.restoreGState()
                    }
                }
            }
            cg.restoreGState()
            stroke(r, cg, said ? colors.line2 : colors.accent, alpha: said ? 1 : 0.4, radius: 5)
            marks(node.key, r, cg, radius: 5)

        case .tool(let failed, let async):
            let tint = colors.color(node.tint)
            fill(r, cg, tint, alpha: async ? 0.55 : 0.85, radius: 3)
            if detail == .near, !node.text.isEmpty {
                cg.setFillColor(colors.panel)
                node.text.draw(cg, x: r.minX + 4, y: r.minY + (r.height - node.text.lineHeight) / 2)
            }
            if failed || async {
                cg.addPath(CGPath(roundedRect: r.insetBy(dx: -1.75, dy: -1.75), cornerWidth: 4.5, cornerHeight: 4.5, transform: nil))
                cg.setStrokeColor(failed ? colors.err : tint)
                cg.setLineWidth(1.5)
                if !failed { cg.setLineDash(phase: 0, lengths: [3, 2.5]) }
                cg.strokePath()
                cg.setLineDash(phase: 0, lengths: [])
            }
            marks(node.key, r, cg, radius: 3)

        case .strand:
            card(r, cg, fill: colors.strandFill, stroke: colors.strandStroke, radius: 8, shadow: false)
            if node.text.isEmpty {
                symbol(node.symbol, colors.warn, in: CGRect(x: r.midX - 8, y: r.minY + 6, width: 16, height: 14))
            } else {
                symbol(node.symbol, colors.warn, in: CGRect(x: r.minX + 7, y: r.minY + 6, width: 15, height: 13))
                if detail != .far {
                    cg.setFillColor(colors.ink)
                    node.text.draw(cg, x: r.minX + 28, y: r.minY + 5)
                }
            }
            marks(node.key, r, cg)

        case .step(let hand):
            fill(r, cg, hand ? colors.ink : colors.warn, alpha: 0.8, radius: 3)
            marks(node.key, r, cg, radius: 3)

        case .task:
            let shape = CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
            cg.addPath(shape)
            cg.setFillColor(colors.line)
            cg.fillPath()
            cg.addPath(shape)
            cg.setStrokeColor(colors.ctx)
            cg.setLineWidth(1.5)
            cg.setLineDash(phase: 0, lengths: [4, 3])
            cg.strokePath()
            cg.setLineDash(phase: 0, lengths: [])
            if detail != .far {
                symbol(node.symbol, colors.ctx, in: CGRect(x: r.minX + 6, y: r.minY + 3, width: 10, height: 10))
                cg.setFillColor(colors.ink2)
                node.text.draw(cg, x: r.minX + 20, y: r.minY + (r.height - node.text.lineHeight) / 2)
            }
            marks(node.key, r, cg, radius: r.height / 2)

        case .touch(let write, let tool):
            // Lit when the file is selected, or the call that touched it.
            let hot = selection == node.key || selection == .tool(tool)
            let shape = CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil)
            cg.addPath(shape)
            cg.setFillColor(write ? (hot ? colors.accent : colors.ink2) : colors.panel)
            cg.fillPath()
            cg.addPath(shape)
            cg.setStrokeColor(hot ? colors.accent : colors.ink2)
            cg.setLineWidth(hot ? 2 : 1.5)
            cg.strokePath()
        }
    }

    private func fill(_ rect: CGRect, _ cg: CGContext, _ color: CGColor, alpha: CGFloat, radius: CGFloat) {
        cg.addPath(CGPath(roundedRect: rect, cornerWidth: min(radius, rect.width / 2), cornerHeight: min(radius, rect.height / 2), transform: nil))
        cg.setFillColor(color)
        cg.setAlpha(alpha)
        cg.fillPath()
        cg.setAlpha(1)
    }

    private func stroke(_ rect: CGRect, _ cg: CGContext, _ color: CGColor, alpha: CGFloat, radius: CGFloat) {
        cg.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: min(radius, rect.width / 2), cornerHeight: min(radius, rect.height / 2), transform: nil))
        cg.setStrokeColor(color)
        cg.setAlpha(alpha)
        cg.setLineWidth(1)
        cg.strokePath()
        cg.setAlpha(1)
    }

    // MARK: What stays put

    override func drawOverlay(_ cg: CGContext) {
        guard let layout else { return }
        let scale = camera.scale
        // The ruler: a pill per turn, and under them how far into the session the canvas is.
        // The fades are a few steps of the background, not gradients: a gradient this size cost a fifth of the frame.
        fade(cg, steps: [(0, 30, 0.92), (30, 38, 0.6), (38, SC.ruler, 0.28)]) { CGRect(x: 0, y: $0, width: bounds.width, height: $1 - $0) }
        var next = -camera.x / scale
        var last = ""
        for knot in layout.axis.knots where knot.x >= next {
            let at = camera.x + knot.x * scale
            if at > bounds.width { break }
            let words = ScoreLayout.offset(knot.time - layout.start.timeIntervalSinceReferenceDate)
            next = knot.x + 140 / scale
            if words == last { continue }
            last = words
            let text = offset(words)
            cg.setFillColor(colors.muted)
            text.draw(cg, x: at - text.width / 2, y: 27)
        }
        var lastPill = -CGFloat.greatestFiniteMagnitude
        for turn in layout.turns {
            let at = camera.x + turn.x * scale
            guard at > -40, at < bounds.width + 40, at - lastPill >= 34 else { continue }
            lastPill = at
            let width = turn.label.width + 14
            let pill = CGRect(x: at - width / 2, y: 4, width: width, height: 18)
            let shape = CGPath(roundedRect: pill, cornerWidth: 9, cornerHeight: 9, transform: nil)
            cg.addPath(shape)
            cg.setFillColor(colors.bg)
            cg.fillPath()
            cg.addPath(shape)
            cg.setStrokeColor(selection == .turn(turn.turn) ? colors.accent : colors.line2)
            cg.setLineWidth(selection == .turn(turn.turn) ? 2 : 1)
            cg.strokePath()
            cg.setFillColor(colors.ink)
            turn.label.draw(cg, x: pill.minX + 7, y: pill.minY + (18 - turn.label.lineHeight) / 2)
        }

        // The rows' names, over a fade so a bar passing under them does not fight the words.
        fade(cg, steps: [(0, 84, 0.94), (84, 96, 0.7), (96, 108, 0.42), (108, SC.gutter, 0.18)]) { CGRect(x: $0, y: 0, width: $1 - $0, height: bounds.height) }
        var lastRow = -CGFloat.greatestFiniteMagnitude
        for row in layout.rows where !row.file || scale >= 0.55 {
            let middle = camera.y + row.y * scale
            // From far away the rows are closer than their names are tall: the first of each cluster is written.
            guard middle > SC.ruler - 6, middle < bounds.height + 10, middle - lastRow >= 13 else { continue }
            lastRow = middle
            var x: CGFloat = 12
            if row.file {
                symbol("doc", colors.muted, in: CGRect(x: x, y: middle - 6, width: 10, height: 12))
                x += 15
            }
            cg.setFillColor(colors.muted)
            row.name.draw(cg, x: x, y: middle - row.name.lineHeight / 2)
            if !row.count.isEmpty {
                cg.setFillColor(colors.ink2)
                row.count.draw(cg, x: x + row.name.width + 6, y: middle - row.count.lineHeight / 2)
            }
        }
    }

    private func fade(_ cg: CGContext, steps: [(from: CGFloat, to: CGFloat, alpha: CGFloat)], rect: (CGFloat, CGFloat) -> CGRect) {
        cg.setFillColor(colors.bg)
        for step in steps {
            cg.setAlpha(step.alpha)
            cg.fill(rect(step.from, step.to))
        }
        cg.setAlpha(1)
    }

    private func offset(_ words: String) -> LaidText {
        if let made = offsets[words] { return made }
        if offsets.count > 400 { offsets.removeAll() }
        let made = LaidText(words, font: CanvasFont.mono, width: 90)
        offsets[words] = made
        return made
    }

    // MARK: What is where

    override func hit(at point: CGPoint) -> CanvasHit? {
        guard let layout else { return nil }
        let detail = camera.detail
        // The last drawn is on top; small marks get a little more room than they take.
        for node in layout.nodes.reversed() where shows(node.kind, detail) {
            let reach: CGFloat = { if case .touch = node.kind { -3 } else { node.rect.width < 8 ? -2 : 0 } }()
            guard node.rect.insetBy(dx: reach, dy: reach).contains(point) else { continue }
            return CanvasHit(key: node.key, turn: nil, tip: node.tip)
        }
        return nil
    }
}
