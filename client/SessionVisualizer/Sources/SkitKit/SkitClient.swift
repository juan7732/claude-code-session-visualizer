import Foundation

/// What went wrong talking to the engine.
public enum SkitError: Error, Equatable, CustomStringConvertible {
    /// Nothing is listening on the socket: no engine is running.
    case unreachable(String)
    /// An engine is listening and did not answer in time: it is busy, or stuck.
    case timedOut(String)
    /// The exchange itself failed: the connection broke, or the answer was cut short or was not HTTP.
    case transport(String)
    /// The engine answered with an error (`{"error": "..."}`).
    case engine(status: Int, message: String)
    /// The engine answered with something this client cannot read: the contract broke.
    case undecodable(path: String, detail: String)

    public var description: String {
        switch self {
        case .unreachable(let why), .timedOut(let why), .transport(let why): why
        case .engine(_, let message): message
        case .undecodable(let path, let detail): "\(path): \(detail)"
        }
    }

    /// A transport failure as the app tells them apart: nobody home, slow, or broken.
    init(_ failure: UnixHTTP.Failure) {
        switch failure {
        case .notListening: self = .unreachable(failure.description)
        case .timedOut: self = .timedOut(failure.description)
        case .pathTooLong, .io, .malformedResponse, .incomplete: self = .transport(failure.description)
        }
    }
}

/// Work that blocks its thread (a socket, a child process), kept off Swift's cooperative pool:
/// that pool has one thread per core, and a few calls waiting on a slow engine would stall every
/// other task in the app.
public enum Blocking {
    private static let queue = DispatchQueue(label: "dev.sessionkit.blocking", qos: .userInitiated, attributes: .concurrent)

    public static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}

/// The typed client for `skit serve`: one method per /v0 route the app uses.
/// It never parses a transcript and never derives anything: what a view needs
/// and /v0 does not serve becomes a route in the engine first.
public struct SkitClient: Sendable {
    public let http: UnixHTTP

    /// `timeout`: seconds to wait for an answer. Thirty for what a person asked for (a long session
    /// is megabytes to write); the polls that keep the lists current use `quick`.
    public init(socketPath: String, timeout: TimeInterval = 30) {
        self.http = UnixHTTP(socketPath: socketPath, timeout: timeout)
    }

    /// The same client, giving up after `timeout` seconds: for a poll, where a late answer is worth nothing.
    public func quick(timeout: TimeInterval = 5) -> SkitClient {
        SkitClient(socketPath: http.socketPath, timeout: timeout)
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
        "GET /v0/sessions/{id}/time",
        "GET /v0/sessions/{id}/images",
        "GET /v0/sessions/{id}/images/{n}",
        "GET /v0/overview",
        "GET /v0/claude",
        "GET /v0/primitives",
        "GET /v0/now",
        "GET /v0/file",
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

    /// Every session added up, or the sessions of one project (its slug, exactly).
    public func overview(project slug: String? = nil) async throws -> Overview {
        try await get("/v0/overview" + (slug.map { "?slug=" + Self.escape($0) } ?? ""))
    }

    /// How Claude Code is configured on this Mac: settings by layer, experiments, flags, projects, memory, skills.
    public func claude() async throws -> ClaudeSnapshot { try await get("/v0/claude") }

    /// The sessions at work in the last `minutes` (nil: the engine's hour) and what each is doing now.
    public func now(minutes: Int? = nil) async throws -> NowReport {
        try await get("/v0/now" + (minutes.map { "?minutes=\($0)" } ?? ""))
    }

    /// What Claude Code is extended with and how much it is used, over the last `days` days (nil: every session kept).
    public func primitives(days: Int? = nil) async throws -> PrimitivesReport {
        try await get("/v0/primitives" + (days.map { "?days=\($0)" } ?? ""))
    }

    /// One primitive with the sessions that used it. Nil when the engine knows none by that name.
    public func primitive(kind: String, name: String, days: Int? = nil) async throws -> PrimitivesReport.Item? {
        let report: PrimitivesReport = try await get("/v0/primitives?kind=" + Self.escape(kind) + "&name=" + Self.escape(name) + (days.map { "&days=\($0)" } ?? ""))
        return report.items.first
    }

    /// A file a session touched, as it is now, with the sessions that touched it. `path` is the
    /// path as `session` wrote it, or where the file is on disk.
    public func file(path: String, session id: String? = nil, text: Bool = true) async throws -> FileView {
        try await get("/v0/file?path=" + Self.escape(path) + (id.map { "&session=" + Self.escape($0) } ?? "") + (text ? "" : "&text=0"))
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

    /// Every image pasted into a prompt or returned by a tool, without the bytes.
    public func images(session id: String) async throws -> [SessionImage] {
        try await get("/v0/sessions/\(Self.escape(id))/images")
    }

    /// One image's bytes, as the transcript holds them.
    public func image(session id: String, _ index: Int) async throws -> Data {
        try await call("GET", "/v0/sessions/\(Self.escape(id))/images/\(index)") { $0 }
    }

    /// Where the session's wall time went, with the `top` slowest calls and longest waits.
    public func time(session id: String, top: Int? = nil) async throws -> SessionTime {
        try await get("/v0/sessions/\(Self.escape(id))/time" + (top.map { "?top=\($0)" } ?? ""))
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
        // The transport blocks on the socket: off the caller's actor, and off the cooperative pool.
        return try await Blocking.run {
            let response: UnixHTTP.Response
            do {
                response = try http.send(method: method, path: path, body: body)
            } catch let failure as UnixHTTP.Failure {
                throw SkitError(failure)
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
        }
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
