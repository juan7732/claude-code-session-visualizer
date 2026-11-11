import SkitKit
import SwiftUI

/// One row of the Transcript (mock: Chat+, NOTES iterations 10 and 11).
struct TranscriptRow: View {
    var model: SessionModel
    var item: TranscriptItem

    var body: some View {
        switch item {
        case .gap(_, let seconds): GapRule(seconds: seconds)
        case .compaction(let n): CompactionLine(model: model, index: n)
        case .prompt(let turn): PromptCard(model: model, turn: turn)
        case .systemTurn(let turn): SystemLine(model: model, turn: turn)
        case .action(let n): ActionBlock(model: model, index: n)
        case .event(let n): EventLine(model: model, index: n)
        case .turnEnd(let turn): TurnEndLine(model: model, turn: turn)
        case .work(let turn, let actions): WorkRow(model: model, turn: turn, actions: actions)
        }
    }
}

/// "21m later" between two turns.
private struct GapRule: View {
    @Environment(\.palette) private var palette
    var seconds: TimeInterval

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(palette.line2).frame(height: 1)
            Text("\(SessionModel.duration(seconds)) later").font(.label(11)).foregroundStyle(palette.muted).fixedSize()
            Rectangle().fill(palette.line2).frame(height: 1)
        }
        .padding(.top, 22).padding(.bottom, 14)
        .accessibilityElement(children: .combine)
    }
}

private struct CompactionLine: View {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var model: SessionModel
    var index: Int

    var body: some View {
        let cut = model.doc.compactions[index]
        let selected = window.selection == .compaction(index)
        HStack(spacing: 8) {
            Image(systemName: "scissors").font(.system(size: 11))
            Text("Context compacted (\(cut.metadata?.trigger ?? "auto")) · \(Format.tokens(cut.metadata?.preTokens ?? 0)) → \(Format.tokens(cut.metadata?.postTokens ?? 0)) · the model continued from a summary")
                .font(.system(size: 12))
            Spacer(minLength: 0)
        }
        .foregroundStyle(palette.warn)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(selected ? palette.warn.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metric.radius, style: .continuous).strokeBorder(palette.warn, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .focusRing(.compaction(index))
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .onTapGesture { window.select(.compaction(index), in: model, scroll: false) }
    }
}

/// What the human asked: a card with a dark leading edge.
private struct PromptCard: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var model: SessionModel
    var turn: Int

