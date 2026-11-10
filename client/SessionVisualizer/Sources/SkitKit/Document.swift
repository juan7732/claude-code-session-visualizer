import Foundation

// The session document: `GET /v0/sessions/{id}`, what `skit show --json` prints.
// Everything a view of one session reads comes from here, from /relations, and
// (for the full text of one result) from /actions/{n}.

public struct SessionDocument: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String?
    public var cwd: String?
    public var gitBranch: String?
    /// How the session was started ("cli", "claude-vscode").
    @EmptyWhenNull public var entrypoints: [String]
    /// The Claude Code versions that wrote the transcript, in order.
    @EmptyWhenNull public var versions: [String]
    /// Every directory the session worked in; the first is where it started.
    @EmptyWhenNull public var cwds: [String]
    public var firstAt: Date
    public var lastAt: Date
    public var project: String?
    public var archivedOnly: Bool?
    public var partial: Bool?
    public var branches: Int?

    @EmptyWhenNull public var prompts: [Prompt]
    @EmptyWhenNull public var turns: [Turn]
    @EmptyWhenNull public var actions: [Action]
    @EmptyWhenNull public var toolCalls: [ToolCall]
    @EmptyWhenNull public var compactions: [Compaction]
    @EmptyWhenNull public var subagents: [Subagent]
    public var summary: SessionSummary

    enum CodingKeys: String, CodingKey {
        case id, title, cwd, cwds, entrypoints, versions, project, partial, branches
        case gitBranch = "git_branch"
        case firstAt = "first_at"
        case lastAt = "last_at"
        case archivedOnly = "archived_only"
        case prompts, turns, actions, compactions, subagents, summary
        case toolCalls = "tool_calls"
    }
}

/// One human message.
public struct Prompt: Codable, Sendable, Equatable {
    public var index: Int
    public var at: Date
    public var text: String
    public var images: Int
    /// Blocks the IDE or Claude Code injected around the prompt.
    @EmptyWhenNull public var context: [Block]
    public var rewound: Bool?
}

/// One turn of the conversation: a prompt (or a system message) and every
/// action the agent took until it stopped. The document repeats the prompt and
/// the actions inside each turn; here a turn refers to them by index.
public struct Turn: Codable, Sendable, Equatable {
    public var index: Int
    /// "human", or what else started the turn ("task_notification", "hook", "system").
    public var origin: String
    public var promptIndex: Int?
    public var startAt: Date
    public var endAt: Date
    public var actionIndexes: [Int]
    public var toolCalls: Int
    public var usage: Usage
    public var apiErrors: Int
    public var rewound: Bool

    public var isHuman: Bool { origin == "human" }
    public var duration: TimeInterval { max(0, endAt.timeIntervalSince(startAt)) }

    public init(index: Int, origin: String, promptIndex: Int?, startAt: Date, endAt: Date, actionIndexes: [Int], toolCalls: Int, usage: Usage, apiErrors: Int = 0, rewound: Bool = false) {
        self.index = index
        self.origin = origin
        self.promptIndex = promptIndex
        self.startAt = startAt
        self.endAt = endAt
        self.actionIndexes = actionIndexes
        self.toolCalls = toolCalls
        self.usage = usage
        self.apiErrors = apiErrors
        self.rewound = rewound
    }

    enum CodingKeys: String, CodingKey {
        case index, origin, prompt, actions, usage, rewound
        case startAt = "start_at"
        case endAt = "end_at"
        case toolCalls = "tool_calls"
        case apiErrors = "api_errors"
    }

    private struct Ref: Decodable {
        var index: Int
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        origin = try c.decode(String.self, forKey: .origin)
        promptIndex = try c.decodeIfPresent(Ref.self, forKey: .prompt)?.index
        startAt = try c.decode(Date.self, forKey: .startAt)
        endAt = try c.decode(Date.self, forKey: .endAt)
        actionIndexes = (try c.decodeIfPresent([Ref].self, forKey: .actions) ?? []).map(\.index)
        toolCalls = try c.decodeIfPresent(Int.self, forKey: .toolCalls) ?? 0
        usage = try c.decode(Usage.self, forKey: .usage)
        apiErrors = try c.decodeIfPresent(Int.self, forKey: .apiErrors) ?? 0
        rewound = try c.decodeIfPresent(Bool.self, forKey: .rewound) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(index, forKey: .index)
        try c.encode(origin, forKey: .origin)
        try c.encode(startAt, forKey: .startAt)
        try c.encode(endAt, forKey: .endAt)
        try c.encode(toolCalls, forKey: .toolCalls)
        try c.encode(usage, forKey: .usage)
    }
}

