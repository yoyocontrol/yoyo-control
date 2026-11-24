#if os(macOS) && canImport(YoyoLink)
import Foundation
import YoyoLink

/// The terminal routes of a paired phone's link session (docs/PROTOCOL.md「终端」): `GET /term` (a duplex request:
/// a terminal's output and the phone's typing), `GET /term/sessions`, `POST /term/kill`. Only over the link, only for
/// remote access's paired devices (not in authority mode), only while remote terminals are on (`RemoteAccess.terminal`).
enum LinkTerminal {
    static func handles(_ path: String) -> Bool { path == "/term" || path.hasPrefix("/term/") }

    static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func fail(_ responder: RpcResponder, _ status: UInt16, _ message: String, code: String? = nil) async {
        var body: [String: Any] = ["error": message]
        if let code { body["code"] = code }
        try? await responder.respond(status: status, headers: ["content-type": "application/json"], body: json(body))
    }

    static func serve(_ request: RpcRequest, _ body: Data, _ responder: RpcResponder, device: RemoteDevice,
                      session: LinkSession) async {
        let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        let query = Router.queryItems(request.path.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? "")
        guard RemoteAccess.current?.terminalEnabled ?? LinkHooks.terminals ?? false else {
            return await fail(responder, 403, "terminals are turned off on this Mac", code: "terminal-off")
        }
        let store = TerminalStore.shared
        switch (request.method.uppercased(), path) {
        case ("GET", "/term/sessions"):
            let list = store.all.map(\.json)
            try? await responder.respond(status: 200, headers: ["content-type": "application/json"],
                                         body: json(["ok": true, "sessions": list, "max": TerminalStore.max]))
        case ("POST", "/term/kill"):
            let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            guard let id = o?["id"] as? String else { return await fail(responder, 400, "id is required") }
            guard let s = store.session(id) else { return await fail(responder, 404, "no such terminal") }
            log("terminal: \(id) ended by \(device.name)")
            s.end(.killed)
            try? await responder.respond(status: 200, headers: ["content-type": "application/json"], body: json(["ok": true]))
        case ("GET", "/term"):
            guard request.duplex else { return await fail(responder, 400, "GET /term is a duplex request") }
            await open(query, responder, device: device, session: session)
        default:
            await fail(responder, 404, "no such endpoint \(path)")
        }
    }

    private static func open(_ query: [String: String], _ responder: RpcResponder, device: RemoteDevice,
                             session: LinkSession) async {
        let store = TerminalStore.shared
        let cols = UInt16(clamping: Int(query["cols"] ?? "") ?? 80)
        let rows = UInt16(clamping: Int(query["rows"] ?? "") ?? 24)
        let terminal: TerminalSession
        var since = query["since"].flatMap { UInt64($0) }
        if let id = query["session"], !id.isEmpty {
            guard let s = store.session(id), !s.hasEnded else { return await fail(responder, 404, "no such terminal", code: "gone") }
            terminal = s
            if query["cols"] != nil, query["rows"] != nil { terminal.resize(cols: cols, rows: rows) }
        } else {
            do {
                terminal = try store.open(cols: cols, rows: rows, cwd: query["cwd"], device: (device.id, device.name))
                since = 0  // the phone's copy is all of it
            } catch is TerminalStore.Full {
                return await fail(responder, 429, "\(TerminalStore.max) terminals are open on this Mac", code: "too-many")
            } catch {
                return await fail(responder, 500, "\(error)")
            }
        }
        let duplex: LinkDuplex
        do {
            duplex = try await responder.acceptDuplex(headers: ["x-term-session": terminal.id])
        } catch {
            return
        }
        let sink = LinkTerminalSink(duplex: duplex, terminal: terminal)
        guard terminal.attach(sink, since: since) else {
            sink.terminalEnded(.exited(0))
            await sink.run()
            return
        }
        log("terminal: \(terminal.id) attached by \(device.name)\(since.map { " from byte \($0)" } ?? "")")
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await sink.run() }
            group.addTask { await sink.readInput() }
            // one ended (the terminal for it, or the phone's stream): end the other
            await group.next()
            sink.stop()
            duplex.cancel()
        }
        terminal.detach(sink)
        log("terminal: \(terminal.id) detached (\(device.name))")
    }
}

