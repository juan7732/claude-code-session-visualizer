import SkitKit
import SwiftUI

/// Two sessions on the same measures (mock: `#/compare`). The counts are the
/// sessions' own rows; files written, commits and background commands come
/// from each session's relations and the context peak from its stats, so both
/// sessions are read once when the page opens.
struct ComparePage: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette

    var body: some View {
        let state = window.compare
        let pair = [state.first, state.second].map { $0.flatMap { store.session($0) } }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Compare").font(.display(28))
                HStack(spacing: 8) {
                    Text("Two sessions on the same measures.").foregroundStyle(palette.muted)
                    picker(Binding(get: { state.first }, set: { state.first = $0 }))
                    Text("against").foregroundStyle(palette.muted)
                    picker(Binding(get: { state.second }, set: { state.second = $0 }))
                }
                .font(.system(size: 13))
                if let a = pair[0], let b = pair[1] {
                    HStack(alignment: .top, spacing: 12) {
                        SessionHead(row: a)
                        SessionHead(row: b)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Card { MeasureTable(a: a, b: b) }.fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Choose two sessions.").foregroundStyle(palette.muted).padding(.top, 30)
                }
            }
            .frame(maxWidth: Metric.wideColumn, alignment: .leading)
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 60)
            .frame(maxWidth: .infinity)
        }
        .background(palette.bg)
        .task(id: (state.first ?? "") + "\n" + (state.second ?? "")) {
            for id in [state.first, state.second].compactMap({ $0 }) {
                await store.loadModel(id)
                await store.loadStats(id)
            }
        }
    }

    private func picker(_ selection: Binding<String?>) -> some View {
        Picker("Session", selection: selection) {
            ForEach(store.sessions.sorted { $0.lastAt > $1.lastAt }) { row in
                Text(row.title.isEmpty ? Format.shortID(row.id) : row.title).tag(Optional(row.id))
            }
        }
        .labelsHidden().frame(maxWidth: 300)
    }
}

/// One side: when, where, its turns as a strip, how far each prompt ran, where its time went.
private struct SessionHead: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var row: SessionSummary

    var body: some View {
        Card {
            HStack {
                Text(row.title.uppercased()).font(.caps).tracking(0.9).foregroundStyle(palette.muted).lineLimit(1)
                Spacer()
                Button("open") { window.open(session: row.id, view: .summary) }.buttonStyle(.plain).foregroundStyle(palette.accent).font(.system(size: 12))
            }
            Text("\(Format.dateTime(row.firstAt)) → \(Format.dateTime(row.lastAt)) · \(Format.projectName(cwd: row.cwd, slug: row.project))")
                .font(.system(size: 12)).foregroundStyle(palette.muted)
            if let model = store.model(row.id) {
                TurnsStrip(turns: CompareContent.turns(of: model)).frame(height: 10)
                    .help("One block a turn, as wide as its actions: red where a tool call failed, grey where something other than you started it.")
            } else {
                RoundedRectangle(cornerRadius: 2).fill(palette.panel2).frame(height: 10)
            }
            Text("Actions per prompt").font(.system(size: 11.5)).foregroundStyle(palette.muted).padding(.top, 4)
            CompareSpark(values: row.shape ?? []).frame(height: 40)
            Text("Where the time went").font(.system(size: 11.5)).foregroundStyle(palette.muted).padding(.top, 4)
            if let time = row.time { CompareTime(time: time) } else { Text("No clock to split.").font(.system(size: 12)).foregroundStyle(palette.muted) }
        }
    }
}

private struct TurnsStrip: View {
    @Environment(\.palette) private var palette
    var turns: [CompareContent.TurnMark]

    var body: some View {
        Canvas { g, size in
            let total = CGFloat(max(1, turns.map(\.weight).reduce(0, +)))
            let gap: CGFloat = turns.count > 80 ? 1 : 2
            let room = max(1, size.width - gap * CGFloat(max(0, turns.count - 1)))
            var x: CGFloat = 0
            for turn in turns {
                let width = max(1, room * CGFloat(turn.weight) / total)
                g.fill(Path(roundedRect: CGRect(x: x, y: 0, width: width, height: size.height), cornerRadius: 2),
                       with: .color(turn.failed ? palette.err.opacity(0.75) : turn.human ? palette.accent.opacity(0.8) : palette.ctx.opacity(0.7)))
                x += width + gap
            }
        }
        .accessibilityHidden(true)
    }
}

private struct CompareSpark: View {
    @Environment(\.palette) private var palette
    var values: [Int]

    var body: some View {
        Canvas { g, size in
            guard let most = values.max(), most > 0 else { return }
            let step = size.width / CGFloat(values.count)
            var bars = Path()
            for (i, value) in values.enumerated() {
                let tall = max(1, CGFloat(value) / CGFloat(most) * size.height)
                bars.addRect(CGRect(x: CGFloat(i) * step, y: size.height - tall, width: max(1, step * 0.78), height: tall))
            }
            g.fill(bars, with: .color(palette.accent.opacity(0.85)))
        }
        .accessibilityHidden(true)
    }
}