/// One step of an agent turn: one API request, its blocks in order.
public struct Action: Codable, Sendable, Equatable {
    public var index: Int
    public var turn: Int
    public var model: String
    public var at: Date
    public var stopReason: String?
    /// Written by Claude Code itself, not by the model ("api_error", "no_response", "other").
    public var synthetic: Bool?
    public var syntheticKind: String?
    public var rewound: Bool?
    public var cwd: String?
    public var usage: Usage
    @EmptyWhenNull public var blocks: [Block]

    enum CodingKeys: String, CodingKey {
        case index, turn, model, at, synthetic, rewound, cwd, usage, blocks
        case stopReason = "stop_reason"
        case syntheticKind = "synthetic_kind"
    }

    /// What the model wrote for the human to read.
    public var text: String {
        blocks.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n")
    }

    public var thinking: String {
        blocks.filter { $0.type == "thinking" }.compactMap(\.thinking).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The ids of the tool calls this action made, in order.
    public var toolUseIDs: [String] {
        blocks.filter { $0.type == "tool_use" }.compactMap(\.id)
    }

    /// Everything the model read for this request, cached or not.
    public var contextTokens: Int {
        usage.inputTokens + usage.cacheCreationInputTokens + usage.cacheReadInputTokens
    }
}

/// A content block: text, thinking, tool_use, tool_result, image, or a newer kind kept by its type.
public struct Block: Codable, Sendable, Equatable {
    public var type: String
    public var text: String?
    public var thinking: String?
    public var id: String?
    public var name: String?
    public var input: JSONValue?
}

/// A tool call with the fact of its answer. The full result is on `/actions/{n}`.
public struct ToolCall: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var input: JSONValue?
    public var at: Date
    /// When the result arrived; nil while unanswered.
    public var endedAt: Date?
    public var isError: Bool
    public var paired: Bool
    public var turn: Int
    public var action: Int
    /// The output was too large for the transcript and went to a file.
    public var spilled: String?
    /// The first line of what came back.
    public var resultHead: String?
    public var resultBytes: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, input, at, paired, turn, action, spilled
        case endedAt = "ended_at"
        case isError = "is_error"
        case resultHead = "result_head"
        case resultBytes = "result_bytes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        input = try c.decodeIfPresent(JSONValue.self, forKey: .input)
        at = try c.decode(Date.self, forKey: .at)
        // Go writes its zero time for "no result yet".
        let ended = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        endedAt = ended.flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        paired = try c.decodeIfPresent(Bool.self, forKey: .paired) ?? false
        turn = try c.decodeIfPresent(Int.self, forKey: .turn) ?? 0
        action = try c.decodeIfPresent(Int.self, forKey: .action) ?? 0
        spilled = try c.decodeIfPresent(String.self, forKey: .spilled)
        resultHead = try c.decodeIfPresent(String.self, forKey: .resultHead)
        resultBytes = try c.decodeIfPresent(Int.self, forKey: .resultBytes)
    }

    /// Seconds from the call to its result.
    public var duration: TimeInterval? {
        endedAt.map { max(0, $0.timeIntervalSince(at)) }
    }
}

/// A compaction: where the context was cut and the summary the model continued from.
public struct Compaction: Codable, Sendable, Equatable {
    public var at: Date
    public var metadata: Metadata?
    public var summary: String?

    public struct Metadata: Codable, Sendable, Equatable {
        public var trigger: String?
        public var preTokens: Int?
        public var postTokens: Int?
        public var cumulativeDroppedTokens: Int?
    }
}

/// A subagent's own transcript, nested under the Agent call that spawned it.
public struct Subagent: Codable, Sendable, Equatable, Identifiable {
    public var agentId: String
    public var toolUseId: String?
    public var meta: Meta?
    public var session: Run?

    public var id: String { agentId }

    public struct Meta: Codable, Sendable, Equatable {
        public var agentType: String?
        public var description: String?
        public var model: String?
        public var finished: Bool?
    }

