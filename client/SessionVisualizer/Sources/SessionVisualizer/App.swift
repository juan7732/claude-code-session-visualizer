import SwiftUI

@main
enum Main {
    static func main() {
        _ = Measure.run(arguments: CommandLine.arguments)
        _ = MeasureCanvas.run(arguments: CommandLine.arguments)
        if let request = SnapshotRequest(arguments: CommandLine.arguments) {
            Snapshot.run(request)
        }
        SessionVisualizerApp.main()
    }
}

struct SessionVisualizerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            // A skit-visualizer:// link goes to a window that is already open, not to a new one.
            Themed { RootView() }.environment(store)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .defaultSize(width: 1280, height: 860)
        .handlesExternalEvents(matching: ["*"])
        .commands { AppCommands(store: store) }

        // Open in New Window: a second window on one session.
        WindowGroup("Session", for: String.self) { $id in
            Themed { RootView(initialSession: id) }.environment(store)
        }
        .defaultSize(width: 1280, height: 860)

        Settings {
            SettingsView().environment(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run straight from `swift run` there is no bundle, so say what kind of app this is.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // And there is no icon: take the drawing from the checkout, so the Dock shows it.
        if Bundle.main.bundleURL.pathExtension != "app" {
            var folder = Bundle.main.bundleURL
            for _ in 0..<5 {
                folder.deleteLastPathComponent()
                guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("Package.swift").path) else { continue }
                if let icon = NSImage(contentsOf: folder.appendingPathComponent("Resources/AppIcon.png")) { NSApp.applicationIconImage = icon }
                break
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
