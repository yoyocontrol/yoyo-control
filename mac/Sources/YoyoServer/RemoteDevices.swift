#if os(macOS)
import CryptoKit
import Foundation

/// A phone paired with this Mac (docs/REMOTE.md「配对」): it names itself (`id`, `name`) when it pairs and gets a
/// token; only the token's SHA-256 is kept.
public struct RemoteDevice: Equatable, Sendable {
    public let id: String
    public var name: String
    public let pairedAt: Date
    public var lastSeenAt: Date?
    let tokenHash: String
    /// The link key (hex of its Ed25519 public key, docs/LINK.md「身份与信任」) the token was first used with over the
    /// link: only that key may use it there, until the device pairs again (a new token, no key yet).
    public internal(set) var linkKey: String? = nil

    var json: [String: Any] {
        var j: [String: Any] = ["id": id, "name": name, "pairedAt": pairedAt.timeIntervalSince1970 * 1000]
        if let lastSeenAt { j["lastSeenAt"] = lastSeenAt.timeIntervalSince1970 * 1000 }
        return j
    }

    /// The device as others see it (`control.device`, a 409's `controllerDevice`).
    var ref: [String: Any] { ["id": id, "name": name] }
}

/// The pairing code being shown (the QR code's `c`) and when it runs out.
public struct PairingCode: Equatable, Sendable {
    public let code: String
    public let expiresAt: Date
}

/// The paired devices (`devices.json`, 0600) and the pairing code being shown (memory only). Thread-safe.
///
/// - One pairing code at a time, 128 random bits, good for `codeTTL`, used once. `maxCodeAttempts` wrong codes in a
///   row end it (a new one must be shown on the Mac).
/// - Invitations (docs/ACCOUNT.md「批准」): a paired phone asks for a code for another phone of its account, by that
///   phone's id and link key; the code works only for that phone over a session from that key, `inviteTTL`, once. Up
///   to `maxInvites` at a time, beside the shown code.
/// - A token is 32 random bytes; a phone pairing again with the same `id` replaces its old token.
/// - `lastSeenAt` is written to disk at most every `seenWriteEvery`.
public final class RemoteDevices: @unchecked Sendable {
    public static let codeTTL: TimeInterval = 5 * 60
    public static let maxCodeAttempts = 10
    public static let inviteTTL: TimeInterval = 10 * 60
    static let maxInvites = 8
    static let maxDevices = 32
    static let seenWriteEvery: TimeInterval = 3600
    static let nameMax = 64

    public let path: String
    private let now: () -> Date
    private let lock = NSLock()
    private var devices: [RemoteDevice] = []
    private var code: PairingCode?
    /// Codes for one phone each (`invite`): the code → who may use it.
    private var invites: [String: Invite] = [:]
    private var wrongCodes = 0
    /// Called (outside the lock) when the list or the pairing code changes.
    public var onChange: (() -> Void)?

    public init(path: String, now: @escaping () -> Date = Date.init) {
        self.path = path
        self.now = now
        devices = Self.load(path)
    }

    // MARK: Reading

    public var list: [RemoteDevice] {
        lock.lock(); defer { lock.unlock() }
        return devices
    }

    public var isEmpty: Bool { list.isEmpty }

    /// The live pairing code, if any.
    public var pairingCode: PairingCode? {
        lock.lock(); defer { lock.unlock() }
        return liveCodeLocked()
    }

    /// What the link's authentication found (`authenticateLink`).
    public enum LinkCheck: Equatable, Sendable {
        /// The token's device; its link key is `key` (bound now, the first time).
        case accepted(RemoteDevice)
        /// The token's device is bound to another link key.
        case otherKey(RemoteDevice)
        case unknownToken
    }

    /// `authenticate` for a link session from `key`: the first one binds the token to that key (saved).
    public func authenticateLink(token: String, key: String) -> LinkCheck {
        guard var device = authenticate(token: token) else { return .unknownToken }
        let key = key.lowercased()
        lock.lock()
        defer { lock.unlock() }
        guard let i = devices.firstIndex(where: { $0.id == device.id && $0.tokenHash == device.tokenHash }) else { return .unknownToken }
        if let bound = devices[i].linkKey {
            return bound == key ? .accepted(devices[i]) : .otherKey(devices[i])
        }
        devices[i].linkKey = key
        saveLocked()
        device = devices[i]
        return .accepted(device)
    }

    /// The device holding `token` (its `lastSeenAt` noted); nil for an unknown one.
    public func authenticate(token: String) -> RemoteDevice? {
        let hash = Self.hash(token)
        lock.lock()
        guard let i = devices.firstIndex(where: { $0.tokenHash == hash }) else {
            lock.unlock()
            return nil
        }
        let t = now()
        let write = devices[i].lastSeenAt.map { t.timeIntervalSince($0) >= Self.seenWriteEvery } ?? true
        devices[i].lastSeenAt = t
        let device = devices[i]
        if write { saveLocked() }
        lock.unlock()
        return device
    }

    // MARK: Pairing

    /// A new pairing code (the one before it no longer works).
    @discardableResult
    public func startPairing() -> PairingCode {
        lock.lock()
        let c = PairingCode(code: Self.random(16), expiresAt: now().addingTimeInterval(Self.codeTTL))
        code = c
        wrongCodes = 0
        lock.unlock()
        onChange?()
        return c
    }