    /// The subagent's steps: the same shapes as the parent's, one level down.
    public struct Run: Codable, Sendable, Equatable {
        public var firstAt: Date
        public var lastAt: Date
        @EmptyWhenNull public var actions: [Action]
        @EmptyWhenNull public var toolCalls: [ToolCall]

        enum CodingKeys: String, CodingKey {
            case actions
            case firstAt = "first_at"
            case lastAt = "last_at"
            case toolCalls = "tool_calls"
        }
    }

    enum CodingKeys: String, CodingKey {
        case meta, session
        case agentId = "agent_id"
        case toolUseId = "tool_use_id"
    }
}

/// `GET /v0/sessions/{id}/actions/{n}`: one action with the full text of its results.
public struct ActionDetail: Codable, Sendable, Equatable {
    public var index: Int
    public var turn: Int
    public var thinking: String?
    @EmptyWhenNull public var toolCalls: [Result]

    public struct Result: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var result: String?
        /// "transcript", or the path of the file a large output was spilled to.
        public var resultSource: String?

        enum CodingKeys: String, CodingKey {
            case id, name, result
            case resultSource = "result_source"
        }
    }

    enum CodingKeys: String, CodingKey {
        case index, turn, thinking
        case toolCalls = "tool_calls"
    }
}

/// `GET /v0/sessions/{id}/relations`: what is connected to what, derived by the engine.
public struct Relations: Codable, Sendable, Equatable {
    @EmptyWhenNull public var spans: [Span]
    @EmptyWhenNull public var tasks: [BackgroundTask]
    @EmptyWhenNull public var handbacks: [Handback]
    @EmptyWhenNull public var retries: [Retry]
    @EmptyWhenNull public var files: [FileTouched]
    @EmptyWhenNull public var outside: [Outside]
    @EmptyWhenNull public var commits: [Commit]
    @EmptyWhenNull public var events: [Event]

    public init(spans: [Span] = [], tasks: [BackgroundTask] = [], handbacks: [Handback] = [], retries: [Retry] = [],
                files: [FileTouched] = [], outside: [Outside] = [], commits: [Commit] = [], events: [Event] = []) {
        self.spans = spans
        self.tasks = tasks
        self.handbacks = handbacks
        self.retries = retries
        self.files = files
        self.outside = outside
        self.commits = commits
        self.events = events
    }

    /// A file the session read or wrote, with every call that touched it, in order.
    public struct FileTouched: Codable, Sendable, Equatable, Identifiable {
        public var path: String
        public var writes: Int
        /// In how many turns it was touched.
        public var turns: Int
        @EmptyWhenNull public var touches: [Touch]

        public var id: String { path }

        public struct Touch: Codable, Sendable, Equatable {
            public var toolId: String
            public var action: Int
            public var turn: Int
            public var at: Date
            /// "read" or "write"
            public var mode: String
            public var tool: String

            enum CodingKeys: String, CodingKey {
                case action, turn, at, mode, tool
                case toolId = "tool_id"
            }
        }
    }

    /// A service beyond the machine: a web host, the web search, a skill, a connector.
    public struct Outside: Codable, Sendable, Equatable, Identifiable {
        /// "web", "search", "skill", "connector"
        public var kind: String
        public var name: String
        @EmptyWhenNull public var calls: [CallRef]

        public var id: String { kind + ":" + name }
    }

    /// A git commit the session made: a `git commit` that did not fail. The id
    /// is there when the output named it (agents often commit quietly).
    public struct Commit: Codable, Sendable, Equatable {
        public var sha: String?
        public var branch: String?
        public var subject: String
        public var call: CallRef
    }

    /// When an action's model stopped writing, when its tools finished, when the next began.
    public struct Span: Codable, Sendable, Equatable {
        public var action: Int
        public var turn: Int
        public var at: Date
        public var genEnd: Date
        public var toolsEnd: Date
        public var end: Date
        /// The action's text was said to the human (the turn stopped on it).
        public var said: Bool?

        enum CodingKeys: String, CodingKey {
            case action, turn, at, end, said
            case genEnd = "gen_end"
            case toolsEnd = "tools_end"
        }
    }

    public struct CallRef: Codable, Sendable, Equatable {
        public var toolId: String
        public var action: Int
        public var turn: Int
        public var at: Date