    var body: some View {
        let key = NodeKey.turn(turn)
        let prompt = model.prompt(ofTurn: turn)
        let text = prompt?.text ?? ""
        let long = text.count > 700
        let expanded = window.transcript.open.contains(key)
        let selected = window.selection == key
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "person.fill").font(.system(size: 10)).foregroundStyle(palette.bg)
                    .frame(width: 18, height: 18).background(palette.ink, in: RoundedRectangle(cornerRadius: 5))
                Text("You").font(.system(size: 12, weight: .semibold))
                Text(who(prompt)).font(.label(11)).foregroundStyle(palette.muted)
                if model.turn(turn)?.rewound == true { Badge(text: "↩ rewound", color: palette.warn) }
            }
            Text(InlineText(palette: palette, query: window.transcript.query).attributed(text, markdown: false))
                .font(.system(size: 13.5)).lineSpacing(3).textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: long && !expanded ? 220 : nil, alignment: .topLeading)
                .clipped()
                .mask {
                    if long && !expanded {
                        LinearGradient(stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                    } else {
                        Rectangle()
                    }
                }
            if long {
                Button(expanded ? "Show less" : "Show more") { window.transcript.open.formSymmetricDifference([key]) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(palette.accent)
            }
            NoteChip(sessionID: model.doc.id, key: key)
        }
        .padding(.leading, 14).padding(.trailing, 14).padding(.top, 10).padding(.bottom, 12)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(selected ? palette.accentSoft : palette.panel)
                .background { Panel(shadow: palette.shadow.opacity(0.5), radius: 9, y: 6) }
        }
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16).fill(palette.ink).frame(width: 4)
        }
        .focusRing(key, radius: 16)
        .padding(.top, 6).padding(.bottom, 10)
        .contentShape(Rectangle())
        .onTapGesture { window.select(key, in: model, scroll: false) }
        .nodeMenu(key, model: model)
    }

    private func who(_ prompt: Prompt?) -> String {
        var parts = [prompt.map { $0.at.formatted(date: .omitted, time: .shortened) } ?? "", "turn \(turn)"]
        if let images = prompt?.images, images > 0 { parts.append("\(images) image\(images == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

/// A turn nobody typed: a task notification or a hook made the agent act again.
private struct SystemLine: View {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var model: SessionModel
    var turn: Int

    var body: some View {
        let key = NodeKey.turn(turn)
        let t = model.turn(turn)
        // The background task this turn picks up, when its first action reads one.
        let task = t?.actionIndexes.compactMap { model.action($0) }.flatMap { model.tools(of: $0) }.compactMap { model.tasksByPickup[$0.id] }.first
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 11)).foregroundStyle(palette.ctx)
            (Text(SessionModel.originLabel(t?.origin ?? "system")).fontWeight(.semibold).foregroundStyle(palette.ink)
                + Text(" · \(t?.startAt.formatted(date: .omitted, time: .shortened) ?? "") · ")
                + Text(task.map { "background task \($0.id) finished\($0.label.map { " (\($0))" } ?? ""), the agent picks it up" } ?? "the agent continued on its own"))
                .font(.system(size: 12)).foregroundStyle(palette.ink2).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(window.selection == key ? palette.accentSoft : palette.panel2, in: RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metric.radius, style: .continuous).strokeBorder(palette.line2, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .focusRing(key)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { window.select(key, in: model, scroll: false) }
        .nodeMenu(key, model: model)
    }
}

/// One action: what the model thought, wrote and called.
private struct ActionBlock: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    @AppStorage(SettingsKey.showThinking) private var showThinking = true
    var model: SessionModel
    var index: Int
    @State private var hover = false

    var body: some View {
        let key = NodeKey.action(index)
        if let action = model.action(index) {
            let state = window.transcript
            // In a folded turn the calls are in the run's line below; the words stay.
            let tools = state.folded.contains(action.turn) ? [] : model.tools(of: action)
            let first = model.turn(action.turn)?.actionIndexes.first == index
            VStack(alignment: .leading, spacing: 0) {
                if first {
                    HStack(spacing: 8) {
                        Text("Claude · \(action.at.formatted(date: .omitted, time: .shortened))").font(.label(11)).foregroundStyle(palette.muted)
                        if action.rewound == true { Badge(text: "↩ rewound", color: palette.warn) }
                        Spacer()
                    }
                    .padding(.top, 10).padding(.bottom, 4)
                }
                ForEach(model.handbacksByAction[index] ?? [], id: \.agentId) { handback in
                    HandbackNote(model: model, handback: handback)
                }
                if action.synthetic == true {
                    Label(action.text.isEmpty ? "Claude Code wrote this, not the model" : SessionModel.firstLine(action.text, max: 200), systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(action.syntheticKind == "api_error" ? palette.err : palette.muted)
                        .padding(.vertical, 4)
                } else {
                    // What the action wrote was read and split into blocks when the model was built, not here at every redraw.
                    let prose = model.prose(index) ?? SessionModel.Prose()
                    if showThinking, !prose.thinking.isEmpty { thought(prose, state) }
                    if prose.hasWords {
                        MarkdownText(blocks: prose.blocks, query: state.query)
                            .padding(.leading, model.said.contains(index) ? 10 : 0)
                            .overlay(alignment: .leading) {
                                if model.said.contains(index) { Rectangle().fill(palette.ink).frame(width: 3) }
                            }
                            .padding(.top, 2).padding(.bottom, 6)
                    }
                }
                if tools.count > 1 {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(tools.count) TOOL CALLS IN PARALLEL").font(.caps).tracking(0.9).foregroundStyle(palette.muted).padding(.vertical, 2)
                        ForEach(tools) { ToolRow(model: model, call: $0) }
                    }
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(palette.line2).frame(width: 2) }
                    .padding(.vertical, 6)
                } else {
                    ForEach(tools) { ToolRow(model: model, call: $0) }
                }
                NoteChip(sessionID: model.doc.id, key: key)
            }
            .padding(.leading, 2).padding(.trailing, 36).padding(.top, 4).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(window.selection == key ? palette.accentSoft : (hover ? palette.panel : .clear), in: RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
            .overlay(alignment: .topTrailing) {
                Text("#\(index)").font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.muted2)
                    .padding(.top, first ? 14 : 6).padding(.trailing, 8)
                    .opacity(hover || first || window.selection == key ? 1 : 0)
            }
            .focusRing(key)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { window.select(key, in: model, scroll: false) }
            .nodeMenu(key, model: model)
        }
    }

    private func thought(_ prose: SessionModel.Prose, _ state: TranscriptState) -> some View {
        let open = state.openThoughts.contains(index)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "bubble.left").font(.system(size: 10))
            Text(InlineText(palette: palette, query: state.query).attributed(open ? prose.thinking : prose.thinkingLine, markdown: false))
                .italic().lineSpacing(2).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12)).foregroundStyle(open ? palette.ink2 : palette.muted)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { state.openThoughts.formSymmetricDifference([index]) }
        .help(open ? "Fold the thinking" : "Show the whole thinking")
    }
}

