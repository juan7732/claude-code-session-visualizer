import AppKit
import Observation
import SkitKit
import SwiftUI

/// The first run (M16: "a first run that explains, before doing any of them").
/// Shown once, in place of the window's content, so nothing connects and no
/// background agent is installed until the person has read what it is and
/// pressed the button. Five steps: what this is, why sessions are lost and what
/// the archive is, the archiver, search and the one download, a tour. Help ›
/// Welcome to SessionVisualizer shows it again, as a sheet.
enum Onboarding {
    /// Bumped when the first run has something new that everyone should see once.
    static let version = 1
}

extension SettingsKey {
    /// The version of the first run this person has been through; 0 for none.
    static let onboardingSeen = "onboarding.seen"
}

/// Asks for the first run to be shown again (Help menu).
@Observable
final class OnboardingCenter {
    static let shared = OnboardingCenter()
    var replay = false
}

/// The window's content, behind the first run until it has been seen.
struct Onboarded<Content: View>: View {
    @AppStorage(SettingsKey.onboardingSeen) private var seen = 0
    @ViewBuilder var content: Content

    var body: some View {
        // A snapshot or an exercise is not a person: it has nothing to be told and must not be stopped.
        if seen < Onboarding.version && !Snapshot.keepsNothing {
            OnboardingView(firstRun: true) { seen = Onboarding.version }
        } else {
            @Bindable var center = OnboardingCenter.shared
            content.sheet(isPresented: $center.replay) {
                Themed { OnboardingView(firstRun: false) { center.replay = false } }
                    .frame(width: 780, height: 600)
            }
        }
    }
}

