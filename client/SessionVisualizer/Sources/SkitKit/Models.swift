import Foundation

// The shapes `skit serve` returns under /v0, as far as the client reads them.
// They are the CLI's `--json` shapes (ADR 0004): fields are only ever added, so
// anything newer than the first /v0 is optional here and an older engine still
// decodes.
//
// Keys are spelled out in CodingKeys instead of using the decoder's snake_case
// conversion: that conversion also rewrites dictionary keys, and note keys
// ("tool:toolu_01AbC") and session ids must arrive exactly as written.

/// A list that an older engine may send as `null` (Go's empty slice) or leave
/// out. Either way it is empty here, so a view never has to ask.
@propertyWrapper
public struct EmptyWhenNull<Element: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public var wrappedValue: [Element]

    public init(wrappedValue: [Element]) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = container.decodeNil() ? [] : try container.decode([Element].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    /// A missing key is an empty list too.
    public func decode<Element>(_ type: EmptyWhenNull<Element>.Type, forKey key: Key) throws -> EmptyWhenNull<Element> {
        try decodeIfPresent(type, forKey: key) ?? EmptyWhenNull(wrappedValue: [])
    }
}

/// `GET /v0`: the routes this engine serves.
public struct RouteList: Codable, Sendable, Equatable {
    public var version: String
    public var routes: [String]
}

/// `GET /v0/status`.
public struct EngineStatus: Codable, Sendable, Equatable {
    public var version: String
    public var uptime: String
    public var claudeDir: String
    public var skitHome: String
    public var index: IndexCounts
    @EmptyWhenNull public var live: [LiveSession]
    public var sessionsOnDisk: Int
    public var cachedSessions: Int?

    enum CodingKeys: String, CodingKey {
        case version
        case uptime
        case claudeDir = "claude_dir"
        case skitHome = "skit_home"
        case index
        case live
        case sessionsOnDisk = "sessions_on_disk"
        case cachedSessions = "cached_sessions"
    }
}

public struct IndexCounts: Codable, Sendable, Equatable {
    public var sessions: Int
    public var archived: Int
    public var segments: Int
    public var bytes: Int64
}

/// A running Claude Code process, from `~/.claude/sessions/<pid>.json`.
public struct LiveSession: Codable, Sendable, Equatable, Identifiable {
    public var pid: Int
    public var sessionId: String?
    public var cwd: String?
    public var name: String?
    public var status: String?
    public var version: String?
    public var id: Int { pid }
}

