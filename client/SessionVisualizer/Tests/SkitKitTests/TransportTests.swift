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
}
