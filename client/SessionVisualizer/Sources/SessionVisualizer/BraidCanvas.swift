import AppKit
import SkitKit
import SwiftUI

/// Where the canvas is looking: a point of the canvas `p` is drawn at
/// `p * scale + (x, y)` in the view.
nonisolated struct Camera: Equatable, Codable, Sendable {
    var x: CGFloat = 60
    var y: CGFloat = 40
    var scale: CGFloat = 0.8

    static let scales: ClosedRange<CGFloat> = 0.06...4

    /// How much is drawn of each node, by zoom (the mock's thresholds).
    enum Detail: Sendable { case far, mid, near }

    var detail: Detail { scale < 0.38 ? .far : scale < 0.62 ? .mid : .near }

    /// The part of the canvas a view of this size shows.
    func visible(in size: CGSize) -> CGRect {
        CGRect(x: -x / scale, y: -y / scale, width: size.width / scale, height: size.height / scale)
    }

    /// Zooms by `factor` keeping the canvas point under `point` (in the view) where it is.
    mutating func zoom(by factor: CGFloat, at point: CGPoint) {
        let next = min(Self.scales.upperBound, max(Self.scales.lowerBound, scale * factor))
        x = point.x - (point.x - x) * (next / scale)
        y = point.y - (point.y - y) * (next / scale)
        scale = next
    }

    /// The canvas as wide as the view, from its top.
    mutating func fitWidth(_ bounds: CGRect, in size: CGSize, pad: CGFloat = 40) {
        guard bounds.width > 0, size.width > pad * 2 else { return }
        scale = min(1.2, max(Self.scales.lowerBound, (size.width - pad * 2) / bounds.width))
        x = pad - bounds.minX * scale
        y = 40 - bounds.minY * scale
    }

    /// The whole canvas in the view.
    mutating func fitAll(_ bounds: CGRect, in size: CGSize, pad: CGFloat = 40) {
        guard bounds.width > 0, bounds.height > 0, size.width > pad * 2, size.height > pad * 2 else { return }
        scale = min(Self.scales.upperBound, max(Self.scales.lowerBound, min((size.width - pad * 2) / bounds.width, (size.height - pad * 2) / bounds.height)))
        x = (size.width - bounds.width * scale) / 2 - bounds.minX * scale
        y = (size.height - bounds.height * scale) / 2 - bounds.minY * scale
    }

    /// Brings `rect` to the middle of the view's height. Sideways the whole
    /// canvas (`bounds`) stays in view when it fits, so a prompt at the left
    /// edge does not push the chain off the right; a camera too far out to
    /// read is brought in.
    mutating func center(on rect: CGRect, in size: CGSize, bounds: CGRect, readable: Bool = true) {
        if readable, scale < 0.6 { scale = 0.8 }
        if bounds.width * scale <= size.width {
            x = (size.width - bounds.width * scale) / 2 - bounds.minX * scale
        } else {
            // As much of the canvas as fits, with the node inside it.
            let centred = size.width / 2 - rect.midX * scale
            x = min(40 - bounds.minX * scale, max(size.width - 40 - bounds.maxX * scale, centred))
        }
        // A tall node (a long strand) shows its top, not its middle.
        y = size.height / 2 - min(rect.midY, rect.minY + size.height / scale * 0.3) * scale
    }

    /// Keeps at least `keep` points of the canvas in the view: a pan or a
    /// collapse cannot leave the window looking at nothing.
    mutating func clamp(to bounds: CGRect, in size: CGSize, keep: CGFloat = 120) {
        guard bounds.width > 0, size.width > keep * 2, size.height > keep * 2 else { return }
        x = min(max(x, keep - bounds.maxX * scale), size.width - keep - bounds.minX * scale)
        y = min(max(y, keep - bounds.maxY * scale), size.height - keep - bounds.minY * scale)
    }

    /// Whether the start of `rect` (all of it when it is small) is in a view of this size.
    func shows(_ rect: CGRect, in size: CGSize) -> Bool {
        let visible = visible(in: size)
        let start = CGRect(x: rect.minX, y: rect.minY, width: min(rect.width, visible.width * 0.9), height: min(rect.height, visible.height * 0.6))
        return visible.insetBy(dx: 8 / scale, dy: 8 / scale).contains(start)
    }
}

