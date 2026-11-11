# 0010 · The client speaks HTTP/1.0 over the Unix socket

Date: 2026-11-10. Status: accepted.

**Context.** `skit serve` listens on a Unix socket (`~/.sessionkit/skit.sock`, mode 0600), and the Swift client talks
only to it (ADR 0001). `URLSession` cannot reach a Unix socket. The plan for M7 named this as the first risk and left
two ways out: a small HTTP client in the app, or an opt-in loopback TCP listener in `serve`.

**Decision.** The client carries its own transport, `SkitKit/UnixHTTP.swift`: a POSIX socket, one HTTP/1.0 request per
connection, the response read until the server closes. Go's server answers an HTTP/1.0 request without chunking and
closes when it is done, so the body is everything after the headers. The client needs no chunked decoding, no keep-alive
and no connection pool.

A loopback listener was not chosen. The socket's file permissions are what keep transcripts private to the user; a TCP
port on localhost is reachable by every local process and, without a token, by a web page. It would also be engine code
that exists only for one client.

**Consequences.** Measured against the running agent: `/v0/status` in 2.5 ms, `/v0/sessions` (13 rows, 31 kB) in 3.8 ms,
an image (75 kB, the one non-JSON route) in 3.1 ms; connecting to a local socket is not a cost worth pooling. Streaming
is out of reach of this transport: a route that pushes events (a live tail) would need its own reader, and is not
planned. The engine is unchanged. A future web face still needs a listener of its own, with a token; that decision is
not made here.

**Changed on 2026-11-11.** "Everything after the headers" could not tell a whole body from one cut short: with the agent
restarted in the middle of an answer, a Markdown export was saved short and reported as exported. The engine now sends
`Content-Length` on every route (it encodes an answer whole before sending it), and the client refuses a body that is
shorter or longer than its length says. Three more things came with it. The requests run on a queue of their own, not on
Swift's cooperative threads, which three stalled polls could use up. The polls give up after 5 seconds where everything
else waits 30. And a request that timed out is told apart from an engine that is not listening: only the second sends
the windows back to "Looking for skit".
