import AppKit
import SkitKit
import SwiftUI

/// The Braid, drawn: reading order from top to bottom, each turn a prompt and
/// the chain of steps it started (`BraidLayout.swift` says what and where).
final class BraidCanvasNSView: CanvasNSView {
    var layout: CanvasLayout? { didSet { needsDisplay = true } }
    var content: BraidContent? { didSet { needsDisplay = true } }

    override var worldBounds: CGRect? { content == nil ? nil : layout?.bounds }

    // MARK: Drawing

    override func drawWorld(_ cg: CGContext, visible: CGRect, detail: Camera.Detail) {
        guard let layout, let content else { return }
        let scale = camera.scale

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
            if dim { beginDimmed(cg) }
            switch node.kind {
            case .prompt(let turn): draw(prompt: content.turns[turn].card, node, cg, detail)
            case .step(let turn, let step): draw(step: content.turns[turn].steps[step], node, cg, detail)
            case .strand(let agent): if let strand = content.strands[agent] { draw(strand: strand, node, cg, detail) }
            case .summary(let turn): draw(summary: content.turns[turn].summary, node, cg, detail)
            }
            if dim { endDimmed(cg) }
            if dimming, !dim { ring(node.rect, cg, colors.warn, width: 2, radius: 8) }
        }
    }

    private func isMatch(_ node: CanvasLayout.Node) -> Bool {
        if matches.contains(node.key) { return true }
        // A summary stands for its turn's actions.
        if case .summary(let turn) = node.kind, let steps = content?.turns[turn].steps { return steps.contains { matches.contains(.action($0.index)) } }
        return false
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
    // MARK: What is where

    /// The node, chip, strand step, note or pill under a point of the canvas.
    override func hit(at point: CGPoint) -> CanvasHit? {
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
}
