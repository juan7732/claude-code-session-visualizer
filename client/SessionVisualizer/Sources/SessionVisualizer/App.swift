import SwiftUI
import UserNotifications

@main
enum Main {
    static func main() {
        // DECISION: the two measurements stay in every build. They read a session over the socket,
        // print numbers and exit; README and ADR 0012 take them with a release build
        // (`swift build -c release`), where the numbers mean something. What draws to a file, takes
        // settings from the command line or drives a window (`--snapshot`, `--set`, `SKIT_EXERCISE`)
        // is in debug builds only: the recipes that use it (`just client-snapshot`,
        // `just client-exercise`) run the debug build.
        _ = Measure.run(arguments: CommandLine.arguments)
        _ = MeasureCanvas.run(arguments: CommandLine.arguments)
        #if DEBUG
        _ = OnboardingSnapshot.run(arguments: CommandLine.arguments)
        if let request = SnapshotRequest(arguments: CommandLine.arguments) {
            Snapshot.run(request)
        }
        #endif
        SessionVisualizerApp.main()
    }
}

struct SessionVisualizerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            // A skit-visualizer:// link goes to a window that is already open, not to a new one.
            // Behind the first run until it has been seen: nothing connects, and no agent is installed, before that.
            Themed { Onboarded { RootView() } }.environment(store)
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
            SettingsView().environment(store).webLinksOnly()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let presenter = NotificationPresenter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CacheReminders.available { UNUserNotificationCenter.current().delegate = presenter }
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
