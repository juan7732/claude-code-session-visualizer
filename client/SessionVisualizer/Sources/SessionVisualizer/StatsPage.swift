import SkitKit
import SwiftUI

/// The numbers across every session (mock: `#/stats`): totals, a year of days,
/// boards by project, tool, model and time, and one row per session. A click
/// on a project narrows every board; nothing here opens a session. Every
/// figure is the engine's (`skit overview`); the table's rows are the sessions
/// the app already lists.
struct StatsPage: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette

    var body: some View {
        let state = window.stats
        let rows = store.sessions.filter { state.project == nil || $0.project == state.project }
        ScrollView {
            // A plain stack: boards and at most a few hundred rows, and no lazy stack in another (README, rules).
            VStack(alignment: .leading, spacing: 14) {
                switch (store.overviews[state.project ?? ""], store.overviews[""]) {
                case (.loaded(let shown), .loaded(let all)):
                    header(shown, all: all, state)
                    boards(shown, all: all, rows: rows, state)
                case (.failed(let why), _), (_, .failed(let why)):
                    Text("The numbers").font(.display(28))
                    Text(why).foregroundStyle(palette.err)
                default:
                    Text("The numbers").font(.display(28))
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: Metric.wideColumn, alignment: .leading)
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 60)
            .frame(maxWidth: .infinity)
        }
        .background(palette.bg)
        .task(id: (state.project ?? "") + "\n\(store.sessions.count)") {
            await store.loadOverview(project: nil)
            if let project = state.project { await store.loadOverview(project: project) }
        }
    }

    private func header(_ shown: Overview, all: Overview, _ state: StatsState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("The numbers").font(.display(28))
            HStack(spacing: 6) {
                if let project = state.project {
                    Text("Across \(Self.count(shown.sessions, "session")) in").foregroundStyle(palette.muted)
                    Text(Self.name(all.projects.first { $0.project == project })).fontWeight(.semibold)
                    Button("show all") { state.project = nil }.buttonStyle(.plain).foregroundStyle(palette.accent)
                } else {
                    Text("Across \(Self.count(shown.sessions, "session")) in \(Self.count(all.projects.count, "project")). Click a project to narrow every board; nothing here opens a session.")
                        .foregroundStyle(palette.muted)
                }
            }
            .font(.system(size: 13))
        }
    }

    @ViewBuilder private func boards(_ shown: Overview, all: Overview, rows: [SessionSummary], _ state: StatsState) -> some View {
        let t = shown.totals
        HStack(spacing: 12) {
            Figure(value: "\(shown.sessions)", label: "sessions")
            Figure(value: "\(t.turns)", label: "turns")
            Figure(value: "\(t.actions)", label: "actions")
            Figure(value: "\(t.toolCalls)", label: "tool calls")
            Figure(value: "\(t.toolErrors)", label: "failed calls")
            Figure(value: Format.tokens(t.outputTokens), label: "output tokens")
            Figure(value: Format.money(t.sessionsWithCost > 0 ? t.cost : nil), label: "known cost")
                .help(t.sessionsWithCost > 0 ? "Claude Code's own figure, recorded by \(Self.count(t.sessionsWithCost, "session")) of \(shown.sessions)" : "No session here recorded a cost")
        }
        Card(title: "When the work happened") { YearCalendar(overview: shown, state: state) }.fixedSize(horizontal: false, vertical: true)
        HStack(alignment: .top, spacing: 12) {
            Card(title: "By project · actions") {
                let most = all.projects.map(\.actions).max() ?? 1
                ForEach(all.projects) { project in
                    BarRow(label: Self.name(project), value: Double(project.actions), of: Double(most), figure: "\(project.actions)", color: palette.accent, on: state.project == project.project) {
                        state.project = state.project == project.project ? nil : project.project
                        state.day = nil
                    }
                    .help("\(Self.count(project.sessions, "session")) · \(project.toolCalls) tool calls, \(project.toolErrors) failed · \(Format.tokens(project.outputTokens)) output")
                }
            }
            Card(title: "Tools · calls and failures") {
                let most = shown.tools.first?.calls ?? 1
                ForEach(shown.tools.prefix(8), id: \.name) { tool in
                    BarRow(label: Self.toolName(tool.name), note: tool.errors > 0 ? "\(tool.errors) failed" : nil, value: Double(tool.calls), of: Double(most), figure: "\(tool.calls)", color: palette.tool)
                }
                if shown.tools.count > 8 { Text("and \(shown.tools.count - 8) more").font(.system(size: 11.5)).foregroundStyle(palette.muted) }
            }
            Card(title: "Where the time went") { TimeBoard(time: shown.time) }
        }
        .fixedSize(horizontal: false, vertical: true)
        HStack(alignment: .top, spacing: 12) {
            Card(title: "Actions by model") {
                let most = shown.models.first?.count ?? 1
                ForEach(shown.models, id: \.name) { model in
                    BarRow(label: model.name.replacingOccurrences(of: "claude-", with: ""), value: Double(model.count), of: Double(most), figure: "\(model.count)", color: palette.accent)
                }
                Text("PROMPT CACHE").font(.caps).tracking(0.9).foregroundStyle(palette.muted).padding(.top, 8)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(Int((shown.cacheHitRatio * 100).rounded()))%").font(.display(22))
                    Text("of all input was read from the cache · \(Format.tokens(shown.cacheRead)) tokens").font(.system(size: 12)).foregroundStyle(palette.muted)
                }
            }
            Card(title: "Autonomy · actions per prompt") {
                let shaped = rows.filter { ($0.shape?.count ?? 0) > 1 }.sorted { $0.requests > $1.requests }.prefix(4)
                if shaped.isEmpty { Text("No session here has more than one prompt.").font(.system(size: 12)).foregroundStyle(palette.muted) }
                ForEach(Array(shaped)) { row in
                    let shape = row.shape ?? []
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(row.title) · median \(StatsContent.median(shape)), longest \(shape.max() ?? 0)").font(.system(size: 11)).foregroundStyle(palette.muted).lineLimit(1)
                        Sparkline(values: shape).frame(height: 34)
                    }
                }
            }
            Card(title: "Also in these sessions") {
                let most = Double(max(1, t.subagents, t.compactions, t.systemTurns, t.images, t.apiErrors))
                BarRow(label: "subagents", value: Double(t.subagents), of: most, figure: "\(t.subagents)", color: palette.warn)
                BarRow(label: "compactions", value: Double(t.compactions), of: most, figure: "\(t.compactions)", color: palette.warn)
                BarRow(label: "system-started turns", value: Double(t.systemTurns), of: most, figure: "\(t.systemTurns)", color: palette.ctx)
                BarRow(label: "images", value: Double(t.images), of: most, figure: "\(t.images)", color: palette.plug)
                BarRow(label: "API errors", value: Double(t.apiErrors), of: most, figure: "\(t.apiErrors)", color: palette.err)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        Card(title: "Every session, one row") { SessionTable(rows: StatsContent.sorted(rows, by: state.sort, ascending: state.ascending), totals: shown, state: state) }
            .fixedSize(horizontal: false, vertical: true)
    }

    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    /// The name a project goes by: the last folder of the directory its sessions start in.
    static func name(_ project: Overview.Project?) -> String {
        guard let project else { return "this project" }
        return Format.projectName(cwd: project.cwd, slug: project.project)
    }

    /// "Google Slides update presentation" for a connector's tool, the name as it is otherwise.
    nonisolated static func toolName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        return name.dropFirst(5).replacingOccurrences(of: "claude_ai_", with: "").replacingOccurrences(of: "__", with: " · ").replacingOccurrences(of: "_", with: " ")
    }
}

