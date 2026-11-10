import Foundation

/// What went wrong talking to the engine.
public enum SkitError: Error, Equatable, CustomStringConvertible {
    /// Nothing answers on the socket.
    case unreachable(String)
    /// The engine answered with an error (`{"error": "..."}`).
    case engine(status: Int, message: String)
    /// The engine answered with something this client cannot read: the contract broke.
    case undecodable(path: String, detail: String)

    public var description: String {
        switch self {
        case .unreachable(let why): why
        case .engine(_, let message): message
        case .undecodable(let path, let detail): "\(path): \(detail)"
        }
    }
}

/// The typed client for `skit serve`: one method per /v0 route the app uses.
/// It never parses a transcript and never derives anything: what a view needs
/// and /v0 does not serve becomes a route in the engine first.
public struct SkitClient: Sendable {
    public let http: UnixHTTP

    public init(socketPath: String) {
        self.http = UnixHTTP(socketPath: socketPath)
    }

    /// The routes this build of the client calls. An engine without one of them
    /// is too old for it (`missingRoutes`).
    public static let requiredRoutes = [
        "GET /v0/status",
        "GET /v0/sessions",
        "GET /v0/sessions/{id}",
        "GET /v0/sessions/{id}/stats",
        "GET /v0/sessions/{id}/actions/{n}",
        "GET /v0/sessions/{id}/relations",
        "GET /v0/sessions/{id}/compactions/{n}",
        "GET /v0/sessions/{id}/export",
        "GET /v0/search",
        "GET /v0/sessions/{id}/annotations",
        "PATCH /v0/sessions/{id}/annotations",
        "GET /v0/annotations",
        "POST /v0/archive",
    ]

    /// The required routes `served` lacks. Query strings in the listing are ignored.
    public static func missingRoutes(in served: [String]) -> [String] {
        let have = Set(served.map { String($0.prefix { $0 != "?" }) })
        return requiredRoutes.filter { !have.contains($0) }
    }

    public func routes() async throws -> RouteList { try await get("/v0") }
    public func status() async throws -> EngineStatus { try await get("/v0/status") }

    public func sessions(project: String? = nil, limit: Int? = nil) async throws -> [SessionSummary] {
        var query: [String] = []
        if let project, !project.isEmpty { query.append("project=" + Self.escape(project)) }
        if let limit { query.append("limit=\(limit)") }
        return try await get("/v0/sessions" + (query.isEmpty ? "" : "?" + query.joined(separator: "&")))
    }

    public func stats(session id: String) async throws -> SessionSummary {
        try await get("/v0/sessions/\(Self.escape(id))/stats")
    }

    /// The whole session: prompts, turns, actions, tool calls, compactions, subagents.
    public func document(session id: String) async throws -> SessionDocument {
        try await get("/v0/sessions/\(Self.escape(id))")
    }

    /// One action with the full text of its tool results. With `agent`, action
    /// `index` of that subagent's own transcript.
    public func action(session id: String, _ index: Int, agent: String? = nil) async throws -> ActionDetail {
        try await get("/v0/sessions/\(Self.escape(id))/actions/\(index)" + (agent.map { "?agent=" + Self.escape($0) } ?? ""))
    }

    /// What compaction `index` did: the sizes, the summary's sections, what was kept and put back.
    public func compaction(session id: String, _ index: Int) async throws -> CompactionDetail {
        try await get("/v0/sessions/\(Self.escape(id))/compactions/\(index)")
    }

    /// The session, or one turn of it, as Markdown (`skit export`).
    public func markdown(session id: String, turn: Int? = nil) async throws -> String {
        try await call("GET", "/v0/sessions/\(Self.escape(id))/export?format=markdown" + (turn.map { "&turn=\($0)" } ?? "")) {
            String(decoding: $0, as: UTF8.self)
        }
    }

    public func relations(session id: String) async throws -> Relations {
        try await get("/v0/sessions/\(Self.escape(id))/relations")
    }

    /// Search across every archived session or inside one. `kind` narrows to
    /// prompt, assistant, thinking, tool_use or tool_result; `mode` is "keyword"
    /// (the default) or "meaning".
    public func search(_ query: String, session: String? = nil, kind: String? = nil, mode: String? = nil, limit: Int = 200) async throws -> [SearchHit] {
        var parts = ["q=" + Self.escape(query), "limit=\(limit)"]
        if let session { parts.append("session=" + Self.escape(session)) }
        if let kind, !kind.isEmpty { parts.append("kind=" + Self.escape(kind)) }
        if let mode, !mode.isEmpty { parts.append("mode=" + Self.escape(mode)) }
        return try await get("/v0/search?" + parts.joined(separator: "&"))
    }

    /// Every annotated session, keyed by session id.
    public func annotations() async throws -> [String: Annotation] {
        try await get("/v0/annotations")
    }

    public func annotation(session id: String) async throws -> Annotation {
        try await get("/v0/sessions/\(Self.escape(id))/annotations")
    }

    @discardableResult
    public func annotate(session id: String, _ patch: AnnotationPatch) async throws -> Annotation {
        try await send("PATCH", "/v0/sessions/\(Self.escape(id))/annotations", body: try JSONEncoder().encode(patch))
    }

    /// Archives the given sessions now (all of them when `ids` is empty).
    public func archive(ids: [String] = []) async throws -> [ArchiveResult] {
        try await send("POST", "/v0/archive", body: try JSONSerialization.data(withJSONObject: ["ids": ids]))
    }

    // MARK: -

    private func get<T: Decodable & Sendable>(_ path: String) async throws -> T {
        try await send("GET", path, body: nil)
    }

    private func send<T: Decodable & Sendable>(_ method: String, _ path: String, body: Data?) async throws -> T {
        try await call(method, path, body: body) { try JSONDecoder.skit().decode(T.self, from: $0) }
    }

    private func call<T: Sendable>(_ method: String, _ path: String, body: Data? = nil, decode: @escaping @Sendable (Data) throws -> T) async throws -> T {
        let http = self.http
        // The transport blocks on the socket; keep it off the caller's actor.
        return try await Task.detached(priority: .userInitiated) {
            let response: UnixHTTP.Response
            do {
                response = try http.send(method: method, path: path, body: body)
            } catch let failure as UnixHTTP.Failure {
                throw SkitError.unreachable(failure.description)
            }
            guard (200..<300).contains(response.status) else {
                let message = (try? JSONDecoder().decode([String: String].self, from: response.body))?["error"]
                throw SkitError.engine(status: response.status, message: message ?? "HTTP \(response.status)")
            }
            do {
                return try decode(response.body)
            } catch {
                throw SkitError.undecodable(path: path, detail: Self.describe(error))
            }
        }.value
    }

    static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return "\(error)" }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch decoding {
        case .keyNotFound(let key, let context): return "missing \"\(key.stringValue)\" at \(path(context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(context.debugDescription) at \(path(context))"
        @unknown default: return "\(decoding)"
        }
    }

    static func escape(_ component: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }
}