/// A subagent coming back into the turn that used it.
private struct HandbackNote: View {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var model: SessionModel
    var handback: Relations.Handback

    var body: some View {
        let sub = model.subagent(handback.agentId)
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "arrow.uturn.backward").font(.system(size: 10))
            Text("Subagent “\(sub?.meta?.description ?? handback.agentId)” handed back: \(SessionModel.firstLine(handback.message ?? "done", max: 160))")
                .font(.system(size: 12))
            Button("open") { window.select(.subagent(handback.agentId), in: model) }.buttonStyle(.plain).font(.system(size: 12)).underline()
            Spacer(minLength: 0)
        }
        .foregroundStyle(palette.warn)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(palette.warn.opacity(0.14), in: RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
        .padding(.top, 8).padding(.bottom, 4)
    }
}

/// One tool call: what it was for and what came back, on one line; its input
/// and full result when opened.
struct ToolRow: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    @AppStorage(SettingsKey.compactTools) private var compact = true
    var model: SessionModel
    var call: ToolCall
    @State private var hover = false

    var body: some View {
        let key = NodeKey.tool(call.id)
        let state = window.transcript
        let open = state.open.contains(key)
        let sub = model.subagentsByTool[call.id]
        let launched = model.tasksByLaunch[call.id]
        let inline = InlineText(palette: palette, query: state.query)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: call.family.symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 18, height: 18).background(palette.color(call.family), in: RoundedRectangle(cornerRadius: 5))
                Text(call.displayName).font(.system(size: 12.5, weight: .semibold)).fixedSize()
                Text(inline.attributed(call.label, markdown: false)).font(.system(size: 12.5)).foregroundStyle(palette.ink2).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // What came back keeps its room; the label gives way and truncates.
                if compact && !open { outcome(sub: sub, launched: launched, inline: inline).lineLimit(1).truncationMode(.tail).frame(maxWidth: 300, alignment: .trailing).layoutPriority(1) }
                if let task = model.tasksByPickup[call.id] {
                    Badge(text: "task \(task.id)", color: palette.ctx).help("Reads the background task launched in turn \(task.launch.turn)")
                }
                if call.isError { Badge(text: "failed", color: palette.err) }
                if model.retryOf[call.id] != nil { Badge(text: "retry", color: palette.ink2) }
                if !call.paired { Badge(text: "no result", color: palette.muted) }
                Text(call.duration.map(SessionModel.duration) ?? "…").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(palette.muted).fixedSize()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(hover ? palette.panel2 : .clear)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { toggle(key, state) }

            if !compact || open {
                if let launched {
                    resultNote(icon: "clock.arrow.circlepath", color: palette.ctx, mono: false,
                               text: "started in the background" + (launched.pickups.first.map { " · read back in turn \($0.turn), \(SessionModel.duration($0.at.timeIntervalSince(call.at))) later" } ?? " · never read"))
                } else if sub == nil, let head = call.resultHead, !head.isEmpty || call.isError {
                    resultNote(icon: nil, color: call.isError ? palette.err : palette.muted, mono: true,
                               text: (call.isError ? "✕ " : "→ ") + (head.isEmpty ? "failed" : head))
                }
            }
            if let sub { StrandView(model: model, sub: sub, open: open) }
            if open { detail }
        }
        .background(palette.panel, in: RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                .strokeBorder(window.selection == key ? palette.accent : (call.isError ? palette.err.opacity(0.5) : .clear), lineWidth: window.selection == key ? 2 : 1)
        }
        .focusRing(key)
        .padding(.vertical, 4)
        .nodeMenu(key, model: model)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(call.displayName), \(call.label)\(call.isError ? ", failed" : "")")
    }

    private func toggle(_ key: NodeKey, _ state: TranscriptState) {
        state.open.formSymmetricDifference([key])
        state.focus = key
        if state.open.contains(key) { Task { await store.loadAction(model.doc.id, call.action) } }
    }

    /// What came back, in the row's trailing slot.
    @ViewBuilder private func outcome(sub: Subagent?, launched: Relations.BackgroundTask?, inline: InlineText) -> some View {
        if let sub {
            Label("subagent · \(sub.session?.actions.count ?? 0) steps", systemImage: "person.2").font(.system(size: 11)).foregroundStyle(palette.warn)
        } else if let launched {
            Label("background" + (launched.pickups.first.map { " → turn \($0.turn)" } ?? ""), systemImage: "clock.arrow.circlepath")
                .font(.system(size: 11)).foregroundStyle(palette.ctx)
        } else if let head = call.resultHead, !head.isEmpty || call.isError {
            Text(inline.attributed((call.isError ? "✕ " : "→ ") + (head.isEmpty ? "failed" : head), markdown: false))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(call.isError ? palette.err : palette.muted)
        }
    }

    private func resultNote(icon: String?, color: Color, mono: Bool, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 10)) }
            Text(text).font(mono ? .system(size: 11, design: .monospaced) : .system(size: 11.5)).lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(color)
        .padding(.leading, 36).padding(.trailing, 10).padding(.bottom, 7)
    }

    /// The input as given and the result as it came back, loaded on demand.
    private var detail: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("INPUT").font(.caps).tracking(0.9).foregroundStyle(palette.muted)
            Pre(text: call.inputText, query: window.transcript.query)
            switch store.actionDetails[model.doc.id]?[call.action] {
            case .loaded(let detail):
                let result = detail.toolCalls.first { $0.id == call.id }
                Text("RESULT" + (result?.resultSource.map { $0 == "transcript" ? "" : " · SPILLED TO A FILE" } ?? "")).font(.caps).tracking(0.9).foregroundStyle(palette.muted).padding(.top, 4)
                Pre(text: result?.result.flatMap { $0.isEmpty ? nil : $0 } ?? (call.paired ? "(empty)" : "(no result recorded)"), query: window.transcript.query)
            case .failed(let why):
                Text(why).font(.system(size: 12)).foregroundStyle(palette.err)
            case .loading, nil:
                Text("Reading the result…").font(.system(size: 12)).foregroundStyle(palette.muted)
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 10)
        .task { await store.loadAction(model.doc.id, call.action) }
    }
}

