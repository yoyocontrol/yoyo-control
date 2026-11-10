// The idiomatic side of uu Link for Swift (docs/LINK.md「Swift」). `Generated/YoyoLink.swift` is UniFFI's binding of
// the Rust core (scripts/link-apple.sh; never edit it); this file adds what Swift code wants on top: typed channels,
// JSON control messages, async sequences, and closure-based authenticator / RPC handler / log sink.

import Foundation

/// The media layer's datagram channels (byte 0 of a datagram is `channel << 4 | 1`). They belong to the session's
/// media API (`sendFrame`, `nextClientEvent`, …); raw datagrams are for the app's own channels 6–15.
public enum LinkChannel: UInt8, Sendable, CaseIterable {
    case video = 1
    case audio = 2
    case input = 3
    case feedback = 4
    case cursor = 5
}

/// QUIC application close codes.
public enum LinkCloseCode: UInt64, Sendable {
    case normal = 0
    case unauthorized = 1
    case rateLimited = 2
    case busy = 3
    case `protocol` = 4
    case shuttingDown = 5
    case replaced = 6
}

/// A control message: its `t` and the whole JSON object.
public struct LinkControlMessage: Sendable, Equatable {
    public let type: String
    public let json: Data

    public init?(json text: String) {
        let data = Data(text.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = object["t"] as? String else { return nil }
        self.type = t
        self.json = data
    }

    public func decode<T: Decodable>(_ type: T.Type, using decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(type, from: json)
    }

    /// The object as Foundation values (`[String: Any]`).
    public var object: [String: Any] {
        (try? JSONSerialization.jsonObject(with: json) as? [String: Any]) ?? [:]
    }
}

extension LinkSession {
    /// Sends a control message; `message` encodes to a JSON object with a string `t`.
    public func send<T: Encodable>(control message: T, using encoder: JSONEncoder = JSONEncoder()) async throws {
        let data = try encoder.encode(message)
        try await sendControl(json: String(decoding: data, as: UTF8.self))
    }

    /// Sends a control message given as Foundation values (must have a string `t`).
    public func send(controlObject object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await sendControl(json: String(decoding: data, as: UTF8.self))
    }