/// What the Stats page orders and sums up for display.
nonisolated enum StatsContent {
    static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }

    static func sorted(_ rows: [SessionSummary], by column: StatsColumn, ascending: Bool) -> [SessionSummary] {
        func before(_ a: SessionSummary, _ b: SessionSummary) -> Bool {
            switch column {
            case .session: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            case .project: return Format.projectName(cwd: a.cwd, slug: a.project).localizedCaseInsensitiveCompare(Format.projectName(cwd: b.cwd, slug: b.project)) == .orderedAscending
            case .lastActive: return a.lastAt < b.lastAt
            case .turns: return a.turns < b.turns
            case .actions: return a.requests < b.requests
            case .calls: return a.toolCalls < b.toolCalls
            case .failed: return a.toolErrors < b.toolErrors
            case .subagents: return a.subagents < b.subagents
            case .output: return a.usage.outputTokens < b.usage.outputTokens
            case .cache: return a.cacheHitRatio < b.cacheHitRatio
            case .cost: return (a.claudeCodeCostUsd ?? -1) < (b.claudeCodeCostUsd ?? -1)
            }
        }
        // Ties keep the newest first, whichever way the column runs.
        return rows.sorted { a, b in
            if before(a, b) { return ascending }
            if before(b, a) { return !ascending }
            return a.lastAt > b.lastAt
        }
    }

    /// The weeks of the year that ends this week: each a Sunday-to-Saturday column of day keys ("2026-11-07").
    static func weeks(endingAt today: Date, count: Int = 53, calendar: Calendar) -> [[Date]] {
        let start = calendar.startOfDay(for: today)
        let weekday = calendar.component(.weekday, from: start) // 1 = Sunday
        guard let lastSaturday = calendar.date(byAdding: .day, value: 7 - weekday, to: start) else { return [] }
        return (0..<count).reversed().map { back in
            (0..<7).reversed().compactMap { day in calendar.date(byAdding: .day, value: -(back * 7 + day), to: lastSaturday) }
        }
    }

    /// The calendar the engine counted days in; the Mac's own when the engine could not name its zone.
    static func calendar(in zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .current
        calendar.locale = .current
        return calendar
    }

    static func key(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// One of the figures across the top.
private struct Figure: View {
    @Environment(\.palette) private var palette
    var value: String
    var label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.display(24)).lineLimit(1).minimumScaleFactor(0.6)
            Text(label.uppercased()).font(.caps).tracking(0.9).foregroundStyle(palette.muted).lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { Panel(shadow: palette.shadow.opacity(0.6), radius: 9, y: 6) }
        .accessibilityElement(children: .combine)
    }
}

