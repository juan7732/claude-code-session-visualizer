import ImageIO
import SkitKit
import SwiftUI

/// What the session touched (mock: `?view=files`): every file with the turns
/// that touched it and what each touch did; the context Claude Code added to
/// the prompts; the images that were pasted in or came back from a tool.
struct FilesView: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    @AppStorage(SettingsKey.inspector) private var inspector = true
    var model: SessionModel
    @FocusState private var filtering: Bool

    private var id: String { model.doc.id }

    var body: some View {
        let state = window.files
        let files = FilesContent.files(of: model, matching: state.filter)
        let blocks = FilesContent.context(of: model)
        let images: [SessionImage] = if case .loaded(let list) = store.images[id] { list } else { [] }
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Picker("Show", selection: Binding(get: { state.tab }, set: { state.tab = $0 })) {
                    Text("Files \(model.relations.files.count)").tag(FilesTab.files)
                    Text("Context \(blocks.count)").tag(FilesTab.context)
                    Text("Images \(model.doc.summary.images)").tag(FilesTab.images)
                }
                .pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
                switch state.tab {
                case .files: fileList(files, state)
                case .context: kindList(blocks, state)
                case .images: imageList(images)
                }
            }
            .frame(width: 400)
            Rectangle().fill(palette.line).frame(width: 1)
            Group {
                switch state.tab {
                case .files:
                    if let file = current(files, state) { FileDetail(model: model, file: file).id(file.path) } else { nothing("This session touched no file the engine can see.") }
                case .context:
                    ContextGallery(model: model, blocks: blocks.filter { state.contextKind == nil || $0.kind == state.contextKind })
                case .images:
                    ImageGallery(model: model, images: store.images[id])
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.bg)
        .overlay {
            if let index = state.lightbox, let image = images.first(where: { $0.index == index }) {
                Lightbox(model: model, image: image, images: images)
            }
        }
        .task(id: id) { await store.loadImages(id) }
        // A link to a file, or a file chosen on the Summary's map: show it here.
        .onChange(of: window.selection, initial: true) { _, key in
            if case .file(let path) = key, model.filesByPath[path] != nil {
                state.tab = .files
                state.selected = path
            }
        }
    }

    private func current(_ files: [Relations.FileTouched], _ state: FilesState) -> Relations.FileTouched? {
        state.selected.flatMap { model.filesByPath[$0] } ?? files.first
    }

    private func nothing(_ text: String) -> some View {
        Text(text).foregroundStyle(palette.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: The lists at the left

    private func fileList(_ files: [Relations.FileTouched], _ state: FilesState) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(palette.muted)
                TextField("Filter files", text: Binding(get: { state.filter }, set: { state.filter = $0 }))
                    .textFieldStyle(.plain).font(.system(size: 12.5)).focused($filtering)
                    .onKeyPress(.escape) {
                        state.filter = ""
                        filtering = false
                        return .handled
                    }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(palette.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.horizontal, 14).padding(.bottom, 6)
            if files.isEmpty {
                nothing(state.filter.isEmpty ? "No files." : "No file matches.")
            } else {
                let chosen = current(files, state)?.path
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(files, id: \.path) { file in
                            ListRow(selected: file.path == chosen, symbol: "doc", title: FilesContent.name(file.path),
                                    facts: FilesContent.facts(file), detail: Format.middleEllipsis(Format.homeRelative(file.path), max: 52)) {
                                state.selected = file.path
                                if window.selection != nil { window.selection = .file(file.path) }
                            }
                            .contextMenu {
                                Button("Inspect") {
                                    inspector = true
                                    state.selected = file.path
                                    window.selection = .file(file.path)
                                }
                                Button("Copy Path") { Exporter.copy(file.path) }
                                Button("Copy Link") {
                                    if let url = SessionLink.url(session: id, view: .files, key: .file(file.path)) { Exporter.copy(url.absoluteString) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 20)
                }
            }
        }
    }

    private func kindList(_ blocks: [FilesContent.ContextBlock], _ state: FilesState) -> some View {
        let kinds = FilesContent.kinds(blocks)
        return ScrollView {
            VStack(spacing: 2) {
                ListRow(selected: state.contextKind == nil, symbol: "square.stack.3d.up", title: "Everything", facts: "\(blocks.count) block\(blocks.count == 1 ? "" : "s")", detail: nil) {
                    state.contextKind = nil
                }
                ForEach(kinds, id: \.name) { kind in
                    ListRow(selected: state.contextKind == kind.name, symbol: "text.badge.plus", title: kind.name, facts: "\(kind.count) block\(kind.count == 1 ? "" : "s")", detail: nil) {
                        state.contextKind = kind.name
                    }
                }
                let attachments = model.doc.summary.attachments ?? 0
                if attachments > 0 {
                    Text("\(attachments) attachment\(attachments == 1 ? "" : "s") between actions (the environment, skill listings, reminders) are not listed here: the engine does not serve them as a list yet. `skit show --context` prints them.")
                        .font(.system(size: 11.5)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10).padding(.top, 10)
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 20)
        }
    }

    private func imageList(_ images: [SessionImage]) -> some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(images) { image in
                    ListRow(selected: window.files.lightbox == image.index, symbol: image.place == "prompt" ? "person.crop.rectangle" : "wrench.adjustable",
                            title: "Image \(image.index + 1)", facts: "turn \(image.turn) · \(FilesContent.place(image)) · \(FilesContent.bytes(image.size))",
                            detail: Format.dateTime(image.at)) {
                        window.files.lightbox = image.index
                    }
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 20)
        }
    }
}

