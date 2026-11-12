import Foundation

/// What Claude Code is extended with on this Mac, and how much the sessions kept here used
/// each thing: `GET /v0/primitives` (`skit primitives`). Skills, agents, slash commands,
/// connectors, hooks, plugins, and the instructions and memory files.
public struct PrimitivesReport: Codable, Sendable, Equatable {
    /// Uses before this moment are not counted; nil counts every session kept.
    public var since: Date?
    /// Sessions the index keeps that were active in the period.
    public var sessions: Int
    @EmptyWhenNull public var kinds: [KindCount]
    @EmptyWhenNull public var items: [Item]
    /// The directories something was found in.
    @EmptyWhenNull public var lookedIn: [String]

    enum CodingKeys: String, CodingKey {
        case since, sessions, kinds, items
        case lookedIn = "looked_in"
    }

    /// One kind added up. `unused` is what was installed or on offer and not used; the engine
    /// does not count it for hooks (a quiet hook leaves no trace) or plugins.
    public struct KindCount: Codable, Sendable, Equatable {
        public var kind: String
        public var items: Int
        public var installed: Int
        public var used: Int
        public var unused: Int
    }

    /// One primitive: every place it is defined, and its use in the period.
    public struct Item: Codable, Sendable, Equatable, Identifiable {
        public var kind: String
        /// The name it is used by; for a connector the key its tools carry, for a memory file its path.
        public var name: String
        /// The name as a person wrote it, when `name` is a key made from it.
        public var title: String?
        public var description: String?
        /// False when no definition was found: it comes with Claude Code, or it is gone.
        public var installed: Bool
        public var builtIn: Bool?
        /// How Claude Code chooses among `definitions`, which are in that order:
        /// "user-first", "project-first", "local-first" or "merged" (all apply).
        public var order: String
        @EmptyWhenNull public var definitions: [Definition]
        public var usage: Usage
        /// The last use in any session kept, whatever the period.
        public var lastUsedAt: Date?
        /// Claude Code's own count (skills).
        public var counter: Counter?
        /// The sessions that used it, latest first: only when one item was asked for.
        @EmptyWhenNull public var sessions: [SessionUse]

        public var id: String { kind + "\u{0}" + name }

        enum CodingKeys: String, CodingKey {
            case kind, name, title, description, installed, order, definitions, usage, sessions
            case builtIn = "built_in"
            case lastUsedAt = "last_used_at"
            case counter = "claude_code_counter"
        }
    }

    /// One place a primitive is defined. `scope` is "managed", "user", "account", "plugin",
    /// "project" or "local"; `where` the project directory or the plugin.
    public struct Definition: Codable, Sendable, Equatable {
        public var scope: String
        public var `where`: String?
        public var path: String?
        public var description: String?
        public var bytes: Int?
        /// The lines of the file at `path`, when the definition is a file of its own.
        public var lines: Int?
        public var modified: Date?
        /// A hook's event, matcher and command; a connector's transport and host or program; a plugin's version.
        public var detail: [String: String]?
        /// Uses the transcripts tie to this very definition.
        public var calls: Int?
    }

    public struct Counter: Codable, Sendable, Equatable {
        public var uses: Int
        public var lastUsedAt: Date?

        enum CodingKeys: String, CodingKey {
            case uses
            case lastUsedAt = "last_used_at"
        }
    }

    public struct Usage: Codable, Sendable, Equatable {
        public var sessions: Int
        public var calls: Int
        public var errors: Int
        /// Calls the person typed as a slash command; the rest were the model's choice.
        public var byUser: Int
        public var seconds: Double
        public var outputTokens: Int
        public var firstAt: Date?
        public var lastAt: Date?
        /// Sessions that had it on offer.
        public var offeredSessions: Int
        public var offeredLastAt: Date?
        @EmptyWhenNull public var projects: [ProjectUse]
        @EmptyWhenNull public var days: [DayUse]

        enum CodingKeys: String, CodingKey {
            case sessions, calls, errors, seconds, projects, days
            case byUser = "by_user"
            case outputTokens = "output_tokens"
            case firstAt = "first_at"
            case lastAt = "last_at"
            case offeredSessions = "offered_sessions"
            case offeredLastAt = "offered_last_at"
        }
    }

    public struct ProjectUse: Codable, Sendable, Equatable {
        /// The slug Claude Code files the project's sessions under.
        public var project: String
        public var cwd: String?
        public var sessions: Int
        public var calls: Int
    }

    /// Uses on one UTC day ("2026-11-07").
    public struct DayUse: Codable, Sendable, Equatable {
        public var day: String
        public var calls: Int
    }

    public struct SessionUse: Codable, Sendable, Equatable, Identifiable {
        public var session: String
        public var title: String
        public var project: String
        public var cwd: String?
        public var calls: Int
        public var errors: Int
        public var byUser: Int
        public var seconds: Double
        public var firstAt: Date
        public var lastAt: Date
        /// The turn of the first use, -1 when it was outside one.
        public var turn: Int

        public var id: String { session }

        enum CodingKeys: String, CodingKey {
            case session, title, project, cwd, calls, errors, seconds, turn
            case byUser = "by_user"
            case firstAt = "first_at"
            case lastAt = "last_at"
        }
    }
}