/// The palette as Core Graphics colours, with the blends the cards use.
struct CanvasColors {
    var bg, panel, panel2, ink, ink2, muted, muted2, line, line2: CGColor
    var accent, warn, err, tool, plug, ctx: CGColor
    var stepFill, strandFill, strandStroke, shadow: CGColor
    var dark: Bool

    init(_ p: Palette) {
        func cg(_ color: Color) -> CGColor { NSColor(color).usingColorSpace(.sRGB)?.cgColor ?? NSColor(color).cgColor }
        func blend(_ a: Color, _ b: Color, _ fraction: CGFloat) -> CGColor {
            (NSColor(a).usingColorSpace(.sRGB)?.blended(withFraction: fraction, of: NSColor(b).usingColorSpace(.sRGB) ?? .gray) ?? NSColor(a)).cgColor
        }
        bg = cg(p.bg); panel = cg(p.panel); panel2 = cg(p.panel2)
        ink = cg(p.ink); ink2 = cg(p.ink2); muted = cg(p.muted); muted2 = cg(p.muted2)
        line = cg(p.line); line2 = cg(p.line2)
        accent = cg(p.accent); warn = cg(p.warn); err = cg(p.err); tool = cg(p.tool); plug = cg(p.plug); ctx = cg(p.ctx)
        stepFill = blend(p.panel, p.accent, 0.10)
        strandFill = blend(p.panel, p.warn, 0.12)
        strandStroke = cg(p.warn.opacity(0.4))
        shadow = cg(p.shadow.opacity(0.35))
        dark = (NSColor(p.bg).usingColorSpace(.sRGB)?.brightnessComponent ?? 1) < 0.5
    }

    func color(_ tint: Tint) -> CGColor {
        switch tint {
        case .ink: ink
        case .ink2: ink2
        case .muted: muted
        case .accent: accent
        case .tool: tool
        case .plug: plug
        case .warn: warn
        case .ctx: ctx
        case .err: err
        }
    }
}

/// What is under a point of the canvas.
struct CanvasHit: Equatable {
    var key: NodeKey
    /// The turn it belongs to, when it is a card that opens or stands for one.
    var turn: Int?
    var tip: String
}

/// The Braid, drawn. One view paints every visible node with Core Graphics and
/// Core Text under the camera's transform: text is sharp at every zoom, and a
/// frame costs only what is on screen. It takes scroll, pinch, drag, click,
/// hover and the context menu itself, and tells its owner what happened.
final class BraidCanvasNSView: NSView {
    var layout: CanvasLayout? { didSet { needsDisplay = true } }
    var content: BraidContent? { didSet { needsDisplay = true } }
    var colors = CanvasColors(.light) { didSet { symbols.removeAll(); needsDisplay = true } }
    var camera = Camera() { didSet { if camera != oldValue { needsDisplay = true } } }
    var selection: NodeKey? { didSet { if selection != oldValue { needsDisplay = true } } }
    var focus: NodeKey? { didSet { if focus != oldValue { needsDisplay = true } } }
    /// The nodes that match the find query; while there are any, the others are dimmed.
    var matches: Set<NodeKey> = [] { didSet { if matches != oldValue { needsDisplay = true } } }
    var backgroundStyle = "dots" { didSet { needsDisplay = true } }

    var onCamera: (Camera) -> Void = { _ in }
    var onSelect: (CanvasHit?) -> Void = { _ in }
    var onDoubleClick: (CanvasHit) -> Void = { _ in }
    var onSize: (CGSize) -> Void = { _ in }
    /// Returns true when it used the key.
    var onKey: (NSEvent) -> Bool = { _ in false }
    var menuItems: (CanvasHit) -> [(title: String, action: () -> Void)] = { _ in [] }

    private var symbols: [String: NSImage] = [:]
    private var dragStart: (point: CGPoint, camera: Camera)?
    private var dragged = false
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.setFillColor(colors.bg)
        cg.fill(bounds)
        guard let layout, let content else { return }
        let scale = camera.scale
        let visible = camera.visible(in: bounds.size)
        drawBackground(cg, visible: visible)

