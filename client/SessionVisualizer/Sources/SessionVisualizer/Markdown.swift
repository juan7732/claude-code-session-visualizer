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

/// Which links text from a transcript may open, and whether a link's label already says where it goes.
/// A transcript is whatever a model, a tool result or a web page put in it: a link in it is not the
/// app's own, so it opens the web and nothing else (no file:, smb:, or another application's scheme).
nonisolated enum LinkPolicy {
    /// True for an http or https address with a host.
    static func opens(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return !(url.host ?? "").isEmpty
    }

    /// True when the label is itself an address on the host the link leads to.
    static func labelNames(_ label: String, host: String) -> Bool {
        let shown = label.trimmingCharacters(in: .whitespacesAndNewlines)
        // A label in another script can look like a host it is not: then the real one is written out.
        guard shown.unicodeScalars.allSatisfy(\.isASCII) else { return false }
        let written = URL(string: shown).flatMap { opens($0) ? $0 : nil } ?? URL(string: "https://" + shown)
        return written?.host?.lowercased() == host.lowercased()
    }
}

/// Inline Markdown as attributed text: bold, italics, links, `code` in a
/// monospaced face on a tinted ground, and the find query marked.
struct InlineText {
    var palette: Palette
    var query = ""

    /// What was asked for before, by everything the answer depends on.
    private struct Made: Hashable {
        var source: String
        var markdown: Bool
        var query: String
        var palette: Palette
    }

    /// DECISION: the attributed texts are kept. A row's body runs again for a hover, a selection, a
    /// scroll, and each run parsed every paragraph's Markdown anew. The key is the text itself with
    /// the query and the palette, so nothing has to be told when a session is read again. The size
    /// is bounded in bytes of source; past it everything is dropped, and what is on screen comes back
    /// at its next draw. A very long text (an opened result) is made each time and not kept.
    private static var made: [Made: AttributedString] = [:]
    private static var madeBytes = 0
    static let keptBytes = 2 << 20
    static let keptEntryBytes = 32 << 10
    /// How many texts are kept now (for the tests).
    static var keptCount: Int { made.count }

    func attributed(_ source: String, markdown: Bool = true) -> AttributedString {
        let size = source.utf8.count
        guard size <= Self.keptEntryBytes else { return make(source, markdown: markdown) }
        let needle = query.trimmingCharacters(in: .whitespaces)
        let key = Made(source: source, markdown: markdown, query: needle.count >= 2 ? needle : "", palette: palette)
        if let kept = Self.made[key] { return kept }
        let text = make(source, markdown: markdown)
        if Self.madeBytes + size > Self.keptBytes {
            Self.made.removeAll(keepingCapacity: true)
            Self.madeBytes = 0
        }
        Self.made[key] = text
        Self.madeBytes += size
        return text
    }

    private func make(_ source: String, markdown: Bool) -> AttributedString {
        var text: AttributedString
        if markdown, let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            text = styled(parsed)
        } else {
            text = AttributedString(source)
        }
        mark(&text)
        return text
    }

    /// The parsed text with code set in its face and its links made safe to click.
    ///
    /// DECISION: a link that is not to the web loses its destination and keeps its words: one click
    /// on `[notes](file:///…/x.command)` must not run anything, and Claude Code's own file links
    /// (`[a.go](src/a.go)`) lead nowhere from here anyway. A web link whose label is not its own
    /// address gets its host after it, muted, so where a click goes is on the page before the click
    /// (the host and not the whole address: the host is what tells one site from another).
    private func styled(_ parsed: AttributedString) -> AttributedString {
        var out = AttributedString()
        // The web link being copied: runs that touch and share a destination are one link.
        var open: (url: URL, label: String)?
        func close() {
            guard let link = open else { return }
            open = nil
            let host = link.url.host ?? ""
            if LinkPolicy.labelNames(link.label, host: host) { return }
            var suffix = AttributedString(" (\(host))")
            suffix.foregroundColor = palette.muted
            out.append(suffix)
        }
        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            if run.inlinePresentationIntent?.contains(.code) == true {
                piece.font = .system(size: 12, design: .monospaced)
                piece.backgroundColor = palette.panel2
            }
            if let url = run.link, LinkPolicy.opens(url) {
                if open?.url != url {
                    close()
                    open = (url, "")
                }
                open?.label += String(piece.characters)
            } else {
                close()
                piece.link = nil
            }
            out.append(piece)
        }
        close()
        return out
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
