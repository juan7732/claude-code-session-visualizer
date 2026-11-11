import SkitKit
import SwiftUI

/// The Settings window (⌘,): what is global, and a tab per view that has options.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            SummarySettings().tabItem { Label("Summary", systemImage: "rectangle.grid.2x2") }
            TranscriptSettings().tabItem { Label("Transcript", systemImage: "text.bubble") }
            CanvasSettings().tabItem { Label("Canvas", systemImage: "point.3.connected.trianglepath.dotted") }
            TimelineSettings().tabItem { Label("Timeline", systemImage: "timeline.selection") }
            EngineSettings().tabItem { Label("Engine", systemImage: "shippingbox") }
        }
        .frame(width: 560, height: 420)
    }
}

private struct GeneralSettings: View {
    @AppStorage(SettingsKey.oled) private var oled = false
    @AppStorage(SettingsKey.sidebar) private var sidebar = true
    @AppStorage(SettingsKey.fileOpener) private var chosen: String?
    @AppStorage(SettingsKey.nowReminderMinutes) private var reminderMinutes = 5

    var body: some View {
        Form {
            Section("Files") {
                let opener = chosen ?? FileOpener.fallback
                Picker("Open files with", selection: Binding(get: { opener }, set: { choice in
                    // "Other…" asks for an application; cancelling leaves the choice as it was.
                    if choice == "other" { if let path = FileOpener.choose() { chosen = path } } else { chosen = choice }
                })) {
                    Text("Each file's default application").tag("")
                    ForEach(FileOpener.installed(), id: \.id) { app in Text(app.name).tag(app.id) }
                    if opener.hasPrefix("/"), let name = FileOpener.name(opener) { Text(name).tag(opener) }
                    Divider()
                    Text("Other…").tag("other")
                }
                Text("What the Open button on a file uses: in the Files view, the inspector and the Claude page.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Now") {
                Picker("Remind me when a cache has", selection: $reminderMinutes) {
                    ForEach([2, 5, 10, 15], id: \.self) { Text("\($0) minutes left").tag($0) }
                }
                Text("For the sessions whose bell is on, on the Now page. After a session's prompt cache expires, its next prompt pays for the whole context again.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Toggle("Pure black in dark mode", isOn: $oled)
                Text("Light and dark follow System Settings. Pure black suits OLED displays.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Window") {
                Toggle("Show the sidebar", isOn: $sidebar)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SummarySettings: View {
    @AppStorage(SettingsKey.contextWindow) private var window = 1_000_000
    @AppStorage(SettingsKey.summaryDigest) private var digest = true
    @AppStorage(SettingsKey.summaryHours) private var hours = true
    @AppStorage(SettingsKey.summaryMap) private var map = true

    var body: some View {
        Form {
            Section("Context") {
                Picker("Context window", selection: $window) {
                    Text("1M tokens").tag(1_000_000)
                    Text("200k tokens").tag(200_000)
                }
                Text("What the Context card's gauge measures the peak against. A transcript does not record the window its model ran with, so this is yours to say.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Under the cards") {
                Toggle("What happened, when", isOn: $digest)
                Text("One row per turn: what you asked, what the agent said when it stopped, the files it wrote.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Map", isOn: $map)
                Text("Turns down a spine, with the files and outside services they touched beside them.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("When this session was alive", isOn: $hours)
                Text("The minutes the agent was working, by day and hour.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct CanvasSettings: View {
    var body: some View {
        Form {
            Section("The canvas") {
                CanvasOptions()
                Text("The same options are behind the gear on the Canvas. Where each session's canvas was left is remembered, for each layout.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct TimelineSettings: View {
    var body: some View {
        Form {
            Section("The playhead") {
                TimelineOptions()
                Text("Playing moves along the strip, where an idle night is one band wide, not along the clock. The same options are behind the gear on the Timeline.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct TranscriptSettings: View {
    @AppStorage(SettingsKey.compactTools) private var compact = true
    @AppStorage(SettingsKey.showThinking) private var thinking = true
    @AppStorage(SettingsKey.scrollMap) private var map = true
    @AppStorage(SettingsKey.keyHint) private var hint = true
    @AppStorage(SettingsKey.inspector) private var inspector = true
    @AppStorage(SettingsKey.foldByDefault) private var fold = false

    var body: some View {
        Form {
            Section("Tool calls") {
                Toggle("Fold them when a session opens", isOn: $fold)
                Text("Folded, a turn shows what was said and one line per run of tool calls. ← and → on a prompt fold and show a turn; ⌥⌘← and ⌥⌘→ do it for the whole session.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Compact rows", isOn: $compact)
                Text("One line per call: what it was for, what came back, how long it took. Off shows the result on a second line. A click opens the input and the full result either way.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Show") {
                Toggle("Thinking", isOn: $thinking)
                Toggle("The scroll map at the right edge", isOn: $map)
                Toggle("The keyboard hint", isOn: $hint)
                Toggle("The inspector when something is selected", isOn: $inspector)
            }
        }
        .formStyle(.grouped)
    }
}

private struct EngineSettings: View {
    @Environment(AppStore.self) private var store
    @State private var service: Loadable<ServiceStatus> = .loading
    @State private var working = false

    var body: some View {
        Form {
            Section("skit") {
                if let status = store.status {
                    LabeledContent("Version", value: status.version)
                    LabeledContent("Sessions", value: "\(status.sessionsOnDisk) on disk · \(status.index.archived) archived")
                    LabeledContent("Index", value: "\(status.index.segments) segments · \(ByteCountFormatter.string(fromByteCount: status.index.bytes, countStyle: .file))")
                    LabeledContent("Home", value: Format.homeRelative(status.skitHome))
                } else {
                    Text("Not connected.").foregroundStyle(.secondary)
                }
                LabeledContent("Socket", value: Format.homeRelative(store.client.http.socketPath))
            }
            Section("Background agent") {
                switch service {
                case .loading: Text("Checking…").foregroundStyle(.secondary)
                case .failed(let why): Text(why).foregroundStyle(.secondary)
                case .loaded(let status):
                    LabeledContent("State", value: status.running ? "Running (pid \(status.pid ?? 0))" : status.installed ? "Installed, not running" : "Not installed")
                    if let binary = status.binary { LabeledContent("Runs", value: Format.homeRelative(binary)) }
                    if let detail = status.detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                }
                Button(working ? "Installing…" : "Install or Restart the Agent") { Task { await install() } }
                    .disabled(working || store.locator.findBinary() == nil)
                Text("The agent keeps skit running from login on, so every session is archived without being asked.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await check() }
    }

    private func check() async {
        guard let binary = store.locator.findBinary() else {
            service = .failed("skit was not found.")
            return
        }
        do {
            service = .loaded(try await Task.detached { try SkitCommand(binary: binary).serviceStatus() }.value)
        } catch {
            service = .failed("\(error)")
        }
    }

    private func install() async {
        guard let binary = store.locator.findBinary() else { return }
        working = true
        defer { working = false }
        do {
            service = .loaded(try await Task.detached { try SkitCommand(binary: binary).installService() }.value)
            await store.connect()
        } catch {
            service = .failed("\(error)")
        }
    }
}
