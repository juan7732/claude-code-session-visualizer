import Foundation

/// The sessions at work and what each is doing at this moment: `GET /v0/now` (`skit now`).
/// The engine reads Claude Code's files about its running processes and the last records of
/// each transcript; the app asks every few seconds while it shows them.
public struct NowReport: Codable, Sendable, Equatable {
    /// The moment the engine looked.
    public var at: Date
    public var windowMinutes: Int
    /// Sessions that did something in the window, the latest first.
    @EmptyWhenNull public var sessions: [Session]
    /// Sessions whose process runs and that did nothing in the window.
    public var runningOutsideWindow: Int

    enum CodingKeys: String, CodingKey {
        case at, sessions
        case windowMinutes = "window_minutes"
        case runningOutsideWindow = "running_outside_window"
    }

    /// What a session is doing.
    public enum State: String, Codable, Sendable, Equatable {
        /// The model is being asked or is answering.
        case model
        /// One or more tool calls are running (a subagent is a tool call).
        case tool
        /// Claude Code says it waits for the person inside a turn: a permission, a question.
        case blocked
        /// The agent stopped, and subagents it started still run.
        case background
        /// The turn is over; it waits for the next prompt.
        case you
        /// No process runs it.
        case closed
        /// A state this app does not know yet.
        case unknown

        public init(from decoder: Decoder) throws {
            self = State(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public struct Session: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        /// The slug Claude Code files the session under; empty for a process with no transcript yet.
        public var project: String?
        /// Where the session started; `workDir` is where its last record was written from.
        public var cwd: String?
        public var workDir: String?
        public var title: String?
        /// A Claude Code process has the session open. `name`, `entrypoint`, `pid` and
        /// `processStatus` are that process's own.
        public var running: Bool
        public var name: String?
        public var entrypoint: String?
        public var pid: Int?
        public var processStatus: String?
        public var state: State
        /// When it began doing what `state` says.
        public var since: Date
        /// Claude Code's word for what a blocked session waits for.
        public var waitingFor: String?
        /// The calls running now, oldest first.
        @EmptyWhenNull public var tools: [Tool]
        public var subagentsRunning: Int?
        /// The first line of what the agent last said when it stopped.
        public var said: String?
        public var lastPrompt: String?
        public var lastAt: Date
        public var model: String?
        public var cache: Cache?
        public var bytes: Int?

        enum CodingKeys: String, CodingKey {
            case id, project, cwd, title, running, name, entrypoint, pid, state, since, tools, said, model, cache, bytes
            case workDir = "work_dir"
            case processStatus = "process_status"
            case waitingFor = "waiting_for"
            case subagentsRunning = "subagents_running"
            case lastPrompt = "last_prompt"
            case lastAt = "last_at"
        }
    }

    /// A tool call that has not come back.
    public struct Tool: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var summary: String?
        public var since: Date
    }

    /// The prompt cache as the session's last request left it.
    public struct Cache: Codable, Sendable, Equatable {
        public var readTokens: Int
        public var writtenTokens: Int
        public var uncachedTokens: Int
        /// The part of the last request's input that was read from the cache.
        public var hitRatio: Double
        /// What the next prompt pays for in full once the cache is gone.
        public var contextTokens: Int
        /// The lifetime of the last write: 300 or 3600 seconds, 0 when not known.
        public var ttlSeconds: Int
        public var lastRequestAt: Date
        /// The last request's time plus the lifetime; nil when the lifetime is not known.
        public var expiresAt: Date?
        public var secondsLeft: Int

        enum CodingKeys: String, CodingKey {
            case readTokens = "read_tokens"
            case writtenTokens = "written_tokens"
            case uncachedTokens = "uncached_tokens"
            case hitRatio = "hit_ratio"
            case contextTokens = "context_tokens"
            case ttlSeconds = "ttl_seconds"
            case lastRequestAt = "last_request_at"
            case expiresAt = "expires_at"
            case secondsLeft = "seconds_left"
        }
    }
}