/// A session's numbers: one row of `GET /v0/sessions`, and with the context
/// curve, `GET /v0/sessions/{id}/stats`.
public struct SessionSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var path: String?
    public var project: String?
    public var title: String
    public var slug: String?
    public var cwd: String?
    public var cwds: [String]?
    public var gitBranch: String?
    public var claudeCodeVersions: [String]?
    public var firstAt: Date
    public var lastAt: Date
    public var duration: String
    /// The part of `duration` spent inside turns; the rest waited for the human.
    public var inTurns: String?
    public var partial: Bool?

    public var prompts: Int
    public var turns: Int
    public var systemTurns: Int
    public var rewoundTurns: Int?
    public var rewoundActions: Int?
    /// API requests: the session's actions, subagents included.
    public var requests: Int
    public var toolCalls: Int
    public var toolErrors: Int
    public var images: Int
    public var compactions: Int
    public var apiErrors: Int
    public var subagents: Int
    public var branches: Int
    /// Blocks the IDE or Claude Code injected into prompts; attachments it added.
    public var injectedBlocks: Int?
    public var attachments: Int?

    public var usage: Usage
    public var cacheHitRatio: Double
    @EmptyWhenNull public var models: [NameCount]
    @EmptyWhenNull public var tools: [ToolCount]
    public var compactionList: [CompactionInfo]?

    /// Claude Code's own figure, when the transcript carries one.
    public var claudeCodeCostUsd: Double?
    public var linesAdded: Int?
    public var linesRemoved: Int?

    /// The context-window size at each action, in order (stats only).
    public var context: [ContextPoint]?
    /// The source transcript is gone; this row comes from the archive.
    public var archivedOnly: Bool?
    /// How many actions each prompt of the human's started, in order.
    public var shape: [Int]?
    /// Where the wall time went, in seconds (`skit time`, without its lists).
    public var time: TimeTotals?

    enum CodingKeys: String, CodingKey {
        case id
        case path
        case project
        case title
        case slug
        case cwd
        case cwds
        case gitBranch = "git_branch"
        case claudeCodeVersions = "claude_code_versions"
        case firstAt = "first_at"
        case lastAt = "last_at"
        case duration
        case inTurns = "in_turns"
        case partial
        case prompts
        case turns
        case systemTurns = "system_turns"
        case rewoundTurns = "rewound_turns"
        case rewoundActions = "rewound_actions"
        case requests
        case toolCalls = "tool_calls"
        case toolErrors = "tool_errors"
        case images
        case compactions
        case apiErrors = "api_errors"
        case subagents
        case branches
        case injectedBlocks = "injected_blocks"
        case attachments
        case usage
        case cacheHitRatio = "cache_hit_ratio"
        case models
        case tools
        case compactionList = "compaction_list"
        case claudeCodeCostUsd = "claude_code_cost_usd"
        case linesAdded = "lines_added"
        case linesRemoved = "lines_removed"
        case context
        case archivedOnly = "archived_only"
        case shape
        case time
    }
}

public struct Usage: Codable, Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationInputTokens: Int
    public var cacheReadInputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheCreationInputTokens: Int = 0, cacheReadInputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }
}

public struct NameCount: Codable, Sendable, Equatable {
    public var name: String
    public var count: Int
}

public struct ToolCount: Codable, Sendable, Equatable {
    public var name: String
    public var calls: Int
    public var errors: Int
}

public struct CompactionInfo: Codable, Sendable, Equatable {
    public var at: Date
    public var trigger: String?
    public var preTokens: Int
    public var postTokens: Int

    enum CodingKeys: String, CodingKey {
        case at
        case trigger
        case preTokens = "pre_tokens"
        case postTokens = "post_tokens"
    }
}

public struct ContextPoint: Codable, Sendable, Equatable {
    public var index: Int
    public var turn: Int
    public var at: Date
    public var tokens: Int
    public var cacheRead: Int
    public var output: Int

    enum CodingKeys: String, CodingKey {
        case index
        case turn
        case at
        case tokens
        case cacheRead = "cache_read"
        case output
    }
}

/// What the human added to a session: `GET /v0/sessions/{id}/annotations`.
public struct Annotation: Codable, Sendable, Equatable {
    public var pinned: Bool
    @EmptyWhenNull public var tags: [String]
    /// Keyed by what the note is about: "session", "turn:3", "action:60", "tool:<id>".
    public var notes: [String: String]
    public var updatedAt: Date?

    public init(pinned: Bool = false, tags: [String] = [], notes: [String: String] = [:], updatedAt: Date? = nil) {
        self.pinned = pinned
        self.tags = tags
        self.notes = notes
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        _tags = try container.decode(EmptyWhenNull<String>.self, forKey: .tags)
        notes = try container.decodeIfPresent([String: String].self, forKey: .notes) ?? [:]
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case pinned
        case tags
        case notes
        case updatedAt = "updated_at"
    }
}

/// The body of `PATCH /v0/sessions/{id}/annotations`. Nil fields are left alone;
/// a note set to "" is removed.
public struct AnnotationPatch: Codable, Sendable, Equatable {
    public var pinned: Bool?
    public var addTags: [String]?
    public var removeTags: [String]?
    public var notes: [String: String]?

