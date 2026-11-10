#if os(macOS)
import Foundation

/// An error that maps straight to an HTTP status and a JSON `{ "error": ..., ...extra }` body.
struct HTTPError: Error {
    let status: Int
    let message: String
    /// More fields of the body next to `error` (a 409 `controlled-elsewhere`'s `code` and `controllerDevice`).
    var extra: [String: Any] = [:]
    init(_ status: Int, _ message: String, extra: [String: Any] = [:]) {
        self.status = status
        self.message = message
        self.extra = extra
    }
}

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]  // lowercased names
    var body: Data
    /// The paired phone asking over the link (LinkPeer, RemoteAccess.swift); nil on the unix socket.
    var remote: RemoteDevice? = nil

    func int(_ name: String) throws -> Int? {
        guard let raw = query[name], !raw.isEmpty else { return nil }
        guard let v = Int(raw) else { throw HTTPError(400, "\(name) must be an integer") }
        return v
    }
}

/// The bytes under a `Connection`: a socket descriptor (the unix socket, `FDTransport`) or a link RPC stream
/// (LinkHTTP.swift). Blocking, for the connection's own thread.
protocol ByteTransport: AnyObject {
    /// Up to `max` bytes; empty = the peer closed, failed, or nothing came within the read timeout.
    func receive(max: Int) -> Data
    /// Writes everything (blocking while the peer is slow) or returns false (peer gone).
    func send(_ data: Data) -> Bool
    /// The peer hung up or the transport failed (does not wait; data waiting to be read is not a hang-up).
    func hungUp() -> Bool
    func close()
}

/// A connected socket descriptor: reads time out per `SO_RCVTIMEO`, set by whoever accepted it.
final class FDTransport: ByteTransport {
    let fd: Int32
    private var closed = false
    init(fd: Int32) { self.fd = fd }
    deinit { close() }

    func receive(max: Int) -> Data {
        var chunk = [UInt8](repeating: 0, count: max)
        while true {
            let n = recv(fd, &chunk, max, 0)
            if n < 0 && errno == EINTR { continue }
            return n > 0 ? Data(chunk[0..<n]) : Data()
        }
    }

    func send(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.send(fd, base + offset, raw.count - offset, 0)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    func hungUp() -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 0) > 0 else { return false }
        if pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
        var byte: UInt8 = 0
        return recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) <= 0
    }

    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }
}

/// One accepted client. On the unix socket: one request per connection, responses use `Connection: close`. On the
/// remote listener (`persistent`): a response with a known length keeps the connection for the next request
/// (HTTP/1.1 keep-alive: the phone's inputs and acks come every few milliseconds); a streamed one closes it.
final class Connection {
    let transport: ByteTransport
    /// Keep-alive is allowed (the remote listener) and the current request did not ask to close.
    var persistent = false
    /// The last response went out whole with `Connection: keep-alive`: another request may follow.
    private(set) var reusable = false
    /// Bytes read past the end of the last request (a pipelined next one).
    private var pending = Data()

    convenience init(fd: Int32) { self.init(transport: FDTransport(fd: fd)) }
    init(transport: ByteTransport) { self.transport = transport }

    /// `status=1` streams (StreamStatus.swift): run on every turn of a stream loop (`peerClosed`, so between two parts)
    /// to write a status part when the display's state changed. false = end the response (it wrote why).
    var betweenParts: ((Connection) -> Bool)?
    /// The response was ended from the server side (`betweenParts`, or the remote device was revoked): `peerClosed`
    /// stays true.
    private(set) var endedByServer = false
    private let endLock = NSLock()
    private var partSeq: UInt64 = 0
    /// The media types of this response's stream parts (`/stream`, `/audio`: StreamWire.swift).
    var wire = StreamWire.current
    deinit { transport.close() }

    /// The next `X-Frame-Seq` of this response's parts (1, 2, …): every part takes one, pictures, cursor and status
    /// parts alike, so a cumulative ack covers them all.
    func nextPartSeq() -> UInt64 {
        partSeq &+= 1
        return partSeq
    }

    /// Ends whatever this connection is doing from another thread (a revoked device): `peerClosed` turns true and the
    /// transport is closed (a blocked write or read returns).
    func endFromServer() {
        endLock.lock()
        endedByServer = true
        endLock.unlock()
        transport.close()
    }

    private var isEnded: Bool {
        endLock.lock(); defer { endLock.unlock() }
        return endedByServer
    }

    static let maxHeaderBytes = 64 * 1024
    /// Room for `POST /clipboard`'s 1 MiB of text as escaped JSON (a trusted local socket; everything else is small).
    static let maxBodyBytes = 8 * 1024 * 1024

    /// Thrown by `readRequest(idleIsQuiet: true)` when the peer closed (or went quiet) before the first byte of a
    /// request: a kept-alive connection simply ends.
    struct Idle: Error {}

