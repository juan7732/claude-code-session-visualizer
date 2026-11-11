import AppKit
import SkitKit
import UniformTypeIdentifiers

/// Getting a session out of the app: a Markdown file, a turn on the pasteboard,
/// a link that opens the app on a node. The Markdown is written by the engine
/// (`skit export`), so the CLI and the app produce the same text.
enum Exporter {
    /// Asks where, then writes the whole session as Markdown.
    static func saveSession(_ session: SessionSummary, store: AppStore) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = fileName(for: session.title, id: session.id)
        panel.title = "Export Session as Markdown"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let text = await store.markdown(session.id) else { return }
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
                store.notice = "Exported to \(url.lastPathComponent)."
            } catch {
                store.notice = "Could not write \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    /// Puts one turn on the pasteboard as Markdown.
    static func copyTurn(_ turn: Int, of sessionID: String, store: AppStore) {
        Task {
            guard let text = await store.markdown(sessionID, turn: turn) else { return }
            copy(text)
            store.notice = "Turn \(turn) copied as Markdown."
        }
    }

    /// Puts text on the pasteboard: the one place the app does (an id, a path, a link, a turn).
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// "Ergo-workspace-CLAUDE.md-setup.md": the title, safe for a file name.
    nonisolated static func fileName(for title: String, id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        var name = ""
        for scalar in title.unicodeScalars {
            if allowed.contains(scalar) { name.unicodeScalars.append(scalar) } else if !name.hasSuffix("-") { name += "-" }
        }
        name = String(name.trimmingCharacters(in: CharacterSet(charactersIn: "-.")).prefix(80))
        return (name.isEmpty ? Format.shortID(id) : name) + ".md"
    }
}

/// A link to a session, or to one node of it: `skit-visualizer://session/<id>?view=transcript&action=60`.
/// The bundled app registers the scheme; opening a link opens the app there.
nonisolated enum SessionLink {
    static let scheme = "skit-visualizer"

    struct Target: Equatable {
        var session: String
        var view: SessionView?
        var key: NodeKey?
    }

    static func url(session: String, view: SessionView? = nil, key: NodeKey? = nil) -> URL? {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "session"
        parts.path = "/" + session
        var items: [URLQueryItem] = []
        if let view { items.append(URLQueryItem(name: "view", value: view.rawValue)) }
        switch key {
        case .turn(let n): items.append(URLQueryItem(name: "turn", value: "\(n)"))
        case .action(let n), .work(let n): items.append(URLQueryItem(name: "action", value: "\(n)"))
        case .tool(let id): items.append(URLQueryItem(name: "tool", value: id))
        case .subagent(let id): items.append(URLQueryItem(name: "subagent", value: id))
        case .step(let agent, let index):
            items.append(URLQueryItem(name: "subagent", value: agent))
            items.append(URLQueryItem(name: "step", value: "\(index)"))
        case .compaction(let n): items.append(URLQueryItem(name: "compaction", value: "\(n)"))
        case .file(let path): items.append(URLQueryItem(name: "file", value: path))
        case .outside(let id): items.append(URLQueryItem(name: "outside", value: id))
        case nil: break
        }
        if !items.isEmpty { parts.queryItems = items }
        return parts.url
    }

    static func parse(_ url: URL) -> Target? {
        guard url.scheme == scheme, url.host == "session",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let session = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !session.isEmpty, !session.contains("/") else { return nil }
        var query: [String: String] = [:]
        for item in parts.queryItems ?? [] { query[item.name] = item.value }
        var key: NodeKey?
        if let agent = query["subagent"] {
            key = query["step"].flatMap(Int.init).map { .step(agent: agent, index: $0) } ?? .subagent(agent)
        } else if let tool = query["tool"] {
            key = .tool(tool)
        } else if let n = query["action"].flatMap(Int.init) {
            key = .action(n)
        } else if let n = query["turn"].flatMap(Int.init) {
            key = .turn(n)
        } else if let n = query["compaction"].flatMap(Int.init) {
            key = .compaction(n)
        } else if let path = query["file"] {
            key = .file(path)
        } else if let id = query["outside"] {
            key = .outside(id)
        }
        return Target(session: session, view: query["view"].flatMap(SessionView.init(rawValue:)), key: key)
    }
}
