import AppKit
import SkitKit
import SwiftUI

/// SessionVisualizer › Install Command Line Tool…: a sheet that links the app's
/// own `skit` into a folder the person's shell searches, says where, and says
/// what is in the way when something is (`CommandLineTool` does the work).
struct CommandLineToolView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.palette) private var palette
    /// A state to show as it is, for pictures: nothing is looked up or changed.
    var fixed: (tool: CommandLineTool, status: CommandLineTool.Status)?
    var done: () -> Void

    @State private var tool: CommandLineTool?
    @State private var status: CommandLineTool.Status?
    /// The app was not started from a bundle, so there is no skit of its own to link.
    @State private var noHelper = false
    @State private var failure: String?
    @State private var copied = false

    var body: some View {
        let words = CommandLineContent.words(status, noHelper: noHelper)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "terminal").font(.system(size: 20, weight: .medium)).foregroundStyle(palette.accent)
                    .frame(width: 42, height: 42).background(palette.accentSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("COMMAND LINE TOOL").font(.caps).tracking(0.9).foregroundStyle(palette.muted)
                    Text("skit in your terminal").font(.display(21))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: words.tone.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(color(words.tone))
                Text(words.headline).font(.system(size: 14, weight: .semibold))
            }
            Text(.init(words.detail)).font(.system(size: 13)).foregroundStyle(palette.ink2)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if words.showsHint, let tool, let status {
                let hint = tool.hint(for: ((status.link ?? status.destination) as NSString).deletingLastPathComponent)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Add this line to \(hint.file), then open a new terminal window:").font(.system(size: 12)).foregroundStyle(palette.muted)
                    HStack(spacing: 10) {
                        Text(hint.line).font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(palette.panel2.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Button(copied ? "Copied" : "Copy") {
                            Exporter.copy(hint.line)
                            copied = true
                        }
                        .controlSize(.small)
                    }
                }
            }
            if let failure {
                Text(failure).font(.system(size: 12)).foregroundStyle(palette.err).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if words.removable { Button("Remove Link") { remove() } }
                Spacer()
                if let action = words.action {
                    Button("Done", action: done).keyboardShortcut(.cancelAction)
                    Button(action) { install() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Done", action: done).keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 2)
        }
        .padding(24)
        .frame(width: 540, alignment: .leading)
        .background(palette.panel)
        .task { await look() }
    }

    private func color(_ tone: CommandLineContent.Tone) -> Color {
        switch tone {
        case .plain: palette.muted
        case .ok: palette.ok
        case .warn: palette.warn
        case .err: palette.err
        }
    }

    /// Finds the app's skit, asks the shell where it looks, and reads what is there. Nothing is changed.
    private func look() async {
        if let fixed {
            (tool, status) = (fixed.tool, fixed.status)
            return
        }
        guard let helper = store.locator.bundledHelper else {
            noHelper = true
            return
        }
        let path = await CommandLineTool.shellSearchPath()
        let found = CommandLineTool(helper: helper, homeDirectory: store.locator.homeDirectory, searchPath: path)
        (tool, status) = (found, found.status())
    }

    private func install() {
        guard fixed == nil, let tool else { return }
        failure = nil
        do {
            try tool.install()
        } catch let error as CommandLineTool.Failure {
            // What is in the way is already said by the state that follows.
            if case .unstable = error { failure = "The app has to be somewhere that lasts before it can be linked to." }
        } catch {
            failure = "The link could not be made: \(error.localizedDescription)"
        }
        status = tool.status()
    }

    private func remove() {
        guard fixed == nil, let tool else { return }
        failure = nil
        do { try tool.remove() } catch { failure = "The link could not be removed: \(error.localizedDescription)" }
        status = tool.status()
    }
}

