#if os(macOS)
import Foundation

/// The account routes (docs/ACCOUNT.md): over its link session a phone paired here and signed in puts this Mac in its
/// account (`POST /account/join { server, key }`, a one-use join key its account server made) or takes it out (`POST
/// /account/leave`); `GET /account` says which account this Mac is in. The menu leaves it with `POST
/// /remote/account/leave` (unix socket).
extension Router {
    /// A phone paired here asking (never the unix socket, never a device the account let in: that one cannot move this
    /// Mac into another account).
    private static func pairedPhone(_ req: HTTPRequest) throws -> (RemoteDevice, RemoteAccess) {
        guard let who = req.remote, !who.tokenHash.isEmpty, let access = RemoteAccess.current,
              access.devices.list.contains(where: { $0.id == who.id }) else {
            throw HTTPError(404, "no such endpoint \(req.path)")
        }
        guard access.devices.isPaired(who.id) else { throw HTTPError(403, "only a phone paired with this Mac may do this") }
        return (who, access)
    }

    /// `GET /account` → `{ account: { id, name, server, joinedAt, disabled } | null, error? }`.
    static func account(_ req: HTTPRequest, _ conn: Connection) throws {
        guard let access = RemoteAccess.current else { throw HTTPError(404, "no such endpoint \(req.path)") }
        conn.json(200, access.membership?.json ?? ["account": NSNull()])
    }

    /// `POST /account/join { server, key }` → `GET /account`'s answer, once this Mac joined.
    static func accountJoin(_ req: HTTPRequest, _ conn: Connection) throws {
        let (who, access) = try pairedPhone(req)
        let body = try jsonBody(req)
        guard let server = body["server"] as? String, let key = body["key"] as? String else {
            throw HTTPError(400, "body must be { server, key } (an older app sent { account }: update it)")
        }
        try waitFor { try await access.joinAccount(server: server, key: key) }
        log("remote: \(who.name) put this Mac in its account")
        conn.json(200, access.membership?.json ?? [:])
    }

    /// `POST /account/leave` (a phone paired here) → `GET /account`'s answer.
    static func accountLeave(_ req: HTTPRequest, _ conn: Connection) throws {
        let (who, access) = try pairedPhone(req)
        try waitFor { await access.leaveAccount() }
        log("remote: \(who.name) took this Mac out of its account")
        conn.json(200, access.membership?.json ?? [:])
    }

    /// `POST /remote/account/leave` (the menu's) → `GET /remote`'s answer.
    static func remoteAccountLeave(_ req: HTTPRequest, _ conn: Connection) throws {
        guard req.remote == nil, let access = RemoteAccess.current else { throw HTTPError(404, "no such endpoint \(req.path)") }
        try waitFor { await access.leaveAccount() }
        conn.json(200, access.json)
    }

    /// `op` run to its end on this route's own thread (a route answers before it returns).
    private static func waitFor(_ op: @escaping @Sendable () async throws -> Void) throws {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: Error?
        Task {
            do { try await op() } catch { failure = error }
            done.signal()
        }
        done.wait()
        if let failure { throw failure }
    }
}
#endif