struct OnboardingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var palette
    /// True on the first run: the archiver is started here. False when shown again from Help.
    var firstRun: Bool
    /// A step to open on and facts to show, for pictures of it.
    var startAt = 0
    var fixedFacts: OnboardingFacts?
    var fixedServing: String?
    var done: () -> Void

    @State private var step = 0
    @State private var facts: OnboardingFacts?
    /// The version of an engine that already answers, before anything was started from here.
    @State private var serving: String?
    @State private var looked = false
    @State private var starting = false
    /// The button was pressed at least once: the person said yes, whatever came of it.
    @State private var agreed = false
    @State private var declined = false

    var body: some View {
        let steps = OnboardingContent.steps
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: steps[step].symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(palette.accent)
                        .frame(width: 44, height: 44).background(palette.accentSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("STEP \(step + 1) OF \(steps.count)").font(.caps).tracking(0.9).foregroundStyle(palette.muted)
                        Text(steps[step].title).font(.display(24)).lineLimit(2)
                    }
                }
                page.frame(maxWidth: .infinity, minHeight: 268, alignment: .topLeading)
                footer(count: steps.count)
            }
            .padding(28)
            .frame(maxWidth: 720)
            .background { Panel(shadow: palette.shadow.opacity(0.6), radius: 14, y: 8) }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.bg)
        .task {
            step = min(max(startAt, 0), steps.count - 1)
            if let fixedFacts {
                (facts, serving, looked) = (fixedFacts, fixedServing, true)
                return
            }
            // Looking is all that happens before the button: who answers on the socket, and what `skit doctor` counts.
            serving = (try? await store.client.routes())?.version
            if let binary = store.locator.findBinary() { facts = await OnboardingFacts.load(binary: binary) }
            looked = true
        }
    }

    @ViewBuilder private var page: some View {
        switch OnboardingContent.steps[step].id {
        case .welcome: welcome
        case .archive: archive
        case .archiver: archiver
        case .search: search
        case .tour: tour
        }
    }

    // MARK: The steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SessionVisualizer shows what Claude Code did: every session as a summary, a transcript, a canvas, a timeline and its files; search across all of them; and what is at work right now.")
                .font(.system(size: 14)).foregroundStyle(palette.ink2).fixedSize(horizontal: false, vertical: true)
            ForEach(OnboardingContent.promises, id: \.title) { promise in
                Point(symbol: promise.symbol, title: promise.title, text: promise.text)
            }
        }
    }

    private var archive: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(OnboardingContent.retention(facts)).font(.system(size: 14)).foregroundStyle(palette.ink2).fixedSize(horizontal: false, vertical: true)
            if let facts, facts.sessions > 0 {
                HStack(spacing: 22) {
                    Figure(value: "\(facts.sessions)", label: facts.sessions == 1 ? "session on this Mac" : "sessions on this Mac")
                    Figure(value: "\(facts.projects)", label: facts.projects == 1 ? "project" : "projects")
                    Figure(value: FilesContent.bytes(facts.bytes), label: "of transcripts")
                    if let oldest = facts.oldest { Figure(value: oldest.formatted(.dateTime.month(.abbreviated).day()), label: "the oldest") }
                }
            }
            Point(symbol: "archivebox", title: "A copy that stays", text: "SessionVisualizer keeps a lossless copy of every session in ~/.sessionkit, compressed, with an index beside it for search. It only ever adds to it: a session Claude Code has deleted is still here.")
            Point(symbol: "trash.slash", title: "Yours to remove", text: "Delete ~/.sessionkit and it is gone. Nothing else is written anywhere.")
        }
    }

    private var archiver: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("A small program, skit, does the reading and the keeping. It runs in the background from login on, archives each session as Claude Code writes it, and is what this window asks for everything it shows.")
                .font(.system(size: 14)).foregroundStyle(palette.ink2).fixedSize(horizontal: false, vertical: true)
            Point(symbol: "gearshape.2", title: "What gets installed", text: "One login item, dev.sessionkit.skit, that runs \"skit serve\". It listens on a socket in ~/.sessionkit that only you can open, and on no network port.")
            Point(symbol: "xmark.bin", title: "How to remove it", text: "\"skit service uninstall\" in a terminal, or remove it in System Settings › General › Login Items. The archive stays until you delete it.")
            archiverState
        }
    }

    @ViewBuilder private var archiverState: some View {
        let state = OnboardingContent.archiver(serving: serving, engine: store.engine, starting: starting, firstRun: firstRun, looked: looked)
        HStack(spacing: 10) {
            switch state.mark {
            case .working: ProgressView().controlSize(.small)
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.ok)
            case .trouble: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(palette.warn)
            case .none: Image(systemName: "circle.dashed").foregroundStyle(palette.muted)
            }
            Text(state.text).font(.system(size: 13)).foregroundStyle(palette.ink2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if state.offersStart {
                Button("Start the Archiver") {
                    starting = true
                    agreed = true
                    declined = false
                    Task {
                        await store.connect()
                        starting = false
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(palette.panel2.opacity(0.5), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        if declined, state.offersStart {
            Text("Without the archiver this window has nothing to show: it reads every session through it. Nothing has been installed. Quit now and nothing will be; open the app again when you want to start it.")
                .font(.system(size: 12)).foregroundStyle(palette.warn).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var search: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Search works on the archive, so it reaches sessions Claude Code no longer has.")
                .font(.system(size: 14)).foregroundStyle(palette.ink2).fixedSize(horizontal: false, vertical: true)
            Point(symbol: "textformat", title: "By words, at once", text: "Prompts, answers, thinking, tool calls and their results. Nothing to set up.")
            Point(symbol: "sparkle.magnifyingglass", title: "By meaning, after one download", text: "To find a turn that shares no words with your question, a small embedding model runs on this Mac. It is the one download: about 310 MB, once, from Hugging Face, with its checksum verified. Start it when you want it:")
            HStack(spacing: 10) {
                Text("skit embed").font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 6).background(palette.panel2.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Button("Copy") { Exporter.copy("skit embed") }.controlSize(.small)
                Text("in a terminal. It needs llama.cpp (brew install llama.cpp).").font(.system(size: 12)).foregroundStyle(palette.muted)
            }
            .padding(.leading, 38)
            Text("For skit in your terminal: SessionVisualizer › Install Command Line Tool…")
                .font(.system(size: 12)).foregroundStyle(palette.muted).padding(.leading, 38).padding(.top, -6)
            Point(symbol: "network.slash", title: "Nothing else uses the network", text: "No account, no telemetry, no update check. What your sessions say stays on this Mac.")
        }
    }

    private var tour: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .topLeading), GridItem(.flexible(), spacing: 14, alignment: .topLeading)], alignment: .leading, spacing: 9) {
                ForEach(OnboardingContent.places, id: \.title) { place in
                    Point(symbol: place.symbol, title: place.title, text: place.text, compact: true)
                }
            }
            Rectangle().fill(palette.line2).frame(height: 1)
            Text("INSIDE A SESSION").font(.caps).tracking(0.9).foregroundStyle(palette.muted)
            Text(OnboardingContent.views).font(.system(size: 12.5)).foregroundStyle(palette.ink2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                ForEach(OnboardingContent.keys, id: \.keys) { key in
                    HStack(spacing: 6) {
                        Text(key.keys).font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 6).padding(.vertical, 2).background(palette.panel2, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Text(key.does).font(.system(size: 12)).foregroundStyle(palette.muted)
                    }
                }
            }
        }
    }

    // MARK: Moving through it

    private func footer(count: Int) -> some View {
        let last = step == count - 1
        let onArchiver = OnboardingContent.steps[step].id == .archiver
        // DECISION: on the first run the archiver's step is not passed without a yes. The window behind
        // this connects as soon as it appears, and connecting installs the agent when none runs: going
        // on without it would install it after all. So it is started here, or the app is quit.
        let unanswered = firstRun && onArchiver && !agreed
            && OnboardingContent.archiver(serving: serving, engine: store.engine, starting: starting, firstRun: firstRun, looked: looked).offersStart
        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(0..<count, id: \.self) { index in
                    Circle().fill(index == step ? palette.accent : palette.line2).frame(width: 7, height: 7)
                }
            }
            Spacer()
            if step > 0 { Button("Back") { step -= 1 } }
            if unanswered {
                if declined {
                    Button("Quit SessionVisualizer") { NSApp.terminate(nil) }
                } else {
                    Button("Not Now") { declined = true }
                }
            } else if last {
                Button(firstRun ? "Open SessionVisualizer" : "Done") { done() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { step += 1 }.buttonStyle(.borderedProminent).keyboardShortcut(starting ? nil : .defaultAction).disabled(starting)
            }
        }
    }
}

