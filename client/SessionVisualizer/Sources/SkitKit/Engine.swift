import Foundation

/// Where the engine is on this Mac: its socket, its binary, its background agent.
public struct EngineLocator: Sendable {
    public var environment: [String: String]
    public var homeDirectory: String
    /// `Contents/Helpers` of the app bundle, when the app runs from one.
    public var helpersDirectory: String?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                homeDirectory: String = NSHomeDirectory(),
                helpersDirectory: String? = nil) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.helpersDirectory = helpersDirectory
    }

    /// skit's home: `$SKIT_HOME`, else `~/.sessionkit`.
    public var skitHome: String {
        if let custom = environment["SKIT_HOME"], !custom.isEmpty { return custom }
        return homeDirectory + "/.sessionkit"
    }

    /// The socket `skit serve` listens on by default.
    public var socketPath: String { skitHome + "/skit.sock" }

    /// Places a `skit` binary may be, in order: `$SKIT_BIN`, the app's own
    /// helper, then the directories a developer install lands in. A GUI app
    /// does not inherit the shell's PATH, so those are named outright.
    public var binaryCandidates: [String] {
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

/// Runs `skit` for the things that are commands, not routes: the background agent.
public struct SkitCommand: Sendable {
    public let binary: String

    public init(binary: String) {
        self.binary = binary
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case failed(exitCode: Int32, message: String)
        case unreadable(String)

        public var description: String {
            switch self {
            case .failed(_, let message): message
            case .unreadable(let what): what
            }
        }
    }

    /// `skit service install --json`: writes the launchd agent that keeps
    /// `skit serve` running from login on, and starts it. Safe to repeat.
    public func installService() throws -> ServiceStatus { try run(["service", "install", "--json"]) }

    /// `skit service status --json`.
    public func serviceStatus() throws -> ServiceStatus { try run(["service", "status", "--json"]) }

    private func run<T: Decodable>(_ arguments: [String]) throws -> T {
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
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            // With --json, skit writes {"error": "..."} on stderr.
            let message = (try? JSONDecoder().decode([String: String].self, from: stderr))?["error"]
                ?? String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.failed(exitCode: process.terminationStatus, message: message)
        }
        do {
            return try JSONDecoder.skit().decode(T.self, from: stdout)
        } catch {
            throw Failure.unreadable("skit \(arguments.joined(separator: " ")): \(SkitClient.describe(error))")
        }
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
        case failed(String)
    }

    public var client: SkitClient
    public var locator: EngineLocator
    /// False attaches only: nothing is installed (snapshots, tests).
    public var managesEngine: Bool
    /// Installs the agent for the `skit` at the given path.
    public var install: @Sendable (String) throws -> ServiceStatus
    /// How long to wait for a freshly installed agent to answer.
    public var attempts = 20
    public var pause: Duration = .milliseconds(300)

    public init(client: SkitClient, locator: EngineLocator, managesEngine: Bool = true,
                install: @escaping @Sendable (String) throws -> ServiceStatus = { try SkitCommand(binary: $0).installService() }) {
        self.client = client
        self.locator = locator
        self.managesEngine = managesEngine
        self.install = install
    }

    /// `onStarting` is told which `skit` is being started, for the window to say so.
    public func connect(onStarting: @Sendable (String) async -> Void = { _ in }) async -> Outcome {
        if let outcome = await attach() { return outcome }
        guard managesEngine else { return .failed("Nothing is serving on \(client.http.socketPath).") }
        guard let binary = locator.findBinary() else { return .missing(lookedIn: locator.binaryCandidates) }
        await onStarting(binary)
        do {
            let install = self.install
            _ = try await Task.detached { try install(binary) }.value
        } catch {
            return .failed("skit service install: \(error)")
        }
        for attempt in 0..<attempts {
            if let outcome = await attach() { return outcome }
            if attempt < attempts - 1 { try? await Task.sleep(for: pause) }
        }
        return .failed("The background agent was installed but does not answer on \(client.http.socketPath). See serve.log in \(locator.skitHome).")
    }

    /// Nil when nothing is serving; otherwise what answered.
    private func attach() async -> Outcome? {
        do {
            let list = try await client.routes()
            let missing = SkitClient.missingRoutes(in: list.routes)
            return missing.isEmpty ? .ready(list) : .incompatible(version: list.version, missing: missing)
        } catch SkitError.unreachable {
            return nil
        } catch {
            return .failed("\(error)")
        }
    }
}