    public init(pinned: Bool? = nil, addTags: [String]? = nil, removeTags: [String]? = nil, notes: [String: String]? = nil) {
        self.pinned = pinned
        self.addTags = addTags
        self.removeTags = removeTags
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case pinned
        case addTags = "add_tags"
        case removeTags = "remove_tags"
        case notes
    }
}

/// One result of `POST /v0/archive`.
public struct ArchiveResult: Codable, Sendable, Equatable {
    public var id: String
    public var project: String
    /// archived | updated | unchanged | failed
    public var action: String
    public var records: Int
    public var bytes: Int64
    public var path: String
    public var kept: [String]?
}

/// `skit service status --json`: the background agent that keeps `skit serve` running.
public struct ServiceStatus: Codable, Sendable, Equatable {
    public var supported: Bool
    public var installed: Bool
    public var running: Bool
    public var pid: Int?
    public var label: String
    public var plist: String?
    public var binary: String?
    public var binaryExists: Bool?
    public var log: String?
    public var detail: String?

    enum CodingKeys: String, CodingKey {
        case supported
        case installed
        case running
        case pid
        case label
        case plist
        case binary
        case binaryExists = "binary_exists"
        case log
        case detail
    }
}

/// Where a session's wall time went: `GET /v0/sessions/{id}/time` (`skit time`).
/// Seconds throughout, and the parts add up: the wall is waiting for you,
/// waiting for background work and the turns; the turns are the model, tools,
/// subagents and waiting for a hand-back.
public struct SessionTime: Codable, Sendable, Equatable {
    public var id: String
    public var firstAt: Date
    public var lastAt: Date
    public var wall: Double
    /// Outside turns, before a prompt of the human's.
    public var waitingForYou: Double
    /// Outside turns, before a turn a notification started.
    public var waitingForBackground: Double
    public var inTurns: Split
    @EmptyWhenNull public var turns: [TurnTime]
    @EmptyWhenNull public var slowestCalls: [SlowCall]
    @EmptyWhenNull public var longestWaits: [Wait]

    enum CodingKeys: String, CodingKey {
        case id, turns
        case firstAt = "first_at"
        case lastAt = "last_at"
        case wall = "wall_seconds"
        case waitingForYou = "waiting_for_you_seconds"
        case waitingForBackground = "waiting_for_background_seconds"
        case inTurns = "in_turns"
        case slowestCalls = "slowest_calls"
        case longestWaits = "longest_waits"
    }

    /// Time inside turns. The model: waiting for its response, thinking and
    /// writing. Tools: calls running, a wait for permission included. Waiting:
    /// after the agent spoke, until a hand-back or a notification.
    public struct Split: Codable, Sendable, Equatable {
        public var seconds: Double
        public var model: Double
        public var tools: Double
        public var subagents: Double
        public var waiting: Double

        enum CodingKeys: String, CodingKey {
            case seconds
            case model = "model_seconds"
            case tools = "tools_seconds"
            case subagents = "subagents_seconds"
            case waiting = "waiting_seconds"
        }
    }

    public struct TurnTime: Codable, Sendable, Equatable {
        public var turn: Int
        public var origin: String
        public var at: Date
        public var end: Date
        public var actions: Int
        public var seconds: Double
        public var model: Double
        public var tools: Double
        public var subagents: Double
        public var waiting: Double

        enum CodingKeys: String, CodingKey {
            case turn, origin, at, end, actions, seconds
            case model = "model_seconds"
            case tools = "tools_seconds"
            case subagents = "subagents_seconds"
            case waiting = "waiting_seconds"
        }
    }

    public struct SlowCall: Codable, Sendable, Equatable {
        public var toolId: String
        public var action: Int
        public var turn: Int
        public var at: Date
        public var name: String
        public var summary: String?
        public var seconds: Double
        public var subagent: Bool?
        public var isError: Bool?

        enum CodingKeys: String, CodingKey {
            case action, turn, at, name, summary, seconds, subagent
            case toolId = "tool_id"
            case isError = "is_error"
        }
    }

