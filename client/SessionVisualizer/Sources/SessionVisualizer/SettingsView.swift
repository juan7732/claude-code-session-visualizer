import SkitKit
import SwiftUI

/// The Settings window (⌘,). A tab per view arrives with the view; M7 has
/// what is global: appearance and the engine.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            EngineSettings().tabItem { Label("Engine", systemImage: "shippingbox") }
        }
        .frame(width: 520, height: 340)
    }
}

private struct GeneralSettings: View {
    @AppStorage(SettingsKey.oled) private var oled = false
    @AppStorage(SettingsKey.sidebar) private var sidebar = true

    var body: some View {
        Form {
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
