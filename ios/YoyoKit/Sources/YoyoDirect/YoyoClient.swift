import Foundation
import UIKit
import YoyoConnect
import YoyoCore
import YoyoLinkClient

/// Pairing with a Mac and reaching it (docs/REMOTE.md): both over uu Link (docs/LINK.md), its binding checked against
/// the Mac's pinned key before every dial.
public enum YoyoClient {
    public enum Failure: LocalizedError, Equatable {
        /// The Mac didn't answer (asleep or offline, Yoyo Control not running, remote access off).
        case unreachable(String)
        /// The Mac doesn't know this phone's token any more (removed there).
        case unpaired
        /// The pairing code was refused (expired, used, wrong).
        case codeRefused(String)
        case server(Int, String)
        /// The Mac answered only off the local network (the relay, a public address) and this phone has no Pro
        /// (`RemoteAccess`): the paywall's cue.
        case needsPro(String)

        public var errorDescription: String? {
            switch self {
            case .unreachable(let name):
                L("Can't reach \(name). Make sure it's on and awake, and that remote access is on there (on a Mac: Allow Remote Access in Yoyo Control's menu).")
            case .unpaired:
                L("This computer no longer knows this iPhone. Pair it again.")
            case .codeRefused(let why):
                L("The computer refused the pairing code: \(why)")
            case .server(let status, let why):
                L("The computer answered \(status): \(why)")
            case .needsPro(let name):
                L("\(name) isn't on the same network as this iPhone. Reaching it from elsewhere needs Yoyo Control Pro.")
            }
        }
    }

    /// The signaling server, where a Mac's binding is asked for when a record has none (docs/RELAY.md「候选」). None is
    /// built in: the app sets its own before the first dial; nil = no lookups (records carry their binding).
    nonisolated(unsafe) public static var signalURL: URL?
    /// Without Pro, how long a session that came up off the local network may take to move onto it (iroh tries the
    /// local addresses beside the relay; the relay may answer first).
    static let lanWait: Duration = .milliseconds(1500)

    /// Pairs over the link (`hello.credential = "Pair <code>"`, docs/LINK.md「配对」): the Mac hands the token back in
    /// `welcome.principal`, bound to this install's link key.
    public static func pair(_ invite: YoyoInvite, deviceId: String, deviceName: String) async throws -> YoyoMac {
        var mac = YoyoMac(id: invite.id, name: invite.name, addresses: invite.addresses, fingerprint: invite.fingerprint,
                          token: "", link: invite.link)
        let connection: YoyoLinkConnection
        do {
            connection = try await YoyoLinkClient.shared.dial(invite.link, fingerprint: invite.fingerprint, hints: mac.linkHints,
                                                              credential: "Pair \(invite.code)",
                                                              device: ScreenControlDevice(id: deviceId, name: deviceName),
                                                              timeout: .seconds(10))
        } catch YoyoLinkClient.Failure.unauthorized(let why) {
            throw Failure.codeRefused(why)
        } catch YoyoLinkClient.Failure.refused(let why) {
            throw Failure.server(409, why)
        } catch YoyoLinkClient.Failure.binding(let why) {
            throw Failure.server(0, why)
        } catch {
            throw Failure.unreachable(invite.name)
        }
        defer { connection.close() }
        let principal = connection.session.principal as? [String: Any]
        guard let token = principal?["token"] as? String else { throw Failure.server(0, "the computer gave no token") }
        let server = principal?["server"] as? [String: Any]
        mac = YoyoMac(id: server?["id"] as? String ?? invite.id, name: server?["name"] as? String ?? invite.name,
                      addresses: invite.addresses, fingerprint: invite.fingerprint, token: token, link: invite.link)
        // the session is this device's now: what it is and its binding as it is (its addresses)
        if let status = try? await status(over: connection) { mac = updated(mac, status: status) }
        return mac
    }

    /// How a dial went.
    enum Dialed: Sendable {
        case reached(DirectLink)
        /// The Mac refused the token (removed there, or bound to another install's key).
        case unauthorized
        /// Reached only off the local network, without Pro.
        case needsPro
        case unreachable
    }

