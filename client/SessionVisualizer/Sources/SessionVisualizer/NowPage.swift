import SkitKit
import SwiftUI

/// The sessions at work (M20; there is no mock for it): a card for every
/// session that did something in the last hour, saying what it is doing at
/// this moment and how long its prompt cache will last. The engine is asked
/// every few seconds while the page shows (`skit now`); the clocks on the
/// cards count between two answers.
struct NowPage: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                switch store.now {
                case .loaded(let report):
                    if report.sessions.isEmpty {
                        Text(NowContent.nothing(report)).font(.system(size: 13)).foregroundStyle(palette.muted).padding(.top, 20)
                    } else {
                        // The cards count by themselves: a second is a redraw of a handful of cards.
                        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { clock in
                            // One lazy grid, and nothing lazy inside a card.
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340, maximum: 560), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                                ForEach(NowContent.ordered(report.sessions)) { session in
                                    NowCard(session: session, now: Snapshot.active ? report.at : clock.date)
                                }
                            }
                        }
                    }
                case .failed(let why):
                    Text(why).foregroundStyle(palette.err)
                case .loading, nil:
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: Metric.wideColumn, alignment: .leading)
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 60)
            .frame(maxWidth: .infinity)
        }
        .background(palette.bg)
        .task(id: store.nowMinutes) {
            while !Task.isCancelled {
                await store.loadNow()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Now").font(.display(28))
            HStack(spacing: 12) {
                if case .loaded(let report) = store.now {
                    Text(NowContent.stamp(report)).font(.system(size: 13)).foregroundStyle(palette.muted)
                }
                Spacer()
                @Bindable var store = store
                Picker("At work in", selection: $store.nowMinutes) {
                    Text("The last hour").tag(60)
                    Text("4 hours").tag(240)
                    Text("A day").tag(1440)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
        }
    }
}

private struct NowCard: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var session: NowReport.Session
    var now: Date
    @State private var hover = false

    var body: some View {
        // Two readings at two distances. The edge says whose move it is (at work, yours, closed) and
        // holds still; the line beside it says what kind of work, and changes hue with it.
        let edge = color(session)
        let activity = NowContent.activity(session)
        let tint = activity.map(hue) ?? edge
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                if let activity {
                    Image(systemName: NowContent.symbol(activity)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(tint).frame(width: 15)
                        .opacity(Int(now.timeIntervalSinceReferenceDate) % 2 == 0 ? 1 : 0.5)
                } else {
                    Circle().fill(tint).frame(width: 8, height: 8)
                }
                Text(NowContent.headline(session)).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(tint).lineLimit(1)
                Text(NowContent.elapsed(from: session.since, to: now) + (session.state == .closed ? " ago" : "")).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(palette.muted)
                Spacer(minLength: 4)
                Text(NowContent.place(session)).font(.system(size: 11.5)).foregroundStyle(palette.muted).lineLimit(1).truncationMode(.head)
            }
            Text(NowContent.title(session)).font(.system(size: 15, weight: .semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            if let detail = NowContent.detail(session) {
                Text(detail).font(.system(size: 12.5, design: session.state == .tool || session.state == .model ? .monospaced : .default))
                    .foregroundStyle(session.state == .model ? palette.muted : palette.ink2)
                    .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let asked = session.lastPrompt, !asked.isEmpty {
                Text("You asked: " + asked).font(.system(size: 12)).foregroundStyle(palette.muted).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            if let cache = session.cache { cacheRow(cache) }
            HStack(spacing: 10) {
                // A cache that is gone has nothing left to be reminded of.
                if let expires = session.cache?.expiresAt, expires > now {
                    let on = store.reminders.isOn(session.id)
                    Button {
                        store.reminders.toggle(session)
                    } label: {
                        Label(on ? "Reminder on" : "Remind me", systemImage: on ? "bell.fill" : "bell")
                    }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(on ? palette.accent : palette.muted)
                    .help(NowContent.reminderHelp(on: on, lead: CacheReminders.lead, available: CacheReminders.available, denied: store.reminders.denied))
                }
                Spacer()
                if let project = session.project, !project.isEmpty {
                    Button("Details") { window.open(session: session.id, view: .summary) }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(palette.muted)
                        .help("Open this session here: its summary, transcript, canvas, timeline and files")
                }
                // Back to where the work is: the editor's window, or the terminal.
                if let host = session.host {
                    Button {
                        HostOpener.open(host)
                    } label: {
                        Label(HostContent.title(host), systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.accent)
                    .help(HostContent.help(host))
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: Metric.radius, style: .continuous).fill(palette.panel)
                .shadow(color: palette.shadow.opacity(hover ? 0.9 : 0.6), radius: 9, y: 6)
        }
        .overlay(alignment: .leading) {
            // The edge says who has the next move.
            UnevenRoundedRectangle(topLeadingRadius: Metric.radius, bottomLeadingRadius: Metric.radius, style: .continuous)
                .fill(edge.opacity(session.state == .closed ? 0.35 : 1)).frame(width: 4)
        }
        .onHover { hover = $0 }
        .contextMenu {
            if let host = session.host {
                Button(HostContent.title(host)) { HostOpener.open(host) }
                Divider()
            }
            Button("Open Its Summary") { window.open(session: session.id, view: .summary) }
            Button("Open the Transcript at Its End") { window.open(session: session.id, view: .transcript) }
            if let cwd = session.cwd {
                Divider()
                Button("Reveal Its Folder in Finder") { FileOpener.reveal(cwd) }
                Button("Copy Its Folder's Path") { Exporter.copy(cwd) }
            }
        }
    }

    private func cacheRow(_ cache: NowReport.Cache) -> some View {
        let state = NowContent.cache(cache, now: now, lead: CacheReminders.lead)
        let tint = switch state.level {
        case .warm: palette.ok
        case .soon: palette.warn
        case .cold, .unknown: palette.muted2
        }
        return VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.line2)
                    Capsule().fill(tint).frame(width: max(0, geo.size.width * state.fraction))
                }
            }
            .frame(height: 4)
            HStack(spacing: 6) {
                Image(systemName: state.level == .cold ? "snowflake" : "flame").font(.system(size: 10.5)).foregroundStyle(tint)
                // The time is what is read at a glance; what it is worth yields when the card is narrow.
                Text(state.text).font(.system(size: 12)).monospacedDigit().foregroundStyle(state.level == .soon ? palette.warn : palette.ink2).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 4)
                Text(state.note).font(.system(size: 11.5)).foregroundStyle(palette.muted).lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .help(NowContent.cacheHelp(cache))
    }

    /// Whose move it is.
    private func color(_ session: NowReport.Session) -> Color {
        switch session.state {
        case .model, .background: palette.accent
        case .tool: session.maybeWaitingForPermission == true ? palette.warn : palette.accent
        case .blocked: palette.err
        case .you: palette.warn
        case .closed, .unknown: palette.muted
        }
    }

    /// What kind of work: a hue a kind. Amber and red are kept for "your move".
    private func hue(_ activity: NowContent.Activity) -> Color {
        switch activity {
        case .thinking, .skill: palette.accent
        case .command, .other: palette.tool
        case .reading, .searching: Color(hex: 0x1F9BB3)
        case .editing: Color(hex: 0x3F7FE0)
        case .web, .connector: palette.plug
        case .subagent: Color(hex: 0x8E5BD9)
        case .permission: palette.warn
        }
    }
}

/// What the Now page says of a session, and in what order it lists them.
nonisolated enum NowContent {
    /// Running sessions first, in the order their processes started, then the closed ones, the
    /// latest first. The engine lists by last activity, which would make cards trade places every few seconds.
    static func ordered(_ sessions: [NowReport.Session]) -> [NowReport.Session] {
        sessions.sorted { a, b in
            if a.running != b.running { return a.running }
            if a.running { return (a.pid ?? 0, a.id) < (b.pid ?? 0, b.id) }
            return (a.lastAt, a.id) > (b.lastAt, b.id)
        }
    }

    /// How many running sessions have the next move with the person: the rail's count.
    static func needsYou(_ now: Loadable<NowReport>?) -> Int {
        guard case .loaded(let report) = now else { return 0 }
        return report.sessions.filter { $0.running && ($0.state == .you || $0.state == .blocked || $0.maybeWaitingForPermission == true) }.count
    }

    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// "3 sessions at work in the last hour: 1 waiting for you, 1 working, 1 closed."
    static func stamp(_ report: NowReport) -> String {
        let sessions = report.sessions
        let window = span(report.windowMinutes)
        guard !sessions.isEmpty else { return "Nothing was at work in \(window)." }
        let blocked = sessions.filter { $0.state == .blocked }.count
        let you = sessions.filter { $0.state == .you }.count
        let working = sessions.filter { [.model, .tool, .background].contains($0.state) }.count
        let closed = sessions.filter { $0.state == .closed }.count
        var parts: [String] = []
        if blocked > 0 { parts.append("\(blocked) \(blocked == 1 ? "needs" : "need") you inside a turn") }
        if you > 0 { parts.append("\(you) waiting for you") }
        if working > 0 { parts.append("\(working) working") }
        if closed > 0 { parts.append("\(closed) closed") }
        var text = "\(count(sessions.count, "session")) at work in \(window): " + parts.joined(separator: ", ") + "."
        if report.runningOutsideWindow > 0 {
            text += " \(report.runningOutsideWindow) more \(report.runningOutsideWindow == 1 ? "is" : "are") open and quiet for longer."
        }
        return text
    }

    static func nothing(_ report: NowReport) -> String {
        var text = "No session did anything in \(span(report.windowMinutes))."
        if report.runningOutsideWindow > 0 {
            text += " \(count(report.runningOutsideWindow, "session")) \(report.runningOutsideWindow == 1 ? "is" : "are") open in Claude Code and quiet for longer: widen the window to see \(report.runningOutsideWindow == 1 ? "it" : "them")."
        }
        return text
    }

    static func span(_ minutes: Int) -> String {
        switch minutes {
        case 60: "the last hour"
        case 1440: "the last day"
        case let m where m % 60 == 0: "the last \(m / 60) hours"
        default: "the last \(minutes) minutes"
        }
    }

    /// The kind of work a session at work is doing, for its icon and its hue.
    enum Activity: Equatable { case thinking, command, reading, searching, editing, web, connector, subagent, skill, other, permission }

    /// Nil for a session that is not at work (your move, or closed).
    static func activity(_ session: NowReport.Session) -> Activity? {
        switch session.state {
        case .model: return .thinking
        case .tool:
            if session.maybeWaitingForPermission == true { return .permission }
            return session.tools.first.map { kind(of: $0.name) } ?? .other
        default: return nil
        }
    }

    static func kind(of tool: String) -> Activity {
        switch tool {
        case "Bash": .command
        case "Read": .reading
        case "Glob", "Grep", "LS", "ToolSearch": .searching
        case "Edit", "MultiEdit", "Write", "NotebookEdit": .editing
        case "Agent", "Task": .subagent
        case "Skill": .skill
        case _ where tool.hasPrefix("Web"): .web
        case _ where tool.hasPrefix("mcp__"): .connector
        default: .other
        }
    }

    static func symbol(_ activity: Activity) -> String {
        switch activity {
        case .thinking: "ellipsis.bubble"
        case .command: "terminal"
        case .reading: "doc.text"
        case .searching: "doc.text.magnifyingglass"
        case .editing: "pencil.line"
        case .web: "globe"
        case .connector: "puzzlepiece.extension"
        case .subagent: "person.2"
        case .skill: "sparkles"
        case .other: "wrench.adjustable"
        case .permission: "hand.raised"
        }
    }

    /// One call, in a few words: "Reading a file", "Running a command", "Using Google Slides".
    static func doing(_ tool: String) -> String {
        switch tool {
        case "Bash": return "Running a command"
        case "Read": return "Reading a file"
        case "Glob", "Grep", "LS": return "Searching the files"
        case "Edit", "MultiEdit", "NotebookEdit": return "Editing a file"
        case "Write": return "Writing a file"
        case "Agent", "Task": return "A subagent is running"
        case "Skill": return "Loading a skill"
        case "ToolSearch": return "Looking for a tool"
        case "WebFetch": return "Reading a web page"
        case "WebSearch": return "Searching the web"
        default: break
        }
        if tool.hasPrefix("mcp__") {
            let server = tool.dropFirst(5).components(separatedBy: "__").first ?? ""
            return "Using " + server.replacingOccurrences(of: "claude_ai_", with: "").replacingOccurrences(of: "_", with: " ")
        }
        return "Running " + tool
    }

    /// What it is doing, in a few words.
    static func headline(_ session: NowReport.Session) -> String {
        switch session.state {
        case .model: return session.lastTool == nil ? "Thinking" : "Thinking it over"
        case .tool:
            guard let first = session.tools.first else { return "A tool is running" }
            if session.tools.count > 1 {
                // Several calls of one kind read as that kind; a mix is just several calls.
                let kinds = Set(session.tools.map { kind(of: $0.name) })
                return kinds.count == 1 ? doing(first.name) + " (\(session.tools.count) at once)" : "Running \(session.tools.count) tools"
            }
            // A guess, and worded as one: the engine cannot see a permission prompt in an editor.
            if session.maybeWaitingForPermission == true { return doing(first.name) + ", or waiting for your permission" }
            return doing(first.name)
        case .blocked:
            return session.waitingFor.flatMap { $0.isEmpty ? nil : "Needs you: " + $0 } ?? "Needs you inside a turn"
        case .background:
            return "Waiting for " + count(session.subagentsRunning ?? 0, "subagent")
        case .you: return "Waiting for you"
        case .closed: return "Closed"
        case .unknown: return "At work"
        }
    }

    /// "Google Slides · update" for a connector's tool, the name as it is otherwise.
    static func toolName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        return name.dropFirst(5).replacingOccurrences(of: "claude_ai_", with: "").replacingOccurrences(of: "__", with: " · ").replacingOccurrences(of: "_", with: " ")
    }

    /// The line under the title: what the tool is running, or what the agent last said.
    static func detail(_ session: NowReport.Session) -> String? {
        switch session.state {
        case .tool, .blocked:
            let lines = session.tools.map { tool in [tool.name, tool.summary ?? ""].filter { !$0.isEmpty }.joined(separator: "  ") }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        case .you, .closed, .background:
            if let said = session.said, !said.isEmpty { return plain(said) }
            return session.cache == nil && (session.lastPrompt ?? "").isEmpty ? "Nothing has been asked in it yet." : nil
        case .model:
            // While the model works: the call it has just had back.
            guard let last = session.lastTool else { return nil }
            return "after " + [last.name.hasPrefix("mcp__") ? toolName(last.name) : last.name, last.summary ?? ""].filter { !$0.isEmpty }.joined(separator: "  ")
                + (last.failed == true ? "  (it failed)" : "")
        case .unknown:
            return nil
        }
    }

    /// Markdown's marks taken off a line that is shown as plain text: [words](link) is its words, `code` its code.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "**", with: "")
    }

    static func title(_ session: NowReport.Session) -> String {
        session.title.flatMap { $0.isEmpty ? nil : $0 } ?? session.name ?? Format.shortID(session.id)
    }

    /// "tools · VS Code": the project, and where the process runs.
    static func place(_ session: NowReport.Session) -> String {
        var parts = [Format.projectName(cwd: session.cwd, slug: session.project)]
        if session.running, let entry = session.entrypoint {
            switch entry {
            case "claude-vscode": parts.append("VS Code")
            case "cli": parts.append("terminal")
            case "claude-desktop", "claude-desktop-3p", "local-agent": parts.append("desktop app")
            default: parts.append(entry)
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 12s, 4m 08s, 3h 08m, 2d 5h.
    static func elapsed(from: Date, to: Date) -> String {
        let s = max(0, Int(to.timeIntervalSince(from)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        if s < 86400 { return "\(s / 3600)h \(String(format: "%02d", s % 3600 / 60))m" }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }

    enum CacheLevel: Equatable { case warm, soon, cold, unknown }

    /// The cache at `now`: how full the bar is, what it says, and what is at stake.
    static func cache(_ cache: NowReport.Cache, now: Date, lead: Int) -> (level: CacheLevel, fraction: Double, text: String, note: String) {
        let context = Format.tokens(cache.contextTokens) + " context"
        guard let expires = cache.expiresAt, cache.ttlSeconds > 0 else {
            return (.unknown, 0, "Cache: lifetime not known", context)
        }
        let left = expires.timeIntervalSince(now)
        if left <= 0 {
            return (.cold, 0, "Cache expired \(elapsed(from: expires, to: now)) ago", "the next prompt pays for " + Format.tokens(cache.contextTokens))
        }
        let level: CacheLevel = left <= Double(lead) * 60 ? .soon : .warm
        // "100% read" alone did not say from where; of what (the last request's input) is in the tooltip.
        let read = "\(Int((cache.hitRatio * 100).rounded()))% from cache"
        return (level, min(1, left / Double(cache.ttlSeconds)), "Warm for \(elapsed(from: now, to: expires))", read + " · " + context)
    }

    static func cacheHelp(_ cache: NowReport.Cache) -> String {
        var lines = ["\(Int((cache.hitRatio * 100).rounded()))% from cache: of everything the last request sent to the model, that much was read from the prompt cache at a fraction of the price. The context is all of it: what the next prompt pays for in full once the cache is gone.", "The last request read \(Format.tokens(cache.readTokens)) tokens from the prompt cache, wrote \(Format.tokens(cache.writtenTokens)) to it and sent \(Format.tokens(cache.uncachedTokens)) uncached."]
        if let expires = cache.expiresAt {
            lines.append("It was sent at \(cache.lastRequestAt.formatted(date: .omitted, time: .standard)) and wrote entries that live \(cache.ttlSeconds >= 3600 ? "an hour" : "five minutes"), so the cache lasts until \(expires.formatted(date: .omitted, time: .standard)). Every request pushes that back.")
        } else {
            lines.append("None of its recent requests wrote to the cache, so how long it lives is not known.")
        }
        return lines.joined(separator: "\n")
    }

    static func reminderHelp(on: Bool, lead: Int, available: Bool, denied: Bool) -> String {
        if !available { return "Notifications need the installed app (just client-app-install); run from the build directory the bell only marks the card." }
        if denied { return "Notifications are turned off for this app in System Settings › Notifications." }
        return on ? "A notification will come when this cache has \(lead) minutes left. Click to turn it off."
            : "Tell me when this session's cache has \(lead) minutes left (the minutes are in Settings › General)."
    }
}
