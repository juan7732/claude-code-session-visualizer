import Foundation
import Testing
@testable import SkitKit

/// How the app reaches its engine at launch (ADR 0009: nothing is set up by hand).
@Suite struct ConnectorTests {
    /// A locator whose only `skit` is a file this test controls.
    private func locator(binary: String?) -> EngineLocator {
        let home = NSTemporaryDirectory() + "sk-home-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        return EngineLocator(environment: binary.map { ["SKIT_BIN": $0] } ?? [:], homeDirectory: home)
    }

    private func executable() throws -> String {
        let path = NSTemporaryDirectory() + "sk-bin-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private static let service = ServiceStatus(supported: true, installed: true, running: true, pid: 1, label: "dev.sessionkit.skit")

    @Test func attachesToAnEngineThatIsServing() async throws {
        let routes = try fixture("routes.json")
        let server = try StubServer { _ in StubServer.http(200, routes) }
        let installs = Counter()
        let connector = EngineConnector(client: SkitClient(socketPath: server.path), locator: locator(binary: try executable())) { _ in
            installs.increment()
            return Self.service
        }
        guard case .ready(let list) = await connector.connect() else {
            Issue.record("a serving engine should be attached to")
            return
        }
        #expect(list.version == "fixture")
        #expect(installs.value == 0, "an engine that answers is never reinstalled")
    }

    @Test func anOlderEngineIsNamedWithWhatItLacks() async throws {
        let server = try StubServer { _ in
            StubServer.http(200, Data(#"{"version":"old","routes":["GET /v0/status","GET /v0/sessions?project=&limit="]}"#.utf8))
        }
        let outcome = await EngineConnector(client: SkitClient(socketPath: server.path), locator: locator(binary: nil)).connect()
        guard case .incompatible(let version, let missing) = outcome else {
            Issue.record("expected incompatible, got \(outcome)")
            return
        }
        #expect(version == "old")
        #expect(missing.contains("PATCH /v0/sessions/{id}/annotations"))
    }

    @Test func withNoSkitAnywhereItSaysWhereItLooked() async {
        let none = EngineLocator(environment: ["PATH": "/nonexistent-a"], homeDirectory: "/nonexistent-home")
        let outcome = await EngineConnector(client: SkitClient(socketPath: StubServer.freshPath()), locator: none).connect()
        // A developer machine may have a real skit in /opt/homebrew or /usr/local; then this is not the missing case.
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/skit") || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/skit") { return }
        #expect(outcome == .missing(lookedIn: none.binaryCandidates))
    }

    @Test func installsTheAgentOnceAndWaitsForIt() async throws {
        let routes = try fixture("routes.json")
        let path = StubServer.freshPath()
        let binary = try executable()
        let installs = Counter()
        let started = Box<StubServer>()
        var connector = EngineConnector(client: SkitClient(socketPath: path), locator: locator(binary: binary)) { asked in
            installs.increment()
            #expect(asked == binary)
            // The agent comes up a moment after the install returns.
            started.value = try StubServer(path: path) { _ in StubServer.http(200, routes) }
            return Self.service
        }
        connector.pause = .milliseconds(10)
        let announced = Box<String>()
        let outcome = await connector.connect { announced.value = $0 }
        guard case .ready = outcome else {
            Issue.record("expected ready after the install, got \(outcome)")
            return
        }
        #expect(installs.value == 1)
        #expect(announced.value == binary)
    }

    @Test func aFailedInstallIsReported() async throws {
        var connector = EngineConnector(client: SkitClient(socketPath: StubServer.freshPath()), locator: locator(binary: try executable())) { _ in
            throw SkitCommand.Failure.failed(exitCode: 1, message: "launchctl bootstrap: denied")
        }
        connector.pause = .milliseconds(1)
        let outcome = await connector.connect()
        #expect(outcome == .failed("skit service install: launchctl bootstrap: denied"))

        var silent = EngineConnector(client: SkitClient(socketPath: StubServer.freshPath()), locator: locator(binary: try executable())) { _ in Self.service }
        silent.attempts = 2
        silent.pause = .milliseconds(1)
        guard case .failed(let why) = await silent.connect() else {
            Issue.record("an agent that never answers is a failure")
            return
        }
        #expect(why.contains("does not answer"))

        let attachOnly = EngineConnector(client: SkitClient(socketPath: StubServer.freshPath()), locator: locator(binary: try executable()), managesEngine: false) { _ in
            Issue.record("attach-only must never install")
            return Self.service
        }
        guard case .failed = await attachOnly.connect() else {
            Issue.record("attach-only with nothing serving is a failure")
            return
        }
    }
}

/// Running `skit` as a command: the agent's status and its install.
@Suite struct CommandTests {
    private func script(_ body: String) throws -> String {
        let path = NSTemporaryDirectory() + "sk-cmd-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    /// A child that fills stderr before it writes its answer: read one pipe after the other, this never ends.
    @Test func bothPipesAreReadAtOnce() throws {
        let answer = NSTemporaryDirectory() + "sk-status-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).json"
        try fixture("service-status.json").write(to: URL(fileURLWithPath: answer))
        let binary = try script("head -c 400000 /dev/zero | tr '\\0' 'e' >&2\ncat '\(answer)'")
        defer { [binary, answer].forEach { try? FileManager.default.removeItem(atPath: $0) } }
        let status = try SkitCommand(binary: binary, timeout: 20).serviceStatus()
        #expect(status.label == "dev.sessionkit.skit" && !status.installed)

        // What it says on stderr when it fails is still the reason given.
        let failing = try script("echo '{\"error\":\"launchctl bootstrap: denied\"}' >&2\nexit 3")
        defer { try? FileManager.default.removeItem(atPath: failing) }
        #expect(throws: SkitCommand.Failure.failed(exitCode: 3, message: "launchctl bootstrap: denied")) { try SkitCommand(binary: failing).installService() }
    }

    @Test func aChildThatHangsIsStopped() throws {
        // `sleep` is a child of the shell and keeps the pipes open after the shell is stopped: neither is waited for.
        let binary = try script("sleep 30")
        defer { try? FileManager.default.removeItem(atPath: binary) }
        let started = Date()
        #expect(throws: SkitCommand.Failure.timedOut(command: "skit service status --json", seconds: 0.3)) {
            try SkitCommand(binary: binary, timeout: 0.3).serviceStatus()
        }
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(SkitCommand.Failure.timedOut(command: "skit service install --json", seconds: 30).description == "skit service install --json did not finish within 30 s and was stopped")
    }
}

/// Where the agent is installed from, and when it is pointed at this app's own `skit`.
@Suite struct AgentPlanTests {
    static let helper = "/Applications/SessionVisualizer.app/Contents/Helpers/skit"

    static func agent(installed: Bool = true, binary: String?, exists: Bool? = true) -> ServiceStatus {
        ServiceStatus(supported: true, installed: installed, running: installed, pid: installed ? 1 : nil, label: "dev.sessionkit.skit", binary: binary, binaryExists: exists)
    }

    @Test func whereTheBundleIs() {
        #expect(BundlePlace.of(Self.helper) == .stable)
        #expect(BundlePlace.of("/Users/me/Applications/SessionVisualizer.app") == .stable)
        #expect(BundlePlace.of("/private/var/folders/xy/T/AppTranslocation/6F1B0A7E-0000/d/SessionVisualizer.app/Contents/Helpers/skit") == .translocated)
        #expect(BundlePlace.of("/Volumes/SessionVisualizer/SessionVisualizer.app/Contents/Helpers/skit") == .volume)
    }

    @Test func theDecision() {
        // Without a bundle (`swift run`, tests) the agent is whatever it is.
        #expect(AgentPlan.decide(helper: nil, agent: Self.agent(binary: "/gone", exists: false)) == .asItIs)
        // From a place that goes away, nothing is installed, whatever the agent is.
        let translocated = "/private/var/folders/xy/T/AppTranslocation/6F1B/d/SessionVisualizer.app/Contents/Helpers/skit"
        #expect(AgentPlan.decide(helper: translocated, agent: nil) == .attachOnly(.translocated))
        #expect(AgentPlan.decide(helper: translocated, agent: Self.agent(binary: "/gone", exists: false)) == .attachOnly(.translocated))
        #expect(AgentPlan.decide(helper: "/Volumes/SV/SessionVisualizer.app/Contents/Helpers/skit", agent: nil) == .attachOnly(.volume))
        // No agent yet, or one that could not be asked about: attach, and install only when nothing answers.
        #expect(AgentPlan.decide(helper: Self.helper, agent: nil) == .asItIs)
        #expect(AgentPlan.decide(helper: Self.helper, agent: Self.agent(installed: false, binary: nil, exists: false)) == .asItIs)
        // The agent already runs this helper.
        #expect(AgentPlan.decide(helper: Self.helper, agent: Self.agent(binary: Self.helper)) == .asItIs)
        #expect(AgentPlan.decide(helper: Self.helper, agent: Self.agent(binary: "/Applications/../Applications/SessionVisualizer.app/Contents/Helpers/skit")) == .asItIs)
        // It names a path that is gone: the copy that was translocated, or was in Downloads before it was moved.
        #expect(AgentPlan.decide(helper: Self.helper, agent: Self.agent(binary: translocated, exists: false)) == .reinstall(Self.helper))
        #expect(AgentPlan.decide(helper: Self.helper, agent: Self.agent(binary: "/Users/me/go/bin/skit", exists: false)) == .reinstall(Self.helper))
        // It runs another copy of the app that is still there: this copy takes over.
        #expect(AgentPlan.decide(helper: Self.helper, agent: Self.agent(binary: "/Users/me/Downloads/SessionVisualizer.app/Contents/Helpers/skit")) == .reinstall(Self.helper))
        // A skit somebody installed themselves and that is still there is theirs to keep (ADR 0011).
        #expect(AgentPlan.decide(helper: Self.helper, agent: Self.agent(binary: "/Users/me/go/bin/skit")) == .asItIs)
    }

    /// An app bundle in a temporary folder, with a `skit` in it that can be run.
    private func bundle(under parent: String = "") throws -> EngineLocator {
        let root = NSTemporaryDirectory() + "sk-bundle-\(getpid())-\(UInt32.random(in: 0...UInt32.max))" + parent
        let helpers = root + "/SessionVisualizer.app/Contents/Helpers"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: helpers + "/skit"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helpers + "/skit")
        return EngineLocator(environment: [:], homeDirectory: root, helpersDirectory: helpers, trustsOnlyItsHelper: true)
    }

    @Test func aStaleAgentIsPointedAtThisAppEvenWhileItServes() async throws {
        let routes = try fixture("routes.json")
        let server = try StubServer { _ in StubServer.http(200, routes) }
        let locator = try bundle()
        let helper = try #require(locator.bundledHelper)
        let installs = Box<[String]>()
        installs.value = []
        var connector = EngineConnector(client: SkitClient(socketPath: server.path), locator: locator, install: { binary in
            installs.value = (installs.value ?? []) + [binary]
            return AgentPlanTests.agent(binary: binary)
        }, status: { _ in AgentPlanTests.agent(binary: "/private/var/folders/xy/T/AppTranslocation/6F1B/d/SessionVisualizer.app/Contents/Helpers/skit", exists: false) })
        connector.pause = .milliseconds(5)
        #expect(await connector.plan() == .reinstall(helper))
        guard case .ready = await connector.connect() else {
            Issue.record("the agent answers after it was pointed at this app")
            return
        }
        #expect(installs.value == [helper])

        // Once it runs this helper, a launch leaves it alone. The agent names the helper the way
        // `skit service install` wrote it, with every link resolved (the temporary folder is behind one).
        let recorded = try #require(EngineConnector.real(helper))
        #expect(recorded != helper, "this test needs a path that resolves to another spelling")
        connector.status = { _ in AgentPlanTests.agent(binary: recorded) }
        #expect(await connector.plan() == .asItIs)
        guard case .ready = await connector.connect() else {
            Issue.record("an agent that runs this helper is attached to")
            return
        }
        #expect(installs.value == [helper])
    }

    @Test func nothingIsInstalledFromATranslocatedCopy() async throws {
        let locator = try bundle(under: "/AppTranslocation/6F1B/d")
        let install: @Sendable (String) throws -> ServiceStatus = { _ in
            Issue.record("an agent must not be installed from a path that is gone after quit")
            return AgentPlanTests.agent(binary: nil)
        }
        let status: @Sendable (String) throws -> ServiceStatus = { _ in
            Issue.record("there is nothing to decide by asking")
            return AgentPlanTests.agent(binary: nil)
        }
        // Nothing serving: the app says to move it.
        let alone = EngineConnector(client: SkitClient(socketPath: StubServer.freshPath()), locator: locator, install: install, status: status)
        #expect(await alone.connect() == .misplaced(.translocated))
        // An agent already serving: the app works for this run.
        let routes = try fixture("routes.json")
        let server = try StubServer { _ in StubServer.http(200, routes) }
        let attached = EngineConnector(client: SkitClient(socketPath: server.path), locator: locator, install: install, status: status)
        guard case .ready = await attached.connect() else {
            Issue.record("an engine that is serving is attached to, wherever the app is")
            return
        }
    }

    @Test func aSlowEngineIsNotInstalledOver() async throws {
        let server = try StubServer { _ in
            Thread.sleep(forTimeInterval: 0.5)
            return StubServer.http(200, Data("{}".utf8))
        }
        let binary = NSTemporaryDirectory() + "sk-bin-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: binary))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary)
        let connector = EngineConnector(client: SkitClient(socketPath: server.path, timeout: 0.1),
                                        locator: EngineLocator(environment: ["SKIT_BIN": binary], homeDirectory: "/nonexistent")) { _ in
            Issue.record("somebody is listening: the agent is not installed again over a slow engine")
            return AgentPlanTests.agent(binary: binary)
        }
        guard case .failed(let why) = await connector.connect() else {
            Issue.record("a slow engine is a failure to say, not a reason to install")
            return
        }
        #expect(why.contains("does not answer"))
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    var value: Value? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
