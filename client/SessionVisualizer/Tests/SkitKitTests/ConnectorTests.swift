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
