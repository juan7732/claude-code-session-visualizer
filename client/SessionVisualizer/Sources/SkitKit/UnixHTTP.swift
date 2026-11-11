import Foundation

/// HTTP over a Unix domain socket, as much of it as `skit serve` needs.
///
/// `URLSession` cannot reach a Unix socket. Rather than open a TCP port for the
/// client (the socket's file permissions are what keep sessions private), this
/// speaks HTTP/1.0 over the socket directly: one request per connection, the
/// server closes when it is done, so the body is everything after the headers.
/// No chunked decoding, no keep-alive, nothing to get subtly wrong. Connecting
/// to a local socket costs microseconds. See docs/decisions/0010.
public struct UnixHTTP: Sendable {
    public struct Response: Sendable {
        public let status: Int
        public let headers: [String: String]
        public let body: Data
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// Nothing is listening: no socket file, or a stale one.
        case notListening(String)
        case pathTooLong(Int)
        case io(String)
        /// The server is there and did not answer (or take the request) within `timeout` seconds.
        case timedOut(TimeInterval)
        case malformedResponse
        /// The body is not as long as `Content-Length` says: the connection closed early, or more came than was announced.
        case incomplete(expected: Int, received: Int)

        public var description: String {
            switch self {
            case .notListening(let path): "nothing is listening on \(path)"
            case .pathTooLong(let n): "socket path is \(n) bytes; a Unix socket allows 103"
            case .io(let what): what
            case .timedOut(let seconds): "no answer within \(seconds.formatted()) s"
            case .malformedResponse: "the server's answer was not HTTP"
            case .incomplete(let expected, let received): "the answer was cut short: \(received) of \(expected) bytes"
            }
        }
    }

    public let socketPath: String
    /// Seconds to wait for the answer before giving up.
    public var timeout: TimeInterval

    public init(socketPath: String, timeout: TimeInterval = 30) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    /// Sends one request and returns the whole response. Blocking: call it off
    /// the main thread (`SkitClient` does).
    public func send(method: String, path: String, body: Data? = nil) throws -> Response {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.io("socket: \(errnoText())") }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { throw Failure.pathTooLong(pathBytes.count) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            if errno == ENOENT || errno == ECONNREFUSED { throw Failure.notListening(socketPath) }
            throw Failure.io("connect: \(errnoText())")
        }

        var head = "\(method) \(path) HTTP/1.0\r\nHost: skit\r\nAccept: application/json\r\n"
        if let body {
            head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        }
        head += "\r\n"
        var request = Data(head.utf8)
        if let body { request.append(body) }
        try writeAll(fd, request)

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                received.append(buffer, count: n)
            } else if n == 0 {
                break
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                // SO_RCVTIMEO ran out: the engine is there, and busy or stuck.
                throw Failure.timedOut(timeout)
            } else {
                throw Failure.io("read: \(errnoText())")
            }
        }
        return try Self.parse(received)
    }

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                if n > 0 {
                    sent += n
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw Failure.timedOut(timeout)
                } else if errno != EINTR {
                    throw Failure.io("write: \(errnoText())")
                }
            }
        }
    }

    /// Splits a raw HTTP/1.x response into status, headers and body.
    ///
    /// DECISION: the body is everything up to the close, and a close is also what a crash or a
    /// timeout on the engine's side looks like. So when the answer says how long it is
    /// (`Content-Length`; Go sets it for every answer it has whole before writing), the body must be
    /// exactly that long. Half an export or half an image is a failure, never a shorter result.
    static func parse(_ raw: Data) throws -> Response {
        let separator = Data("\r\n\r\n".utf8)
        guard let split = raw.range(of: separator),
              let head = String(data: raw[raw.startIndex..<split.lowerBound], encoding: .utf8)
        else { throw Failure.malformedResponse }
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/"), let status = Int(statusLine[1]) else {
            throw Failure.malformedResponse
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let body = Data(raw[split.upperBound...])
        if let declared = headers["content-length"] {
            guard let expected = Int(declared), expected >= 0 else { throw Failure.malformedResponse }
            guard body.count == expected else { throw Failure.incomplete(expected: expected, received: body.count) }
        }
        return Response(status: status, headers: headers, body: body)
    }

    private func errnoText() -> String { String(cString: strerror(errno)) }
}