/// A terminal's attached phone: its output out on the duplex stream (in order, one writer), the phone's messages in.
final class LinkTerminalSink: TerminalSink, @unchecked Sendable {
    private enum Out {
        case message(DuplexMessage, bytes: Int)
        case end
    }

    let duplex: LinkDuplex
    weak var terminal: TerminalSession?
    private let outbox: AsyncStream<Out>.Continuation
    private let stream: AsyncStream<Out>
    private let lock = NSLock()
    private var backlogBytes = 0
    private var over = false

    init(duplex: LinkDuplex, terminal: TerminalSession) {
        self.duplex = duplex
        self.terminal = terminal
        (stream, outbox) = AsyncStream<Out>.makeStream()
    }

    var terminalBacklog: Int {
        lock.lock(); defer { lock.unlock() }
        return backlogBytes
    }

    private func addBacklog(_ n: Int) {
        lock.lock()
        backlogBytes += n
        lock.unlock()
    }

    /// The phone went: the writer stops.
    func stop() {
        outbox.finish()
    }

    func terminalAttached(_ attached: TerminalSession.Attached) {
        let hello: [String: Any] = [
            "t": "attached", "session": terminal?.id ?? "", "offset": attached.offset, "reset": attached.reset,
            "cols": Int(terminal?.cols ?? 0), "rows": Int(terminal?.rows ?? 0),
        ]
        outbox.yield(.message(.text(text: String(decoding: LinkTerminal.json(hello), as: UTF8.self)), bytes: 0))
        var replay = attached.replay
        while !replay.isEmpty {
            let chunk = replay.prefix(TerminalSession.readMax)
            replay = replay.dropFirst(chunk.count)
            terminalOutput(Data(chunk))
        }
    }

    func terminalOutput(_ data: Data) {
        addBacklog(data.count)
        outbox.yield(.message(.binary(data: data), bytes: data.count))
    }

    func terminalEnded(_ end: TerminalEnd) {
        lock.lock()
        let was = over
        over = true
        lock.unlock()
        guard !was else { return }
        var m: [String: Any] = ["t": end == .replaced || end == .off || end == .killed ? "detached" : "exit", "reason": end.reason]
        if case .exited(let code) = end { m["code"] = Int(code) }
        outbox.yield(.message(.text(text: String(decoding: LinkTerminal.json(m), as: UTF8.self)), bytes: 0))
        outbox.yield(.end)
        outbox.finish()
    }

    /// Sends what comes, until the terminal ended for it (then FIN) or the stream fails.
    func run() async {
        for await out in stream {
            switch out {
            case .message(let m, let bytes):
                do { try await duplex.send(message: m) } catch { return }
                if bytes > 0 {
                    addBacklog(-bytes)
                    terminal?.drained()
                }
            case .end:
                try? await duplex.finish()
                return
            }
        }
    }

    /// The phone's typing (binary) and resizes (`{"t":"resize","cols","rows"}`), until it finished or went.
    func readInput() async {
        while true {
            let m: DuplexMessage?
            do { m = try await duplex.recv() } catch { return }
            guard let m else { return }
            switch m {
            case .binary(let data):
                terminal?.write(data)
            case .text(let text):
                guard let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { continue }
                if o["t"] as? String == "resize", let c = o["cols"] as? Int, let r = o["rows"] as? Int {
                    terminal?.resize(cols: UInt16(clamping: c), rows: UInt16(clamping: r))
                }
            case .close:
                return
            }
        }
    }
}
#endif