    /// A stretch between two turns; `whom` is "you" or "background".
    public struct Wait: Codable, Sendable, Equatable {
        public var afterTurn: Int
        public var beforeTurn: Int
        public var at: Date
        public var end: Date
        public var seconds: Double
        public var whom: String

        enum CodingKeys: String, CodingKey {
            case at, end, seconds
            case afterTurn = "after_turn"
            case beforeTurn = "before_turn"
            case whom = "for"
        }
    }
}

/// An image in a session, without its bytes: `GET /v0/sessions/{id}/images` (`skit images`).
/// The bytes are on `/images/{index}`.
public struct SessionImage: Codable, Sendable, Equatable, Identifiable {
    public var index: Int
    public var turn: Int
    public var at: Date
    /// "prompt" (pasted or dropped by the human) or "tool_result" (a tool returned it).
    public var place: String
    public var toolId: String?
    public var mediaType: String
    /// Decoded size in bytes.
    public var size: Int

    public var id: Int { index }

    enum CodingKeys: String, CodingKey {
        case index, turn, at, size
        case place = "where"
        case toolId = "tool_id"
        case mediaType = "media_type"
    }
}

/// Every session added up: `GET /v0/overview` (`skit overview`). Made from the
/// summaries the index keeps; days are days in `timezone`, the engine's own.
public struct Overview: Codable, Sendable, Equatable {
    public var sessions: Int
    public var timezone: String
    public var totals: Totals
    @EmptyWhenNull public var projects: [Project]
    @EmptyWhenNull public var days: [Day]
    @EmptyWhenNull public var tools: [ToolCount]
    @EmptyWhenNull public var models: [NameCount]
    public var cacheHitRatio: Double
    public var cacheRead: Int
    public var time: TimeTotals
    /// Sessions summarised before the index kept activity and since gone from disk: in the totals, on no day.
    public var withoutActivity: Int

    enum CodingKeys: String, CodingKey {
        case sessions, timezone, totals, projects, days, tools, models, time
        case cacheHitRatio = "cache_hit_ratio"
        case cacheRead = "cache_read_tokens"
        case withoutActivity = "sessions_without_activity"
    }

    public struct Totals: Codable, Sendable, Equatable {
        public var turns: Int
        public var systemTurns: Int
        public var actions: Int
        public var toolCalls: Int
        public var toolErrors: Int
        public var outputTokens: Int
        public var subagents: Int
        public var compactions: Int
        public var images: Int
        public var apiErrors: Int
        /// Claude Code's own figure, over the sessions that recorded one.
        public var cost: Double
        public var sessionsWithCost: Int

        enum CodingKeys: String, CodingKey {
            case turns, actions, subagents, compactions, images
            case systemTurns = "system_turns"
            case toolCalls = "tool_calls"
            case toolErrors = "tool_errors"
            case outputTokens = "output_tokens"
            case apiErrors = "api_errors"
            case cost = "claude_code_cost_usd"
            case sessionsWithCost = "sessions_with_cost"
        }
    }

    /// One project's sessions added up. `project` is the slug Claude Code files it under.
    public struct Project: Codable, Sendable, Equatable, Identifiable {
        public var project: String
        public var cwd: String?
        public var sessions: Int
        public var actions: Int
        public var toolCalls: Int
        public var toolErrors: Int
        public var outputTokens: Int

        public var id: String { project }

        enum CodingKeys: String, CodingKey {
            case project, cwd, sessions, actions
            case toolCalls = "tool_calls"
            case toolErrors = "tool_errors"
            case outputTokens = "output_tokens"
        }
    }

    /// One day, as "2026-11-07", with the sessions that did something on it.
    public struct Day: Codable, Sendable, Equatable, Identifiable {
        public var day: String
        public var actions: Int
        public var toolCalls: Int
        public var toolErrors: Int
        public var outputTokens: Int
        @EmptyWhenNull public var sessions: [String]

        public var id: String { day }

