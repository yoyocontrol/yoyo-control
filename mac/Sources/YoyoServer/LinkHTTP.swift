#if os(macOS)
import Foundation

// The link's way into the existing routes (docs/LINK.md「RPC 流」): a request runs through `Router.handle` on a
// `Connection` whose transport is not a socket; what the route writes (an HTTP/1.1 response) is parsed back into a
// status, headers and body. Input (`ServerEvent::Input`) takes the same way into `POST /input`.

/// An HTTP/1.1 response read back from the bytes a route wrote: the head once it is complete, then the body's bytes.
struct HTTPResponseParser {
    private var buffer = Data()
    private(set) var status: Int?
    /// Lowercased names; `connection` left out (it means nothing off a socket).
    private(set) var headers: [String: String] = [:]

    /// Feeds bytes; returns the body bytes among them (after the head).
    mutating func feed(_ data: Data) -> Data {
        guard status == nil else { return data }
        buffer.append(data)
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return Data() }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        status = first.count >= 2 ? Int(first[1]) ?? 500 : 500
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if name == "connection" { continue }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let rest = Data(buffer[end.upperBound...])
        buffer = Data()
        return rest
    }
}

/// A transport that keeps what a route writes (a whole, short response: `POST /input`'s JSON).
final class CapturedTransport: ByteTransport {
    private(set) var written = Data()
    private var closed = false

    func receive(max: Int) -> Data { Data() }
    func send(_ data: Data) -> Bool {
        guard !closed else { return false }
        written.append(data)
        return true
    }
    func hungUp() -> Bool { closed }
    func close() { closed = true }
}

extension Router {
    /// Runs one request through the routes and returns the whole response (status, headers, JSON-or-not body).
    static func call(_ req: HTTPRequest) -> (status: Int, headers: [String: String], body: Data) {
        let transport = CapturedTransport()
        let conn = Connection(transport: transport)
        do {
            try handle(req, conn)
        } catch let err as HTTPError {
            conn.error(err)
        } catch {
            conn.error(HTTPError(500, "\(error)"))
        }
        var parser = HTTPResponseParser()
        let body = parser.feed(transport.written)
        return (parser.status ?? 500, parser.headers, body)
    }

    /// An `HTTPRequest` from a link request's method, path (with its query) and lowercased headers.
    static func linkRequest(method: String, path: String, headers: [String: String], body: Data,
                            remote: RemoteDevice?) -> HTTPRequest {
        let components = URLComponents(string: "http://x" + (path.hasPrefix("/") ? path : "/" + path))
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        var lowered: [String: String] = [:]
        for (k, v) in headers { lowered[k.lowercased()] = v }
        return HTTPRequest(method: method.uppercased(), path: components?.path ?? path, query: query, headers: lowered,
                           body: body, remote: remote)
    }

    /// A `/stream`-style query string (`display=1&codecs=hevc,h264&…`) as the routes read it.
    static func queryItems(_ query: String) -> [String: String] {
        let q = query.hasPrefix("?") ? String(query.dropFirst()) : query
        var out: [String: String] = [:]
        for item in URLComponents(string: "http://x/?" + q)?.queryItems ?? [] { out[item.name] = item.value ?? "" }
        return out
    }
}
#endif