/// A subagent's run under the call that spawned it: one line closed, its steps open.
private struct StrandView: View {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var model: SessionModel
    var sub: Subagent
    var open: Bool

    var body: some View {
        let key = NodeKey.subagent(sub.agentId)
        let steps = model.steps(of: sub)
        let handback = model.relations.handbacks.first { $0.agentId == sub.agentId }
        let seconds = sub.session.map { $0.lastAt.timeIntervalSince($0.firstAt) } ?? 0
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: "person.2").font(.system(size: 11)).foregroundStyle(palette.warn)
                (Text("Subagent").fontWeight(.semibold).foregroundStyle(palette.ink)
                    + Text(" · \(sub.meta?.model ?? "") · \(sub.meta?.description ?? sub.agentId) · \(steps.count) steps · \(SessionModel.duration(seconds))"
                        + (handback.map { " · handed back into action \($0.action)" } ?? "")))
                    .font(.system(size: 12)).foregroundStyle(palette.ink2).lineLimit(1)
                Spacer(minLength: 0)
            }
            if open {
                ForEach(steps, id: \.index) { step in
                    // A step is a node of its own: a click inspects it.
                    let stepKey = NodeKey.step(agent: sub.agentId, index: step.index)
                    HStack(spacing: 8) {
                        Text("\(step.index)").font(.system(size: 10, design: .monospaced)).foregroundStyle(palette.muted).frame(width: 18, alignment: .trailing)
                        Image(systemName: step.family?.symbol ?? "text.bubble").font(.system(size: 10)).foregroundStyle(step.family.map(palette.color) ?? palette.muted).frame(width: 14)
                        Text(step.title).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(SessionModel.duration(step.seconds)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(palette.muted)
                    }
                    .padding(.vertical, 2).padding(.horizontal, 4)
                    .background(window.selection == stepKey ? palette.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { window.select(stepKey, in: model, scroll: false) }
                    .accessibilityAddTraits(.isButton)
                }
            } else {
                Label(SessionModel.firstLine(handback?.message ?? (sub.meta?.finished == false ? "working…" : "done"), max: 150), systemImage: "arrow.uturn.backward")
                    .font(.system(size: 11.5)).foregroundStyle(palette.warn).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                .strokeBorder(window.selection == key ? palette.accent : palette.warn.opacity(0.4), lineWidth: window.selection == key ? 2 : 1)
        }
        .focusRing(key)
        .padding(.leading, 36).padding(.trailing, 10).padding(.top, 2).padding(.bottom, 8)
        .contentShape(Rectangle())
        .onTapGesture { window.select(key, in: model, scroll: false) }
    }
}

