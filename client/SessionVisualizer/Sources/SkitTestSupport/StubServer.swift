import Foundation

/// A Unix-socket server for one test: it answers every connection with the
/// bytes `respond` returns for the request it read, then closes, as `skit
/// serve` does for an HTTP/1.0 request.
public final class StubServer: @unchecked Sendable {
    public let path: String
    private let fd: Int32
    private let lock = NSLock()
    private var seen: [String] = []
    private var stopped = false

    /// The requests received so far, head and body as text.
    public var requests: [String] { lock.withLock { seen } }

    public static func freshPath() -> String {
        NSTemporaryDirectory() + "sk-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
    }

    /// `concurrent`: each connection is answered on a thread of its own, so a slow answer does not
    /// hold up the next request (the default answers one at a time, in the order they arrive).
    public init(path: String = StubServer.freshPath(), concurrent: Bool = false, respond: @escaping @Sendable (String) -> Data) throws {
        self.path = path
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { throw StubError.cannotListen(path) }
        let listener = fd
        Thread.detachNewThread { [self] in
            while true {
                let conn = accept(listener, nil, nil)
                if conn < 0 { return }
                if concurrent {
                    Thread.detachNewThread { [self] in serve(conn, respond) }
                } else {
                    serve(conn, respond)
                }
            }
        }
    }

    private func serve(_ conn: Int32, _ respond: @Sendable (String) -> Data) {
        var on: Int32 = 1
        setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        // Read the head, then as many body bytes as Content-Length announces.
        while true {
            let n = read(conn, &buffer, buffer.count)
            if n <= 0 { break }
            request.append(buffer, count: n)
            let text = String(decoding: request, as: UTF8.self)
            guard let end = text.range(of: "\r\n\r\n") else { continue }
            let length = text[..<end.lowerBound].split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            if text[end.upperBound...].utf8.count >= length { break }
        }
        let text = String(decoding: request, as: UTF8.self)
        lock.withLock { seen.append(text) }
        let answer = respond(text)
        answer.withUnsafeBytes { _ = write(conn, $0.baseAddress, $0.count) }
        close(conn)
    }

    /// Stops listening, as an engine that quit: the socket file goes, and a connect finds nothing there.
    public func stop() {
        let wasListening = lock.withLock {
            defer { stopped = true }
            return !stopped
        }
        guard wasListening else { return }
        unlink(path)
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    deinit { stop() }

    /// `length`: the `Content-Length` to announce, as Go's server does for an answer it has whole
    /// (nil announces none; a number other than the body's plays a cut or padded answer).
    public static func http(_ status: Int, _ body: Data, type: String = "application/json", length: Int? = nil) -> Data {
        var out = Data("HTTP/1.0 \(status) X\r\nContent-Type: \(type)\r\n\(length.map { "Content-Length: \($0)\r\n" } ?? "")\r\n".utf8)
        out.append(body)
        return out
    }
}

public enum StubError: Error {
    case cannotListen(String)
}
