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

/// A canvas under a camera: one view that paints what is visible with Core
/// Graphics and Core Text, so text is sharp at every zoom and a frame costs
/// only what is on screen. It takes scroll, pinch, drag, click, hover and the
/// context menu itself, and tells its owner what happened. What is drawn is a
/// subclass's: the Braid (reading order) and the Score (time-true staves).
class CanvasNSView: NSView {
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

    /// How far the canvas moves for a point of scrolling.
    static let scrollSpeed: CGFloat = 0.85

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    // MARK: What a subclass says

    /// The extent of what is laid out, in canvas points; nil while there is nothing to draw.
    var worldBounds: CGRect? { nil }

    /// Draws what is in `visible`, under the camera's transform.
    func drawWorld(_ cg: CGContext, visible: CGRect, detail: Camera.Detail) {}

    /// Draws what stays put while the canvas moves under it (a ruler, row names), in the view's own points.
    func drawOverlay(_ cg: CGContext) {}

    /// What is under a point of the canvas.
    func hit(at point: CGPoint) -> CanvasHit? { nil }

    /// Whether a node says what it is under the pointer even when it is close enough to read.
    var tipsWhenNear: Bool { false }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.setFillColor(colors.bg)
        cg.fill(bounds)
        guard worldBounds != nil else { return }
        let visible = camera.visible(in: bounds.size)
        drawBackground(cg, visible: visible)

        cg.saveGState()
        cg.translateBy(x: camera.x, y: camera.y)
        cg.scaleBy(x: camera.scale, y: camera.scale)
        // Core Text draws upwards; the view counts downwards.
        cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        drawWorld(cg, visible: visible, detail: camera.detail)
        cg.restoreGState()

        cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        drawOverlay(cg)
    }

    /// What is drawn until `endDimmed` is faded as one: a node that find did
    /// not match. A plain alpha would be undone by the first part of the node
    /// that sets its own.
    func beginDimmed(_ cg: CGContext) {
        cg.saveGState()
        cg.setAlpha(0.3)
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
    }

    func endDimmed(_ cg: CGContext) {
        cg.endTransparencyLayer()
        cg.restoreGState()
    }

    /// Dots, lines or a grid behind the canvas: they move and scale with it, and
    /// thin out before they would crowd.
    func drawBackground(_ cg: CGContext, visible: CGRect) {
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

    func draw(_ edge: CanvasLayout.Edge, _ cg: CGContext) {
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

    func card(_ rect: CGRect, _ cg: CGContext, fill: CGColor, stroke: CGColor, radius: CGFloat = 8, dashed: Bool = false, shadow: Bool) {
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

    func ring(_ rect: CGRect, _ cg: CGContext, _ color: CGColor, width: CGFloat, radius: CGFloat, dashed: Bool = false) {
        cg.addPath(CGPath(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerWidth: radius + 1, cornerHeight: radius + 1, transform: nil))
        cg.setStrokeColor(color)
        cg.setLineWidth(max(width, width / camera.scale * 0.8))
        if dashed { cg.setLineDash(phase: 0, lengths: [5, 3]) }
        cg.strokePath()
        if dashed { cg.setLineDash(phase: 0, lengths: []) }
    }

    /// The selection's ring and the keyboard's dashed one.
    func marks(_ key: NodeKey, _ rect: CGRect, _ cg: CGContext, radius: CGFloat = 8) {
        if selection == key { ring(rect, cg, colors.accent, width: 2, radius: radius) } else if focus == key { ring(rect, cg, colors.accent, width: 1.5, radius: radius, dashed: true) }
    }

    /// The square at the start of a card's header: its colour says what kind of step, its glyph which.
    func badge(_ name: String, _ tint: CGColor, at origin: CGPoint, _ cg: CGContext, detail: Camera.Detail) {
        let box = CGRect(x: origin.x, y: origin.y, width: 16, height: 16)
        cg.addPath(CGPath(roundedRect: box, cornerWidth: 4.5, cornerHeight: 4.5, transform: nil))
        cg.setFillColor(tint)
        cg.fillPath()
        if detail != .far || camera.scale > 0.25 { symbol(name, colors.panel, in: box.insetBy(dx: 3, dy: 3)) }
    }
    /// An SF Symbol in a colour, kept once made: a glyph is drawn many times a frame.
    func symbol(_ name: String, _ color: CGColor, in rect: CGRect) {
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

    func canvasPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: (p.x - camera.x) / camera.scale, y: (p.y - camera.y) / camera.scale)
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

    func move(_ change: (inout Camera) -> Void) {
        var next = camera
        change(&next)
        if let worldBounds { next.clamp(to: worldBounds, in: bounds.size) }
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
            // A trackpad's deltas are points; a wheel's are lines. Both a little under one to one:
            // at full speed the canvas ran ahead of the fingers (Juan, 2026-11-10: "about 15 % too fast").
            let k: CGFloat = (event.hasPreciseScrollingDeltas ? 1 : 10) * Self.scrollSpeed
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
        let tip = camera.detail == .near && !tipsWhenNear ? nil : found.flatMap { $0.tip.isEmpty ? nil : $0.tip }
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
