import Foundation

/// `skit` in the person's terminal: a link, in a folder their shell searches,
/// to the `skit` inside the app. A link and not a copy, so the terminal's skit
/// is always the app's own and the archiver's.
///
/// DECISION: the app does this itself and not through an engine command. It is
/// about where the app bundle is, like the link scheme the app registers, and a
/// `skit` command that puts `skit` on the PATH could not be run before it had.
///
/// DECISION: a folder of the person's own. Never one that asks for a password,
/// and never Homebrew's, where a formula for skit would later refuse to link
/// over it. The shell's profile is not edited: when the folder is not on the
/// PATH, the line to add is shown and the person adds it.
public struct CommandLineTool: Sendable {
    /// The `skit` inside the app bundle.
    public var helper: String
    public var homeDirectory: String
    /// The folders the person's shell searches, in order. Nil when the shell could not be asked.
    public var searchPath: [String]?
    /// The person's shell, for which profile the PATH line belongs in.
    public var shell: String

    public static let name = "skit"

    public init(helper: String, homeDirectory: String = NSHomeDirectory(), searchPath: [String]? = nil,
                shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") {
        self.helper = helper
        self.homeDirectory = homeDirectory
        self.searchPath = searchPath
        self.shell = shell
    }

    /// Where the link may go, in order of preference.
    public var candidates: [String] {
        [homeDirectory + "/.local/bin", homeDirectory + "/bin", "/usr/local/bin"]
    }

    public struct Status: Equatable, Sendable {
        /// The link to this app's skit, when there is one.
        public var link: String?
        /// Where Install puts the link (or has put it).
        public var destination: String
        /// The link's folder is on the shell's PATH. Nil when the PATH is not known.
        public var onPath: Bool?
        /// What `skit` means in a terminal now: the first one on the PATH. Nil when there is none or the PATH is not known.
        public var resolved: String?
        /// The destination holds a `skit` that is not a link of this app's. It is never replaced.
        public var occupied: Bool
        /// The destination holds a link of this app's kind that points at another copy of the app, or at one that is gone.
        public var stale: String?
        /// The app is somewhere that does not last (a disk image, App Translocation): a link there would break.
        public var place: BundlePlace

        public init(link: String?, destination: String, onPath: Bool?, resolved: String?, occupied: Bool, stale: String?, place: BundlePlace) {
            self.link = link
            self.destination = destination
            self.onPath = onPath
            self.resolved = resolved
            self.occupied = occupied
            self.stale = stale
            self.place = place
        }

        /// A terminal runs this app's skit.
        public var works: Bool { link != nil && resolved == link }
        /// Another skit comes first on the PATH.
        public var shadowedBy: String? { link != nil && resolved != nil && resolved != link ? resolved : nil }
    }

    public enum Failure: Error, Equatable {
        /// There is a `skit` at the path that this app did not put there.
        case occupied(String)
        case unstable(BundlePlace)
    }

    // MARK: What is there

    public func status() -> Status {
        let destination = self.destination()
        let path = destination + "/" + Self.name
        let link = candidates.map { $0 + "/" + Self.name }.first { isLink($0, to: helper) }
        var stale: String?
        if link == nil, let target = ownLinkTarget(path), !same(target, helper) { stale = target }
        let folder = link.map { ($0 as NSString).deletingLastPathComponent } ?? destination
        return Status(
            link: link,
            destination: path,
            onPath: searchPath.map { $0.contains { same($0, folder) } },
            resolved: resolved(),
            occupied: link == nil && exists(path) && ownLinkTarget(path) == nil,
            stale: stale,
            place: BundlePlace.of(helper))
    }

    /// The folder the link goes in: where one of this app's already is, else the first candidate
    /// that the shell searches and the person can write to, else `~/.local/bin`.
    public func destination() -> String {
        if let held = candidates.first(where: { ownLinkTarget($0 + "/" + Self.name) != nil }) { return held }
        if let searchPath {
            let found = candidates.first { folder in
                searchPath.contains { same($0, folder) } && FileManager.default.isWritableFile(atPath: folder)
            }
            if let found { return found }
        }
        return candidates[0]
    }