/// An API error, or a message Claude Code wrote itself.
private struct EventLine: View {
    @Environment(\.palette) private var palette
    var model: SessionModel
    var index: Int

    var body: some View {
        let event = model.relations.events[index]
        let error = event.kind.contains("api_error")
        HStack(spacing: 8) {
            Image(systemName: error ? "exclamationmark.triangle" : "info.circle").font(.system(size: 11))
            Text((error ? "API error, retried by Claude Code" : "Claude Code") + (event.message.map { " · " + SessionModel.firstLine($0, max: 140) } ?? ""))
                .font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 6)
            Text(event.at.formatted(date: .omitted, time: .shortened)).font(.label(11))
        }
        .foregroundStyle(error ? palette.err : palette.muted)
        .padding(.horizontal, 12).padding(.vertical, 5)
    }
}

private struct TurnEndLine: View {
    @Environment(\.palette) private var palette
    var model: SessionModel
    var turn: Int

    var body: some View {
        if let t = model.turn(turn) {
            HStack(spacing: 8) {
                Text("↳").foregroundStyle(palette.ink)
                Text("TURN \(turn) ENDED · \(t.actionIndexes.count) ACTION\(t.actionIndexes.count == 1 ? "" : "S") · \(t.toolCalls) TOOL CALL\(t.toolCalls == 1 ? "" : "S") · \(SessionModel.duration(t.duration).uppercased())")
                    .tracking(0.6)
            }
            .font(.caps).foregroundStyle(palette.muted)
            .padding(.top, 6)
        }
    }
}

/// A run of tool calls folded into one line: how many, of what, whether any
/// failed, how long it took. A click shows them again.
private struct WorkRow: View {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var model: SessionModel
    var turn: Int
    var actions: [Int]
    @State private var hover = false