private struct CompareTime: View {
    @Environment(\.palette) private var palette
    var time: TimeTotals

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            line("Of \(SessionModel.duration(time.wall)), waiting for you", time.waitingForYou, of: time.wall, palette.muted2)
            line("In turns · the model", time.model, of: time.seconds, palette.accent)
            line("In turns · tools running", time.tools, of: time.seconds, palette.tool)
            if time.subagents + time.waiting > 0 { line("In turns · subagents and hand-backs", time.subagents + time.waiting, of: time.seconds, palette.warn) }
        }
    }

    private func line(_ label: String, _ part: Double, of whole: Double, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12)).frame(width: 220, alignment: .leading).lineLimit(1)
            GeometryReader { geo in
                Capsule().fill(color).frame(width: whole > 0 && part > 0 ? max(3, geo.size.width * part / whole) : 0, height: 7).frame(maxHeight: .infinity)
            }
            .frame(height: 12)
            Text(WherePanel.percent(part, of: whole) + " · " + SessionModel.duration(part)).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.ink2).frame(width: 110, alignment: .trailing)
        }
    }
}

/// The measures, one row each, the two sessions in columns.
private struct MeasureTable: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var palette
    var a: SessionSummary
    var b: SessionSummary

    var body: some View {
        let rows = CompareContent.measures(a, b, modelA: store.model(a.id), modelB: store.model(b.id), statsA: stats(a.id), statsB: stats(b.id))
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text(Format.middleEllipsis(a.title, max: 34).uppercased()).font(.caps).tracking(0.7).foregroundStyle(palette.muted).frame(width: 300, alignment: .trailing)
                Text(Format.middleEllipsis(b.title, max: 34).uppercased()).font(.caps).tracking(0.7).foregroundStyle(palette.muted).frame(width: 300, alignment: .trailing)
            }
            .padding(.horizontal, 8).padding(.bottom, 6)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack {
                    Text(row.label).foregroundStyle(palette.ink2).frame(maxWidth: .infinity, alignment: .leading)
                    Text(row.a).monospacedDigit().frame(width: 300, alignment: .trailing)
                    Text(row.b).monospacedDigit().frame(width: 300, alignment: .trailing)
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(index.isMultiple(of: 2) ? palette.panel2.opacity(0.35) : .clear)
            }
        }
    }

    private func stats(_ id: String) -> SessionSummary? {
        if case .loaded(let stats) = store.stats[id] { stats } else { nil }
    }
}

/// What the Compare page lays side by side, from what the engine served for each session.
nonisolated enum CompareContent {
    struct TurnMark: Equatable, Sendable {
        var weight: Int
        var human: Bool
        var failed: Bool
    }

    struct Measure: Equatable, Sendable {
        var label: String
        var a: String
        var b: String
    }

    static func turns(of model: SessionModel) -> [TurnMark] {
        let failed = Set(model.doc.toolCalls.filter(\.isError).map(\.turn))
        return model.doc.turns.map { TurnMark(weight: max(1, $0.actionIndexes.count), human: $0.isHuman, failed: failed.contains($0.index)) }
    }

    /// A measure that needs the session read shows "…" until it is.
    static func measures(_ a: SessionSummary, _ b: SessionSummary, modelA: SessionModel?, modelB: SessionModel?, statsA: SessionSummary?, statsB: SessionSummary?) -> [Measure] {
        func row(_ label: String, _ value: (SessionSummary) -> String) -> Measure { Measure(label: label, a: value(a), b: value(b)) }
        func read(_ label: String, _ value: (SessionModel) -> String) -> Measure {
            Measure(label: label, a: modelA.map(value) ?? "…", b: modelB.map(value) ?? "…")
        }
        func seconds(_ part: KeyPath<TimeTotals, Double>) -> (SessionSummary) -> String {
            { $0.time.map { SessionModel.duration($0[keyPath: part]) } ?? "—" }
        }
        func peak(_ stats: SessionSummary?) -> String {
            guard let stats else { return "…" }
            return stats.context?.map(\.tokens).max().map(Format.tokens) ?? "—"
        }
        var out = [
            row("Prompts") { "\($0.prompts)" },
            row("Actions") { "\($0.requests)" },
            row("Tool calls") { "\($0.toolCalls)" },
            row("Failed calls") { "\($0.toolErrors)" },
            row("Median actions per prompt") { "\(StatsContent.median($0.shape ?? []))" },
            row("Longest autonomous run") { "\($0.shape?.max() ?? 0) actions" },
            read("Files written") { "\($0.relations.files.filter { $0.writes > 0 }.count)" },
            read("Commits") { "\($0.relations.commits.count)" },
            row("Subagents") { "\($0.subagents)" },
            read("Background commands") { "\($0.relations.tasks.count)" },
            row("Compactions") { "\($0.compactions)" },
            Measure(label: "Context peak", a: peak(statsA), b: peak(statsB)),
            row("Output tokens") { Format.tokens($0.usage.outputTokens) },
            row("Cache hit") { $0.requests > 0 ? "\(Int(($0.cacheHitRatio * 100).rounded()))%" : "—" },
            row("Wall") { $0.duration },
            row("In turns", seconds(\.seconds)),
            row("The model", seconds(\.model)),
            row("Tools running", seconds(\.tools)),
        ]
        // The tools both used most, by calls in the two together.
        var calls: [String: (Int, Int)] = [:]
        for tool in a.tools { calls[tool.name, default: (0, 0)].0 += tool.calls }
        for tool in b.tools { calls[tool.name, default: (0, 0)].1 += tool.calls }
        let top = calls.sorted { ($0.value.0 + $0.value.1, $1.key) > ($1.value.0 + $1.value.1, $0.key) }.prefix(8)
        out += top.map { Measure(label: StatsPage.toolName($0.key), a: "\($0.value.0)", b: "\($0.value.1)") }
        return out
    }
}
