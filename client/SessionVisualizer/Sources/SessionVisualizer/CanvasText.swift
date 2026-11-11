import AppKit
import CoreText

/// The faces the canvas writes in. Core Text fonts, made once: the canvas
/// breaks every text into lines itself so that a card's height is known before
/// it is drawn and never changes with the zoom. A CTFont is immutable and safe
/// to use from any thread, which the compiler cannot know.
nonisolated enum CanvasFont {
    nonisolated(unsafe) static let title = make(12, .semibold)
    nonisolated(unsafe) static let text = make(12, .regular)
    nonisolated(unsafe) static let prompt = make(12.5, .regular)
    nonisolated(unsafe) static let meta = make(11, .regular)
    nonisolated(unsafe) static let small = make(11, .regular)
    nonisolated(unsafe) static let smallBold = make(11, .semibold)
    nonisolated(unsafe) static let strand = make(11.5, .regular)
    nonisolated(unsafe) static let mono = makeMono(10)
    nonisolated(unsafe) static let note = makeMono(10.5)
    nonisolated(unsafe) static let turn = CTFontCreateWithName("AvenirNext-Bold" as CFString, 12, nil)
    nonisolated(unsafe) static let caps = CTFontCreateWithName("AvenirNext-Regular" as CFString, 11, nil)

    private static func make(_ size: CGFloat, _ weight: NSFont.Weight) -> CTFont { NSFont.systemFont(ofSize: size, weight: weight) as CTFont }
    private static func makeMono(_ size: CGFloat) -> CTFont { NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont }
}

/// A text broken into its lines for a given width, ready to draw. Made once per
/// node when a session's canvas is built; drawing it is one call per line.
nonisolated struct LaidText: @unchecked Sendable {
    let lines: [CTLine]
    let lineHeight: CGFloat
    /// From the top of a line's box to its baseline.
    let baseline: CGFloat
    /// The widest line.
    let width: CGFloat

    static let empty = LaidText(lines: [], lineHeight: 0, baseline: 0, width: 0)

    var isEmpty: Bool { lines.isEmpty }
    var height: CGFloat { CGFloat(lines.count) * lineHeight }

    private init(lines: [CTLine], lineHeight: CGFloat, baseline: CGFloat, width: CGFloat) {
        self.lines = lines
        self.lineHeight = lineHeight
        self.baseline = baseline
        self.width = width
    }

    /// Breaks `string` into at most `maxLines` lines no wider than `width`;
    /// what does not fit ends in an ellipsis. Line breaks in the string are
    /// read as spaces: a card shows a passage, not its layout.
    init(_ string: String, font: CTFont, width: CGFloat, maxLines: Int = 1, lineHeight: CGFloat? = nil) {
        // No card shows more than a few lines: do not typeset a pasted file to find the first three.
        let flat = string.prefix(maxLines * 400).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let natural = ceil(ascent + descent + CTFontGetLeading(font))
        let height = lineHeight ?? natural
        guard !flat.isEmpty, width > 4, maxLines > 0 else {
            self.init(lines: [], lineHeight: height, baseline: 0, width: 0)
            return
        }
        let attributes = [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true] as CFDictionary
        guard let attributed = CFAttributedStringCreate(nil, flat as CFString, attributes) else {
            self.init(lines: [], lineHeight: height, baseline: 0, width: 0)
            return
        }
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let length = CFAttributedStringGetLength(attributed)
        var lines: [CTLine] = []
        var start = 0
        while start < length, lines.count < maxLines {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(width)))
            if lines.count == maxLines - 1, start + count < length {
                // The last line allowed, and more to say: cut it with an ellipsis.
                let rest = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: length - start))
                let ellipsis = CFAttributedStringCreate(nil, "…" as CFString, attributes).map(CTLineCreateWithAttributedString)
                lines.append(CTLineCreateTruncatedLine(rest, Double(width), .end, ellipsis) ?? CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
                break
            }
            lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
            start += count
        }
        let widest = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }.max() ?? 0
        self.init(lines: lines, lineHeight: height, baseline: (height - natural) / 2 + ascent, width: min(width, ceil(widest)))
    }

    /// Draws the lines with their top-left corner at (x, y), in the context's
    /// fill colour. The context is flipped (y grows downwards) and its text
    /// matrix has been flipped back once per frame.
    func draw(_ cg: CGContext, x: CGFloat, y: CGFloat) {
        for (i, line) in lines.enumerated() {
            cg.textPosition = CGPoint(x: x, y: y + baseline + CGFloat(i) * lineHeight)
            CTLineDraw(line, cg)
        }
    }
}
