import AppKit
import SkitKit
import SwiftUI

/// A file a session touched, as it is on disk now: its text with the colours of
/// its language, or why there is none (deleted, not text), a button that opens
/// it in the application chosen in Settings, and beside it every session that
/// touched the same file. The engine reads the file (`skit file`); it reads
/// only files an archived session touched.
struct FilePane: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    /// Read through `FileOpener.setting`, so that with nothing chosen it is VS Code when that is installed.
    @AppStorage(SettingsKey.fileOpener) private var chosen: String?
    var model: SessionModel
    var file: Relations.FileTouched

    private var opener: String { chosen ?? FileOpener.fallback }
    @State private var view: Loadable<FileView> = .loading
    @State private var styled: NSAttributedString?

    var body: some View {
        Group {
            switch view {
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let why):
                message("questionmark.folder", why)
            case .loaded(let now):
                VStack(alignment: .leading, spacing: 10) {
                    bar(now)
                    HStack(alignment: .top, spacing: 14) {
                        content(now).frame(maxWidth: .infinity, maxHeight: .infinity)
                        history(now).frame(width: 250)
                    }
                }
            }
        }
        .task(id: file.path + "\n" + model.doc.id) { await load() }
    }

    private func load() async {
        (view, styled) = (.loading, nil)
        do {
            let now = try await store.client.file(path: file.path, session: model.doc.id)
            view = .loaded(now)
            guard let text = now.text else { return }
            // Colouring a long file takes a moment: off the main thread, and the plain text shows meanwhile.
            let colors = CodeColors(palette)
            let path = now.path
            styled = await Task.detached(priority: .userInitiated) { Styled(text: Highlighter.attributed(text, path: path, colors: colors)) }.value.text
        } catch SkitError.engine(404, _) {
            view = .failed("The engine does not know where this file is on disk. It learns that when it archives a session: this one may not be archived yet (Session › Archive Now), or the path was only named in passing.")
        } catch {
            view = .failed("\(error)")
        }
    }

    private func bar(_ now: FileView) -> some View {
        HStack(spacing: 10) {
            Image(systemName: now.exists ? "doc.text" : "trash").foregroundStyle(now.exists ? palette.muted : palette.err)
            Text(FilePane.state(now)).font(.system(size: 12.5)).foregroundStyle(now.exists ? palette.ink2 : palette.err)
            Spacer(minLength: 8)
            if now.exists {
                Button(FileOpener.title(opener)) { FileOpener.open(now.path, with: opener) }
                    .help("Open \(now.path) (the application is chosen in Settings › General)")
                Button("Reveal in Finder") { FileOpener.reveal(now.path) }
            }
            Button("Copy Path") { Exporter.copy(now.path) }
        }
        .controlSize(.small)
    }

    /// "39 kB · changed Nov 10, 10:04 PM", or what happened to it.
    static func state(_ now: FileView) -> String {
        switch now.reason {
        case "deleted": return "Not found at \(Format.homeRelative(now.path)): deleted or moved since, or named from a directory the transcript does not record."
        case "directory": return "A directory."
        case "unreadable": return "There, and not readable."
        default: break
        }
        var parts = [FilesContent.bytes(now.bytes ?? 0)]
        if let modified = now.modified { parts.append("changed " + Format.dateTime(modified)) }
        if now.reason == "binary" { parts.append("not text") }
        if now.truncated == true { parts.append("the first 2 MB are shown") }
        return "As it is now · " + parts.joined(separator: " · ")
    }

    @ViewBuilder private func content(_ now: FileView) -> some View {
        if let text = now.text {
            CodeView(text: styled ?? Highlighter.plain(text, colors: CodeColors(palette)), background: NSColor(palette.panel))
                .clipShape(RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
        } else if now.reason == "deleted" {
            message("trash", "Nothing to show: there is no file at that path now. What the session did to it is under Touches, and the sessions that touched it are on the right.")
        } else if now.reason == "binary" {
            message("photo", "This is not a text file. Open it in an application that reads it.")
        } else if now.exists, now.reason == nil {
            message("doc", "The file is empty.")
        } else {
            message("questionmark.folder", FilePane.state(now))
        }
    }

    private func message(_ symbol: String, _ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(palette.muted2)
            Text(text).font(.system(size: 12.5)).foregroundStyle(palette.muted).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.panel, in: RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
    }

    /// Every archived session that read or wrote this file, the latest first.
    private func history(_ now: FileView) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SESSIONS THAT TOUCHED IT · \(now.sessions.count)").font(.caps).tracking(0.9).foregroundStyle(palette.muted)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(now.sessions) { entry in
                        HistoryRow(entry: entry, current: entry.session == model.doc.id) {
                            // The same file in that session's Files view, under the path it wrote there.
                            window.open(session: entry.session, at: .file(entry.raw), select: true, view: .files)
                        }
                    }
                }
            }
            Text("A write is counted when an edit tool wrote the file or a shell command redirected into it; a script that wrote it counts as a read.")
                .font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HistoryRow: View {
    @Environment(\.palette) private var palette
    var entry: FileView.History
    var current: Bool
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? Format.shortID(entry.session) : entry.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
                Text(FilePane.counts(entry) + " · " + Format.dateTime(entry.lastAt)).font(.system(size: 11.5)).foregroundStyle(palette.muted).lineLimit(1)
                if current { Text("this session").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(palette.accent) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(current ? palette.panel : hover ? palette.panel2.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(current)
        .onHover { hover = $0 }
        .help(current ? "The session you are in" : "Open this file in that session")
    }
}

extension FilePane {
    /// "3 written · 44 read".
    static func counts(_ entry: FileView.History) -> String {
        [entry.writes > 0 ? "\(entry.writes) written" : nil, entry.reads > 0 ? "\(entry.reads) read" : nil].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The application "Open" opens a file in, chosen in Settings › General.
enum FileOpener {
    /// Editors worth offering by name when they are installed.
    static let known: [(id: String, name: String)] = [
        ("com.microsoft.VSCode", "Visual Studio Code"), ("com.todesktop.230313mzl4w4u92", "Cursor"), ("dev.zed.Zed", "Zed"),
        ("com.apple.dt.Xcode", "Xcode"), ("com.sublimetext.4", "Sublime Text"), ("com.apple.TextEdit", "TextEdit"),
    ]

    /// With nothing chosen: Visual Studio Code when it is installed, else each file's default application.
    static var fallback: String { NSWorkspace.shared.urlForApplication(withBundleIdentifier: known[0].id) != nil ? known[0].id : "" }

    /// The setting in effect.
    static var setting: String { UserDefaults.standard.string(forKey: SettingsKey.fileOpener) ?? fallback }

    static func installed() -> [(id: String, name: String)] {
        known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }

    /// The application for a setting: a bundle id, or the path of an application chosen by hand.
    static func application(_ setting: String) -> URL? {
        if setting.isEmpty { return nil }
        if setting.hasPrefix("/") { return FileManager.default.fileExists(atPath: setting) ? URL(fileURLWithPath: setting) : nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: setting)
    }

    static func name(_ setting: String) -> String? {
        if let known = known.first(where: { $0.id == setting }) { return known.name }
        return application(setting).map { $0.deletingPathExtension().lastPathComponent }
    }

    /// "Open in Visual Studio Code", or "Open" for each file's default application.
    static func title(_ setting: String) -> String {
        application(setting).flatMap { _ in name(setting) }.map { "Open in \($0)" } ?? "Open"
    }

    static func open(_ path: String, with setting: String) {
        let file = URL(fileURLWithPath: path)
        if let app = application(setting) {
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(file)
        }
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Lets the person pick any application; returns its path.
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Choose"
        panel.message = "The application that opens files from SessionVisualizer"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

/// A text view that only shows: selectable, searchable with ⌘F while it has the keyboard, and quick with long files.
struct CodeView: NSViewRepresentable {
    var text: NSAttributedString
    var background: NSColor

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.drawsBackground = true
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        view.backgroundColor = background
        if view.textStorage?.isEqual(to: text) != true {
            view.textStorage?.setAttributedString(text)
            view.scroll(.zero)
        }
    }
}

/// An attributed text on its way from the thread that coloured it to the view: it is not changed after it is made.
nonisolated struct Styled: @unchecked Sendable {
    var text: NSAttributedString
}

/// The colours of code, as AppKit colours: made on the main thread, used off it.
nonisolated struct CodeColors: @unchecked Sendable {
    var ink, comment, string, number, keyword: NSColor

    @MainActor init(_ palette: Palette) {
        ink = NSColor(palette.ink)
        comment = NSColor(palette.muted)
        string = NSColor(palette.tool)
        number = NSColor(palette.warn)
        keyword = NSColor(palette.accent)
    }
}

/// A small highlighter: comments, strings, numbers and keywords, by the file's
/// extension. It reads no grammar; it is right about the common cases of the
/// languages a session usually touches and leaves the rest plain.
nonisolated enum Highlighter {
    enum Kind: Equatable, Sendable { case comment, string, number, keyword }

    struct Span: Equatable, Sendable {
        var range: NSRange
        var kind: Kind
    }

    struct Language: Sendable {
        var lineComments: [String] = []
        var block: (open: String, close: String)?
        var quotes: [Character] = ["\""]
        /// Python's """ and '''.
        var tripleQuotes = false
        var keywords: Set<String> = []
        /// Markdown: a line that starts with # is a heading, `text` is code.
        var markdown = false
    }

    /// Above this many characters a file is shown plain: the colours are not worth the wait.
    static let limit = 400_000

    static func language(for path: String) -> Language? {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        let c = Language(lineComments: ["//"], block: ("/*", "*/"), quotes: ["\"", "'"])
        switch ext.isEmpty ? name : ext {
        case "go":
            return Language(lineComments: ["//"], block: ("/*", "*/"), quotes: ["\"", "'", "`"], keywords: words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var nil true false"))
        case "swift":
            return Language(lineComments: ["//"], block: ("/*", "*/"), keywords: words("actor any as async await break case catch class continue default defer do else enum extension fallthrough false fileprivate final for func guard if import in init inout internal is let nil nonisolated private protocol public repeat rethrows return self static struct subscript super switch throw throws true try typealias var where while"))
        case "js", "mjs", "cjs", "jsx", "ts", "tsx":
            return Language(lineComments: ["//"], block: ("/*", "*/"), quotes: ["\"", "'", "`"], keywords: words("async await break case catch class const continue default delete do else export extends false finally for from function if import in instanceof interface let new null of return static super switch this throw true try type typeof undefined var void while yield"))
        case "py":
            return Language(lineComments: ["#"], quotes: ["\"", "'"], tripleQuotes: true, keywords: words("and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield"))
        case "rs":
            return Language(lineComments: ["//"], block: ("/*", "*/"), keywords: words("as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while"))
        case "sh", "bash", "zsh", "justfile", "makefile", "dockerfile", "mk":
            return Language(lineComments: ["#"], quotes: ["\"", "'"], keywords: words("if then else elif fi for while do done case esac in function return exit export local set echo cd"))
        case "json", "jsonl":
            return Language(quotes: ["\""], keywords: words("true false null"))
        case "yaml", "yml", "toml", "cfg", "ini", "conf":
            return Language(lineComments: ["#"], quotes: ["\"", "'"], keywords: words("true false null yes no on off"))
        case "css", "scss":
            return Language(block: ("/*", "*/"), quotes: ["\"", "'"])
        case "html", "htm", "xml", "svg", "plist":
            return Language(block: ("<!--", "-->"), quotes: ["\"", "'"])
        case "sql":
            return Language(lineComments: ["--"], block: ("/*", "*/"), quotes: ["'"], keywords: words("select from where and or not null insert into values update set delete create table index on join left right inner outer group by order having limit as distinct primary key references default"))
        case "c", "h", "cc", "cpp", "hpp", "m", "mm", "java", "kt", "cs":
            var language = c
            language.keywords = words("auto bool break case catch char class const continue default do double else enum extern false float for if import int interface long namespace new nil null private protected public return short signed sizeof static struct switch this throw true try typedef union unsigned using var void while")
            return language
        case "md", "markdown":
            return Language(quotes: [], markdown: true)
        default:
            return nil
        }
    }

    private static func words(_ list: String) -> Set<String> { Set(list.split(separator: " ").map(String.init)) }

    /// What to colour, in the order it appears. Ranges are in UTF-16, as text views count.
    static func spans(_ text: String, language: Language) -> [Span] {
        let u = Array(text.utf16)
        let n = u.count
        var out: [Span] = []
        func starts(_ token: String, at i: Int) -> Bool {
            let t = Array(token.utf16)
            guard i + t.count <= n else { return false }
            for k in 0..<t.count where u[i + k] != t[k] { return false }
            return true
        }
        func letter(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }
        func digit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
        let newline: UInt16 = 10, backslash: UInt16 = 92
        let quotes = language.quotes.compactMap { $0.utf16.first }
        var i = 0
        var lineStart = true
        while i < n {
            let c = u[i]
            if language.markdown {
                if lineStart, c == 35 { // a heading runs to the end of its line
                    var j = i
                    while j < n, u[j] != newline { j += 1 }
                    out.append(Span(range: NSRange(location: i, length: j - i), kind: .keyword))
                    i = j
                    continue
                }
                if c == 96 { // `code`, on one line
                    var j = i + 1
                    while j < n, u[j] != 96, u[j] != newline { j += 1 }
                    if j < n, u[j] == 96 {
                        out.append(Span(range: NSRange(location: i, length: j + 1 - i), kind: .string))
                        i = j + 1
                        lineStart = false
                        continue
                    }
                }
                lineStart = c == newline
                i += 1
                continue
            }
            if let block = language.block, starts(block.open, at: i) {
                var j = i + block.open.utf16.count
                while j < n, !starts(block.close, at: j) { j += 1 }
                j = min(n, j + block.close.utf16.count)
                out.append(Span(range: NSRange(location: i, length: j - i), kind: .comment))
                i = j
                continue
            }
            if language.lineComments.contains(where: { starts($0, at: i) }) {
                var j = i
                while j < n, u[j] != newline { j += 1 }
                out.append(Span(range: NSRange(location: i, length: j - i), kind: .comment))
                i = j
                continue
            }
            if quotes.contains(c) {
                let triple = language.tripleQuotes && i + 2 < n && u[i + 1] == c && u[i + 2] == c
                var j = i + (triple ? 3 : 1)
                while j < n {
                    if u[j] == backslash { j += 2; continue }
                    if triple {
                        if j + 2 < n, u[j] == c, u[j + 1] == c, u[j + 2] == c { j += 3; break }
                    } else if u[j] == c {
                        j += 1
                        break
                    } else if u[j] == newline, c != 96 { // an unclosed quote ends with its line (a backtick string may run on)
                        break
                    }
                    j += 1
                }
                j = min(n, j)
                out.append(Span(range: NSRange(location: i, length: j - i), kind: .string))
                i = j
                continue
            }
            if digit(c), i == 0 || !(letter(u[i - 1]) || digit(u[i - 1])) {
                var j = i
                while j < n, digit(u[j]) || letter(u[j]) || u[j] == 46 { j += 1 }
                out.append(Span(range: NSRange(location: i, length: j - i), kind: .number))
                i = j
                continue
            }
            if letter(c) {
                var j = i
                while j < n, letter(u[j]) || digit(u[j]) { j += 1 }
                if !language.keywords.isEmpty, let word = String(utf16CodeUnits: Array(u[i..<j]), count: j - i) as String?, language.keywords.contains(word) {
                    out.append(Span(range: NSRange(location: i, length: j - i), kind: .keyword))
                }
                i = j
                continue
            }
            i += 1
        }
        return out
    }

    static func plain(_ text: String, colors: CodeColors) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        return NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: colors.ink, .paragraphStyle: paragraph])
    }

    /// The text in its language's colours; plain when the language is not known or the file is very long.
    static func attributed(_ text: String, path: String, colors: CodeColors) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: plain(text, colors: colors))
        guard text.utf16.count <= limit, let language = language(for: path) else { return out }
        for span in spans(text, language: language) {
            switch span.kind {
            case .comment: out.addAttribute(.foregroundColor, value: colors.comment, range: span.range)
            case .string: out.addAttribute(.foregroundColor, value: colors.string, range: span.range)
            case .number: out.addAttribute(.foregroundColor, value: colors.number, range: span.range)
            case .keyword:
                out.addAttribute(.foregroundColor, value: colors.keyword, range: span.range)
                if language.markdown { out.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold), range: span.range) }
            }
        }
        return out
    }
}