/// The words of the sheet for each state the link can be in. Markdown: code in backticks.
nonisolated enum CommandLineContent {
    enum Tone: Equatable {
        case plain, ok, warn, err

        var symbol: String {
            switch self {
            case .plain: "circle.dashed"
            case .ok: "checkmark.circle.fill"
            case .warn: "exclamationmark.triangle.fill"
            case .err: "xmark.octagon.fill"
            }
        }
    }

    struct Words: Equatable {
        var tone: Tone
        var headline: String
        var detail: String
        /// The line for the shell's profile is shown under the words.
        var showsHint = false
        /// The title of the button that makes the link, when there is something to make.
        var action: String?
        var removable = false
    }

    static func words(_ status: CommandLineTool.Status?, noHelper: Bool = false) -> Words {
        if noHelper {
            return Words(tone: .plain, headline: "This copy has no skit of its own",
                         detail: "It was started from a build folder, not from an app bundle, so there is nothing inside it to link. `just install` puts a skit in `~/go/bin`.")
        }
        guard let status else {
            return Words(tone: .plain, headline: "Looking", detail: "Asking your shell where it looks for commands.")
        }
        let destination = "`\(Format.homeRelative(status.destination))`"
        if status.place != .stable {
            let from = status.place == .volume ? "a disk image" : "the folder it was downloaded to"
            return Words(tone: .err, headline: "Move the app to Applications first",
                         detail: "The app is running from \(from), a place that does not last. A link to the skit inside it would break as soon as the app moved.")
        }
        if let link = status.link.map({ "`\(Format.homeRelative($0))`" }) {
            if let other = status.shadowedBy.map({ "`\(Format.homeRelative($0))`" }) {
                return Words(tone: .warn, headline: "Linked, but another skit comes first",
                             detail: "The link is at \(link). A terminal runs \(other) instead: it is earlier on your PATH, and it can be older or newer than the app's. Remove that one to use the app's own.",
                             removable: true)
            }
            switch status.onPath {
            case false?:
                return Words(tone: .warn, headline: "Linked, but your shell does not look there",
                             detail: "The link is at \(link). That folder is not on your PATH yet.", showsHint: true, removable: true)
            case nil:
                return Words(tone: .plain, headline: "Linked",
                             detail: "The link is at \(link). Your shell could not be asked whether it looks there. If a new terminal window does not find `skit`, the line below is what is missing.",
                             showsHint: true, removable: true)
            case true?:
                return Words(tone: .ok, headline: "skit is in your terminal",
                             detail: "A new terminal window finds the app's own skit at \(link). Try `skit doctor`. The link follows the app: update the app and the terminal's skit is updated with it.",
                             removable: true)
            }
        }
        if status.occupied {
            return Words(tone: .err, headline: "Another skit is already there",
                         detail: "\(destination) was not put there by this app, so it has been left alone. Move it away, then install.", action: "Install")
        }
        if let stale = status.stale {
            return Words(tone: .warn, headline: "The link points at another copy of the app",
                         detail: "\(destination) leads to `\(Format.homeRelative(stale))`, which is not this copy or is gone. Link Again points it here.", action: "Link Again")
        }
        var detail = "The app has its own skit inside it. Install puts a link to it at \(destination), so that `skit` in a terminal is always the app's own. Nothing else is changed, and the link can be removed here."
        if let other = status.resolved {
            detail += " A terminal already finds a skit at `\(Format.homeRelative(other))`; this window says afterwards which of the two comes first."
        }
        return Words(tone: .plain, headline: "Not installed", detail: detail, action: "Install")
    }
}

#if DEBUG
/// `SessionVisualizer --tool-snapshot out.png [--state new|installed|offpath|shadowed|occupied|real] [--appearance light|dark]`
/// draws the sheet in one state to a file and exits. Nothing is linked or removed, and nothing is
/// looked up but for `real`: that one asks the shell and reads what is there for the app in
/// /Applications, as the sheet would on this Mac.
enum CommandLineToolSnapshot {
    static func run(arguments: [String]) -> Never? {
        guard let at = arguments.firstIndex(of: "--tool-snapshot"), at + 1 < arguments.count else { return nil }
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } }
        let home = NSHomeDirectory()
        let dark = value("--appearance") == "dark"
        let size = CGSize(width: 540, height: 330)
        if value("--state") == "real" {
            let locator = EngineLocator(helpersDirectory: "/Applications/SessionVisualizer.app/Contents/Helpers")
            let store = AppStore(locator: locator, socketPath: "/nonexistent/skit.sock", managesEngine: false)
            OffscreenPicture.write(Themed { CommandLineToolView {} }.environment(store), size: size, dark: dark, after: .seconds(4), to: arguments[at + 1])
        }
        let tool = CommandLineTool(helper: "/Applications/SessionVisualizer.app/Contents/Helpers/skit", homeDirectory: home, searchPath: [], shell: "/bin/zsh")
        let link = home + "/.local/bin/skit"
        var status = CommandLineTool.Status(link: nil, destination: link, onPath: false, resolved: nil, occupied: false, stale: nil, place: .stable)
        switch value("--state") ?? "new" {
        case "installed": (status.link, status.onPath, status.resolved) = (link, true, link)
        case "offpath": status.link = link
        case "shadowed": (status.link, status.onPath, status.resolved) = (link, true, home + "/go/bin/skit")
        case "occupied": status.occupied = true
        default: break
        }
        let store = AppStore(socketPath: "/nonexistent/skit.sock", managesEngine: false)
        let view = Themed { CommandLineToolView(fixed: (tool, status)) {} }.environment(store)
        OffscreenPicture.write(view, size: size, dark: dark, to: arguments[at + 1])
    }
}
#endif