    /// The code is no longer shown (the Mac closed the window).
    public func stopPairing() {
        lock.lock()
        let had = code != nil
        code = nil
        lock.unlock()
        if had { onChange?() }
    }

    struct Invite {
        let deviceId: String
        let linkKey: String
        let expiresAt: Date
    }

    /// A code for the phone `id` alone, over a session from `linkKey` (hex), asked for by a phone already paired.
    public func invite(id: String, linkKey: String) throws -> PairingCode {
        guard Self.validId(id) else { throw PairError.badDevice("device.id must be 8–64 of A–Z a–z 0–9 _ -") }
        let key = linkKey.lowercased()
        guard key.utf8.count == 64, key.allSatisfy(\.isHexDigit) else { throw PairError.badDevice("linkKey must be 64 hex digits") }
        lock.lock()
        defer { lock.unlock() }
        let t = now()
        invites = invites.filter { $0.value.expiresAt > t && $0.value.deviceId != id }
        guard invites.count < Self.maxInvites else { throw PairError.full }
        let c = PairingCode(code: Self.random(16), expiresAt: t.addingTimeInterval(Self.inviteTTL))
        invites[c.code] = Invite(deviceId: id, linkKey: key, expiresAt: c.expiresAt)
        return c
    }

    public enum PairError: Error, Equatable {
        /// No code is being shown, it expired, or it was wrong (`attemptsLeft` more before it ends).
        case badCode
        case badDevice(String)
        case full
    }

    /// Pairs the phone (`id`, `name`) with the live code, or an invitation made for it: its token (shown once). The
    /// code is used up.
    ///
    /// `linkKey`: pairing over the link (`hello.credential = "Pair <code>"`, docs/LINK.md「配对」): the token is bound
    /// to the session's client key at once, as its first link use would bind it.
    public func pair(code given: String, id: String, name: String, linkKey: String? = nil) throws -> String {
        guard Self.validId(id) else { throw PairError.badDevice("device.id must be 8–64 of A–Z a–z 0–9 _ -") }
        let name = Self.cleanName(name)
        lock.lock()
        let t = now()
        let invited = invites.first { Self.constantTimeEqual($0.key, given) && $0.value.expiresAt > t }
        if let (_, who) = invited {
            // only the phone it was made for, from its key
            guard who.deviceId == id, who.linkKey == linkKey?.lowercased() else {
                lock.unlock()
                throw PairError.badCode
            }
        } else if !(liveCodeLocked().map { Self.constantTimeEqual($0.code, given) } ?? false) {
            if liveCodeLocked() != nil {
                wrongCodes += 1
                if wrongCodes >= Self.maxCodeAttempts { code = nil }
            }
            lock.unlock()
            onChange?()
            throw PairError.badCode
        }
        devices.removeAll { $0.id == id }
        guard devices.count < Self.maxDevices else {
            lock.unlock()
            throw PairError.full
        }
        // the code is used up
        if let (used, _) = invited { invites[used] = nil } else { code = nil }
        let token = Self.random(32)
        devices.append(RemoteDevice(id: id, name: name, pairedAt: now(), lastSeenAt: now(), tokenHash: Self.hash(token),
                                    linkKey: linkKey?.lowercased()))
        saveLocked()
        lock.unlock()
        onChange?()
        return token
    }

    /// Forgets the device: its token stops working at once. false when it wasn't paired.
    @discardableResult
    public func remove(id: String) -> Bool {
        lock.lock()
        let before = devices.count
        devices.removeAll { $0.id == id }
        let removed = devices.count != before
        if removed { saveLocked() }
        lock.unlock()
        if removed { onChange?() }
        return removed
    }

    // MARK: Private

    private func liveCodeLocked() -> PairingCode? {
        guard let c = code else { return nil }
        if c.expiresAt <= now() {
            code = nil
            return nil
        }
        return c
    }

    private func saveLocked() {
        let body: [String: Any] = [
            "version": 1,
            "devices": devices.map { d -> [String: Any] in
                var j = d.json
                j["tokenHash"] = d.tokenHash
                if let k = d.linkKey { j["linkKey"] = k }
                return j
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) else { return }
        do {
            try RemoteIdentity.writePrivate(data, to: path)
        } catch {
            log("remote: \(error)")
        }
    }

    private static func load(_ path: String) -> [RemoteDevice] {
        guard let data = FileManager.default.contents(atPath: path),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = json["devices"] as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard let id = d["id"] as? String, let hash = d["tokenHash"] as? String, hash.count == 64,
                  let paired = d["pairedAt"] as? Double else { return nil }
            let seen = (d["lastSeenAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            return RemoteDevice(id: id, name: d["name"] as? String ?? id, pairedAt: Date(timeIntervalSince1970: paired / 1000),
                                lastSeenAt: seen, tokenHash: hash, linkKey: d["linkKey"] as? String)
        }
    }

    /// 8–64 of A–Z a–z 0–9 _ - (a UUID fits).
    static func validId(_ id: String) -> Bool {
        (8...64).contains(id.utf8.count) && id.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f || c == 0x2d
        }
    }

    static func cleanName(_ raw: String) -> String {
        let trimmed = raw.filter { !$0.isNewline && $0 != "\0" }.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "iPhone" : String(trimmed.prefix(nameMax))
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `bytes` random bytes as base64url without padding.
    static func random(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return Data(b).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
#endif