        enum CodingKeys: String, CodingKey {
            case action, turn, at
            case toolId = "tool_id"
        }
    }

    /// A command started in the background, and every later call that read it.
    public struct BackgroundTask: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var label: String?
        public var launch: CallRef
        @EmptyWhenNull public var pickups: [CallRef]
        public var stop: CallRef?
        public var output: String?
    }

    /// A subagent finishing and the parent action that started after it.
    public struct Handback: Codable, Sendable, Equatable {
        public var agentId: String
        public var spawn: CallRef
        public var endedAt: Date
        public var action: Int
        public var message: String?

        enum CodingKeys: String, CodingKey {
            case spawn, action, message
            case agentId = "agent_id"
            case endedAt = "ended_at"
        }
    }

    /// A failed tool call and the next call of the same tool in the turn.
    public struct Retry: Codable, Sendable, Equatable {
        public var failed: CallRef
        public var retry: CallRef
    }

    /// An API error, or a message Claude Code wrote itself.
    public struct Event: Codable, Sendable, Equatable {
        public var kind: String
        public var at: Date
        public var turn: Int
        public var action: Int?
        public var message: String?
    }
}

/// `GET /v0/sessions/{id}/compactions/{n}`: what a compaction did to the context.
public struct CompactionDetail: Codable, Sendable, Equatable {
    public var index: Int
    public var turn: Int
    public var at: Date
    public var trigger: String?
    public var durationMs: Int?
    public var preTokens: Int
    public var postTokens: Int
    public var cumulativeDropped: Int?
    /// The last action before the cut and the context it read; -1 when there was none.
    public var lastActionBefore: Int?
    public var contextBefore: Int?
    public var firstActionAfter: Int?
    public var contextAfter: Int?
    public var reinjectedChars: Int?
    public var summarisedPrompts: Int?
    public var summary: Summary?
    /// Messages kept word for word across the cut.
    @EmptyWhenNull public var preserved: [Piece]
    /// What Claude Code put back after the cut: instructions, files, reminders.
    @EmptyWhenNull public var reinjected: [Piece]
    /// Files the model was told to read again.
    @EmptyWhenNull public var fileRefs: [String]

    public struct Summary: Codable, Sendable, Equatable {
        public var chars: Int
        @EmptyWhenNull public var sections: [Section]

        public struct Section: Codable, Sendable, Equatable {
            public var title: String
            public var chars: Int
        }
    }

    public struct Piece: Codable, Sendable, Equatable {
        public var type: String
        public var role: String?
        public var kind: String?
        public var turn: Int?
        public var action: Int?
        public var chars: Int
        public var head: String?
    }

    enum CodingKeys: String, CodingKey {
        case index, turn, at, trigger, summary, preserved, reinjected
        case durationMs = "duration_ms"
        case preTokens = "pre_tokens"
        case postTokens = "post_tokens"
        case cumulativeDropped = "cumulative_dropped"
        case lastActionBefore = "last_action_before"
        case contextBefore = "context_before"
        case firstActionAfter = "first_action_after"
        case contextAfter = "context_after"
        case reinjectedChars = "reinjected_chars"
        case summarisedPrompts = "summarised_prompts"
        case fileRefs = "file_refs"
    }
}

/// One hit of `GET /v0/search`.
public struct SearchHit: Codable, Sendable, Equatable {
    public var session: String
    public var project: String?
    public var title: String?
    public var agent: String?
    /// The agent turn; -1 for session-level pieces.
    public var turn: Int
    /// The action; -1 for prompts and summaries.
    public var action: Int
    /// prompt | assistant | thinking | tool_use | tool_result | context | summary
    public var kind: String
    public var tool: String?
    public var at: Date?
    /// The matching text with the words between « and ».
    public var snippet: String
    /// Why it is here: "keyword" (it has the words) or "meaning".
    public var match: String?

    public init(session: String, project: String? = nil, title: String? = nil, agent: String? = nil, turn: Int, action: Int,
                kind: String, tool: String? = nil, at: Date? = nil, snippet: String, match: String? = nil) {
        self.session = session
        self.project = project
        self.title = title
        self.agent = agent
        self.turn = turn
        self.action = action
        self.kind = kind
        self.tool = tool
        self.at = at
        self.snippet = snippet
        self.match = match
    }
}
