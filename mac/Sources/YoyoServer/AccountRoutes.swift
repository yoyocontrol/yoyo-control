#if os(macOS)
import Foundation

/// The account routes (docs/ACCOUNT.md): a paired phone, over its link session, puts this Mac in its account
/// (`POST /account/join`) and asks for a code for another phone of the account (`POST /account/invite`); `GET
/// /account` says which account this Mac is in. The menu leaves it with `POST /remote/account/leave` (unix socket).
extension Router {
    /// The paired phone asking (never the unix socket, never a device another program let in).
    private static func pairedPhone(_ req: HTTPRequest) throws -> (RemoteDevice, RemoteAccess) {
        guard let who = req.remote, !who.tokenHash.isEmpty, let access = RemoteAccess.current,
              access.devices.list.contains(where: { $0.id == who.id }) else {
            throw HTTPError(404, "no such endpoint \(req.path)")
        }
        return (who, access)
    }

    /// `GET /account` → `{ account: { id, since } | null }`.
    static func account(_ req: HTTPRequest, _ conn: Connection) throws {
        guard let access = RemoteAccess.current else { throw HTTPError(404, "no such endpoint \(req.path)") }
        if req.remote != nil { _ = try pairedPhone(req) }
        conn.json(200, ["account": access.json["account"] ?? NSNull()])
    }

    /// `POST /account/join { account }` → the signed statement for the account service (`RemoteAccess.join`).
    static func accountJoin(_ req: HTTPRequest, _ conn: Connection) throws {
        let (who, access) = try pairedPhone(req)
        guard let account = (try jsonBody(req))["account"] as? String else { throw HTTPError(400, "account is required") }
        let statement = try access.join(account: account)
        log("remote: \(who.name) put this Mac in its account")
        conn.json(200, statement)
    }

    /// `POST /account/invite { id, name, linkKey }` → `{ code, expiresAt }`: a code that pairs the phone `id` alone,
    /// over a session from `linkKey` (its uu Link id), for `RemoteDevices.inviteTTL`.
    static func accountInvite(_ req: HTTPRequest, _ conn: Connection) throws {
        let (who, access) = try pairedPhone(req)
        let body = try jsonBody(req)
        guard let id = body["id"] as? String, let key = body["linkKey"] as? String else { throw HTTPError(400, "id and linkKey are required") }
        let name = RemoteDevices.cleanName(body["name"] as? String ?? "")
        let code: PairingCode
        do {
            code = try access.devices.invite(id: id, linkKey: key)
        } catch RemoteDevices.PairError.badDevice(let why) {
            throw HTTPError(400, why)
        } catch {
            throw HTTPError(429, "too many invitations waiting")
        }
        log("remote: \(who.name) let \(name) in (a code for it alone)")
        conn.json(200, ["code": code.code, "expiresAt": code.expiresAt.timeIntervalSince1970 * 1000])
    }

    /// `POST /remote/account/leave` (the menu's) → `GET /remote`'s answer.
    static func remoteAccountLeave(_ req: HTTPRequest, _ conn: Connection) throws {
        guard req.remote == nil, let access = RemoteAccess.current else { throw HTTPError(404, "no such endpoint \(req.path)") }
        access.leaveAccount()
        conn.json(200, access.json)
    }
}
#endif