/// A point of a step: a symbol, a few words, a sentence or two.
private struct Point: View {
    @Environment(\.palette) private var palette
    var symbol: String
    var title: String
    var text: String
    var compact = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol).font(.system(size: compact ? 13 : 15)).foregroundStyle(palette.accent).frame(width: compact ? 20 : 26, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(text).font(.system(size: compact ? 12 : 13)).foregroundStyle(palette.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct Figure: View {
    @Environment(\.palette) private var palette
    var value: String
    var label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.display(22)).monospacedDigit()
            Text(label.uppercased()).font(.caps).tracking(0.7).foregroundStyle(palette.muted)
        }
    }
}

/// What Claude Code holds on this Mac, counted by `skit doctor` before anything is installed.
nonisolated struct OnboardingFacts: Equatable, Sendable {
    var sessions = 0
    var projects = 0
    var bytes = 0
    var oldest: Date?
    /// Days after which Claude Code deletes a transcript; 0 when it says never.
    var retentionDays = 30

    /// Made-up numbers, for pictures.
    static let demo = OnboardingFacts(sessions: 214, projects: 9, bytes: 1_840_000_000, oldest: Date(timeIntervalSince1970: 1_792_000_000), retentionDays: 30)

    /// Reads `skit doctor --json`. Nil when it is not that.
    static func parse(_ data: Data) -> OnboardingFacts? {
        struct Doctor: Decodable {
            struct Retention: Decodable { var cleanup_period_days: Int }
            struct Project: Decodable { var sessions: [Session]? }
            struct Session: Decodable {
                var kind: String?
                var bytes: Int?
                var subagent_bytes: Int?
                var mod_time: Date?
            }
            var retention: Retention?
            var projects: [Project]?
        }
        guard let doctor = try? JSONDecoder.skit().decode(Doctor.self, from: data) else { return nil }
        var facts = OnboardingFacts(retentionDays: doctor.retention?.cleanup_period_days ?? 30)
        for project in doctor.projects ?? [] {
            let sessions = (project.sessions ?? []).filter { $0.kind == nil || $0.kind == "main" }
            if !sessions.isEmpty { facts.projects += 1 }
            for session in sessions {
                facts.sessions += 1
                facts.bytes += (session.bytes ?? 0) + (session.subagent_bytes ?? 0)
                if let at = session.mod_time, facts.oldest.map({ at < $0 }) ?? true { facts.oldest = at }
            }
        }
        return facts
    }

    /// Runs `skit doctor --json`: it reads Claude Code's folder and installs nothing.
    static func load(binary: String) async -> OnboardingFacts? {
        await Task.detached(priority: .utility) { () -> OnboardingFacts? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["doctor", "--json"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? parse(data) : nil
        }.value
    }
}

/// The words of the first run, and what its one decision shows.
nonisolated enum OnboardingContent {
    enum StepID: Equatable { case welcome, archive, archiver, search, tour }

    struct Step: Equatable {
        var id: StepID
        var symbol: String
        var title: String
    }

    static let steps = [
        Step(id: .welcome, symbol: "hand.wave", title: "Welcome to SessionVisualizer"),
        Step(id: .archive, symbol: "clock.arrow.circlepath", title: "Claude Code forgets. This keeps."),
        Step(id: .archiver, symbol: "gearshape.2", title: "The archiver"),
        Step(id: .search, symbol: "magnifyingglass", title: "Finding things again"),
        Step(id: .tour, symbol: "map", title: "Where things are"),
    ]

    static let promises: [(symbol: String, title: String, text: String)] = [
        ("eye", "It only reads Claude Code's files", "Your sessions live in ~/.claude. This app never writes there, and never changes how Claude Code works."),
        ("internaldrive", "It keeps its own copy, on this Mac", "A lossless archive in ~/.sessionkit, so a session is still here after Claude Code has deleted it."),
        ("lock", "Nothing leaves this Mac", "No account and no telemetry. The network is used for one thing, once, and only if you ask: a model for search by meaning."),
    ]

    /// What Claude Code does with a transcript in time, with this Mac's own setting when it is known.
    static func retention(_ facts: OnboardingFacts?) -> String {
        let days = facts?.retentionDays ?? 30
        if days <= 0 { return "Claude Code keeps a transcript of every session in ~/.claude/projects. On this Mac it is set to keep them, but they stay plain files that a cleanup, a reinstall or a new Mac can take with it." }
        let when = facts == nil ? "after 30 days unless told otherwise" : "\(days) days after it was last used"
        return "Claude Code keeps a transcript of every session in ~/.claude/projects, and deletes each one \(when). What you worked out with it last month is gone unless something kept it."
    }

    static let places: [(symbol: String, title: String, text: String)] = [
        ("rectangle.stack", "Sessions", "Every session, by project. Pin, tag, open."),
        ("bolt", "Now", "What each running session is doing, and how long its prompt cache will last."),
        ("magnifyingglass", "Search", "Across every session kept, by words or by meaning."),
        ("chart.bar", "Stats", "A year of days, tools, models, where the time went."),
        ("puzzlepiece.extension", "Primitives", "Skills, agents, connectors: what is installed and what is used."),
        ("asterisk", "Claude", "How Claude Code itself is set up on this Mac."),
    ]

    static let views = "Summary (⌘1) for what happened at a glance, Transcript (⌘2) to read it, Canvas (⌘3) and Timeline (⌘4) to see how the work went, Files (⌘5) for what it touched."

    static let keys: [(keys: String, does: String)] = [("⌘K", "open a session"), ("⌘R", "refresh"), ("⌘F", "find in a session"), ("⌥⌘E", "back to its editor")]

    enum Mark: Equatable { case none, working, ok, trouble }

    /// The archiver's line: what is running, what the button would do, how starting went.
    static func archiver(serving: String?, engine: EngineState, starting: Bool, firstRun: Bool, looked: Bool) -> (mark: Mark, text: String, offersStart: Bool) {
        if starting {
            return (.working, "Starting the archiver.", false)
        }
        switch engine {
        case .ready:
            return (.ok, "The archiver is running. It is going through your sessions now; the first pass can take a few minutes.", false)
        case .starting:
            return (.working, "Starting the archiver.", false)
        case .missing:
            return (.trouble, "The archiver could not be found in this copy of the app. Go on: the window will say what to do.", false)
        case .misplaced(let place):
            return (.trouble, AppStore.moveAdvice(place), false)
        case .incompatible(let version, _), .unreadable(let version, _):
            return (.trouble, "An older archiver (skit \(version)) is running and does not match this app. Go on: the window offers to bring it up to date.", false)
        case .failed(let why):
            return (.trouble, "It did not start: \(why)", firstRun)
        case .connecting:
            break
        }
        if let serving { return (.ok, "An archiver is already running on this Mac (skit \(serving)). Nothing needs to be installed.", false) }
        if !looked { return (.working, "Looking for an archiver that is already running.", false) }
        return (.none, firstRun ? "Not running yet. Nothing has been installed." : "The archiver is not running.", firstRun)
    }
}

#if DEBUG
/// `SessionVisualizer --onboarding-snapshot out.png [--step 0…4] [--appearance light|dark] [--size 1100x760]`
/// draws one step of the first run to a file and exits, with made-up numbers and nothing asked of
/// an engine. For the README and the launch pictures.
enum OnboardingSnapshot {
    static func run(arguments: [String]) -> Never? {
        guard let at = arguments.firstIndex(of: "--onboarding-snapshot"), at + 1 < arguments.count else { return nil }
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } }
        let output = arguments[at + 1]
        let step = value("--step").flatMap(Int.init) ?? 0
        let dark = value("--appearance") == "dark"
        let parts = (value("--size") ?? "1100x760").split(separator: "x").compactMap { Double($0) }
        let size = parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : CGSize(width: 1100, height: 760)

        let store = AppStore(socketPath: "/nonexistent/skit.sock", managesEngine: false)
        // The archiver's step is drawn as a new Mac sees it: nothing running, the button offered.
        let view = Themed { OnboardingView(firstRun: true, startAt: step, fixedFacts: .demo, fixedServing: nil) {} }.environment(store)
        OffscreenPicture.write(view, size: size, dark: dark, to: output)
    }
}

/// Draws a view in a window nobody sees, writes it as a PNG and exits.
enum OffscreenPicture {
    static func write(_ view: some View, size: CGSize, dark: Bool, after wait: Duration = .milliseconds(700), to output: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        app.appearance = appearance
        window.appearance = appearance
        window.titlebarAppearsTransparent = true
        window.title = "SessionVisualizer"
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.setFrame(CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size), display: true)
        window.orderFrontRegardless()
        Task {
            try? await Task.sleep(for: wait)
            guard let frame = window.contentView?.superview, let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { exit(1) }
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
            exit((try? png.write(to: URL(fileURLWithPath: output))) == nil ? 1 : 0)
        }
        app.run()
        exit(0)
    }
}
#endif