/// A name, a bar as long as its share of the largest, and the figure.
private struct BarRow: View {
    @Environment(\.palette) private var palette
    var label: String
    var note: String?
    var value: Double
    var of: Double
    var figure: String
    var color: Color
    var on = false
    var action: (() -> Void)?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            (Text(label) + Text(note.map { "  · " + $0 } ?? "").foregroundStyle(palette.err).font(.system(size: 11)))
                .font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            GeometryReader { geo in
                Capsule().fill(color).frame(width: value > 0 ? max(3, geo.size.width * value / max(1, of)) : 0, height: 6)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(width: 90, height: 14)
            Text(figure).font(.system(size: 12.5, weight: .semibold)).monospacedDigit().frame(width: 52, alignment: .trailing)
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(on ? palette.accentSoft : hover && action != nil ? palette.panel2.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { action?() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(action != nil ? .isButton : [])
    }
}

/// The split of `skit time` across the sessions on show.
private struct TimeBoard: View {
    @Environment(\.palette) private var palette
    var time: TimeTotals

    var body: some View {
        if time.wall <= 0 {
            Text("No session here has a clock to split.").font(.system(size: 12)).foregroundStyle(palette.muted)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text("Of \(SessionModel.duration(time.wall)), first record to last, every session").font(.system(size: 12)).foregroundStyle(palette.ink2)
                SplitBar(parts: [(time.waitingForYou, palette.muted2), (time.waitingForBackground, palette.ctx), (time.seconds, palette.ink)], length: 2000, height: 8)
                share("waiting for you", time.waitingForYou, of: time.wall, palette.muted2)
                if time.waitingForBackground > 0 { share("waiting for background work", time.waitingForBackground, of: time.wall, palette.ctx) }
                share("in turns", time.seconds, of: time.wall, palette.ink)
                Text("In turns").font(.system(size: 12)).foregroundStyle(palette.ink2).padding(.top, 4)
                SplitBar(parts: [(time.model, palette.accent), (time.tools, palette.tool), (time.subagents, palette.warn), (time.waiting, palette.ctx)], length: 2000, height: 8)
                share("the model", time.model, of: time.seconds, palette.accent)
                share("tools running", time.tools, of: time.seconds, palette.tool)
                if time.subagents > 0 { share("subagents running", time.subagents, of: time.seconds, palette.warn) }
                if time.waiting > 0 { share("waiting for a hand-back", time.waiting, of: time.seconds, palette.ctx) }
            }
        }
    }

    private func share(_ label: String, _ part: Double, of whole: Double, _ color: Color) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(label).font(.system(size: 12))
            Spacer(minLength: 8)
            Text(WherePanel.percent(part, of: whole) + " · " + SessionModel.duration(part)).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.ink2)
        }
    }
}

/// How many actions each prompt started: one bar a prompt.
private struct Sparkline: View {
    @Environment(\.palette) private var palette
    var values: [Int]