        enum CodingKeys: String, CodingKey {
            case day, actions, sessions
            case toolCalls = "tool_calls"
            case toolErrors = "tool_errors"
            case outputTokens = "output_tokens"
        }
    }
}

/// The split of `skit time` in seconds, as a session's summary and the overview carry it.
public struct TimeTotals: Codable, Sendable, Equatable {
    public var wall: Double
    public var waitingForYou: Double
    public var waitingForBackground: Double
    public var seconds: Double
    public var model: Double
    public var tools: Double
    public var subagents: Double
    public var waiting: Double

    enum CodingKeys: String, CodingKey {
        case seconds
        case wall = "wall_seconds"
        case waitingForYou = "waiting_for_you_seconds"
        case waitingForBackground = "waiting_for_background_seconds"
        case model = "model_seconds"
        case tools = "tools_seconds"
        case subagents = "subagents_seconds"
        case waiting = "waiting_seconds"
    }
}

/// How Claude Code is set up on this Mac: `GET /v0/claude` (`skit claude`).
/// Read-only and whitelisted: the engine never copies the account, tokens or
/// ids; `identity` says only whether each is set.
public struct ClaudeSnapshot: Codable, Sendable, Equatable {
    public var claudeDir: String
    @EmptyWhenNull public var layers: [Layer]
    @EmptyWhenNull public var effective: [Setting]
    @EmptyWhenNull public var experiments: [Experiment]
    @EmptyWhenNull public var flags: [Flag]
    public var flagsCachedAt: Date?
    @EmptyWhenNull public var projects: [Project]
    @EmptyWhenNull public var connectors: [String]
    @EmptyWhenNull public var memory: [File]
    @EmptyWhenNull public var skills: [Skill]
    public var state: [String: JSONValue]?
    public var identity: [String: String]?

    enum CodingKeys: String, CodingKey {
        case layers, effective, experiments, flags, projects, connectors, memory, skills, state, identity
        case claudeDir = "claude_dir"
        case flagsCachedAt = "flags_cached_at"
    }

    /// One settings file, lowest precedence first in the list.
    public struct Layer: Codable, Sendable, Equatable {
        public var name: String
        public var path: String
        public var exists: Bool
        public var modified: Date?
        public var settings: [String: JSONValue]?
    }

    /// A setting as it is in effect: the layer that wins, and the ones it overrides.
    public struct Setting: Codable, Sendable, Equatable {
        public var key: String
        public var value: JSONValue
        public var from: String
        @EmptyWhenNull public var also: [String]
    }

    /// An experiment this install is assigned to. Variation 0 is the control group.
    public struct Experiment: Codable, Sendable, Equatable {
        public var flag: String
        public var experimentId: String
        public var variationId: Int
        public var value: JSONValue

        enum CodingKeys: String, CodingKey {
            case flag, value
            case experimentId = "experiment_id"
            case variationId = "variation_id"
        }
    }

    public struct Flag: Codable, Sendable, Equatable {
        public var key: String
        public var value: JSONValue
        public var inExperiment: Bool?

        enum CodingKeys: String, CodingKey {
            case key, value
            case inExperiment = "in_experiment"
        }
    }

    public struct Project: Codable, Sendable, Equatable {
        public var path: String
        public var allowedTools: Int
        @EmptyWhenNull public var mcpServers: [String]
        public var trusted: Bool

        enum CodingKeys: String, CodingKey {
            case path, trusted
            case allowedTools = "allowed_tools"
            case mcpServers = "mcp_servers"
        }
    }

    public struct File: Codable, Sendable, Equatable {
        public var path: String
        public var bytes: Int
        public var lines: Int
        public var modified: Date
    }

    public struct Skill: Codable, Sendable, Equatable {
        public var name: String
        public var path: String?
        public var uses: Int?
        public var onDisk: Bool

        enum CodingKeys: String, CodingKey {
            case name, path, uses
            case onDisk = "on_disk"
        }
    }
}
