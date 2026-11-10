import Foundation
import YoyoConnect
import YoyoCore

/// Where a Mac's uu Link binding is asked for when this phone has none (a record from before the code carried it):
/// the signaling server (docs/RELAY.md「候选」, `GET /v1/candidates/<fp>`), where the Mac keeps it while it listens.
/// The binding is checked against the pin before it is dialed, as any other (YoyoLinkClient).
enum SignalLookup {
    /// The room for `fingerprint` ("sha256:<hex>", as paired): 64 lowercase hex digits, or nil when it isn't one.
    static func room(_ fingerprint: String) -> String? { ConnectPin.normalized(fingerprint) }

    /// `https://…/v1/candidates/<room>` (`ws` / `wss` bases as `http` / `https`).
    static func candidatesURL(_ base: URL, _ room: String) -> URL? {
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = c.scheme == "ws" || c.scheme == "http" ? "http" : "https"
        return c.url?.appending(path: "v1/candidates/\(room)")
    }

    /// The binding the Mac told its room (nil: none, the Mac isn't there, or no answer in time).
    static func link(fingerprint: String, base: URL?, timeout: TimeInterval = 3) async -> ConnectLinkBinding? {
        guard let base, let room = room(fingerprint), let url = candidatesURL(base, room) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return ConnectLinkBinding(json: json["link"])
    }
}