/// A row of the left-hand lists: a glyph, a name with its facts beside it, a quieter line under them.
private struct ListRow: View {
    @Environment(\.palette) private var palette
    var selected: Bool
    var symbol: String
    var title: String
    var facts: String
    var detail: String?
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(palette.muted).frame(width: 16).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    (Text(title).font(.system(size: 12.5, weight: .semibold)) + Text("  " + facts).font(.system(size: 11.5)).foregroundStyle(palette.muted))
                        .lineLimit(2)
                    if let detail {
                        Text(detail).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(palette.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(selected ? palette.panel : hover ? palette.panel2.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// One file: where in the session it was touched, the file as it is now, and
/// each touch with the command or edit that made it and what came back.
private struct FileDetail: View {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    @AppStorage(SettingsKey.inspector) private var inspector = true
    var model: SessionModel
    var file: Relations.FileTouched
    @State private var all = false

    private static let first = 40

    var body: some View {
        let name = file.path.split(separator: "/").last.map(String.init) ?? file.path
        let state = window.files
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(FilesContent.name(file.path)).font(.display(20))
                    Text(Format.homeRelative(file.path)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(palette.muted).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack(spacing: 10) {
                    Text("\(file.touches.count) touch\(file.touches.count == 1 ? "" : "es"), \(file.writes) write\(file.writes == 1 ? "" : "s"), across \(file.turns) turn\(file.turns == 1 ? "" : "s")")
                        .foregroundStyle(palette.ink2)
                    Button("Inspect") {
                        inspector = true
                        window.selection = .file(file.path)
                    }
                    .buttonStyle(.plain).foregroundStyle(palette.accent)
                    Spacer()
                    Picker("Show", selection: Binding(get: { state.showsTouches }, set: { state.showsTouches = $0 })) {
                        Text("The file").tag(false)
                        Text("Touches \(file.touches.count)").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                .font(.system(size: 12.5))
            }
            TurnStrip(marks: FilesContent.strip(file, turns: model.doc.turns.count))
                .help("One mark per turn of the session: green where a turn wrote the file, grey where it only read it.")
            if state.showsTouches {
                touches(name)
            } else {
                FilePane(model: model, file: file)
            }
        }
        .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, state.showsTouches ? 0 : 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// What the session did to the file, a card a touch.
    private func touches(_ name: String) -> some View {
        let shown = all ? file.touches : Array(file.touches.prefix(Self.first))
        return ScrollView {
            // A plain stack: a file has tens of touches, not thousands.
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, touch in
                    TouchCard(model: model, touch: touch, name: name)
                }
                if file.touches.count > shown.count {
                    Button("Show the other \(file.touches.count - shown.count) touches") { all = true }.buttonStyle(.plain).foregroundStyle(palette.accent)
                }
                Text("Each touch shows the command or edit that made it. The file as it was at that turn, and what each write changed, are not here yet (issue #5).")
                    .font(.system(size: 11.5)).foregroundStyle(palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.bottom, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The session's turns as one line of marks: which wrote the file, which read it.
private struct TurnStrip: View {
    @Environment(\.palette) private var palette
    var marks: [FilesContent.Mark]

    var body: some View {
        Canvas { g, size in
            guard !marks.isEmpty else { return }
            let gap: CGFloat = marks.count > 120 ? 1 : 2
            let width = max(1, (size.width - gap * CGFloat(marks.count - 1)) / CGFloat(marks.count))
            for (i, mark) in marks.enumerated() {
                let touched = mark != .none
                let rect = CGRect(x: CGFloat(i) * (width + gap), y: touched ? 0 : 3.5, width: width, height: touched ? 10 : 3)
                g.fill(Path(roundedRect: rect, cornerRadius: min(1.5, width / 2)), with: .color(mark == .wrote ? palette.ok : mark == .read ? palette.muted : palette.line2))
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}

private struct TouchCard: View {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var model: SessionModel
    var touch: Relations.FileTouched.Touch
    var name: String

    var body: some View {
        let call = model.toolsByID[touch.toolId]
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Badge(text: touch.mode, color: touch.mode == "write" ? palette.ok : palette.muted)
                Text(call?.displayName ?? touch.tool).font(.system(size: 12.5, weight: .semibold)).fixedSize()
                Text(call.map { $0.input?["description"]?.string ?? ($0.family == .file ? "" : SessionModel.firstLine($0.label, max: 120)) } ?? "")
                    .font(.system(size: 12.5)).foregroundStyle(palette.ink2).lineLimit(1)
                Spacer(minLength: 8)
                Button("turn \(touch.turn) · action \(touch.action)") { window.reveal(.action(touch.action), in: model) }
                    .buttonStyle(.plain).foregroundStyle(palette.accent).font(.system(size: 12)).help("Show in the Transcript")
                Text(NowLine.offset(touch.at, from: model.doc.turns.first?.startAt ?? model.doc.firstAt))
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(palette.muted).fixedSize()
            }
            if let call {
                Pre(text: FilesContent.excerpt(of: FilesContent.source(call), around: name), query: name, limit: 4000)
                if let head = call.resultHead, !head.isEmpty || call.isError {
                    Text((call.isError ? "✕ " : "→ ") + (head.isEmpty ? "failed" : head))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(call.isError ? palette.err : palette.muted).lineLimit(2)
                }
            }
        }
        .padding(12)
        .background(palette.panel, in: RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
        .contextMenu {
            Button("Inspect the Call") {
                UserDefaults.standard.set(true, forKey: SettingsKey.inspector)
                window.selection = .tool(touch.toolId)
            }
            Button("Show in Transcript") { window.reveal(.action(touch.action), in: model) }
            Button("Show on the Canvas") {
                window.transcript.focus = .action(touch.action)
                window.sessionView = .canvas
            }
        }
    }
}

/// What Claude Code added to the prompts: one card per injected block.
private struct ContextGallery: View {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var model: SessionModel
    var blocks: [FilesContent.ContextBlock]

    var body: some View {
        let prompts = Set(blocks.map(\.turn)).count
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Injected context").font(.display(20))
                    Text(blocks.isEmpty ? "No injected blocks in this session." : "\(blocks.count) block\(blocks.count == 1 ? "" : "s") on \(prompts) prompt\(prompts == 1 ? "" : "s"): what Claude Code added to what you wrote.")
                        .font(.system(size: 12.5)).foregroundStyle(palette.ink2)
                }
                ForEach(blocks) { block in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(block.kind.uppercased()).font(.caps).tracking(0.9).foregroundStyle(palette.muted)
                            Spacer()
                            Button("turn \(block.turn)") { window.reveal(.turn(block.turn), in: model) }.buttonStyle(.plain).foregroundStyle(palette.accent).font(.system(size: 12))
                            Text(block.at.formatted(date: .omitted, time: .shortened)).font(.system(size: 11)).foregroundStyle(palette.muted)
                        }
                        Text(block.text.count > 900 ? String(block.text.prefix(900)) + "…" : block.text)
                            .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(palette.ink2).lineSpacing(2).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if block.text.count > 900 {
                            Text("\(block.text.count - 900) more characters").font(.system(size: 11)).foregroundStyle(palette.muted)
                        }
                    }
                    .padding(12)
                    .background(palette.panel, in: RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 60)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The session's pictures: pasted into a prompt, or returned by a tool.
private struct ImageGallery: View {
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var model: SessionModel
    var images: Loadable<[SessionImage]>?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 14)], alignment: .leading, spacing: 14) {
                switch images {
                case .loaded(let list):
                    ForEach(list) { image in
                        Button {
                            window.files.lightbox = image.index
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Picture(sessionID: model.doc.id, index: image.index)
                                    .frame(height: 160).frame(maxWidth: .infinity)
                                    .background(palette.panel2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                Text("Image \(image.index + 1)").font(.system(size: 12.5, weight: .semibold))
                                Text("turn \(image.turn) · \(FilesContent.place(image)) · \(FilesContent.bytes(image.size))").font(.system(size: 11.5)).foregroundStyle(palette.muted)
                            }
                            .padding(10)
                            .background(palette.panel, in: RoundedRectangle(cornerRadius: Metric.radius, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Image \(image.index + 1), turn \(image.turn)")
                    }
                case .failed(let why):
                    Text(why).foregroundStyle(palette.err)
                case .loading, nil:
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 60)
            if case .loaded(let list) = images, list.isEmpty {
                Text("No images in this session.").foregroundStyle(palette.muted).padding(.top, 60)
            }
        }
    }
}

/// One image of the session, fetched when it comes on screen. In the grid it is
/// a thumbnail, made once off the main thread and kept: decoding every
/// full-size picture again each time another one arrived made a session with
/// two hundred images crawl (Juan, 2026-11-10).
private struct Picture: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var palette
    var sessionID: String
    var index: Int
    /// The picture itself, for the lightbox; otherwise a thumbnail.
    var full = false
    @State private var image: NSImage?
    @State private var failure: String?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else if let failure {
                Label(failure, systemImage: "photo").font(.system(size: 11.5)).foregroundStyle(palette.muted).padding(8)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: Pictures.key(sessionID, index, full: full)) {
            let key = Pictures.key(sessionID, index, full: full)
            if let kept = Pictures.cache.object(forKey: key as NSString) {
                image = kept
                return
            }
            (image, failure) = (nil, nil)
            // A few at a time: a grid that comes on screen asks for dozens at once.
            await Pictures.gate.enter()
            defer { Task { await Pictures.gate.leave() } }
            if Task.isCancelled { return }
            do {
                let data = try await store.client.image(session: sessionID, index)
                if Task.isCancelled { return }
                let side = full ? nil : Pictures.thumbnailSide
                guard let made = await Task.detached(priority: .userInitiated, operation: { Pictures.decode(data, maxSide: side) }).value else {
                    failure = "Not an image the Mac can draw"
                    return
                }
                Pictures.cache.setObject(made, forKey: key as NSString, cost: Int(made.size.width * made.size.height * 4))
                image = made
            } catch {
                failure = "\(error)"
            }
        }
    }
}

/// The pictures already decoded, and the gate that keeps a screenful from being fetched all at once.
enum Pictures {
    static let thumbnailSide = 640
    static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 256 << 20
        return cache
    }()
    static let gate = Gate(limit: 4)

    nonisolated static func key(_ sessionID: String, _ index: Int, full: Bool) -> String {
        "\(sessionID)/\(index)/\(full ? "full" : "thumb")"
    }

    /// The image, or with `maxSide` a smaller copy no longer than that on its long side, decoded now and not at first draw.
    nonisolated static func decode(_ data: Data, maxSide: Int?) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
        if let maxSide { options[kCGImageSourceThumbnailMaxPixelSize] = maxSide }
        guard let made = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: made, size: NSSize(width: made.width, height: made.height))
    }

    /// Lets `limit` callers through at a time; the rest wait their turn.
    actor Gate {
        private var free: Int
        private var waiting: [CheckedContinuation<Void, Never>] = []

        init(limit: Int) { free = limit }

        func enter() async {
            if free > 0 {
                free -= 1
                return
            }
            await withCheckedContinuation { waiting.append($0) }
        }

        func leave() {
            if waiting.isEmpty { free += 1 } else { waiting.removeFirst().resume() }
        }
    }
}

/// One image large, over the view: ← and → step, esc closes.
private struct Lightbox: View {
    @Environment(AppStore.self) private var store
    @Environment(WindowState.self) private var window
    @Environment(\.palette) private var palette
    var model: SessionModel
    var image: SessionImage
    var images: [SessionImage]
    @FocusState private var keyboard: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).onTapGesture { window.files.lightbox = nil }
            VStack(spacing: 12) {
                Picture(sessionID: model.doc.id, index: image.index, full: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 14) {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }.disabled(images.first?.index == image.index).help("Previous image (←)")
                    Text("Image \(image.index + 1) of \(images.count) · turn \(image.turn) · \(FilesContent.place(image)) · \(image.mediaType) · \(FilesContent.bytes(image.size))")
                        .font(.system(size: 12.5)).foregroundStyle(.white)
                    Button { step(1) } label: { Image(systemName: "chevron.right") }.disabled(images.last?.index == image.index).help("Next image (→)")
                    Button("Show in Transcript") {
                        window.files.lightbox = nil
                        window.reveal(image.toolId.flatMap { model.toolsByID[$0] }.map { .action($0.action) } ?? .turn(image.turn), in: model)
                    }
                    Button("Copy") {
                        if let picture = Pictures.cache.object(forKey: Pictures.key(model.doc.id, image.index, full: true) as NSString) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.writeObjects([picture])
                        }
                    }
                    Button { window.files.lightbox = nil } label: { Image(systemName: "xmark") }.help("Close (esc)")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.black.opacity(0.55), in: Capsule())
                .environment(\.colorScheme, .dark)
            }
            .padding(28)
        }
        .focusable().focusEffectDisabled().focused($keyboard)
        .onAppear { keyboard = true }
        .onKeyPress(phases: .down) { press in
            switch press.key {
            case .escape: window.files.lightbox = nil
            case .leftArrow: step(-1)
            case .rightArrow: step(1)
            default: return .ignored
            }
            return .handled
        }
        .transition(.opacity)
    }