    var body: some View {
        if let first = actions.first {
            let key = NodeKey.work(first)
            let calls = model.calls(inRun: first)
            let failed = calls.filter(\.isError).count
            VStack(alignment: .leading, spacing: 4) {
                // The run opens the agent's reply when nothing was said before it.
                if model.turn(turn)?.actionIndexes.first == first, model.prose(first)?.hasWords == false {
                    Text("Claude · \(model.action(first)?.at.formatted(date: .omitted, time: .shortened) ?? "")")
                        .font(.label(11)).foregroundStyle(palette.muted).padding(.top, 10)
                }
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(palette.muted)
                    Text("\(calls.count) tool call\(calls.count == 1 ? "" : "s")").font(.system(size: 12.5, weight: .semibold)).fixedSize()
                    ForEach(Self.tally(calls), id: \.name) { entry in
                        HStack(spacing: 4) {
                            Image(systemName: entry.family.symbol).font(.system(size: 9)).foregroundStyle(palette.color(entry.family))
                            Text(entry.count > 1 ? "\(entry.name) \(entry.count)" : entry.name).font(.system(size: 11.5)).foregroundStyle(palette.ink2)
                        }
                        .fixedSize()
                    }
                    Spacer(minLength: 6)
                    if failed > 0 { Badge(text: "\(failed) failed", color: palette.err) }
                    if actions.count > 1 { Text("\(actions.count) steps").font(.system(size: 11)).foregroundStyle(palette.muted).fixedSize() }
                    Text(SessionModel.duration(Self.seconds(model, actions, calls))).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(palette.muted).fixedSize()
                }
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(hover ? palette.panel2 : palette.panel, in: RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Metric.radius, style: .continuous)
                        .strokeBorder(window.selection == key ? palette.accent : (failed > 0 ? palette.err.opacity(0.5) : .clear), lineWidth: window.selection == key ? 2 : 1)
                }
                .focusRing(key)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { window.setFolded(turn, false, in: model) }
            .nodeMenu(key, model: model)
            .help("Show these tool calls")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(calls.count) tool calls, folded\(failed > 0 ? ", \(failed) failed" : "")")
        }
    }

    /// The tools of the run by how often they were called, the four most used.
    private static func tally(_ calls: [ToolCall]) -> [(name: String, family: ToolFamily, count: Int)] {
        var counts: [String: (ToolFamily, Int)] = [:]
        for call in calls { counts[call.displayName, default: (call.family, 0)].1 += 1 }
        return counts.map { (name: $0.key, family: $0.value.0, count: $0.value.1) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
            .prefix(4).map { $0 }
    }

    /// From the first action of the run to the last result that came back.
    private static func seconds(_ model: SessionModel, _ actions: [Int], _ calls: [ToolCall]) -> TimeInterval {
        guard let start = actions.first.flatMap({ model.action($0) })?.at else { return 0 }
        let end = calls.compactMap(\.endedAt).max() ?? actions.last.flatMap { model.spans[$0]?.end } ?? start
        return max(0, end.timeIntervalSince(start))
    }
}

// MARK: Small parts

struct Badge: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule()).fixedSize()
    }
}

/// Preformatted text: a command, a file, a result.
struct Pre: View {
    @Environment(\.palette) private var palette
    var text: String
    var query = ""
    /// Results can be megabytes; a row shows the start and says how much more there is.
    var limit = 6000

    /// Longer than this, what is shown is drawn by a text view of its own.
    ///
    /// DECISION: SwiftUI lays a `Text` out whole, and the inspector shows a result up to 200,000
    /// characters: seconds of a stuck window for one click. The `NSTextView` the file viewer uses
    /// lays out what is on screen. It scrolls by itself, so it has a height of its own; the line is
    /// drawn above what a transcript row shows (6,000), which keeps scrolling panes out of the
    /// Transcript's own scroll.
    static let longAbove = 8000
    static let longHeight: CGFloat = 420

