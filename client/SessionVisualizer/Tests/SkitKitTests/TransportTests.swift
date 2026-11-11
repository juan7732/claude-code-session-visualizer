import Foundation
import Testing
@testable import SkitKit

@Suite struct TransportTests {
    @Test func parsesStatusHeadersAndBody() throws {
        let raw = Data("HTTP/1.0 404 Not Found\r\nContent-Type: application/json\r\nX-A:  b \r\n\r\n{\"error\":\"x\"}\r\n\r\ntail".utf8)
        let response = try UnixHTTP.parse(raw)
        #expect(response.status == 404)
        #expect(response.headers["content-type"] == "application/json")
        #expect(response.headers["x-a"] == "b")
        #expect(String(decoding: response.body, as: UTF8.self) == "{\"error\":\"x\"}\r\n\r\ntail")
        #expect(throws: UnixHTTP.Failure.malformedResponse) { try UnixHTTP.parse(Data("nonsense".utf8)) }
    }

    @Test func aMissingSocketIsNotListening() {
        let http = UnixHTTP(socketPath: NSTemporaryDirectory() + "no-such-\(getpid()).sock")
        #expect(throws: UnixHTTP.Failure.notListening(http.socketPath)) { try http.send(method: "GET", path: "/v0/status") }
        let long = UnixHTTP(socketPath: String(repeating: "x", count: 200))
        #expect(throws: UnixHTTP.Failure.pathTooLong(200)) { try long.send(method: "GET", path: "/") }
    }

    @Test func sendsOneRequestAndReadsToTheEnd() throws {
        let big = Data(repeating: 0x61, count: 300_000) // larger than one read
        let server = try StubServer { _ in StubServer.http(200, big, type: "image/png") }
        let response = try UnixHTTP(socketPath: server.path).send(method: "GET", path: "/v0/sessions/x/images/0")
        #expect(response.status == 200)
        #expect(response.headers["content-type"] == "image/png")
        #expect(response.body == big)
        #expect(server.requests.first?.hasPrefix("GET /v0/sessions/x/images/0 HTTP/1.0\r\n") == true)
    }