    /// The Mac over its link (docs/LINK.md): its binding (the record's, else the signaling server's), checked against
    /// its pin, dialed at the binding's addresses and the ones this phone knows it at, `Bearer <token>` in `hello`.
    /// Without Pro, a session must be (or soon get) on the local network.
    static func dial(_ mac: YoyoMac, pro: Bool) async -> Dialed {
        var binding = mac.link
        if binding == nil { binding = await SignalLookup.link(fingerprint: mac.fingerprint, base: signalURL) }
        guard let binding, !Task.isCancelled else { return .unreachable }
        let connection: YoyoLinkConnection
        do {
            connection = try await YoyoLinkClient.shared.dial(binding, fingerprint: mac.fingerprint, hints: mac.linkHints,
                                                              credential: "Bearer \(mac.token)")
        } catch YoyoLinkClient.Failure.unauthorized {
            return .unauthorized
        } catch {
            return .unreachable
        }
        if !pro {
            let deadline = ContinuousClock.now + lanWait
            while !connection.isLocalNetwork, ContinuousClock.now < deadline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if !connection.isLocalNetwork {
                connection.close()
                return .needsPro
            }
        }
        if Task.isCancelled {
            connection.close()
            return .unreachable
        }
        return .reached(DirectLink(connection: connection))
    }

    /// Reaches `mac`: its link, again with the signaling server's binding when the record's (an old one) got nowhere.
    /// The Mac comes back as `/status` said it is (its binding, its platform).
    static func locate(_ mac: YoyoMac, pro: Bool, probes: DirectProbes = .live) async throws -> (mac: YoyoMac, link: DirectLink) {
        var m = mac
        var dialed = await probes.link(m, pro)
        if case .unreachable = dialed, m.link != nil,
           let fresh = await SignalLookup.link(fingerprint: m.fingerprint, base: signalURL), fresh != m.link {
            m.link = fresh
            dialed = await probes.link(m, pro)
        }
        switch dialed {
        case .reached(let link):
            if let status = try? await status(over: link.connection) { m = updated(m, status: status) }
            return (m, link)
        case .unauthorized: throw Failure.unpaired
        case .needsPro: throw Failure.needsPro(mac.name)
        case .unreachable: throw Failure.unreachable(mac.name)
        }
    }

    /// One request to `mac` over its link (`method path`, a JSON body), the JSON object it answered: the account routes
    /// (docs/ACCOUNT.md, `GET /account`, `POST /account/join`, `POST /account/invite`). They aren't screen use, so off
    /// the local network needs no Pro. A status other than 200 is `Failure.server`.
    public static func call(_ mac: YoyoMac, method: String, path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        let (_, link) = try await locate(mac, pro: true)
        defer { link.connection.close() }
        var request = URLRequest(url: DirectBackend.linkBase.appending(path: path.hasPrefix("/") ? String(path.dropFirst()) : path))
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await link.connection.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard response.statusCode == 200 else {
            throw Failure.server(response.statusCode, json["error"] as? String ?? "the computer answered \(response.statusCode)")
        }
        return json
    }

    /// This install's uu Link id (hex), which a computer binds this phone's token to: what another phone asks the
    /// computer to make a code for (docs/ACCOUNT.md「批准」).
    public static var linkId: String? { YoyoLinkClient.linkId }

    /// An invitation to the computer `fingerprint` (its `id`, `name`) with `code`: its uu Link binding as its signaling
    /// room has it now (docs/ACCOUNT.md「批准」); nil when it isn't there.
    public static func invite(id: String, name: String, fingerprint: String, code: String) async -> YoyoInvite? {
        guard let link = await SignalLookup.link(fingerprint: fingerprint, base: signalURL) else { return nil }
        return YoyoInvite(id: id, name: name, fingerprint: fingerprint, code: code, link: link)
    }

    /// `GET /status` over a session.
    static func status(over connection: YoyoLinkConnection) async throws -> [String: Any] {
        let request = URLRequest(url: DirectBackend.linkBase.appending(path: "status"))
        let (data, response) = try await connection.data(for: request)
        guard response.statusCode == 200, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw YoyoError.http(response.statusCode, nil)
        }
        return json
    }

    /// `mac` with the binding and platform a `/status` named.
    static func updated(_ mac: YoyoMac, status: [String: Any]) -> YoyoMac {
        var m = mac
        if let p = status["platform"] as? String, !p.isEmpty { m.platform = p }
        if let l = ConnectLinkBinding(json: status["link"]) { m.link = l }
        return m
    }
}
