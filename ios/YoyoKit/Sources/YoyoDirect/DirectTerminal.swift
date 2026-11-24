import Foundation
import YoyoCore
import YoyoLink
import YoyoLinkClient

// The Mac's terminals (docs/PROTOCOL.md「终端」) over the link: `GET /term` as a duplex request (the Mac's
// `{"t":"attached"|"exit"|"detached"}` text messages and the output as binary ones; the phone's typing as binary,
// `{"t":"resize"}` as text), `GET /term/sessions`, `POST /term/kill`. A terminal page may show while the Screen
// page's own session is gone (its routing ends it as the page leaves): `DirectWays.liveConnection` dials one then.
extension DirectBackend {
    var hasTerminal: Bool { ways?.connection()?.serverHas("terminal") ?? false }

    func openTerminal(session: String?, since: UInt64?, cols: Int, rows: Int, cwd: String?) async throws -> any YoyoTerminalChannel {
        guard let ways else { throw URLError(.networkConnectionLost) }
        let link = try await ways.liveConnection()
        var query = [URLQueryItem(name: "cols", value: "\(cols)"), URLQueryItem(name: "rows", value: "\(rows)")]
        if let session { query.append(URLQueryItem(name: "session", value: session)) }
        if let since { query.append(URLQueryItem(name: "since", value: "\(since)")) }
        if let cwd { query.append(URLQueryItem(name: "cwd", value: cwd)) }
        var c = URLComponents()
        c.path = "/term"
        c.queryItems = query
        let (status, body, duplex) = try await link.duplex("GET", c.string ?? "/term",
                                                           headers: ["authorization": "Bearer \(token)"])
        guard let duplex else {
            let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            switch (status, o?["code"] as? String) {
            case (401, _): throw YoyoError.unauthorized
            case (403, "terminal-off"): throw YoyoTerminalError.off
            case (404, "gone"): throw YoyoTerminalError.gone
            case (429, _): throw YoyoTerminalError.tooMany
            default: throw YoyoError.http(status, o?["error"] as? String)
            }
        }
        return DirectTerminalChannel(duplex: duplex)
    }

    func terminals() async throws -> [YoyoTerminalInfo] {
        guard let ways else { throw URLError(.networkConnectionLost) }
        let link = try await ways.liveConnection()
        let (data, resp) = try await link.data(for: try request("GET", "term/sessions", timeout: 6))
        guard (200..<300).contains(resp.statusCode) else {
            let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if resp.statusCode == 403 { throw YoyoTerminalError.off }
            throw YoyoError.http(resp.statusCode, o?["error"] as? String)
        }
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (o?["sessions"] as? [[String: Any]] ?? []).compactMap(YoyoTerminalInfo.init(json:))
    }

    func endTerminal(id: String) async throws {
        guard let ways else { throw URLError(.networkConnectionLost) }
        let link = try await ways.liveConnection()
        let (data, resp) = try await link.data(for: try request("POST", "term/kill", json: ["id": id], timeout: 6))
        guard (200..<300).contains(resp.statusCode) || resp.statusCode == 404 else {
            let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw YoyoError.http(resp.statusCode, o?["error"] as? String)
        }
    }
}

/// One attached terminal: a duplex stream of the link.
final class DirectTerminalChannel: YoyoTerminalChannel, @unchecked Sendable {
    let events: AsyncStream<YoyoTerminalEvent>
    private let duplex: LinkDuplex
    private let continuation: AsyncStream<YoyoTerminalEvent>.Continuation
    /// What is typed goes out in order (one writer).
    private let outbox: AsyncStream<DuplexMessage>.Continuation
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    private var closed = false

    init(duplex: LinkDuplex) {
        self.duplex = duplex
        (events, continuation) = AsyncStream<YoyoTerminalEvent>.makeStream()
        let (out, outbox) = AsyncStream<DuplexMessage>.makeStream()
        self.outbox = outbox
        let reader = Task.detached(priority: .userInitiated) { [duplex, continuation] in
            var ended = false
            while true {
                let m: DuplexMessage?
                do { m = try await duplex.recv() } catch { break }
                guard let m else { break }
                switch m {
                case .binary(let data):
                    continuation.yield(.output(data))
                case .text(let text):
                    guard let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { continue }
                    switch o["t"] as? String {
                    case "attached":
                        let offset = (o["offset"] as? NSNumber)?.uint64Value ?? 0
                        continuation.yield(.attached(session: o["session"] as? String ?? "", offset: offset,
                                                     reset: o["reset"] as? Bool ?? true))
                    case "exit":
                        ended = true
                        continuation.yield(.exited(code: o["code"] as? Int ?? 0))
                    case "detached":
                        ended = true
                        continuation.yield(.detached(reason: o["reason"] as? String ?? ""))
                    default:
                        break
                    }
                case .close:
                    break
                }
            }
            if !ended { continuation.yield(.lost) }
            continuation.finish()
        }
        let writer = Task.detached(priority: .userInitiated) { [duplex] in
            for await m in out {
                do { try await duplex.send(message: m) } catch { return }
            }
            try? await duplex.finish()
        }
        tasks = [reader, writer]
    }

    func send(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        outbox.yield(.binary(data: bytes))
    }

    func resize(cols: Int, rows: Int) {
        outbox.yield(.text(text: #"{"t":"resize","cols":\#(cols),"rows":\#(rows)}"#))
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        outbox.finish()
        duplex.cancel()
    }

    deinit { close() }
}

extension DirectWays {
    /// The Mac's link session now: the Screen page's while it is up, else one of the terminal's own (dialed when none
    /// is up, kept until the page closes).
    func liveConnection() async throws -> YoyoLinkConnection {
        if let c = connection(), !c.isClosed { return c }
        if let own = spare, !own.isClosed { return own }
        switch await YoyoClient.dial(mac, pro: pro) {
        case .reached(let link):
            setSpare(link.connection)
            return link.connection
        case .unauthorized:
            throw YoyoError.unauthorized
        case .needsPro, .unreachable:
            throw URLError(.cannotConnectToHost)
        }
    }
}