        cg.saveGState()
        cg.translateBy(x: camera.x, y: camera.y)
        cg.scaleBy(x: scale, y: scale)
        // Core Text draws upwards; the view counts downwards.
        cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let detail = camera.detail

        cg.setFillColor(colors.line)
        for rule in layout.separators where rule.y >= visible.minY && rule.y <= visible.maxY {
            cg.fill(CGRect(x: 0, y: rule.y, width: rule.width, height: 1 / scale))
        }
        for edge in layout.edges where edge.bounds.intersects(visible) { draw(edge, cg) }
        if scale >= 0.16 {
            for label in layout.labels where label.origin.y >= visible.minY - 30 && label.origin.y <= visible.maxY {
                let turn = content.turns[label.turn]
                cg.setFillColor(colors.ink)
                turn.name.draw(cg, x: label.origin.x, y: label.origin.y)
                if detail != .far {
                    cg.setFillColor(colors.muted)
                    turn.facts.draw(cg, x: label.origin.x + turn.name.width + 6, y: label.origin.y + 1)
                }
            }
        }
        if detail == .near {
            for note in layout.notes where note.rect.intersects(visible) { draw(note, cg) }
        }
        if scale >= 0.2 {
            for pill in layout.pills where pill.rect.intersects(visible) { draw(pill, cg) }
        }
        let dimming = !matches.isEmpty
        for node in layout.nodes(in: visible) where node.rect.intersects(visible) {
            let dim = dimming && !isMatch(node)
            if dim { cg.setAlpha(0.3) }
            switch node.kind {
            case .prompt(let turn): draw(prompt: content.turns[turn].card, node, cg, detail)
            case .step(let turn, let step): draw(step: content.turns[turn].steps[step], node, cg, detail)
            case .strand(let agent): if let strand = content.strands[agent] { draw(strand: strand, node, cg, detail) }
            case .summary(let turn): draw(summary: content.turns[turn].summary, node, cg, detail)
            }
            if dim { cg.setAlpha(1) }
            if dimming, !dim { ring(node.rect, cg, colors.warn, width: 2, radius: 8) }
        }
        cg.restoreGState()
    }

    private func isMatch(_ node: CanvasLayout.Node) -> Bool {
        if matches.contains(node.key) { return true }
        // A summary stands for its turn's actions.
        if case .summary(let turn) = node.kind, let steps = content?.turns[turn].steps { return steps.contains { matches.contains(.action($0.index)) } }
        return false
    }

    /// Dots, lines or a grid behind the canvas: they move and scale with it, and
    /// thin out before they would crowd.
    private func drawBackground(_ cg: CGContext, visible: CGRect) {
        guard backgroundStyle != "blank" else { return }
        var step: CGFloat = 24
        while step * camera.scale < 14 { step *= 2 }
        let spacing = step * camera.scale
        let startX = camera.x.truncatingRemainder(dividingBy: spacing), startY = camera.y.truncatingRemainder(dividingBy: spacing)
        var rects: [CGRect] = []
        switch backgroundStyle {
        case "lines", "grid":
            var y = startY
            while y < bounds.height { rects.append(CGRect(x: 0, y: y, width: bounds.width, height: 1)); y += spacing }
            if backgroundStyle == "grid" {
                var x = startX
                while x < bounds.width { rects.append(CGRect(x: x, y: 0, width: 1, height: bounds.height)); x += spacing }
            }
            cg.setFillColor(colors.line)
        default:
            var y = startY
            while y < bounds.height {
                var x = startX
                while x < bounds.width { rects.append(CGRect(x: x, y: y, width: 1.5, height: 1.5)); x += spacing }
                y += spacing
            }
            cg.setFillColor(colors.line2)
        }
        cg.fill(rects)
    }

    private func draw(_ edge: CanvasLayout.Edge, _ cg: CGContext) {
        let color: CGColor, dash: [CGFloat]
        switch edge.kind {
        case .chain: (color, dash) = (colors.accent, [])
        case .spawn: (color, dash) = (colors.warn, [])
        case .handback: (color, dash) = (colors.warn, [4, 4])
        case .launch: (color, dash) = (colors.ctx, [])
        case .thread, .pickup: (color, dash) = (colors.ctx, [3, 4])
        }
        cg.setStrokeColor(color)
        cg.setLineWidth(1.5)
        cg.setLineDash(phase: 0, lengths: dash)
        cg.setAlpha(edge.kind == .chain ? 0.8 : 1)
        cg.move(to: edge.from)
        if let c1 = edge.control1, let c2 = edge.control2 { cg.addCurve(to: edge.to, control1: c1, control2: c2) } else { cg.addLine(to: edge.to) }
        cg.strokePath()
        cg.setLineDash(phase: 0, lengths: [])
        cg.setFillColor(color)
        if edge.arrow {
            // The head points the way the line arrives.
            let back = edge.control2 ?? edge.from
            let angle = atan2(edge.to.y - back.y, edge.to.x - back.x)
            let size: CGFloat = 6
            cg.move(to: edge.to)
            cg.addLine(to: CGPoint(x: edge.to.x - size * cos(angle - 0.45), y: edge.to.y - size * sin(angle - 0.45)))
            cg.addLine(to: CGPoint(x: edge.to.x - size * cos(angle + 0.45), y: edge.to.y - size * sin(angle + 0.45)))
            cg.closePath()
            cg.fillPath()
        } else if edge.kind == .launch {
            cg.fillEllipse(in: CGRect(x: edge.to.x - 3, y: edge.to.y - 3, width: 6, height: 6))
        }
        cg.setAlpha(1)
    }

    private func draw(_ note: CanvasLayout.Note, _ cg: CGContext) {
        switch note.kind {
        case .result(let failed):
            cg.setFillColor(failed ? colors.err : colors.muted)
            note.text.draw(cg, x: note.rect.minX + 4, y: note.rect.minY)
        case .task:
            symbol("clock.arrow.circlepath", colors.ctx, in: CGRect(x: note.rect.minX, y: note.rect.minY + 2, width: 11, height: 11))
            cg.setFillColor(colors.ctx)
            note.text.draw(cg, x: note.rect.minX + 16, y: note.rect.minY)
        }
        if note.key != nil, note.key == selection { ring(note.rect.insetBy(dx: -3, dy: -1), cg, colors.accent, width: 1.5, radius: 5) }
    }

    private func draw(_ pill: CanvasLayout.Pill, _ cg: CGContext) {
        let rect = pill.rect
        let tint = pill.kind == .compaction ? colors.warn : colors.muted
        let path = CGPath(roundedRect: rect, cornerWidth: 9, cornerHeight: 9, transform: nil)
        cg.addPath(path)
        cg.setFillColor(colors.bg)
        cg.fillPath()
        cg.addPath(path)
        cg.setStrokeColor(pill.kind == .compaction ? colors.warn : colors.line2)
        cg.setLineWidth(pill.key != nil && pill.key == selection ? 2 : 1)
        cg.strokePath()
        var x = rect.minX + 9
        if pill.kind == .compaction {
            symbol("scissors", colors.warn, in: CGRect(x: x, y: rect.minY + 3.5, width: 11, height: 11))
            x += 16
        }
        cg.setFillColor(tint)
        pill.text.draw(cg, x: x, y: rect.minY + (18 - pill.text.lineHeight) / 2)
    }

    private func card(_ rect: CGRect, _ cg: CGContext, fill: CGColor, stroke: CGColor, radius: CGFloat = 8, dashed: Bool = false, shadow: Bool) {
        if shadow {
            // A soft step of shade under the card: a real blur costs more than the card.
            cg.addPath(CGPath(roundedRect: rect.offsetBy(dx: 0, dy: 2.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
            cg.setFillColor(colors.shadow)
            cg.setAlpha(0.35)
            cg.fillPath()
            cg.setAlpha(1)
        }
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        cg.addPath(path)
        cg.setFillColor(fill)
        cg.fillPath()
        cg.addPath(path)
        cg.setStrokeColor(stroke)
        cg.setLineWidth(1)
        if dashed { cg.setLineDash(phase: 0, lengths: [4, 3]) }
        cg.strokePath()
        if dashed { cg.setLineDash(phase: 0, lengths: []) }
    }

    private func ring(_ rect: CGRect, _ cg: CGContext, _ color: CGColor, width: CGFloat, radius: CGFloat, dashed: Bool = false) {
        cg.addPath(CGPath(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerWidth: radius + 1, cornerHeight: radius + 1, transform: nil))
        cg.setStrokeColor(color)
        cg.setLineWidth(max(width, width / camera.scale * 0.8))
        if dashed { cg.setLineDash(phase: 0, lengths: [5, 3]) }
        cg.strokePath()
        if dashed { cg.setLineDash(phase: 0, lengths: []) }
    }

    /// The selection's ring and the keyboard's dashed one.
    private func marks(_ key: NodeKey, _ rect: CGRect, _ cg: CGContext, radius: CGFloat = 8) {
        if selection == key { ring(rect, cg, colors.accent, width: 2, radius: radius) } else if focus == key { ring(rect, cg, colors.accent, width: 1.5, radius: radius, dashed: true) }
    }

    /// The square at the start of a card's header: its colour says what kind of step, its glyph which.
    private func badge(_ name: String, _ tint: CGColor, at origin: CGPoint, _ cg: CGContext, detail: Camera.Detail) {
        let box = CGRect(x: origin.x, y: origin.y, width: 16, height: 16)
        cg.addPath(CGPath(roundedRect: box, cornerWidth: 4.5, cornerHeight: 4.5, transform: nil))
        cg.setFillColor(tint)
        cg.fillPath()
        if detail != .far || camera.scale > 0.25 { symbol(name, colors.panel, in: box.insetBy(dx: 3, dy: 3)) }
    }

    private func draw(prompt card: PromptContent, _ node: CanvasLayout.Node, _ cg: CGContext, _ detail: Camera.Detail) {
        let r = node.rect
        if card.human {
            self.card(r, cg, fill: colors.panel, stroke: colors.line, shadow: detail == .near)
            badge("person.fill", colors.ink, at: CGPoint(x: r.minX + 11, y: r.minY + 9), cg, detail: detail)
            if camera.scale >= 0.22 {
                cg.setFillColor(colors.ink)
                card.who.draw(cg, x: r.minX + 34, y: r.minY + 9)
                cg.setFillColor(colors.muted)
                card.time.draw(cg, x: r.minX + 34 + card.who.width + 7, y: r.minY + 10)
                if detail != .far { card.right.draw(cg, x: r.maxX - 11 - card.right.width, y: r.minY + 11) }
            }
            if detail == .near {
                cg.setFillColor(colors.ink)
                card.text.draw(cg, x: r.minX + 11, y: r.minY + 30)
            }
        } else {
            self.card(r, cg, fill: colors.panel2, stroke: colors.line2, dashed: true, shadow: false)
            badge("clock.arrow.circlepath", colors.ctx, at: CGPoint(x: r.minX + 9, y: r.minY + 7), cg, detail: detail)
            if camera.scale >= 0.22 {
                cg.setFillColor(colors.ink)
                card.who.draw(cg, x: r.minX + 32, y: r.minY + 7)
                cg.setFillColor(colors.muted)
                card.time.draw(cg, x: r.minX + 32 + card.who.width + 7, y: r.minY + 8)
            }
            if detail == .near {
                cg.setFillColor(colors.ink2)
                card.text.draw(cg, x: r.minX + 9, y: r.minY + 27)
            }
        }
        marks(node.key, r, cg)
    }

    private func draw(step: StepContent, _ node: CanvasLayout.Node, _ cg: CGContext, _ detail: Camera.Detail) {
        let r = node.rect
        card(r, cg, fill: step.said ? colors.panel : colors.stepFill, stroke: step.failed ? colors.err : colors.line, shadow: detail == .near)
        badge(step.symbol, colors.color(step.tint), at: CGPoint(x: r.minX + 9, y: r.minY + 7), cg, detail: detail)
        if camera.scale >= 0.22 {
            let titleX = r.minX + 32
            cg.setFillColor(colors.ink)
            step.title.draw(cg, x: titleX, y: r.minY + 7)
            if detail != .far {
                cg.setFillColor(colors.ink2)
                step.subtitle.draw(cg, x: titleX + step.title.width + 6, y: r.minY + 7)
                var right = r.maxX - 9 - step.right.width
                cg.setFillColor(colors.muted2)
                step.right.draw(cg, x: right, y: r.minY + 9)
                for badge in step.badges.reversed() {
                    let width = badge.text.width + 10
                    right -= width + 6
                    let tint = colors.color(badge.tint)
                    cg.addPath(CGPath(roundedRect: CGRect(x: right, y: r.minY + 8, width: width, height: 14), cornerWidth: 7, cornerHeight: 7, transform: nil))
                    cg.setFillColor(tint)
                    cg.setAlpha(0.16)
                    cg.fillPath()
                    cg.setAlpha(1)
                    cg.setFillColor(tint)
                    badge.text.draw(cg, x: right + 5, y: r.minY + 9)
                }
                if step.thoughtFirst { symbol("brain", colors.muted, in: CGRect(x: right - 18, y: r.minY + 9, width: 12, height: 12)) }
            }
        }
        if detail == .near, !step.body.isEmpty {
            cg.setFillColor(step.bodyMuted ? colors.muted : colors.ink2)
            step.body.draw(cg, x: r.minX + 9, y: r.minY + 7 + 16 + 4)
        }
        if detail != .far {
            for (chip, rect) in zip(step.chips, step.chipRects(origin: r.origin)) { draw(chip, rect, cg, detail) }
        }
        marks(node.key, r, cg)
    }

    private func draw(_ chip: ChipContent, _ rect: CGRect, _ cg: CGContext, _ detail: Camera.Detail) {
        let path = CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
        cg.addPath(path)
        cg.setFillColor(colors.panel)
        cg.fillPath()
        cg.addPath(path)
        cg.setStrokeColor(chip.failed ? colors.err : colors.line2)
        cg.setLineWidth(1)
        if chip.async { cg.setLineDash(phase: 0, lengths: [3, 2.5]) }
        cg.strokePath()
        if chip.async { cg.setLineDash(phase: 0, lengths: []) }
        symbol(chip.symbol, colors.color(chip.tint), in: CGRect(x: rect.minX + 6, y: rect.minY + 5, width: 12, height: 12))
        cg.setFillColor(chip.failed ? colors.err : colors.ink)
        chip.name.draw(cg, x: rect.minX + 22, y: rect.minY + (rect.height - chip.name.lineHeight) / 2)
        if detail == .near {
            cg.setFillColor(colors.muted)
            chip.label.draw(cg, x: rect.minX + 22 + chip.name.width + 5, y: rect.minY + (rect.height - chip.label.lineHeight) / 2)
            chip.duration.draw(cg, x: rect.maxX - 8 - chip.duration.width, y: rect.minY + (rect.height - chip.duration.lineHeight) / 2)
        }
        if chip.async {
            cg.setFillColor(colors.color(chip.tint))
            cg.fillEllipse(in: CGRect(x: rect.maxX - 4, y: rect.midY - 4, width: 8, height: 8))
        }
        marks(.tool(chip.toolID), rect, cg, radius: rect.height / 2)
    }

    private func draw(strand: StrandContent, _ node: CanvasLayout.Node, _ cg: CGContext, _ detail: Camera.Detail) {
        let r = node.rect
        card(r, cg, fill: colors.strandFill, stroke: colors.strandStroke, radius: 12, shadow: false)
        symbol("person.2.fill", colors.warn, in: CGRect(x: r.minX + 9, y: r.minY + 9, width: 15, height: 13))
        if camera.scale >= 0.22 {
            cg.setFillColor(colors.ink)
            let title = Self.subagentTitle
            title.draw(cg, x: r.minX + 31, y: r.minY + 8)
            if detail != .far {
                cg.setFillColor(colors.muted)
                strand.model.draw(cg, x: r.minX + 31 + title.width + 7, y: r.minY + 9)
                strand.duration.draw(cg, x: r.maxX - 9 - strand.duration.width, y: r.minY + 10)
            }
        }
        if detail != .far {
            cg.setFillColor(colors.ink2)
            strand.description.draw(cg, x: r.minX + 9, y: r.minY + 8 + 16 + 3)
            // A long strand draws only the rows in view.
            let visible = camera.visible(in: bounds.size)
            for (step, rect) in zip(strand.steps, strand.stepRects(origin: r.origin)) where rect.maxY >= visible.minY && rect.minY <= visible.maxY {
                cg.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
                cg.setFillColor(colors.panel)
                cg.fillPath()
                cg.setFillColor(colors.muted2)
                Self.number(step.index).draw(cg, x: rect.minX + 6, y: rect.minY + 4)
                symbol(step.symbol, colors.color(step.tint), in: CGRect(x: rect.minX + 26, y: rect.minY + 4.5, width: 11, height: 11))
                cg.setFillColor(step.hand ? colors.warn : colors.ink2)
                step.title.draw(cg, x: rect.minX + 42, y: rect.minY + (rect.height - step.title.lineHeight) / 2)
                marks(.step(agent: strand.agentID, index: step.index), rect, cg, radius: 6)
            }
        }
        marks(node.key, r, cg, radius: 12)
    }

    private func draw(summary: SummaryContent, _ node: CanvasLayout.Node, _ cg: CGContext, _ detail: Camera.Detail) {
        let r = node.rect
        card(r, cg, fill: colors.panel, stroke: colors.line, shadow: detail == .near)
        var x = r.minX + 10
        for said in summary.dots {
            cg.setFillColor(said ? colors.ink : colors.accent)
            cg.setAlpha(said ? 1 : 0.7)
            cg.fillEllipse(in: CGRect(x: x, y: r.midY - 3.5, width: 7, height: 7))
            x += 10
        }
        cg.setAlpha(1)
        guard detail != .far else { return }
        x += 4
        if x + 60 < r.maxX {
            cg.setFillColor(colors.ink2)
            summary.text.draw(cg, x: x, y: r.minY + (r.height - summary.text.lineHeight) / 2)
            x += summary.text.width + 8
            if !summary.failed.isEmpty, x + summary.failed.width < r.maxX - 6 {
                cg.setFillColor(colors.err)
                summary.failed.draw(cg, x: x, y: r.minY + (r.height - summary.failed.lineHeight) / 2)
            }
        }
    }

    private static let subagentTitle = LaidText("Subagent", font: CanvasFont.title, width: 80)
    private static var numbers: [Int: LaidText] = [:]

    private static func number(_ n: Int) -> LaidText {
        if let made = numbers[n] { return made }
        let made = LaidText("\(n)", font: CanvasFont.mono, width: 30)
        numbers[n] = made
        return made
    }

    /// An SF Symbol in a colour, kept once made: a glyph is drawn many times a frame.
    private func symbol(_ name: String, _ color: CGColor, in rect: CGRect) {
        let key = name + "|" + (color.components?.map { String(format: "%.3f", $0) }.joined(separator: ",") ?? "")
        let image: NSImage
        if let made = symbols[key] {
            image = made
        } else {
            let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium).applying(.init(paletteColors: [NSColor(cgColor: color) ?? .labelColor]))
            image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) ?? NSImage()
            symbols[key] = image
        }
        guard image.size.width > 0 else { return }
        // Fit the glyph in the box without stretching it.
        let ratio = min(rect.width / image.size.width, rect.height / image.size.height)
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    // MARK: What is where

    private func canvasPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: (p.x - camera.x) / camera.scale, y: (p.y - camera.y) / camera.scale)
    }

    /// The node, chip, strand step, note or pill under a point of the canvas.
    func hit(at point: CGPoint) -> CanvasHit? {
        guard let layout, let content else { return nil }
        let probe = CGRect(x: point.x, y: point.y, width: 0.01, height: 0.01)
        for node in layout.nodes(in: probe).reversed() where node.rect.contains(point) {
            switch node.kind {
            case .prompt(let turn):
                return CanvasHit(key: node.key, turn: content.turns[turn].index, tip: content.turns[turn].card.tip)
            case .summary(let turn):
                return CanvasHit(key: node.key, turn: content.turns[turn].index, tip: "Turn \(content.turns[turn].index), collapsed. Double-click to show it.")
            case .step(let turn, let step):
                let step = content.turns[turn].steps[step]
                if camera.detail != .far, let i = step.chipRects(origin: node.rect.origin).firstIndex(where: { $0.contains(point) }) {
                    return CanvasHit(key: .tool(step.chips[i].toolID), turn: nil, tip: "")
                }
                return CanvasHit(key: node.key, turn: nil, tip: step.tip)
            case .strand(let agent):
                if camera.detail != .far, let strand = content.strands[agent], let i = strand.stepRects(origin: node.rect.origin).firstIndex(where: { $0.contains(point) }) {
                    return CanvasHit(key: .step(agent: agent, index: strand.steps[i].index), turn: nil, tip: "")
                }
                return CanvasHit(key: node.key, turn: nil, tip: "Subagent")
            }
        }
        if camera.detail == .near, let note = layout.notes.first(where: { $0.key != nil && $0.rect.contains(point) }), let key = note.key {
            return CanvasHit(key: key, turn: nil, tip: "")
        }
        if let pill = layout.pills.first(where: { $0.key != nil && $0.rect.contains(point) }), let key = pill.key {
            return CanvasHit(key: key, turn: nil, tip: "")
        }
        return nil
    }

    // MARK: Events

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onSize(newSize)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    private func move(_ change: (inout Camera) -> Void) {
        var next = camera
        change(&next)
        if let layout { next.clamp(to: layout.bounds, in: bounds.size) }
        camera = next
        onCamera(next)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            // ⌘ or ⌃ with the wheel zooms where the pointer is.
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
            move { $0.zoom(by: exp(delta * 0.01), at: point) }
        } else {
            let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            move { $0.x += event.scrollingDeltaX * k; $0.y += event.scrollingDeltaY * k }
        }
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        move { $0.zoom(by: 1 + event.magnification, at: point) }
    }

    override func smartMagnify(with event: NSEvent) {
        // A two-finger double tap: in to read, or back out to the width.
        let point = convert(event.locationInWindow, from: nil)
        move { $0.zoom(by: $0.scale < 0.75 ? 1 / $0.scale : 0.5 / $0.scale, at: point) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragStart = (convert(event.locationInWindow, from: nil), camera)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - dragStart.point.x, dy = point.y - dragStart.point.y
        if !dragged, hypot(dx, dy) > 3 {
            dragged = true
            NSCursor.closedHand.push()
        }
        if dragged { move { $0.x = dragStart.camera.x + dx; $0.y = dragStart.camera.y + dy } }
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        if dragged {
            NSCursor.pop()
            return
        }
        let found = hit(at: canvasPoint(event))
        if event.clickCount == 2, let found {
            onDoubleClick(found)
        } else if event.clickCount == 1 {
            onSelect(found)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let found = hit(at: canvasPoint(event))
        // Far out the cards carry no words: say what the pointer is on.
        let tip = camera.detail == .near ? nil : found.flatMap { $0.tip.isEmpty ? nil : $0.tip }
        if toolTip != tip { toolTip = tip }
        if found != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }

    override func keyDown(with event: NSEvent) {
        if !onKey(event) { super.keyDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let found = hit(at: canvasPoint(event)) else { return nil }
        onSelect(found)
        let items = menuItems(found)
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        for item in items {
            if item.title == "-" {
                menu.addItem(.separator())
            } else {
                let action = MenuAction(item.action)
                let entry = NSMenuItem(title: item.title, action: #selector(MenuAction.fire), keyEquivalent: "")
                entry.target = action
                entry.representedObject = action
                menu.addItem(entry)
            }
        }
        return menu
    }
}

/// The target of a menu item that runs a closure. The item keeps it alive as
/// its represented object.
private final class MenuAction: NSObject {
    private let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }

    @objc func fire() { run() }
}
