import SkitKit
import SwiftUI

/// The inspector: a drawer under every view of a session that shows the
/// selected node (NOTES, iteration 11: the bottom drawer, Juan's pick).
struct Drawer: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    @AppStorage(SettingsKey.inspectorHeight) private var height = 280.0
    var model: SessionModel
    var key: NodeKey
    @State private var dragStart: Double?

    var body: some View {
        let tabs = availableTabs
        let tab = tabs.contains(window.inspectorTab) ? window.inspectorTab : .details
        VStack(spacing: 0) {
            grip
            header(tabs: tabs, tab: tab)
            Rectangle().fill(palette.line).frame(height: 1)
            ScrollView {
                Group {
                    switch tab {
                    case .details: DrawerDetails(model: model, key: key)
                    case .io: DrawerIO(model: model, calls: calls, step: step)
                    case .note: DrawerNote(sessionID: model.doc.id, key: key).id(key)
                    }
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(height: height)
        .background(palette.panel2)
        .overlay(alignment: .top) { Rectangle().fill(palette.line).frame(height: 1) }
    }

    /// The tool calls the "Input and result" tab shows: the selected one, or the action's.
    private var calls: [ToolCall] {
        switch key {
        case .tool(let id): model.toolsByID[id].map { [$0] } ?? []
        case .action(let n): model.action(n).map { model.tools(of: $0) } ?? []
        case .work(let first): model.calls(inRun: first)
        case .step(let agent, let index): model.tools(ofStep: index, agent: agent)
        default: []
        }
    }

    /// The subagent step whose calls those are, when the selection is one.
    private var step: (agent: String, index: Int)? {
        if case .step(let agent, let index) = key { (agent, index) } else { nil }
    }

    private var availableTabs: [InspectorTab] {
        calls.isEmpty ? [.details, .note] : [.details, .io, .note]
    }

    private var grip: some View {
        Rectangle().fill(.clear).frame(height: 6)
            .overlay { Capsule().fill(palette.line2).frame(width: 36, height: 3) }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStart == nil { dragStart = height }
                    height = min(640, max(140, (dragStart ?? height) - value.translation.height))
                }
                .onEnded { _ in dragStart = nil })
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .help("Drag to resize")
    }

    private func header(tabs: [InspectorTab], tab: InspectorTab) -> some View {
        let siblings = model.siblings(of: key)
        let position = siblings.firstIndex(of: key)
        return HStack(spacing: 8) {
            Picker("Tab", selection: Binding(get: { tab }, set: { window.inspectorTab = $0 })) {
                ForEach(tabs) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Badge(text: key.kindLabel, color: palette.accent)
            crumbs
            Spacer(minLength: 8)
            if window.sessionView != .transcript, model.itemID(for: key) != nil {
                Button("Show in Transcript") {
                    window.sessionView = .transcript
                    window.select(key, in: model)
                }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(palette.accent)
            }
            actionDots
            Button { step(siblings, position, -1) } label: { Image(systemName: "chevron.left") }
                .disabled(position.map { $0 <= 0 } ?? true).help("Previous")
            Button { step(siblings, position, 1) } label: { Image(systemName: "chevron.right") }
                .disabled(position.map { $0 >= siblings.count - 1 } ?? true).help("Next")
            Button { window.selection = nil } label: { Image(systemName: "xmark") }.help("Close (esc)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func step(_ siblings: [NodeKey], _ position: Int?, _ by: Int) {
        guard let position, siblings.indices.contains(position + by) else { return }
        window.select(siblings[position + by], in: model)
    }

    /// turn › action › tool, each a way back up.
    private var crumbs: some View {
        HStack(spacing: 5) {
            ForEach(Array(path.enumerated()), id: \.offset) { i, crumb in
                if i > 0 { Text("›").foregroundStyle(palette.muted) }
                if crumb.key == key {
                    Text(crumb.label).fontWeight(.semibold)
                } else {
                    Button(crumb.label) { window.select(crumb.key, in: model) }.buttonStyle(.plain).foregroundStyle(palette.accent)
                }
            }
        }
        .font(.system(size: 12)).lineLimit(1)
    }

    private var path: [(label: String, key: NodeKey)] {
        switch key {
        case .turn(let n): return [("Turn \(n)", key)]
        case .action(let n):
            guard let action = model.action(n) else { return [] }
            return [("Turn \(action.turn)", .turn(action.turn)), ("Action \(n)", key)]
        case .tool(let id):
            guard let call = model.toolsByID[id] else { return [] }
            return [("Turn \(call.turn)", .turn(call.turn)), ("Action \(call.action)", .action(call.action)), (call.displayName, key)]
        case .subagent(let id):
            guard let call = model.subagent(id)?.toolUseId.flatMap({ model.toolsByID[$0] }) else { return [("Subagent", key)] }
            return [("Turn \(call.turn)", .turn(call.turn)), ("Action \(call.action)", .action(call.action)), ("Subagent", key)]
        case .compaction(let n): return [("Compaction \(n + 1)", key)]
        case .step(let agent, let index):
            guard let call = model.subagent(agent)?.toolUseId.flatMap({ model.toolsByID[$0] }) else { return [("Subagent", .subagent(agent)), ("Step \(index)", key)] }
            return [("Turn \(call.turn)", .turn(call.turn)), ("Action \(call.action)", .action(call.action)), ("Subagent", .subagent(agent)), ("Step \(index)", key)]
        case .file(let path): return [((path as NSString).lastPathComponent, key)]
        case .outside(let id): return [(model.outsideByID[id]?.name ?? id, key)]
        case .work(let first):
            guard let turn = model.action(first)?.turn else { return [] }
            let count = model.calls(inRun: first).count
            return [("Turn \(turn)", .turn(turn)), ("\(count) tool call\(count == 1 ? "" : "s")", key)]
        }
    }

    /// One dot per action of the turn; the current one filled.
    @ViewBuilder private var actionDots: some View {
        let current: Int? = switch key {
        case .action(let n): n
        case .tool(let id): model.toolsByID[id]?.action
        default: nil
        }
        if let current, let turn = model.action(current).flatMap({ model.turn($0.turn) }), turn.actionIndexes.count > 1, turn.actionIndexes.count <= 40 {
            HStack(spacing: 3) {
                ForEach(turn.actionIndexes, id: \.self) { index in
                    Circle().fill(index == current ? palette.accent : palette.muted2).frame(width: 6, height: 6)
                        .onTapGesture { window.select(.action(index), in: model) }
                        .help("Action \(index)")
                }
            }
        }
    }
}

// MARK: Details

private struct DrawerDetails: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var model: SessionModel
    var key: NodeKey

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 24, alignment: .top)], alignment: .leading, spacing: 14) {
            switch key {
            case .turn(let n): turn(n)
            case .action(let n): action(n)
            case .tool(let id): tool(id)
            case .subagent(let id): subagent(id)
            case .compaction(let n): compaction(n)
            case .work(let first): work(first)
            case .step(let agent, let index): step(agent, index)
            case .file(let path): file(path)
            case .outside(let id): outside(id)
            }
        }
        .font(.system(size: 12.5))
    }

    private func offset(_ date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(model.doc.firstAt).rounded()))
        return String(format: "+%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60) + " · " + Format.dateTime(date)
    }

    @ViewBuilder private func turn(_ n: Int) -> some View {
        if let turn = model.turn(n) {
            let prompt = model.prompt(ofTurn: n)
            let calls = turn.actionIndexes.compactMap { model.action($0) }.flatMap { model.tools(of: $0) }
            Section_(prompt != nil ? "Prompt" : "Started by") {
                Sub("\(offset(turn.startAt)) · \(SessionModel.originLabel(turn.origin).lowercased()) · \(SessionModel.duration(turn.duration))")
                if let prompt {
                    Full(prompt.text)
                } else {
                    Sub("The agent kept working without a prompt from you: a \(SessionModel.originLabel(turn.origin).lowercased()) opened this turn.")
                }
            }
            if let context = prompt?.context, !context.isEmpty {
                Section_("\(context.count) injected block\(context.count == 1 ? "" : "s")") {
                    ForEach(Array(context.enumerated()), id: \.offset) { _, block in Full(block.text ?? "") }
                }
            }
            Section_("The agent's turn") {
                Facts(rows: [
                    ("Actions", "\(turn.actionIndexes.count)"),
                    ("Tool calls", "\(calls.count)" + (calls.contains(where: \.isError) ? ", \(calls.filter(\.isError).count) failed" : "")),
                    ("Duration", SessionModel.duration(turn.duration)),
                    ("Output", Format.tokens(turn.usage.outputTokens)),
                ])
            }
            Section_("Actions") {
                ForEach(turn.actionIndexes, id: \.self) { index in
                    if let action = model.action(index) {
                        let first = model.tools(of: action).first
                        LinkRow(symbol: first?.family.symbol ?? "text.bubble", color: first.map { palette.color($0.family) } ?? palette.ink2,
                                name: "#\(index)", label: first.map { $0.displayName + " · " + $0.label } ?? SessionModel.firstLine(action.text),
                                trailing: model.spans[index].map { SessionModel.duration($0.end.timeIntervalSince($0.at)) }) {
                            window.select(.action(index), in: model)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func action(_ n: Int) -> some View {
        if let action = model.action(n) {
            Section_("Shaped by") {
                Sub(offset(action.at) + (model.spans[n].map { " · " + SessionModel.duration($0.end.timeIntervalSince($0.at)) } ?? "") + " · " + action.model.replacingOccurrences(of: "claude-", with: ""))
                ForEach(Array(model.feeds(of: action).enumerated()), id: \.offset) { _, feed in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(palette.muted)
                        if let link = feed.link {
                            Button(feed.text) { window.select(link, in: model) }.buttonStyle(.plain).foregroundStyle(palette.accent).multilineTextAlignment(.leading)
                        } else {
                            Text(feed.text)
                        }
                    }
                }
            }
            if !action.thinking.isEmpty { Section_("Thought") { Full(action.thinking, italic: true) } }
            if !action.text.isEmpty { Section_(model.said.contains(n) ? "Said to you" : "Wrote") { Full(action.text) } }
            let calls = model.tools(of: action)
            // An action that is one tool call: say what it asked and what came back right here.
            if calls.count == 1, let call = calls.first {
                Section_("\(call.displayName) · came back") {
                    Full((call.isError ? "✕ " : "→ ") + (call.resultHead.flatMap { $0.isEmpty ? nil : $0 } ?? (call.paired ? "(empty)" : "(nothing yet)")))
                    Full(String(call.inputText.prefix(600)) + (call.inputText.count > 600 ? "…" : ""))
                    Sub("The whole input and result are under “Input and result”.")
                }
            }
            if !calls.isEmpty {
                Section_(calls.count > 1 ? "Called in parallel" : "Called") {
                    ForEach(calls) { call in
                        LinkRow(symbol: call.family.symbol, color: palette.color(call.family), name: call.displayName, label: call.label,
                                trailing: call.duration.map(SessionModel.duration), failed: call.isError) {
                            window.select(.tool(call.id), in: model)
                        }
                    }
                }
            }
            Section_("Usage") {
                Facts(rows: [
                    ("Context", Format.tokens(action.contextTokens) + " tokens"),
                    ("Cache read", Format.tokens(action.usage.cacheReadInputTokens)),
                    ("Cache write", Format.tokens(action.usage.cacheCreationInputTokens)),
                    ("Output", Format.tokens(action.usage.outputTokens)),
                    ("Stop", action.stopReason ?? "—"),
                ] + (action.cwd.map { [("Directory", Format.homeRelative($0))] } ?? []))
            }
        }
    }

    /// A folded run: every call in it, with what came back. A click shows the
    /// call in the transcript (the turn unfolds).
    @ViewBuilder private func work(_ first: Int) -> some View {
        let calls = model.calls(inRun: first)
        Section_("\(calls.count) tool call\(calls.count == 1 ? "" : "s"), folded") {
            if let start = model.action(first)?.at { Sub(offset(start)) }
            ForEach(calls) { call in
                LinkRow(symbol: call.family.symbol, color: palette.color(call.family), name: call.displayName, label: call.label,
                        trailing: call.duration.map(SessionModel.duration), failed: call.isError) {
                    window.select(.tool(call.id), in: model)
                }
            }
        }
        Section_("What came back") {
            ForEach(calls) { call in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(call.isError ? "✕" : "→").foregroundStyle(call.isError ? palette.err : palette.muted)
                    Text(call.resultHead.flatMap { $0.isEmpty ? nil : $0 } ?? (call.paired ? "(empty)" : "(nothing yet)"))
                        .foregroundStyle(call.isError ? palette.err : palette.ink2).lineLimit(1)
                }
                .font(.system(size: 11, design: .monospaced))
            }
        }
    }

    @ViewBuilder private func tool(_ id: String) -> some View {
        if let call = model.toolsByID[id] {
            Section_("Call") {
                Sub(offset(call.at) + (call.duration.map { " · " + SessionModel.duration($0) } ?? "") + (call.isError ? " · failed" : ""))
                if let failed = model.retryOf[id] {
                    Button("A retry of an earlier call that failed") { window.select(.tool(failed.toolId), in: model) }.buttonStyle(.plain).foregroundStyle(palette.accent)
                }
                if let retry = model.retriedBy[id] {
                    Button("Retried by a later call") { window.select(.tool(retry.toolId), in: model) }.buttonStyle(.plain).foregroundStyle(palette.accent)
                }
                if let sub = model.subagentsByTool[id] {
                    Button("Spawned subagent “\(sub.meta?.description ?? sub.agentId)”, \(sub.session?.actions.count ?? 0) steps") {
                        window.select(.subagent(sub.agentId), in: model)
                    }
                    .buttonStyle(.plain).foregroundStyle(palette.accent)
                }
                if let task = model.tasksByLaunch[id] {
                    Text("Launched background task \(task.id)" + (task.pickups.isEmpty ? ", never read back" : ", read back \(task.pickups.count) time\(task.pickups.count == 1 ? "" : "s")"))
                }
                if let task = model.tasksByPickup[id] {
                    Button("Reads background task \(task.id), launched in turn \(task.launch.turn)") { window.select(.tool(task.launch.toolId), in: model) }
                        .buttonStyle(.plain).foregroundStyle(palette.accent)
                }
                Facts(rows: [
                    ("Answered", call.paired ? "yes" : "no result recorded"),
                    ("Result", call.resultBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—"),
                ] + (call.spilled != nil ? [("Spilled", "to a file, too large for the transcript")] : []))
            }
            Section_("Came back") {
                Full((call.isError ? "✕ " : "→ ") + (call.resultHead ?? (call.paired ? "(empty)" : "(nothing yet)")))
                Sub("The whole input and result are under “Input and result”.")
            }
        }
    }

    @ViewBuilder private func subagent(_ id: String) -> some View {
        if let sub = model.subagent(id) {
            let handback = model.relations.handbacks.first { $0.agentId == id }
            Section_("Subagent") {
                Sub([sub.meta?.agentType, sub.meta?.model, sub.session.map { SessionModel.duration($0.lastAt.timeIntervalSince($0.firstAt)) }].compactMap { $0 }.joined(separator: " · "))
                Full(sub.meta?.description ?? id)
                if let handback {
                    Button("Handed back into action \(handback.action)") { window.select(.action(handback.action), in: model) }.buttonStyle(.plain).foregroundStyle(palette.accent)
                    if let message = handback.message, !message.isEmpty { Full(message) }
                } else {
                    Sub("No hand-back in this session.")
                }
            }
            Section_("Steps") {
                ForEach(model.steps(of: sub), id: \.index) { step in
                    LinkRow(symbol: step.family?.symbol ?? "text.bubble", color: step.family.map(palette.color) ?? palette.warn,
                            name: "\(step.index)", label: step.title, trailing: SessionModel.duration(step.seconds)) {
                        window.select(.step(agent: id, index: step.index), in: model, scroll: false)
                    }
                }
            }
        }
    }

    @ViewBuilder private func compaction(_ n: Int) -> some View {
        if model.doc.compactions.indices.contains(n) {
            let cut = model.doc.compactions[n]
            Section_("Compaction") {
                Sub(offset(cut.at) + " · " + (cut.metadata?.trigger ?? "auto"))
                Facts(rows: [
                    ("Before", Format.tokens(cut.metadata?.preTokens ?? 0) + " tokens"),
                    ("After", Format.tokens(cut.metadata?.postTokens ?? 0) + " tokens"),
                    ("Dropped so far", Format.tokens(cut.metadata?.cumulativeDroppedTokens ?? 0)),
                ])
            }
            switch store.compactionDetails[model.doc.id]?[n] {
            case .loaded(let detail): compactionDetail(detail)
            case .failed(let why): Section_("What it did") { Text(why).foregroundStyle(palette.err) }
            case .loading, nil:
                Section_("What it did") { Sub("Reading what was kept and what was put back…") }
                    .task(id: n) { await store.loadCompaction(model.doc.id, n) }
            }
            Section_("Summary the model continued from") { Full(cut.summary ?? "(not recorded)") }
        }
    }

    /// What the engine worked out about one compaction (`skit context --compaction`).
    @ViewBuilder private func compactionDetail(_ detail: CompactionDetail) -> some View {
        Section_("What it did") {
            Facts(rows: [
                detail.lastActionBefore.flatMap { $0 >= 0 ? ("Last action before", "#\($0)" + (detail.contextBefore.map { " · read \(Format.tokens($0)) tokens" } ?? "")) : nil },
                detail.firstActionAfter.flatMap { $0 >= 0 ? ("First action after", "#\($0)" + (detail.contextAfter.map { " · read \(Format.tokens($0)) tokens" } ?? "")) : nil },
                detail.durationMs.map { ("Took", SessionModel.duration(Double($0) / 1000)) },
                detail.summarisedPrompts.map { ("Prompts summarised", "\($0)") },
                detail.summary.map { ("Summary", "\(Format.tokens($0.chars)) characters in \($0.sections.count) section\($0.sections.count == 1 ? "" : "s")") },
                detail.reinjectedChars.map { ("Put back", "\(Format.tokens($0)) characters in \(detail.reinjected.count) piece\(detail.reinjected.count == 1 ? "" : "s")") },
            ].compactMap { $0 })
            HStack(spacing: 12) {
                if let before = detail.lastActionBefore, before >= 0 {
                    Button("Show the last action before") { window.select(.action(before), in: model) }
                }
                if let after = detail.firstActionAfter, after >= 0 {
                    Button("Show the first action after") { window.select(.action(after), in: model) }
                }
            }
            .buttonStyle(.plain).foregroundStyle(palette.accent)
        }
        if let sections = detail.summary?.sections, !sections.isEmpty {
            Section_("The summary's sections") {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    LinkRow(symbol: "text.alignleft", color: palette.warn, name: section.title, label: "", trailing: Format.tokens(section.chars) + " chars", action: nil)
                }
            }
        }
        if !detail.preserved.isEmpty {
            Section_("Kept word for word (\(detail.preserved.count))") {
                ForEach(Array(detail.preserved.prefix(30).enumerated()), id: \.offset) { _, piece in
                    let target: NodeKey? = (piece.action ?? -1) >= 0 ? .action(piece.action ?? 0) : (piece.turn ?? -1) >= 0 ? .turn(piece.turn ?? 0) : nil
                    LinkRow(symbol: "pin", color: palette.ink2, name: (piece.kind ?? piece.type).replacingOccurrences(of: "_", with: " "),
                            label: piece.head ?? "", trailing: Format.tokens(piece.chars) + " chars",
                            action: target.map { key in { window.select(key, in: model) } })
                }
                if detail.preserved.count > 30 { Sub("\(detail.preserved.count - 30) more") }
            }
        }
        if !detail.reinjected.isEmpty {
            Section_("Put back after the cut (\(detail.reinjected.count))") {
                ForEach(Array(detail.reinjected.prefix(30).enumerated()), id: \.offset) { _, piece in
                    LinkRow(symbol: "arrow.uturn.down", color: palette.ctx, name: piece.type.replacingOccurrences(of: "_", with: " "),
                            label: piece.head ?? "", trailing: Format.tokens(piece.chars) + " chars", action: nil)
                }
                if detail.reinjected.count > 30 { Sub("\(detail.reinjected.count - 30) more") }
            }
        }
        if !detail.fileRefs.isEmpty {
            Section_("Files the model was told to read again") {
                ForEach(detail.fileRefs, id: \.self) { path in
                    Text(Format.homeRelative(path)).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.ink2).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    /// One step of a subagent: what it wrote and what it called.
    @ViewBuilder private func step(_ agent: String, _ index: Int) -> some View {
        if let sub = model.subagent(agent), let run = sub.session, run.actions.indices.contains(index) {
            let action = run.actions[index]
            let calls = model.tools(ofStep: index, agent: agent)
            Section_("Step \(index) of \(run.actions.count)") {
                Sub(offset(action.at) + " · " + action.model.replacingOccurrences(of: "claude-", with: ""))
                Button("Subagent “\(sub.meta?.description ?? agent)”") { window.select(.subagent(agent), in: model, scroll: false) }
                    .buttonStyle(.plain).foregroundStyle(palette.accent)
            }
            if !action.thinking.isEmpty { Section_("Thought") { Full(action.thinking, italic: true) } }
            if !action.text.isEmpty { Section_("Wrote") { Full(action.text) } }
            if !calls.isEmpty {
                Section_(calls.count > 1 ? "Called in parallel" : "Called") {
                    ForEach(calls) { call in
                        LinkRow(symbol: call.family.symbol, color: palette.color(call.family), name: call.displayName, label: call.label,
                                trailing: call.duration.map(SessionModel.duration), failed: call.isError, action: nil)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(call.isError ? "✕" : "→").foregroundStyle(call.isError ? palette.err : palette.muted)
                            Text(call.resultHead.flatMap { $0.isEmpty ? nil : $0 } ?? (call.paired ? "(empty)" : "(nothing yet)"))
                                .foregroundStyle(call.isError ? palette.err : palette.ink2).lineLimit(2)
                        }
                        .font(.system(size: 11, design: .monospaced))
                    }
                    Sub("The whole input and result are under “Input and result”.")
                }
            }
            Section_("Usage") {
                Facts(rows: [
                    ("Context", Format.tokens(action.contextTokens) + " tokens"),
                    ("Output", Format.tokens(action.usage.outputTokens)),
                    ("Stop", action.stopReason ?? "—"),
                ])
            }
        }
    }

    /// A file: every call that read or wrote it, in order.
    @ViewBuilder private func file(_ path: String) -> some View {
        if let file = model.filesByPath[path] {
            Section_("File") {
                Text(Format.homeRelative(path)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                Facts(rows: [
                    ("Written", "\(file.writes) time\(file.writes == 1 ? "" : "s")"),
                    ("Read", "\(file.touches.count - file.writes) time\(file.touches.count - file.writes == 1 ? "" : "s")"),
                    ("In", "\(file.turns) turn\(file.turns == 1 ? "" : "s")"),
                ])
                Sub("Found in tool inputs: the edit tools' paths, and paths named in shell commands.")
                HStack(spacing: 8) {
                    Button("View File") {
                        // The Files view on this file, as it is now; Open and Reveal in Finder are there.
                        window.files.selected = path
                        window.files.tab = .files
                        window.files.showsTouches = false
                        window.sessionView = .files
                    }
                }
                .controlSize(.small).padding(.top, 2)
            }
            Section_("Touched by") {
                ForEach(Array(file.touches.prefix(60).enumerated()), id: \.offset) { _, touch in
                    let call = model.toolsByID[touch.toolId]
                    LinkRow(symbol: touch.mode == "write" ? "pencil" : "eye", color: touch.mode == "write" ? palette.accent : palette.muted,
                            name: "turn \(touch.turn)", label: touch.tool + (call.map { $0.label.isEmpty ? "" : " · " + $0.label } ?? ""),
                            trailing: touch.mode, failed: call?.isError ?? false) {
                        window.select(.tool(touch.toolId), in: model)
                    }
                }
                if file.touches.count > 60 { Sub("\(file.touches.count - 60) more") }
            }
        }
    }

    /// A service beyond the machine: every call that reached it.
    @ViewBuilder private func outside(_ id: String) -> some View {
        if let service = model.outsideByID[id] {
            let what = ["web": "Web host", "search": "Web search", "skill": "Skill", "connector": "Connector"][service.kind] ?? service.kind
            Section_(what) {
                Text(service.name).font(.system(size: 13, weight: .semibold)).textSelection(.enabled)
                Sub("\(service.calls.count) call\(service.calls.count == 1 ? "" : "s") in \(Set(service.calls.map(\.turn)).count) turn\(Set(service.calls.map(\.turn)).count == 1 ? "" : "s")")
            }
            Section_("Calls") {
                ForEach(Array(service.calls.prefix(60).enumerated()), id: \.offset) { _, ref in
                    let call = model.toolsByID[ref.toolId]
                    LinkRow(symbol: call?.family.symbol ?? "globe", color: palette.plug, name: "turn \(ref.turn)",
                            label: call.map { $0.label.isEmpty ? $0.displayName : $0.label } ?? ref.toolId,
                            trailing: call?.duration.map(SessionModel.duration), failed: call?.isError ?? false) {
                        window.select(.tool(ref.toolId), in: model)
                    }
                }
                if service.calls.count > 60 { Sub("\(service.calls.count - 60) more") }
            }
        }
    }
}

// MARK: Input and result

private struct DrawerIO: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var palette
    var model: SessionModel
    var calls: [ToolCall]
    /// Set when the calls are a subagent step's: their results come from its own transcript.
    var step: (agent: String, index: Int)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(calls) { call in
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(call.displayName) · INPUT".uppercased()).font(.caps).tracking(0.9).foregroundStyle(palette.muted)
                        Pre(text: call.inputText, limit: 200_000)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        result(call)
                    }
                }
            }
        }
        .task(id: calls.map(\.id)) {
            if let step {
                await store.loadStep(model.doc.id, agent: step.agent, index: step.index)
            } else {
                for action in Set(calls.map(\.action)) { await store.loadAction(model.doc.id, action) }
            }
        }
    }

    private func detail(for call: ToolCall) -> Loadable<ActionDetail>? {
        if let step { return store.stepDetails[model.doc.id]?[AppStore.stepKey(agent: step.agent, index: step.index)] }
        return store.actionDetails[model.doc.id]?[call.action]
    }

    @ViewBuilder private func result(_ call: ToolCall) -> some View {
        switch detail(for: call) {
        case .loaded(let detail):
            let result = detail.toolCalls.first { $0.id == call.id }
            let spilled = result?.resultSource.map { $0 != "transcript" } ?? false
            Text("RESULT" + (spilled ? " · SPILLED TO A FILE" : "") + (call.isError ? " · FAILED" : "")).font(.caps).tracking(0.9)
                .foregroundStyle(call.isError ? palette.err : palette.muted)
            Pre(text: result?.result.flatMap { $0.isEmpty ? nil : $0 } ?? (call.paired ? "(empty)" : "(no result recorded)"), limit: 200_000)
        case .failed(let why):
            Text(why).foregroundStyle(palette.err)
        case .loading, nil:
            Text("RESULT").font(.caps).tracking(0.9).foregroundStyle(palette.muted)
            Text("Reading the result…").foregroundStyle(palette.muted)
        }
    }
}

// MARK: Note

/// A note on the selected node, kept by the engine in annotations.json.
private struct DrawerNote: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var palette
    var sessionID: String
    var key: NodeKey
    @State private var text = ""
    @State private var saved = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $text)
                .font(.system(size: 13)).scrollContentBackground(.hidden)
                .padding(8).frame(minHeight: 110)
                .background(palette.panel, in: RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
            HStack {
                Text(text == saved ? (saved.isEmpty ? "Add a note. It is saved with the session, on this Mac." : "Saved.") : "Not saved yet.")
                    .font(.system(size: 11.5)).foregroundStyle(palette.muted)
                Spacer()
                Button("Save") { save() }.disabled(text == saved).keyboardShortcut("s", modifiers: .command)
            }
        }
        .onAppear {
            saved = store.annotation(sessionID).notes[key.noteKey] ?? ""
            text = saved
        }
        .onDisappear { if text != saved { save() } }
    }

    private func save() {
        let (id, noteKey, value) = (sessionID, key.noteKey, text)
        saved = value
        Task { await store.setNote(id, key: noteKey, value) }
    }
}