    var body: some View {
        Canvas { g, size in
            guard let most = values.max(), most > 0 else { return }
            let step = size.width / CGFloat(values.count)
            let width = max(1, min(14, step - 1))
            var bars = Path()
            for (i, value) in values.enumerated() {
                let tall = max(1, CGFloat(value) / CGFloat(most) * size.height)
                bars.addRect(CGRect(x: CGFloat(i) * step, y: size.height - tall, width: width, height: tall))
            }
            g.fill(bars, with: .color(palette.accent.opacity(0.85)))
        }
        .accessibilityHidden(true)
    }
}

/// A year of days, a column a week: the darker the square, the more actions.
/// A click on a day shows its numbers and the sessions that were at work.
private struct YearCalendar: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var palette
    var overview: Overview
    var state: StatsState

    var body: some View {
        // The days are the engine's, in its time zone: the grid is laid out in the same one.
        let calendar = StatsContent.calendar(in: overview.timezone)
        let weeks = StatsContent.weeks(endingAt: Date(), calendar: calendar)
        let days = Dictionary(overview.days.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let most = max(1, overview.days.map(\.actions).max() ?? 1)
        let today = StatsContent.key(Date(), calendar: calendar)
        let first = weeks.first?.first.map { StatsContent.key($0, calendar: calendar) } ?? ""
        let active = overview.days.filter { $0.day >= first }.count
        VStack(alignment: .leading, spacing: 8) {
            Text("\(StatsPage.count(active, "active day")) in the last year · click a day")
                .font(.system(size: 11.5)).foregroundStyle(palette.muted)
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(" ").font(.system(size: 9.5)).frame(height: 12)
                    ForEach(0..<7, id: \.self) { row in
                        Text(["", "Mon", "", "Wed", "", "Fri", ""][row]).font(.system(size: 9.5)).foregroundStyle(palette.muted).frame(height: 13)
                    }
                }
                .frame(width: 26, alignment: .leading)
                ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                    VStack(spacing: 3) {
                        Text(monthLabel(week, previous: index > 0 ? weeks[index - 1] : nil, calendar: calendar))
                            .font(.system(size: 9.5)).foregroundStyle(palette.muted).fixedSize().frame(width: 13, height: 12, alignment: .leading)
                        ForEach(week, id: \.self) { date in
                            let key = StatsContent.key(date, calendar: calendar)
                            cell(date, key: key, day: days[key], most: most, future: key > today)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if let key = state.day { detail(key, days[key]) }
            if overview.withoutActivity > 0 {
                Text("\(StatsPage.count(overview.withoutActivity, "session")) summarised before days were kept, and gone from disk since: counted in the totals, on no day.")
                    .font(.system(size: 11.5)).foregroundStyle(palette.muted)
            }
        }
    }

    private func cell(_ date: Date, key: String, day: Overview.Day?, most: Int, future: Bool) -> some View {
        let fill: Color = day.map { palette.accent.opacity(0.22 + 0.78 * Double($0.actions) / Double(most)) } ?? palette.panel2.opacity(future ? 0.3 : 1)
        let name = date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let what: String = day.map { " · \($0.actions) actions · \(StatsPage.count($0.sessions.count, "session"))" } ?? (future ? "" : " · nothing")
        return RoundedRectangle(cornerRadius: 3)
            .fill(fill)
            .overlay { if state.day == key { RoundedRectangle(cornerRadius: 3).strokeBorder(palette.ink, lineWidth: 1.5) } }
            .frame(maxWidth: .infinity).frame(height: 13)
            .contentShape(Rectangle())
            .onTapGesture { if !future { state.day = state.day == key ? nil : key } }
            .help(name + what)
    }

    private func monthLabel(_ week: [Date], previous: [Date]?, calendar: Calendar) -> String {
        guard let first = week.first else { return "" }
        let month = calendar.component(.month, from: first)
        if let before = previous?.first, calendar.component(.month, from: before) == month { return "" }
        return calendar.shortMonthSymbols[month - 1]
    }

    private func detail(_ key: String, _ day: Overview.Day?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(palette.line).frame(height: 1)
            Text(key).font(.system(size: 12.5, weight: .semibold)).padding(.top, 4)
            if let day {
                Text("\(day.actions) actions · \(day.toolCalls) tool calls · \(day.toolErrors) failed · \(Format.tokens(day.outputTokens)) output tokens · \(StatsPage.count(day.sessions.count, "session"))")
                    .font(.system(size: 12.5)).foregroundStyle(palette.ink2)
                Text(day.sessions.map { id in store.session(id)?.title ?? Format.shortID(id) }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(palette.muted).lineLimit(2)
            } else {
                Text("Nothing that day.").font(.system(size: 12.5)).foregroundStyle(palette.muted)
            }
        }
    }
}

/// Every session of the boards, one row each; a click on a heading sorts by it.
private struct SessionTable: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var palette
    var rows: [SessionSummary]
    /// The engine's sums for the sessions on show: the last row.
    var totals: Overview
    var state: StatsState
    @State private var all = false

    private static let first = 200

    private func width(_ column: StatsColumn) -> CGFloat? {
        switch column {
        case .session: nil
        case .project: 150
        case .lastActive: 104
        case .output, .cost: 70
        default: 58
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(StatsColumn.allCases) { column in
                    Button {
                        if state.sort == column { state.ascending.toggle() } else { (state.sort, state.ascending) = (column, !column.numeric) }
                    } label: {
                        Text(column.title.uppercased() + (state.sort == column ? (state.ascending ? " ▴" : " ▾") : ""))
                            .font(.caps).tracking(0.7).foregroundStyle(state.sort == column ? palette.ink : palette.muted).lineLimit(1)
                            .frame(maxWidth: width(column) == nil ? .infinity : nil, alignment: column.numeric ? .trailing : .leading)
                            .frame(width: width(column), alignment: column.numeric ? .trailing : .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Sort by \(column.title.lowercased())")
                }
                Text("SHAPE").font(.caps).tracking(0.7).foregroundStyle(palette.muted).frame(width: 80, alignment: .leading)
            }
            .padding(.horizontal, 8).padding(.bottom, 6)
            Rectangle().fill(palette.line2).frame(height: 1)
            ForEach(Array((all ? rows : Array(rows.prefix(Self.first))).enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Text(row.title.isEmpty ? Format.shortID(row.id) : row.title).lineLimit(1)
                        if store.isLive(row.id) { Circle().fill(palette.ok).frame(width: 6, height: 6) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Format.projectName(cwd: row.cwd, slug: row.project)).foregroundStyle(palette.ink2).lineLimit(1).frame(width: width(.project), alignment: .leading)
                    number(Format.ago(row.lastAt), .lastActive)
                    number("\(row.turns)", .turns)
                    number("\(row.requests)", .actions)
                    number("\(row.toolCalls)", .calls)
                    number(row.toolErrors > 0 ? "\(row.toolErrors)" : "", .failed)
                    number(row.subagents > 0 ? "\(row.subagents)" : "", .subagents)
                    number(Format.tokens(row.usage.outputTokens), .output)
                    number(row.requests > 0 ? "\(Int((row.cacheHitRatio * 100).rounded()))%" : "", .cache)
                    number(row.claudeCodeCostUsd.map { Format.money($0) } ?? "", .cost)
                    Sparkline(values: row.shape ?? []).frame(width: 80, height: 14)
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(index.isMultiple(of: 2) ? palette.panel2.opacity(0.35) : .clear)
            }
            if !all, rows.count > Self.first {
                Button("Show the other \(rows.count - Self.first) sessions") { all = true }.buttonStyle(.plain).foregroundStyle(palette.accent).padding(.top, 8)
            }
            // The totals are the overview's, so they hold for every session even while only the first rows are listed.
            let t = totals.totals
            Rectangle().fill(palette.line2).frame(height: 1).padding(.top, 2)
            HStack(spacing: 8) {
                Text("Total · \(StatsPage.count(totals.sessions, "session"))").frame(maxWidth: .infinity, alignment: .leading)
                Text("").frame(width: width(.project))
                number("", .lastActive)
                number("\(t.turns)", .turns)
                number("\(t.actions)", .actions)
                number("\(t.toolCalls)", .calls)
                number("\(t.toolErrors)", .failed)
                number("\(t.subagents)", .subagents)
                number(Format.tokens(t.outputTokens), .output)
                number(t.actions > 0 ? "\(Int((totals.cacheHitRatio * 100).rounded()))%" : "", .cache)
                number(t.sessionsWithCost > 0 ? Format.money(t.cost) : "", .cost)
                Text("").frame(width: 80)
            }
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 7)
            .help("Cache is all input read from the cache over all input, across these sessions. Cost is Claude Code's own figure, summed over the \(StatsPage.count(t.sessionsWithCost, "session")) that recorded one.")
            .accessibilityElement(children: .combine)
        }
    }

    private func number(_ text: String, _ column: StatsColumn) -> some View {
        Text(text).monospacedDigit().lineLimit(1).frame(width: width(column), alignment: .trailing)
    }
}