    private func step(_ by: Int) {
        guard let at = images.firstIndex(where: { $0.index == image.index }), images.indices.contains(at + by) else { return }
        window.files.lightbox = images[at + by].index
    }
}

/// What the Files view lists, from what the engine served: an order, a few words, an excerpt.
nonisolated enum FilesContent {
    enum Mark: Equatable, Sendable { case none, read, wrote }

    struct ContextBlock: Identifiable, Equatable, Sendable {
        var id: Int
        var turn: Int
        var at: Date
        var kind: String
        var text: String
    }

    /// The files, most written first, then most touched; narrowed to the ones whose path holds `filter`.
    static func files(of model: SessionModel, matching filter: String) -> [Relations.FileTouched] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return model.relations.files
            .filter { needle.isEmpty || $0.path.lowercased().contains(needle) }
            .sorted { a, b in
                if a.writes != b.writes { return a.writes > b.writes }
                if a.touches.count != b.touches.count { return a.touches.count > b.touches.count }
                return a.path < b.path
            }
    }

    /// "agent/CLAUDE.md": the file and the folder it is in.
    static func name(_ path: String) -> String {
        path.split(separator: "/").suffix(2).joined(separator: "/")
    }

    static func facts(_ file: Relations.FileTouched) -> String {
        (file.writes > 0 ? "\(file.writes) written · " : "") + "\(file.touches.count) touch\(file.touches.count == 1 ? "" : "es") · \(file.turns) turn\(file.turns == 1 ? "" : "s")"
    }

    /// One mark per turn of the session.
    static func strip(_ file: Relations.FileTouched, turns: Int) -> [Mark] {
        var marks = [Mark](repeating: .none, count: max(0, turns))
        for touch in file.touches where marks.indices.contains(touch.turn) {
            if touch.mode == "write" { marks[touch.turn] = .wrote } else if marks[touch.turn] == .none { marks[touch.turn] = .read }
        }
        return marks
    }

    /// What a call did to a file, as the model wrote it: the command, the content, the replacement.
    static func source(_ call: ToolCall) -> String {
        call.input?.firstString("command", "content", "new_string") ?? call.input?.pretty ?? ""
    }

    /// The part of a long command or file around the first mention of `name`: a little before, more after.
    static func excerpt(of source: String, around name: String, before: Int = 200, after: Int = 1400) -> String {
        guard source.count > before + after, !name.isEmpty, let found = source.range(of: name) else {
            return source.count > before + after ? String(source.prefix(before + after)) + "…" : source
        }
        let start = source.index(found.lowerBound, offsetBy: -before, limitedBy: source.startIndex) ?? source.startIndex
        let end = source.index(found.lowerBound, offsetBy: after, limitedBy: source.endIndex) ?? source.endIndex
        return (start > source.startIndex ? "…" : "") + source[start..<end] + (end < source.endIndex ? "…" : "")
    }

    /// The blocks Claude Code injected into the prompts, in order.
    static func context(of model: SessionModel) -> [ContextBlock] {
        var out: [ContextBlock] = []
        for turn in model.doc.turns {
            guard let prompt = model.prompt(ofTurn: turn.index) else { continue }
            for block in prompt.context {
                let text = block.text ?? ""
                let (kind, body) = named(text, type: block.type)
                out.append(ContextBlock(id: out.count, turn: turn.index, at: prompt.at, kind: kind, text: body))
            }
        }
        return out
    }

    /// `<system-reminder>…</system-reminder>` is a "system reminder": the tag names the block, and is not shown twice.
    static func named(_ text: String, type: String) -> (kind: String, body: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<"), let close = trimmed.firstIndex(of: ">") else { return (type, trimmed) }
        let tag = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        guard !tag.isEmpty, tag.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return (type, trimmed) }
        var body = String(trimmed[trimmed.index(after: close)...])
        if body.hasSuffix("</\(tag)>") { body.removeLast(tag.count + 3) }
        return (tag.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " "), body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func kinds(_ blocks: [ContextBlock]) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for block in blocks { counts[block.kind, default: 0] += 1 }
        return counts.map { (name: $0.key, count: $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    static func place(_ image: SessionImage) -> String {
        image.place == "prompt" ? "in your prompt" : "from a tool"
    }

    /// 950 B, 75 kB, 1.3 MB.
    static func bytes(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1f MB", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(Int((Double(n) / 1_000).rounded())) kB" }
        return "\(n) B"
    }
}
