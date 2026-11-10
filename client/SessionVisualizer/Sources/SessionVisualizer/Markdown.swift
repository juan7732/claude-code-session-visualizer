import SwiftUI

/// The block structure of what Claude writes: paragraphs, headings, lists,
/// fenced code and tables. SwiftUI renders inline Markdown (bold, code, links)
/// but not blocks, so the blocks are split here and each is drawn on its own.
nonisolated enum MarkdownBlock: Hashable, Sendable {
    case paragraph(String)
    case heading(String)
    case list([String], ordered: Bool)
    /// Fenced code, kept as written, in a monospaced face.
    case code(String)
    /// A table: its rows of cells, the first row being the header.
    case table([[String]])

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var items: [String] = []
        var ordered = false
        var code: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        func flushList() {
            if !items.isEmpty { blocks.append(.list(items, ordered: ordered)) }
            items = []
        }

        // True while the lines of one table follow each other.
        var tableOpen = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { if !trimmed.hasPrefix("|") || code != nil { tableOpen = false } }
            if var open = code {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(open.joined(separator: "\n")))
                    code = nil
                } else {
                    open.append(line)
                    code = open
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushParagraph(); flushList()
                code = []
            } else if trimmed.isEmpty {
                flushParagraph(); flushList()
            } else if trimmed.hasPrefix("#"), let space = trimmed.firstIndex(of: " "), trimmed[..<space].allSatisfy({ $0 == "#" }) {
                flushParagraph(); flushList()
                blocks.append(.heading(String(trimmed[trimmed.index(after: space)...])))
            } else if let item = listItem(trimmed) {
                flushParagraph()
                if !items.isEmpty, ordered != item.ordered { flushList() }
                ordered = item.ordered
                items.append(item.text)
            } else if trimmed.hasPrefix("|") {
                flushParagraph(); flushList()
                var cells = trimmed.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.first == "" { cells.removeFirst() }
                if cells.last == "" { cells.removeLast() }
                // The |---|---| line under the header says nothing.
                let rule = !cells.isEmpty && cells.allSatisfy { !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }
                if case .table(var rows)? = blocks.last, tableOpen {
                    if !rule { rows.append(cells) }
                    blocks[blocks.count - 1] = .table(rows)
                } else if !rule {
                    blocks.append(.table([cells]))
                }
                tableOpen = true
                continue
            } else if !items.isEmpty, line.hasPrefix("  ") {
                items[items.count - 1] += " " + trimmed // a wrapped list item
            } else {
                flushList()
                paragraph.append(trimmed)
            }
        }
        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        flushParagraph(); flushList()
        return blocks
    }

    private static func listItem(_ line: String) -> (text: String, ordered: Bool)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return (String(line.dropFirst(2)), false)
        }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3, line.dropFirst(digits.count).hasPrefix(". ") {
            return (String(line.dropFirst(digits.count + 2)), true)
        }
        return nil
    }
}

/// Inline Markdown as attributed text: bold, italics, links, `code` in a
/// monospaced face on a tinted ground, and the find query marked.
struct InlineText {
    var palette: Palette
    var query = ""

    func attributed(_ source: String, markdown: Bool = true) -> AttributedString {
        var text: AttributedString
        if markdown, let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            text = parsed
            for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
                text[run.range].font = .system(size: 12, design: .monospaced)
                text[run.range].backgroundColor = palette.panel2
            }
        } else {
            text = AttributedString(source)
        }
        mark(&text)
        return text
    }

    /// Paints every occurrence of the query, ignoring case.
    private func mark(_ text: inout AttributedString) {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else { return }
        var from = text.startIndex
        while from < text.endIndex, let found = text[from...].range(of: needle, options: .caseInsensitive) {
            text[found].backgroundColor = palette.warn.opacity(0.35)
            from = found.upperBound
        }
    }
}

/// What Claude wrote, block by block.
struct MarkdownText: View {
    @Environment(\.palette) private var palette
    var blocks: [MarkdownBlock]
    var query = ""

    var body: some View {
        let inline = InlineText(palette: palette, query: query)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    Text(inline.attributed(text)).lineSpacing(3)
                case .heading(let text):
                    Text(inline.attributed(text)).fontWeight(.semibold)
                case .list(let items, let ordered):
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(ordered ? "\(i + 1)." : "•").foregroundStyle(palette.muted).frame(minWidth: 14, alignment: .trailing)
                                Text(inline.attributed(item)).lineSpacing(3)
                            }
                        }
                    }
                case .table(let rows):
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { r, cells in
                            GridRow {
                                ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                                    Text(inline.attributed(cell)).fontWeight(r == 0 ? .semibold : .regular)
                                        .foregroundStyle(r == 0 ? palette.ink : palette.ink2)
                                }
                            }
                            if r == 0, rows.count > 1 { Rectangle().fill(palette.line2).frame(height: 1).gridCellUnsizedAxes(.horizontal) }
                        }
                    }
                    .font(.system(size: 12.5))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(palette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                case .code(let text):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(inline.attributed(text, markdown: false))
                            .font(.system(size: 11.5, design: .monospaced)).lineSpacing(2)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                    }
                    .background(palette.panel2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .font(.system(size: 13.5))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