// MARK: Parts

/// A titled group of the drawer's details.
private struct Section_<Content: View>: View {
    @Environment(\.palette) private var palette
    var title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caps).tracking(0.9).foregroundStyle(palette.muted)
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct Sub: View {
    @Environment(\.palette) private var palette
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.system(size: 11.5)).foregroundStyle(palette.muted) }
}

/// Text in full, in a panel that scrolls when it is long.
private struct Full: View {
    @Environment(\.palette) private var palette
    var text: String
    var italic = false

    init(_ text: String, italic: Bool = false) {
        self.text = text
        self.italic = italic
    }

    var body: some View {
        let shown = text.count > 4000 ? String(text.prefix(4000)) + "\n… \(text.count - 4000) more characters" : text
        Text(shown).italic(italic).font(.system(size: 12)).lineSpacing(2).foregroundStyle(palette.ink2).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(palette.panel, in: RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
    }
}

/// A row that leads to another node.
private struct LinkRow: View {
    @Environment(\.palette) private var palette
    var symbol: String
    var color: Color
    var name: String
    var label: String
    var trailing: String?
    var failed = false
    var action: (() -> Void)?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(color).frame(width: 14)
            Text(name).fontWeight(.semibold).fixedSize()
            Text(label).foregroundStyle(palette.ink2).lineLimit(1)
            Spacer(minLength: 6)
            if failed { Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(palette.err) }
            if let trailing { Text(trailing).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(palette.muted) }
        }
        .font(.system(size: 12))
        .padding(.vertical, 5)
        .background(hover && action != nil ? palette.line : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { action?() }
    }
}
