import SkitKit
import SwiftUI

/// A search snippet as the engine writes it: the matching words between « and ».
enum Snippet {
    /// The snippet with its marks painted.
    static func attributed(_ snippet: String, palette: Palette) -> AttributedString {
        var out = AttributedString()
        var marked = false
        for part in snippet.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "«" || $0 == "»" }) {
            var piece = AttributedString(String(part))
            if marked {
                piece.backgroundColor = palette.warn.opacity(0.3)
                piece.foregroundColor = palette.ink
            }
            out += piece
            marked.toggle()
        }
        return out
    }

    /// The words the engine marked, lowercased, longest first.
    nonisolated static func marks(_ snippet: String) -> [String] {
        var out: [String] = []
        var rest = Substring(snippet)
        while let open = rest.firstIndex(of: "«"), let close = rest[open...].firstIndex(of: "»") {
            let word = rest[rest.index(after: open)..<close].lowercased()
            if !word.isEmpty, !out.contains(word) { out.append(word) }
            rest = rest[rest.index(after: close)...]
        }
        return out.sorted { $0.count > $1.count }
    }

    /// Text with every marked word painted, ignoring case.
    static func painted(_ text: String, marks: [String], palette: Palette) -> AttributedString {
        var out = AttributedString(text)
        for word in marks {
            var from = out.startIndex
            while from < out.endIndex, let found = out[from...].range(of: word, options: .caseInsensitive) {
                out[found].backgroundColor = palette.warn.opacity(0.3)
                from = found.upperBound
            }
        }
        return out
    }

    /// The part of a long text around the first marked word: `before` characters
    /// ahead of it and `after` behind, with an ellipsis where it was cut. With no
    /// marked word, the window opens where `passage` (an excerpt of the text) begins.
    nonisolated static func window(_ text: String, marks: [String], passage: String? = nil, before: Int = 500, after: Int = 900) -> String {
        var first = marks.compactMap { text.range(of: $0, options: .caseInsensitive)?.lowerBound }.min()
        if first == nil, let passage {
            // The excerpt's opening words, as they stand in the text (its whitespace may have been flattened).
            let opening = passage.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "… \n")).prefix(24)
            if !opening.isEmpty { first = text.range(of: opening)?.lowerBound }
            // A passage is read from its start: little before it, more after.
            if let found = first {
                let start = text.index(found, offsetBy: -min(before, 120), limitedBy: text.startIndex) ?? text.startIndex
                let end = text.index(found, offsetBy: after + before - 120, limitedBy: text.endIndex) ?? text.endIndex
                return (start > text.startIndex ? "…" : "") + text[start..<end] + (end < text.endIndex ? "…" : "")
            }
        }
        let at = first ?? text.startIndex
        let start = text.index(at, offsetBy: -before, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(at, offsetBy: after, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + text[start..<end] + (end < text.endIndex ? "…" : "")
    }
}

/// The kinds of text the engine indexes, as the views name and colour them.
enum SearchKind {
    /// The scopes of a search, in the order of the scope bar.
    static let scopes: [(kind: String, label: String)] = [
        ("", "Everything"), ("prompt", "Prompts"), ("assistant", "Responses"), ("thinking", "Thinking"),
        ("tool_use", "Tool inputs"), ("tool_result", "Tool results"),
    ]

    static func label(_ kind: String) -> String { kind.replacingOccurrences(of: "_", with: " ") }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "prompt": "person"
        case "assistant": "text.bubble"
        case "thinking": "brain"
        case "tool_use": "terminal"
        case "tool_result": "arrow.turn.down.right"
        case "summary": "scissors"
        default: "doc.text"
        }
    }

    static func color(_ kind: String, _ palette: Palette) -> Color {
        switch kind {
        case "prompt": palette.ink
        case "assistant": palette.accent
        case "thinking": palette.muted
        case "tool_use", "tool_result": palette.tool
        case "summary": palette.warn
        default: palette.ctx
        }
    }
}