    var body: some View {
        let shown = Self.cut(text, limit: limit)
        Group {
            if shown.utf8.count > Self.longAbove {
                CodeView(text: Self.styled(shown, query: query, palette: palette), background: NSColor(palette.panel2))
                    .frame(height: Self.longHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
            } else {
                Text(InlineText(palette: palette, query: query).attributed(shown, markdown: false))
                    .font(.system(size: 11, design: .monospaced)).lineSpacing(2).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .background(palette.panel2, in: RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
            }
        }
    }

    /// The text, or its first `limit` characters and how many more there are.
    nonisolated static func cut(_ text: String, limit: Int) -> String {
        // A text has at most as many characters as bytes, and its bytes are counted without reading it.
        if text.utf8.count <= limit { return text }
        let count = text.count
        return count > limit ? String(text.prefix(limit)) + "\n… \(count - limit) more characters" : text
    }

    /// The same look as the short form, for the text view: monospaced, the find query marked.
    static func styled(_ text: String, query: String, palette: Palette) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        let out = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor(palette.ink), .paragraphStyle: paragraph,
        ])
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else { return out }
        let whole = text as NSString
        var from = 0
        while from < whole.length {
            let found = whole.range(of: needle, options: .caseInsensitive, range: NSRange(location: from, length: whole.length - from))
            if found.location == NSNotFound { break }
            out.addAttribute(.backgroundColor, value: NSColor(palette.warn).withAlphaComponent(0.35), range: found)
            from = found.location + max(1, found.length)
        }
        return out
    }
}

/// "✎ Note" under a row that has one.
struct NoteChip: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var palette
    var sessionID: String
    var key: NodeKey

    var body: some View {
        if let note = store.annotation(sessionID).notes[key.noteKey], !note.isEmpty {
            Label("Note", systemImage: "pencil").font(.label(11)).foregroundStyle(palette.warn)
                .padding(.horizontal, 8).padding(.vertical, 1)
                .background(palette.warn.opacity(0.14), in: Capsule())
                .padding(.top, 6)
                .help(note)
        }
    }
}

private struct FocusRing: ViewModifier {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var key: NodeKey
    var radius: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            if window.transcript.focus == key {
                RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(palette.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
        }
    }
}

private struct NodeMenu: ViewModifier {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @AppStorage(SettingsKey.inspector) private var inspector = true
    var key: NodeKey
    var model: SessionModel

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Inspect") {
                inspector = true
                window.select(key, in: model, scroll: false)
            }
            Button("Add a Note…") {
                inspector = true
                window.inspectorTab = .note
                window.select(key, in: model, scroll: false)
            }
            if let turn = model.turnIndex(of: key), (model.turn(turn)?.toolCalls ?? 0) > 0 {
                let folded = window.transcript.folded.contains(turn)
                Button(folded ? "Show This Turn's Tool Calls" : "Fold This Turn's Tool Calls") { window.setFolded(turn, !folded, in: model) }
            }
            Divider()
            if let turn = model.turnIndex(of: key) {
                Button("Copy Turn as Markdown") { Exporter.copyTurn(turn, of: model.doc.id, store: store) }
            }
            Button("Copy Link") {
                if let url = SessionLink.url(session: model.doc.id, view: .transcript, key: key) { Exporter.copy(url.absoluteString) }
            }
            if case .tool(let id) = key, let call = model.toolsByID[id] {
                Divider()
                Button("Copy Input") { Exporter.copy(call.inputText) }
            }
            if case .action(let n) = key, let action = model.action(n), !action.text.isEmpty {
                Divider()
                Button("Copy Text") { Exporter.copy(action.text) }
            }
            if case .turn(let n) = key, let prompt = model.prompt(ofTurn: n) {
                Divider()
                Button("Copy Prompt") { Exporter.copy(prompt.text) }
            }
        }
    }
}

extension View {
    /// The dashed ring that shows where the keyboard is.
    func focusRing(_ key: NodeKey, radius: CGFloat = Metric.radius) -> some View {
        modifier(FocusRing(key: key, radius: radius))
    }

    /// The same actions on every node: inspect, note, copy.
    func nodeMenu(_ key: NodeKey, model: SessionModel) -> some View {
        modifier(NodeMenu(key: key, model: model))
    }
}