    @Test func clientDecodesAnswersAndEngineErrors() async throws {
        let sessions = try fixture("sessions.json")
        let annotation = try fixture("annotation.json")
        let server = try StubServer { request in
            if request.hasPrefix("GET /v0/sessions?project=my%20work&limit=5 ") { return StubServer.http(200, sessions) }
            if request.hasPrefix("PATCH /v0/sessions/abc/annotations ") { return StubServer.http(200, annotation) }
            if request.hasPrefix("GET /v0/status ") { return StubServer.http(200, Data("{\"version\":1}".utf8)) }
            return StubServer.http(404, Data("{\"error\":\"no session matches\"}".utf8))
        }
        let client = SkitClient(socketPath: server.path)

        let rows = try await client.sessions(project: "my work", limit: 5)
        #expect(rows.count == 4)

        let patched = try await client.annotate(session: "abc", AnnotationPatch(pinned: true))
        #expect(patched.pinned)
        let sent = try #require(server.requests.last)
        #expect(sent.contains("Content-Length: 15\r\n"))
        #expect(sent.hasSuffix("{\"pinned\":true}"))

        await #expect(throws: SkitError.engine(status: 404, message: "no session matches")) {
            _ = try await client.stats(session: "nope")
        }
        // An answer the models cannot read names the route and the field.
        do {
            _ = try await client.status()
            Issue.record("a status without its fields must not decode")
        } catch let SkitError.undecodable(path, detail) {
            #expect(path == "/v0/status")
            #expect(detail.contains("version") || detail.contains("uptime"))
        }
        await #expect(throws: SkitError.self) {
            _ = try await SkitClient(socketPath: server.path + ".gone").status()
        }
    }

    /// The body is everything up to the close, and a close is also what a crash looks like: an
    /// answer that says how long it is must be that long.
    @Test func anAnswerShorterOrLongerThanItSaysIsNotAResult() throws {
        func raw(_ declared: String, _ body: String) -> Data { Data("HTTP/1.0 200 OK\r\nContent-Length: \(declared)\r\n\r\n\(body)".utf8) }
        #expect(try UnixHTTP.parse(raw("5", "hello")).body == Data("hello".utf8))
        #expect(try UnixHTTP.parse(raw("0", "")).body.isEmpty)
        #expect(throws: UnixHTTP.Failure.incomplete(expected: 5000, received: 5)) { try UnixHTTP.parse(raw("5000", "hello")) }
        #expect(throws: UnixHTTP.Failure.incomplete(expected: 2, received: 5)) { try UnixHTTP.parse(raw("2", "hello")) }
        #expect(throws: UnixHTTP.Failure.malformedResponse) { try UnixHTTP.parse(raw("many", "hello")) }
        #expect(throws: UnixHTTP.Failure.malformedResponse) { try UnixHTTP.parse(raw("-1", "hello")) }
        // An answer that announces no length is read to the close, as before.
        #expect(try UnixHTTP.parse(Data("HTTP/1.0 200 OK\r\n\r\nhello".utf8)).body == Data("hello".utf8))
    }

    @Test func aCutExportIsAFailureNotAShorterExport() async throws {
        let whole = Data(String(repeating: "# a turn\n", count: 2000).utf8)
        let server = try StubServer { request in
            // The engine died, or gave up, a third of the way through writing.
            if request.hasPrefix("GET /v0/sessions/cut/") { return StubServer.http(200, whole.prefix(whole.count / 3), type: "text/markdown", length: whole.count) }
            return StubServer.http(200, whole, type: "text/markdown", length: whole.count)
        }
        let client = SkitClient(socketPath: server.path)
        #expect(try await client.markdown(session: "whole").utf8.count == whole.count)
        await #expect(throws: SkitError.transport("the answer was cut short: \(whole.count / 3) of \(whole.count) bytes")) {
            _ = try await client.markdown(session: "cut")
        }
        await #expect(throws: SkitError.transport("the answer was cut short: \(whole.count / 3) of \(whole.count) bytes")) {
            _ = try await client.image(session: "cut", 0)
        }
    }

    /// Nobody home, slow and broken are three different things to the app.
    @Test func aSlowEngineIsNotAMissingOne() async throws {
        let server = try StubServer { _ in
            Thread.sleep(forTimeInterval: 0.6)
            return StubServer.http(200, Data("{}".utf8))
        }
        let started = Date()
        do {
            _ = try await SkitClient(socketPath: server.path).quick(timeout: 0.15).routes()
            Issue.record("an engine that does not answer in time must not look like an answer")
        } catch SkitError.timedOut(let why) {
            #expect(why == "no answer within 0.15 s")
        }
        #expect(Date().timeIntervalSince(started) < 0.5, "the wait is the timeout, not the engine's pace")
        do {
            _ = try await SkitClient(socketPath: StubServer.freshPath()).routes()
            Issue.record("nothing is listening there")
        } catch SkitError.unreachable {
        }
        #expect(SkitError(.io("read: Connection reset by peer")) == .transport("read: Connection reset by peer"))
        #expect(SkitError(.malformedResponse) == .transport("the server's answer was not HTTP"))
        #expect(SkitClient(socketPath: "/x").http.timeout == 30 && SkitClient(socketPath: "/x").quick().http.timeout == 5)
    }

    @Test func blockingWorkRunsOffTheCooperativePool() async throws {
        let label = try await Blocking.run { String(cString: __dispatch_queue_get_label(nil)) }
        #expect(label == "dev.sessionkit.blocking")
        // More waits at once than the cooperative pool has threads: they overlap, they do not queue.
        let started = Date()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<24 { group.addTask { try await Blocking.run { Thread.sleep(forTimeInterval: 0.2) } } }
            try await group.waitForAll()
        }
        #expect(Date().timeIntervalSince(started) < 2.4, "24 waits of 0.2 s one after the other would take 4.8 s")
        await #expect(throws: SkitError.self) { try await Blocking.run { throw SkitError.transport("x") } }
    }
}