    /// The request's head only (the body is left for `readBody`): the remote listener checks who asks before taking a
    /// body. `idleIsQuiet`: nothing at all before EOF / the timeout is `Idle`, not an error to answer.
    func readHead(idleIsQuiet: Bool = false) throws -> (HTTPRequest, contentLength: Int) {
        reusable = false
        var buffer = pending
        pending = Data()
        let separator = Data("\r\n\r\n".utf8)
        var headerEnd = buffer.range(of: separator)
        while headerEnd == nil {
            let chunk = transport.receive(max: 8192)
            guard !chunk.isEmpty else {
                if idleIsQuiet && buffer.isEmpty { throw Idle() }
                throw HTTPError(400, "connection closed before request was complete")
            }
            buffer.append(chunk)
            headerEnd = buffer.range(of: separator)
            if headerEnd == nil && buffer.count > Self.maxHeaderBytes {
                throw HTTPError(431, "request headers too large")
            }
        }
        let head = String(decoding: buffer[..<headerEnd!.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3 else { throw HTTPError(400, "malformed request line") }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        pending = Data(buffer[headerEnd!.upperBound...])
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { throw HTTPError(400, "bad Content-Length") }
        if headers["transfer-encoding"].map({ $0.lowercased() != "identity" }) == true {
            throw HTTPError(400, "chunked request bodies are not supported")
        }

        let target = String(requestLine[1])
        let components = URLComponents(string: "http://x" + target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let request = HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: components?.path ?? target,
            query: query,
            headers: headers,
            body: Data()
        )
        return (request, length)
    }

    /// The body of the request `readHead` read: `length` bytes, at most `max`.
    func readBody(length: Int, max: Int = maxBodyBytes) throws -> Data {
        guard length <= max else { throw HTTPError(413, "body too large") }
        var body = pending
        pending = Data()
        while body.count < length {
            let chunk = transport.receive(max: min(65_536, length - body.count))
            guard !chunk.isEmpty else { throw HTTPError(400, "connection closed before body was complete") }
            body.append(chunk)
        }
        if body.count > length {
            pending = Data(body[(body.startIndex + length)...])
            body = Data(body.prefix(length))
        }
        return body
    }

    func readRequest() throws -> HTTPRequest {
        var (request, length) = try readHead()
        request.body = try readBody(length: length)
        return request
    }

    /// Writes everything or returns false (client gone).
    @discardableResult
    func write(_ data: Data) -> Bool {
        transport.send(data)
    }

    /// True if the peer has hung up (readable with EOF or error), or `betweenParts` says the response should end (then
    /// for good), or the server ended it (`endFromServer`).
    func peerClosed() -> Bool {
        if isEnded { return true }
        if let betweenParts, !betweenParts(self) {
            endLock.lock(); endedByServer = true; endLock.unlock()
            return true
        }
        return transport.hungUp()
    }

    /// A streamed (close-delimited) response's head: the connection ends with it. `keepAlive`: `respond`'s, whose
    /// length is known.
    @discardableResult
    func writeHead(status: Int, headers: [(String, String)], keepAlive: Bool = false) -> Bool {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += keepAlive ? "Connection: keep-alive\r\n\r\n" : "Connection: close\r\n\r\n"
        return write(Data(head.utf8))
    }

    func respond(status: Int, contentType: String, body: Data, extraHeaders: [(String, String)] = []) {
        let headers = [("Content-Type", contentType), ("Content-Length", "\(body.count)")] + extraHeaders
        let keep = persistent
        if writeHead(status: status, headers: headers, keepAlive: keep), write(body) { reusable = keep }
    }

    func json(_ status: Int, _ object: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        respond(status: status, contentType: "application/json", body: body)
    }

    func error(_ err: HTTPError) {
        json(err.status, err.extra.merging(["error": err.message]) { _, e in e })
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: "Status"
        }
    }
}

/// Unix-domain stream socket server: an accept thread plus one thread per connection
/// (handlers block on capture/encoding, so they stay off the GCD pool).
final class HTTPServer: @unchecked Sendable {
    let listenFD: Int32
    let path: String
    let handler: (HTTPRequest, Connection) throws -> Void
    /// accept() failed for good (not because of stop()); the standalone helper exits, the desktop app logs it.
    var onFatal: ((String) -> Void)?
    private let lock = NSLock()
    private var stopped = false

    init(path: String, handler: @escaping (HTTPRequest, Connection) throws -> Void) throws {
        self.handler = handler
        self.path = path
        var addr = sockaddr_un()
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw HTTPError(500, "socket path too long")
        }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBytes { dst.copyMemory(from: $0) }
        }

        unlink(path)  // stale socket from a previous run
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HTTPError(500, "socket: \(String(cString: strerror(errno)))") }
        let oldMask = umask(0o177)  // socket file is created 0600
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)
        guard rc == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw HTTPError(500, "bind: \(msg)")
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw HTTPError(500, "listen: \(msg)")
        }
        listenFD = fd
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func start() {
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(listenFD, nil, nil)
                if client < 0 {
                    if isStopped { return }
                    if errno == EINTR || errno == ECONNABORTED { continue }
                    let why = "accept failed: \(String(cString: strerror(errno)))"
                    log(why)
                    stop()
                    onFatal?(why)
                    return
                }
                if isStopped {
                    close(client)
                    return
                }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 10, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                // User-interactive: a stream's thread drives the encoders, and the hardware video encoder
                // (an XPC service) inherits this QoS — at the default one it starves when the Mac is busy
                // (seen: 0.5–5 s per frame at load 70, vs ~9 ms).
                let t = Thread { [self] in serve(Connection(fd: client)) }
                t.qualityOfService = .userInteractive
                t.start()
            }
        }
    }

    /// Stops accepting, closes the listening socket and removes the socket file. Requests in flight (a stream)
    /// end when their client hangs up.
    func stop() {
        lock.lock()
        let first = !stopped
        stopped = true
        lock.unlock()
        guard first else { return }
        // shutdown() wakes a thread blocked in accept(); close() alone does not on every macOS version
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
        unlink(path)
    }

    private func serve(_ conn: Connection) {
        do {
            let request = try conn.readRequest()
            try handler(request, conn)
        } catch let err as HTTPError {
            conn.error(err)
        } catch {
            conn.error(HTTPError(500, "\(error)"))
        }
    }
}
#endif