    /// The control messages from the other side, until the session ends.
    public var controlMessages: AsyncStream<LinkControlMessage> {
        AsyncStream { continuation in
            let task = Task {
                while let text = await self.recvControl() {
                    if let m = LinkControlMessage(json: text) { continuation.yield(m) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Sends `channel << 4 | 1` then `payload` on one of the app's channels (6–15).
    public func send(_ payload: Data, onChannel channel: UInt8) throws {
        try sendDatagram(channel: channel, payload: payload)
    }

    /// The datagrams of an app channel (6–15), whole (byte 0 = the header), until the session ends.
    public func datagrams(onChannel channel: UInt8) -> AsyncStream<Data> {
        AsyncStream { continuation in
            let task = Task {
                while let d = try? await self.recvDatagram(channel: channel) {
                    continuation.yield(d)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Server: the media layer's events (target bitrate, deliveries, recovery / key frame needed, input).
    public var serverEvents: AsyncStream<ServerMediaEvent> {
        AsyncStream { continuation in
            let task = Task {
                while let e = await self.nextServerEvent() { continuation.yield(e) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Client: the media layer's events (frames, audio packets, cursor, input acked / failed).
    public var clientEvents: AsyncStream<ClientMediaEvent> {
        AsyncStream { continuation in
            let task = Task {
                while let e = await self.nextClientEvent() { continuation.yield(e) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func close(_ code: LinkCloseCode = .normal, reason: String = "") async {
        await close(code: code.rawValue, reason: reason)
    }

    /// Who the server says the client is (`welcome.principal`), as Foundation values.
    public var principal: Any? {
        try? JSONSerialization.jsonObject(with: Data(welcome().principalJson.utf8), options: [.fragmentsAllowed])
    }
}

extension LinkListener {
    /// The authenticated sessions, until the endpoint is closed.
    public var sessions: AsyncStream<LinkSession> {
        AsyncStream { continuation in
            let task = Task {
                while let s = await self.accept() { continuation.yield(s) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension LinkEndpoint {
    /// The address info now and at every change, until the endpoint is closed.
    public var addressUpdates: AsyncStream<AddrInfo> {
        AsyncStream { continuation in
            watchAddr(observer: LinkAddrObserver { continuation.yield($0) })
        }
    }

    /// Starts accepting sessions with closures for authentication and RPC.
    public func listen(
        _ settings: ServerSettings,
        authenticate: @escaping @Sendable (AuthRequest) async -> LinkAuthDecision,
        rpc: (@Sendable (LinkSession, RpcRequest, Data, RpcResponder) async -> Void)? = nil
    ) throws -> LinkListener {
        try listen(
            settings: settings,
            authenticator: LinkAuthenticator(authenticate),
            rpc: rpc.map { LinkRpcHandler($0) }
        )
    }
}

extension RpcResponse {
    /// The body's pieces as they arrive.
    public var body: AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    while let c = try await self.chunk() { continuation.yield(c) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension RpcRequest {
    public init(_ method: String, _ path: String, headers: [String: String] = [:]) {
        self.init(method: method, path: path, headers: headers)
    }
}

/// An authenticator's answer.
public enum LinkAuthDecision: Sendable {
    /// `principalJSON`: a JSON value for `welcome.principal`; `features`: nil = the server's list.
    case accept(principalJSON: String, features: [String]? = nil)
    case deny(DenyCode, message: String)
}

/// `Authenticator` from a closure (runs in a task; answers through the reply).
public final class LinkAuthenticator: Authenticator, @unchecked Sendable {
    private let decide: @Sendable (AuthRequest) async -> LinkAuthDecision

    public init(_ decide: @escaping @Sendable (AuthRequest) async -> LinkAuthDecision) {
        self.decide = decide
    }

    public func authenticate(request: AuthRequest, reply: AuthReply) {
        let decide = self.decide
        Task {
            switch await decide(request) {
            case let .accept(principal, features):
                try? reply.accept(principalJson: principal, features: features)
            case let .deny(code, message):
                try? reply.deny(code: code, message: message)
            }
        }
    }
}

/// `RpcHandler` from a closure (runs in a task).
public final class LinkRpcHandler: RpcHandler, @unchecked Sendable {
    private let handler: @Sendable (LinkSession, RpcRequest, Data, RpcResponder) async -> Void

    public init(_ handler: @escaping @Sendable (LinkSession, RpcRequest, Data, RpcResponder) async -> Void) {
        self.handler = handler
    }

    public func handle(session: LinkSession, request: RpcRequest, body: Data, responder: RpcResponder) {
        let handler = self.handler
        Task { await handler(session, request, body, responder) }
    }
}

/// `AddrObserver` from a closure.
public final class LinkAddrObserver: AddrObserver, @unchecked Sendable {
    private let onChange: @Sendable (AddrInfo) -> Void

    public init(_ onChange: @escaping @Sendable (AddrInfo) -> Void) {
        self.onChange = onChange
    }

    public func onAddr(info: AddrInfo) {
        onChange(info)
    }
}

/// The link's log lines (`link:` stats, sessions, paths, guard).
public enum LinkLog {
    /// Sends every line to `handler` (nil: back to the default, nowhere).
    public static func setHandler(_ handler: (@Sendable (LogLevel, String) -> Void)?) {
        setLogSink(sink: handler.map { LinkLogSink($0) })
    }
}

final class LinkLogSink: LogSink, @unchecked Sendable {
    private let handler: @Sendable (LogLevel, String) -> Void

    init(_ handler: @escaping @Sendable (LogLevel, String) -> Void) {
        self.handler = handler
    }

    func log(level: LogLevel, message: String) {
        handler(level, message)
    }
}
