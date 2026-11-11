import Foundation

/// Where the engine is on this Mac: its socket, its binary, its background agent.
public struct EngineLocator: Sendable {
    public var environment: [String: String]
    public var homeDirectory: String
    /// `Contents/Helpers` of the app bundle, when the app runs from one.
    public var helpersDirectory: String?
    /// When the bundle holds a `skit`, that is the only one this app starts (`binaryCandidates`).
    public var trustsOnlyItsHelper: Bool

    /// True in a release build: the app that ships starts the `skit` it was signed with and no other.
    public static var releaseBuild: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                homeDirectory: String = NSHomeDirectory(),
                helpersDirectory: String? = nil,
                trustsOnlyItsHelper: Bool = EngineLocator.releaseBuild) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.helpersDirectory = helpersDirectory
        self.trustsOnlyItsHelper = trustsOnlyItsHelper
    }

    /// skit's home: `$SKIT_HOME`, else `~/.sessionkit`.
    public var skitHome: String {
        if let custom = environment["SKIT_HOME"], !custom.isEmpty { return custom }
        return homeDirectory + "/.sessionkit"
    }

    /// The socket `skit serve` listens on by default.
    public var socketPath: String { skitHome + "/skit.sock" }

    /// The `skit` inside the app bundle, when the bundle holds one.
    public var bundledHelper: String? {
        guard let helpersDirectory else { return nil }
        let path = helpersDirectory + "/skit"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Places a `skit` binary may be, in order: `$SKIT_BIN`, the app's own
    /// helper, then the directories a developer install lands in. A GUI app
    /// does not inherit the shell's PATH, so those are named outright.
    ///
    /// DECISION: the signed app with a helper inside looks nowhere else. What this finds is installed
    /// as a login agent that reads every transcript, so an environment variable or a directory on the
    /// PATH must not be able to put another program in its place. A debug build, and a run without a
    /// bundle (`swift run`, tests), keep the whole list: that is how a developer points at a build.
    public var binaryCandidates: [String] {
        if trustsOnlyItsHelper, let bundledHelper { return [bundledHelper] }
        var out: [String] = []
        if let explicit = environment["SKIT_BIN"], !explicit.isEmpty { out.append(explicit) }
        if let helpersDirectory { out.append(helpersDirectory + "/skit") }
        for dir in (environment["PATH"] ?? "").split(separator: ":") where !dir.isEmpty {
            out.append(dir + "/skit")
        }
        out += [homeDirectory + "/go/bin/skit", "/opt/homebrew/bin/skit", "/usr/local/bin/skit", homeDirectory + "/.local/bin/skit"]
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// The first candidate that exists and can be executed.
    public func findBinary() -> String? {
        binaryCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Where the app bundle is, as far as installing a login agent for the `skit` inside it goes.
public enum BundlePlace: Equatable, Sendable {
    /// A place that is still there after the app quits.
    case stable
    /// App Translocation: macOS runs an app opened straight from where it was downloaded from a
    /// random read-only path, which is gone when the app quits.
    case translocated
    /// A mounted volume, such as the disk image the app came on.
    case volume

    /// The place of a path inside the bundle (or of the bundle itself).
    public static func of(_ path: String) -> BundlePlace {
        if path.contains("/AppTranslocation/") { return .translocated }
        if path.hasPrefix("/Volumes/") { return .volume }
        return .stable
    }
}

/// What the app does about the background agent when it starts.
public enum AgentPlan: Equatable, Sendable {
    /// Attach to what is serving; install the agent only when nothing is.
    case asItIs
    /// Install the agent for this `skit` before attaching: the one it names is gone or belongs to another copy of the app.
    case reinstall(String)
    /// Install nothing from where the app is now; attach when something is serving.
    case attachOnly(BundlePlace)

    /// The decision, from where the app's own `skit` is (nil without a bundle: `swift run`, tests)
    /// and what `skit service status` says about the agent (nil when it could not be asked).
    ///
    /// DECISION: an agent is repointed to this app's helper only when what it runs now is gone, or is
    /// the helper of another copy of the app (the copy that was in Downloads, a path App
    /// Translocation made up). An agent somebody installed from a `skit` of their own that is still
    /// there is kept: ADR 0011 says a Mac where an agent is already serving keeps it, and the window
    /// offers the restart when that engine turns out not to match.
    public static func decide(helper: String?, agent: ServiceStatus?) -> AgentPlan {
        guard let helper else { return .asItIs }
        let place = BundlePlace.of(helper)
        guard place == .stable else { return .attachOnly(place) }
        guard let agent, agent.installed, let binary = agent.binary, !binary.isEmpty else { return .asItIs }
        if (binary as NSString).standardizingPath == (helper as NSString).standardizingPath { return .asItIs }
        if agent.binaryExists == false || binary.hasSuffix(".app/Contents/Helpers/skit") { return .reinstall(helper) }
        return .asItIs
    }
}

/// Runs `skit` for the things that are commands, not routes: the background agent.
public struct SkitCommand: Sendable {
    public let binary: String
    /// Seconds a command may take before it is stopped.
    public var timeout: TimeInterval

    public init(binary: String, timeout: TimeInterval = 30) {
        self.binary = binary
        self.timeout = timeout
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case failed(exitCode: Int32, message: String)
        case unreadable(String)
        /// The command was still running after `seconds` and was stopped.
        case timedOut(command: String, seconds: TimeInterval)

        public var description: String {
            switch self {
            case .failed(_, let message): message
            case .unreadable(let what): what
            case .timedOut(let command, let seconds): "\(command) did not finish within \(seconds.formatted()) s and was stopped"
            }
        }
    }

    /// `skit service install --json`: writes the launchd agent that keeps
    /// `skit serve` running from login on, and starts it. Safe to repeat.
    public func installService() throws -> ServiceStatus { try run(["service", "install", "--json"]) }

    /// `skit service status --json`.
    public func serviceStatus() throws -> ServiceStatus { try run(["service", "status", "--json"]) }

    /// Blocking: call it through `Blocking.run`.
    func run<T: Decodable>(_ arguments: [String]) throws -> T {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw Failure.unreadable("cannot run \(binary): \(error.localizedDescription)")
        }
        // Both pipes are drained at once: a child that fills one while this side waits on the other
        // never finishes. And a deadline: a child that hangs is stopped, not waited for.
        let stdout = Collected(), stderr = Collected()
        let readers = DispatchGroup()
        for (pipe, into) in [(out, stdout), (err, stderr)] {
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                into.set(pipe.fileHandleForReading.readDataToEndOfFile())
                readers.leave()
            }
        }
        let late = Flag()
        let pid = process.processIdentifier
        let deadline = DispatchWorkItem {
            guard process.isRunning else { return }
            late.raise()
            process.terminate()
            // One that ignores the request is not asked twice.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(pid, SIGKILL) } }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        process.waitUntilExit()
        deadline.cancel()
        let command = "skit " + arguments.joined(separator: " ")
        if late.isRaised {
            // What it started may still hold the pipes open: its output is not waited for.
            throw Failure.timedOut(command: command, seconds: timeout)
        }
        // The child is gone; what it wrote is in the pipes. A grandchild that kept them open does not hold this up for long.
        _ = readers.wait(timeout: .now() + 5)
        guard process.terminationStatus == 0 else {
            // With --json, skit writes {"error": "..."} on stderr.
            let message = (try? JSONDecoder().decode([String: String].self, from: stderr.data))?["error"]
                ?? String(decoding: stderr.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.failed(exitCode: process.terminationStatus, message: message)
        }
        do {
            return try JSONDecoder.skit().decode(T.self, from: stdout.data)
        } catch {
            throw Failure.unreadable("\(command): \(SkitClient.describe(error))")
        }
    }

    /// What a reader thread took from a pipe.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        var data: Data { lock.withLock { bytes } }
        func set(_ data: Data) { lock.withLock { bytes = data } }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        var isRaised: Bool { lock.withLock { raised } }
        func raise() { lock.withLock { raised = true } }
    }
}

/// Reaches the engine when the app starts: attach to the `skit serve` that is
/// already answering, or have the `skit` on this Mac install its background
/// agent and wait for it. The person never sets anything up by hand (ADR 0009).
public struct EngineConnector: Sendable {
    public enum Outcome: Equatable, Sendable {
        case ready(RouteList)
        /// No `skit` in any of the places it is looked for.
        case missing(lookedIn: [String])
        /// An engine answers but lacks routes this client calls.
        case incompatible(version: String, missing: [String])
        /// Nothing is serving, and the app is somewhere an agent must not be installed from.
        case misplaced(BundlePlace)
        case failed(String)
    }

    public var client: SkitClient
    public var locator: EngineLocator
    /// False attaches only: nothing is installed (snapshots, tests).
    public var managesEngine: Bool
    /// Installs the agent for the `skit` at the given path.
    public var install: @Sendable (String) throws -> ServiceStatus
    /// Asks the `skit` at the given path what the agent runs now.
    public var status: @Sendable (String) throws -> ServiceStatus
    /// How long to wait for a freshly installed agent to answer.
    public var attempts = 20
    public var pause: Duration = .milliseconds(300)

    public init(client: SkitClient, locator: EngineLocator, managesEngine: Bool = true,
                install: @escaping @Sendable (String) throws -> ServiceStatus = { try SkitCommand(binary: $0).installService() },
                status: @escaping @Sendable (String) throws -> ServiceStatus = { try SkitCommand(binary: $0, timeout: 10).serviceStatus() }) {
        self.client = client
        self.locator = locator
        self.managesEngine = managesEngine
        self.status = status
        self.install = install
    }

    /// What to do about the agent before attaching (`AgentPlan.decide`). The agent is asked about
    /// only when the answer can change something: the app has a helper, in a place that stays.
    public func plan() async -> AgentPlan {
        guard managesEngine, let helper = locator.bundledHelper else { return .asItIs }
        guard BundlePlace.of(helper) == .stable else { return AgentPlan.decide(helper: helper, agent: nil) }
        let status = self.status
        var agent = try? await Blocking.run { try status(helper) }
        if let binary = agent?.binary {
            // An engine that does not say whether the binary is there: look.
            if agent?.binaryExists == nil { agent?.binaryExists = FileManager.default.fileExists(atPath: binary) }
            // `skit service install` records its own path with every link resolved. The same file
            // under another spelling is the same helper, not a stale agent to install over at every launch.
            if let recorded = Self.real(binary), recorded == Self.real(helper) { agent?.binary = helper }
        }
        return AgentPlan.decide(helper: helper, agent: agent)
    }

    /// The path with every symbolic link resolved, as the kernel sees it; nil when nothing is there.
    static func real(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `onStarting` is told which `skit` is being started, for the window to say so.
    public func connect(onStarting: @Sendable (String) async -> Void = { _ in }) async -> Outcome {
        let plan = await plan()
        if case .reinstall(let helper) = plan { return await start(helper, onStarting: onStarting) }
        if let outcome = await attach() { return outcome }
        guard managesEngine else { return .failed("Nothing is serving on \(client.http.socketPath).") }
        if case .attachOnly(let place) = plan { return .misplaced(place) }
        guard let binary = locator.findBinary() else { return .missing(lookedIn: locator.binaryCandidates) }
        return await start(binary, onStarting: onStarting)
    }

    /// Installs the agent for `binary` (which also restarts one that is running) and waits for it to answer.
    public func start(_ binary: String, onStarting: @Sendable (String) async -> Void = { _ in }) async -> Outcome {
        await onStarting(binary)
        do {
            let install = self.install
            _ = try await Blocking.run { try install(binary) }
        } catch {
            return .failed("skit service install: \(error)")
        }
        for attempt in 0..<attempts {
            if let outcome = await attach() { return outcome }
            if attempt < attempts - 1 { try? await Task.sleep(for: pause) }
        }
        return .failed("The background agent was installed but does not answer on \(client.http.socketPath). See serve.log in \(locator.skitHome).")
    }

    /// Nil when nothing is listening; otherwise what answered, or why it could not be asked.
    private func attach() async -> Outcome? {
        do {
            let list = try await client.routes()
            let missing = SkitClient.missingRoutes(in: list.routes)
            return missing.isEmpty ? .ready(list) : .incompatible(version: list.version, missing: missing)
        } catch SkitError.unreachable {
            return nil
        } catch SkitError.timedOut {
            // Somebody is listening: installing the agent again over it is not the answer to a slow one.
            return .failed("skit is running and does not answer on \(client.http.socketPath). See serve.log in \(locator.skitHome).")
        } catch {
            return .failed("\(error)")
        }
    }
}