    /// The first `skit` on the shell's PATH, as a terminal would find it.
    private func resolved() -> String? {
        guard let searchPath else { return nil }
        for folder in searchPath {
            let path = (folder as NSString).appendingPathComponent(Self.name)
            if FileManager.default.isExecutableFile(atPath: path) {
                // Said the way the link is named, so the two can be compared.
                if let link = candidates.map({ $0 + "/" + Self.name }).first(where: { same($0, path) }) { return link }
                return path
            }
        }
        return nil
    }

    // MARK: Doing it

    /// Puts the link in place and returns where. A link of this app's that is already there is
    /// pointed at this copy; anything else by that name is left alone and reported.
    @discardableResult
    public func install() throws -> String {
        let place = BundlePlace.of(helper)
        guard place == .stable else { throw Failure.unstable(place) }
        let folder = destination()
        let path = folder + "/" + Self.name
        let files = FileManager.default
        if exists(path) {
            guard ownLinkTarget(path) != nil else { throw Failure.occupied(path) }
            try files.removeItem(atPath: path)
        }
        try files.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try files.createSymbolicLink(atPath: path, withDestinationPath: helper)
        return path
    }

    /// Removes the links this app made, wherever among the candidates they are, and returns them.
    /// A `skit` that is not such a link is not touched.
    @discardableResult
    public func remove() throws -> [String] {
        var removed: [String] = []
        for path in candidates.map({ $0 + "/" + Self.name }) where ownLinkTarget(path) != nil {
            try FileManager.default.removeItem(atPath: path)
            removed.append(path)
        }
        return removed
    }

    // MARK: The line for the profile

    public struct Hint: Equatable, Sendable {
        /// The file the line belongs in, as the person would write it.
        public var file: String
        public var line: String
    }

    /// What to add to the shell's profile so that it searches `folder`.
    public func hint(for folder: String) -> Hint {
        let shown = folder.hasPrefix(homeDirectory + "/") ? "$HOME" + folder.dropFirst(homeDirectory.count) : folder
        switch (shell as NSString).lastPathComponent {
        case "fish": return Hint(file: "~/.config/fish/config.fish", line: "fish_add_path \"\(shown)\"")
        case "bash": return Hint(file: "~/.bash_profile", line: "export PATH=\"\(shown):$PATH\"")
        case "zsh": return Hint(file: "~/.zshrc", line: "export PATH=\"\(shown):$PATH\"")
        default: return Hint(file: "your shell's profile", line: "export PATH=\"\(shown):$PATH\"")
        }
    }

    // MARK: Asking the shell

    private static let marker = "__SKIT_PATH__"

    /// The PATH a new terminal window would have: the person's shell is started as a terminal
    /// starts it (login, interactive), asked for `$PATH`, and that is all. Nil when it does not
    /// answer in time or at all.
    ///
    /// A GUI app's own PATH is the system's short one, not the one the profile builds, so there
    /// is no other way to know whether a folder is searched.
    public static func shellSearchPath(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                                       timeout: TimeInterval = 5) async -> [String]? {
        guard shell.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<[String]?, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-l", "-i", "-c", "echo \"\(marker)$PATH\""]
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            let collected = Collected()
            pipe.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData) }
            process.terminationHandler = { _ in
                // What the shell wrote last may still be on its way through the pipe.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: parse(collected.text))
                }
            }
            do { try process.run() } catch {
                process.terminationHandler = nil
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: nil)
                return
            }
            // An interactive shell does not stop when asked politely, and nothing of it is worth keeping.
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    /// The folders in what the shell printed: the last marked line, split at the colons.
    static func parse(_ output: String) -> [String]? {
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.contains(marker) }),
              let at = line.range(of: marker) else { return nil }
        let folders = line[at.upperBound...].split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        return folders.isEmpty ? nil : folders
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ more: Data) { lock.withLock { data.append(more) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

    // MARK: Files

    /// True when anything is at the path, a link that leads nowhere included.
    private func exists(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    /// Where the link at `path` points, when it is a link to a `skit` inside an app bundle: the
    /// kind this app makes. Nil for anything else, which is somebody else's.
    private func ownLinkTarget(_ path: String) -> String? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
              target.hasSuffix(".app/Contents/Helpers/" + Self.name) else { return nil }
        return target
    }

    private func isLink(_ path: String, to target: String) -> Bool {
        ownLinkTarget(path).map { same($0, target) } ?? false
    }

    private func same(_ a: String, _ b: String) -> Bool {
        (a as NSString).standardizingPath == (b as NSString).standardizingPath
    }
}
