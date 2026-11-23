#if os(macOS)
import CryptoKit
import Foundation

/// This Mac in its person's account at an account server (docs/ACCOUNT.md; the library: docs/ACCOUNT-LIB.md): the
/// Swift twin of @yoyocontrol/account's `AccountMember` — the same wire names, checks and membership file.
///
/// - Joining: with a join key (`joinWithKey`) — the one a paired, signed-in phone hands over (`POST /account/join`) or an
///   admin's. The account server's address and signing keys, and the owner, are pinned in `account.json` (0600):
///   nothing the server says later changes who owns this Mac; `leave()` is the only way out (or the signed list).
/// - Coming in: a device of the account brings a ticket the server signed for it and this Mac (`redeem`); the Mac then
///   gives it a token of its own (`RemoteDevices.admit`). Such a token counts while `ticketValid` says so.
/// - Revocations: the account's signed list, asked for and waited on (25 s requests), so a removed device is out within
///   seconds while the server is up; while it is away everything already let in goes on.
/// - Every request of its own is signed with the link key (`<Ns>Link <linkId>.<ts>.<sig>`), the raw Ed25519 seed in
///   `link-key`.
/// - Not here (yet): joining with a code shown on the Mac, the services an account lends (a Mac has its own).
public final class AccountMembership: @unchecked Sendable {
    /// The wire's names, made of one namespace (protocol.ts `Wire`).
    public struct Wire: Sendable {
        public let ns: String
        public init(_ ns: String = "yoyo") { self.ns = ns }
        var ticketTyp: String { "\(ns)-ticket+jwt" }
        var revocationsTyp: String { "\(ns)-revocations+jwt" }
        var endorsementTyp: String { "\(ns)-key-endorsement+jwt" }
        var endorsementField: String { "\(ns)_endorsement" }
        var linkScheme: String { ns.prefix(1).uppercased() + ns.dropFirst() + "Link" }
        var joinKeyPrefix: String { "\(ns)_jk_" }
        func computerProofText(_ origin: String, _ method: String, _ pathQ: String, _ ts: Int, _ bodyHash: String) -> String {
            "\(ns)-account-computer-v1\n\(origin)\n\(method) \(pathQ)\n\(ts)\n\(bodyHash)"
        }
        func joinKeyProofText(_ origin: String, _ linkId: String, _ key: String) -> String {
            "\(ns)-account-joinkey-v1\n\(origin)\n\(linkId)\n\(AccountMembership.sha256b64url(Data(key.utf8)))"
        }
    }

    /// What this Mac tells the account server about itself.
    public struct SelfInfo: @unchecked Sendable {
        public var linkId: String
        public var name: String
        public var relays: [String]
        public var direct: [String]
        /// What the app needs of it (`info`: a JSON object).
        public var info: [String: Any]

        public init(linkId: String, name: String, relays: [String], direct: [String], info: [String: Any]) {
            self.linkId = linkId
            self.name = name
            self.relays = relays
            self.direct = direct
            self.info = info
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// Joining or leaving went wrong: an HTTP status for the caller and why.
        case join(Int, String)
        /// A ticket refused: protocol.ts's codes (malformed, unknown_key, bad_signature, expired, wrong_issuer,
        /// wrong_computer, not_owner, replayed, revoked, busy).
        case ticket(String)

        public var description: String {
            switch self {
            case .join(_, let why): why
            case .ticket(let code): "the ticket was refused (\(code))"
            }
        }
    }

    /// What a ticket says (the parts a Mac uses).
    public struct TicketClaims: Sendable, Equatable {
        public let account: String
        public let deviceId: String
        public let deviceName: String
        public let iat: Int
        /// When the device's sign-in ends (unix s); a ticket without it: 90 days after `iat`.
        public let sx: Int
    }

    struct Key: Equatable {
        let kid: String
        let x: String
        let endorsement: String?
    }

    struct Record: Equatable {
        var server: String
        var keys: [Key]
        var accountId: String
        var accountName: String?
        var linkId: String
        /// Unix ms.
        var joinedAt: Double
        /// When it joined by the server's clock (unix ms): an earlier membership's tickets count for nothing.
        var since: Double
        var synced: Bool
        var version: Int
        var devices: [(id: String, at: Int)]
        var disabled: Int?

        static func == (a: Record, b: Record) -> Bool {
            a.server == b.server && a.keys == b.keys && a.accountId == b.accountId && a.accountName == b.accountName
                && a.linkId == b.linkId && a.joinedAt == b.joinedAt && a.since == b.since && a.synced == b.synced
                && a.version == b.version && a.disabled == b.disabled
                && a.devices.map(\.id) == b.devices.map(\.id) && a.devices.map(\.at) == b.devices.map(\.at)
        }
    }

    static let ticketTTL = 120
    static let skew = 30
    static let sessionMax = 90 * 86_400
    static let accountIdPattern = "^a_[A-Za-z0-9_-]{10,40}$"

    public let path: String
    public let wire: Wire
    private let linkKeyPath: String
    private let selfInfo: () -> SelfInfo?
    private let session: URLSession
    private let now: () -> Date
    private let lock = NSLock()
    private var rec: Record?
    /// The file is there but is no record: in an account it cannot read (`leave` clears it).
    private var broken = false
    private var seen: [String: Int] = [:]
    private var sentSelf: Data?
    private var keysFetchedAt = Date.distantPast
    private var syncAt: Date?
    private var syncError: String?
    private var loop: Task<Void, Never>?
    private var kicked = false
    /// Waits on the revocation list at most this long (s), and the retry backoff (tests set them lower).
    var waitS = 25
    var retryMin: TimeInterval = 5
    var retryMax: TimeInterval = 300
    /// Called (on any thread) when what counts changed: a new revocation list, out of the account, joined.
    public var onChange: (() -> Void)?

    /// `path`: the membership file; `linkKeyPath`: the link key (`link-key`); `selfInfo`: what this Mac says of itself
    /// (nil while it cannot say: no link yet).
    public init(path: String, linkKeyPath: String, namespace: String = "yoyo", session: URLSession = .shared,
                now: @escaping () -> Date = Date.init, selfInfo: @escaping () -> SelfInfo?) {
        self.path = path
        self.linkKeyPath = linkKeyPath
        wire = Wire(namespace)
        self.session = session
        self.now = now
        self.selfInfo = selfInfo
        load()
    }

    // MARK: Reading

    /// In an account (or one whose file cannot be read): the link must listen for its devices.
    public var joined: Bool {
        lock.lock(); defer { lock.unlock() }
        return rec != nil || broken
    }

    var record: Record? {
        lock.lock(); defer { lock.unlock() }
        return rec
    }

    /// `GET /account`, `GET /remote`'s `account`: `{ account: { id, name, server, joinedAt, disabled } | null, error? }`.
    public var json: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        var j: [String: Any] = ["account": NSNull()]
        if let r = rec {
            j["account"] = ["id": r.accountId, "name": r.accountName ?? NSNull(), "server": r.server, "joinedAt": r.joinedAt,
                            "disabled": r.disabled != nil] as [String: Any]
        }
        if let syncError { j["error"] = syncError }
        return j
    }

    /// Whether a token made for a ticket still counts: the same account and this membership of it, the device's
    /// sign-in not over (`sx`), the device not revoked since the ticket, the account not disabled.
    public func ticketValid(_ g: AccountGrant) -> Bool {
        guard Double(g.sx) > now().timeIntervalSince1970 else { return false }
        lock.lock(); defer { lock.unlock() }
        guard let r = rec, r.accountId == g.acc, Double(g.tat + 1) * 1000 > r.since else { return false }
        return !Self.revoked(r, device: g.dev, iat: g.tat)
    }

    static func revoked(_ r: Record, device: String, iat: Int) -> Bool {
        r.disabled != nil || r.devices.contains { $0.id == device && iat <= $0.at }
    }

    // MARK: The link key

    private var cachedKey: Curve25519.Signing.PrivateKey?

    /// The link key and its Link id (hex), read once; nil without a 32-byte key file.
    func linkKey() -> (key: Curve25519.Signing.PrivateKey, id: String)? {
        lock.lock(); defer { lock.unlock() }
        if cachedKey == nil, let seed = FileManager.default.contents(atPath: linkKeyPath), seed.count == 32 {
            cachedKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        }
        guard let k = cachedKey else { return nil }
        return (k, k.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined())
    }

    func sign(_ id: String, _ text: String) -> String? {
        guard let (key, own) = linkKey(), own == id, let sig = try? key.signature(for: Data(text.utf8)) else { return nil }
        return Self.b64url(sig)
    }

    // MARK: Joining and leaving

    /// With a join key (the account's phone made it, or the server's admin): no approval, no confirmation.
    public func joinWithKey(server raw: String, key: String) async throws {
        guard let server = Self.origin(raw) else { throw Failure.join(400, "the account server is an https address (https://account.example.com)") }
        guard !joined else { throw Failure.join(409, "this Mac is in an account already: leave it first") }
        guard key.hasPrefix(wire.joinKeyPrefix), key.utf8.count == wire.joinKeyPrefix.utf8.count + 43,
              key.dropFirst(wire.joinKeyPrefix.count).allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            throw Failure.join(400, "that is not a join key")
        }
        guard let me = selfInfo() else { throw Failure.join(409, "this Mac has no Link entry yet: it cannot join an account") }
        guard let proof = sign(me.linkId, wire.joinKeyProofText(server, me.linkId, key)) else {
            throw Failure.join(409, "this Mac's link key cannot sign")
        }
        var body = Self.selfBody(me)
        body["key"] = key
        body["linkId"] = me.linkId
        body["proof"] = proof
        let (status, answer) = try await post(server + "/v1/computers/join", body)
        guard status == 200 else {
            throw Failure.join(status == 429 ? 429 : 403, "the account server refused the key (\(answer["error"] as? String ?? "\(status)"))")
        }
        let account = answer["account"] as? [String: Any]
        let srv = answer["server"] as? [String: Any]
        let keys = (srv?["keys"] as? [Any] ?? []).compactMap { cleanKey($0) }
        guard let id = account?["id"] as? String, id.range(of: Self.accountIdPattern, options: .regularExpression) != nil,
              srv?["url"] as? String == server, !keys.isEmpty else {
            throw Failure.join(502, "the account server's answer is not a membership")
        }
        let at = (answer["computer"] as? [String: Any])?["joinedAt"] as? Double
        let t = now().timeIntervalSince1970 * 1000
        let since = at.flatMap { abs($0 - t) < 86_400_000 ? $0 : nil } ?? t
        let r = Record(server: server, keys: keys, accountId: id, accountName: (account?["name"] as? String).map { String($0.prefix(64)) },
                       linkId: me.linkId, joinedAt: t, since: since, synced: false, version: 0, devices: [], disabled: nil)
        let taken: Bool = lock.withLock {
            guard rec == nil, !broken else { return false }
            rec = r
            sentSelf = Self.serialized(Self.selfBody(me))
            saveLocked()
            kicked = true
            return true
        }
        guard taken else { throw Failure.join(409, "this Mac is in an account already: leave it first") }
        log("account: this Mac joined account \(id.prefix(10))…\(r.accountName.map { " (\($0))" } ?? "") at \(server)")
        onChange?()
    }

    /// Out of the account (from this Mac): every token made for a ticket is void at once; the server is told when it
    /// can be reached. false when it was in none.
    @discardableResult
    public func leave() async -> Bool {
        let (r, was): (Record?, Bool) = lock.withLock {
            let r = rec
            let was = r != nil || broken
            rec = nil
            broken = false
            try? FileManager.default.removeItem(atPath: path)
            return (r, was)
        }
        guard was else { return false }
        onChange?()
        if let r {
            log("account: this Mac left account \(r.accountId.prefix(10))…")
            _ = try? await signed(r, "POST", "/v1/computer/leave", body: [:])
        }
        return true
    }

    // MARK: Tickets

    /// A ticket taken (once): its claims, or `Failure.ticket`.
    public func redeem(_ jwt: String) async throws -> TicketClaims {
        guard let r = record, let me = linkKey(), me.id == r.linkId else { throw Failure.ticket("not_owner") }
        if let kid = Self.kid(jwt), !r.keys.contains(where: { $0.kid == kid }) { try? await refreshKeys(r, offered: nil) }
        // nothing comes in before the account's revocation list has been seen once
        if let cur = record, !cur.synced { try? await pull(cur, wait: 0) }
        guard let cur = record, cur.accountId == r.accountId else { throw Failure.ticket("not_owner") }
        guard cur.synced else { throw Failure.ticket("busy") }
        let p = try verify(jwt, typ: wire.ticketTyp, keys: cur.keys, issuer: cur.server)
        let audience = p["aud"] as? String ?? (p["aud"] as? [String])?.first
        guard audience == cur.linkId else { throw Failure.ticket("wrong_computer") }
        let dev = p["dev"] as? [String: Any]
        guard let exp = p["exp"] as? Int, let iat = p["iat"] as? Int, let jti = p["jti"] as? String, !jti.isEmpty,
              let devId = dev?["id"] as? String, !devId.isEmpty, let devName = dev?["name"] as? String else {
            throw Failure.ticket("malformed")
        }
        let t = Int(now().timeIntervalSince1970)
        guard exp - iat <= Self.ticketTTL, iat <= t + Self.skew else { throw Failure.ticket("malformed") }
        var sx = iat + Self.sessionMax
        if let s = p["sx"] {
            guard let s = s as? Int else { throw Failure.ticket("malformed") }
            guard s > t else { throw Failure.ticket("expired") }
            sx = s
        }
        guard p["sub"] as? String == cur.accountId else { throw Failure.ticket("not_owner") }
        guard !Self.revoked(cur, device: devId, iat: iat) else { throw Failure.ticket("revoked") }
        guard Double(iat + 1) * 1000 > cur.since else { throw Failure.ticket("expired") }
        let fresh: String? = lock.withLock {
            if seen[jti] != nil { return "replayed" }
            if seen.count >= 20_000 { seen = seen.filter { $0.value + Self.skew > t } }
            guard seen.count < 20_000 else { return "busy" }
            seen[jti] = exp
            return nil
        }
        if let fresh { throw Failure.ticket(fresh) }
        return TicketClaims(account: cur.accountId, deviceId: devId, deviceName: devName, iat: iat, sx: sx)
    }

    /// A compact JWS with EdDSA by one of `keys`, of `typ`, by `issuer`, not run out: its payload.
    func verify(_ jwt: String, typ: String, keys: [Key], issuer: String) throws -> [String: Any] {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let h = Self.json(parts[0]), let p = Self.json(parts[1]), let sig = Self.unb64url(parts[2]) else {
            throw Failure.ticket("malformed")
        }
        guard h["typ"] as? String == typ else { throw Failure.ticket("malformed") }
        guard h["alg"] as? String == "EdDSA", let kid = h["kid"] as? String, let k = keys.first(where: { $0.kid == kid }),
              let raw = Self.unb64url(k.x), let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
            throw Failure.ticket("unknown_key")
        }
        guard pub.isValidSignature(sig, for: Data("\(parts[0]).\(parts[1])".utf8)) else { throw Failure.ticket("bad_signature") }
        guard p["iss"] is String, p["sub"] is String, p["iat"] is Int else { throw Failure.ticket("malformed") }
        if let exp = p["exp"] {
            guard let exp = exp as? Int else { throw Failure.ticket("malformed") }
            guard Int(now().timeIntervalSince1970) - Self.skew < exp else { throw Failure.ticket("expired") }
        }
        guard p["iss"] as? String == issuer else { throw Failure.ticket("wrong_issuer") }
        return p
    }

    // MARK: Keeping in step with the server

    public func start() {
        lock.lock()
        guard loop == nil else { lock.unlock(); return }
        loop = Task.detached { [weak self] in await self?.run() }
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let l = loop
        loop = nil
        lock.unlock()
        l?.cancel()
    }

    private func run() async {
        var delay: TimeInterval = 0
        var said = ""
        while !Task.isCancelled {
            guard let r = record else {
                await sleep(60)
                continue
            }
            do {
                var aside: String?
                do { try await tellSelf(r) } catch { aside = "\(error)" }
                if let cur = record { try await pull(cur, wait: waitS) }
                setSync(aside)
                if let aside, aside != said { log("account: the account server: \(aside) (told again later; revocations still come)") }
                said = aside ?? ""
                delay = 0
            } catch {
                if Task.isCancelled { break }
                guard record?.accountId == r.accountId else { continue }
                let msg = "\(error)"
                setSync(msg)
                if msg != said { log("account: the account server: \(msg) (retrying; what is signed in here goes on)") }
                said = msg
                delay = min(retryMax, max(retryMin, delay * 2))
            }
            await sleep(delay == 0 ? 1 : delay)
        }
    }

    private func setSync(_ error: String?) {
        lock.lock()
        syncAt = now()
        syncError = error
        lock.unlock()
    }

    /// Sleeps `seconds`, or until something wants the loop sooner (joined).
    private func sleep(_ seconds: TimeInterval) async {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end, !Task.isCancelled {
            let k: Bool = lock.withLock {
                defer { kicked = false }
                return kicked
            }
            if k { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func tellSelf(_ r: Record) async throws {
        guard let me = selfInfo(), me.linkId == r.linkId else { return }
        let body = Self.selfBody(me)
        let data = Self.serialized(body)
        if lock.withLock({ sentSelf == data }) { return }
        let (status, _) = try await signed(r, "POST", "/v1/computer/update", body: body)
        guard status == 200 || status == 404 else { throw Failure.join(status, "update refused (\(status))") }
        lock.withLock { sentSelf = data }
    }

    /// The account's signed revocation list, asked for and (with `wait`) waited on.
    func pull(_ r: Record, wait: Int) async throws {
        let (status, b) = try await signed(r, "GET", "/v1/computer/revocations?account=\(r.accountId)&after=\(r.version)&wait=\(wait)",
                                           timeout: TimeInterval(wait + 20))
        if status == 404 { throw Failure.join(404, "it does not list this Mac (kept as it is: only a signed list takes a computer out)") }
        guard status == 200 else {
            throw Failure.join(status, "revocation list refused (\(status)\(status == 401 ? ": is this Mac's clock right?" : ""))")
        }
        guard let list = b["list"] as? String else { throw Failure.join(502, "no revocation list in the answer") }
        if let kid = Self.kid(list), !r.keys.contains(where: { $0.kid == kid }) { try await refreshKeys(r, offered: b["keys"]) }
        guard let keyed = record, keyed.accountId == r.accountId, keyed.server == r.server else { return }
        let p = try verify(list, typ: wire.revocationsTyp, keys: keyed.keys, issuer: keyed.server)
        guard p["sub"] as? String == keyed.accountId else { throw Failure.ticket("not_owner") }
        guard let ver = p["ver"] as? Int, let devices = Self.entries(p["devices"]), let computers = Self.entries(p["computers"]) else {
            throw Failure.ticket("malformed")
        }
        let disabled: Int?
        if p["disabled"] == nil || p["disabled"] is NSNull { disabled = nil } else if let d = p["disabled"] as? Int { disabled = d } else { throw Failure.ticket("malformed") }
        guard ver >= keyed.version else {
            throw Failure.join(409, "its revocation list is older than the one held here (was its data restored from a backup?): revocations made since are NOT known here")
        }
        enum Outcome { case stale, out, same, next }
        let outcome: Outcome = lock.withLock {
            guard rec == keyed else { return .stale }
            if computers.contains(where: { $0.id == keyed.linkId }) {
                rec = nil
                try? FileManager.default.removeItem(atPath: path)
                return .out
            }
            if keyed.synced && ver == keyed.version { return .same }
            var next = keyed
            next.synced = true
            next.version = ver
            next.devices = devices
            next.disabled = disabled
            rec = next
            saveLocked()
            return .next
        }
        switch outcome {
        case .stale, .same: return
        case .out:
            log("account: account \(keyed.accountId.prefix(10))… took this Mac out (its signed list says so): it is in no account now")
            onChange?()
            return
        case .next: break
        }
        log("account: revocation list #\(ver): \(devices.count) device(s)\(disabled != nil ? ", the account is disabled" : "")")
        onChange?()
    }

    /// The server's keys (a minute apart at most unless offered): a new one is kept only through the chain of
    /// endorsements from one already pinned.
    private func refreshKeys(_ r: Record, offered: Any?) async throws {
        var list = offered as? [Any]
        if list == nil {
            let t = now()
            let recent: Bool = lock.withLock {
                let recent = t.timeIntervalSince(keysFetchedAt) < 60
                if !recent { keysFetchedAt = t }
                return recent
            }
            if recent { return }
            var req = URLRequest(url: URL(string: r.server + "/.well-known/jwks.json")!)
            req.timeoutInterval = 10
            let (data, res) = try await session.data(for: req)
            guard (res as? HTTPURLResponse)?.statusCode == 200 else { return }
            list = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["keys"] as? [Any]
        }
        guard let list, list.count <= 32 else { return }
        let offeredKeys = list.compactMap { cleanKey($0) }
        var trusted = r.keys
        var grew = true
        while grew {
            grew = false
            for k in offeredKeys where !trusted.contains(where: { $0.kid == k.kid }) {
                guard let e = k.endorsement, endorsed(e, key: k, by: trusted) else { continue }
                trusted.append(k)
                grew = true
            }
        }
        guard trusted.count > r.keys.count else { return }
        lock.withLock {
            if rec == r {
                rec?.keys = trusted
                saveLocked()
            }
        }
        log("account: the account server has \(trusted.count - r.keys.count) new signing key(s), endorsed by one pinned here")
    }

    /// `e` is a compact JWS (typ endorsement) by a trusted key over `{ kid, x, iat }` of `key`.
    private func endorsed(_ e: String, key: Key, by trusted: [Key]) -> Bool {
        let parts = e.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let h = Self.json(parts[0]), let p = Self.json(parts[1]), let sig = Self.unb64url(parts[2]),
              h["alg"] as? String == "EdDSA", h["typ"] as? String == wire.endorsementTyp,
              let signer = trusted.first(where: { $0.kid == h["kid"] as? String }), let raw = Self.unb64url(signer.x),
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
              pub.isValidSignature(sig, for: Data("\(parts[0]).\(parts[1])".utf8)) else { return false }
        return p["kid"] as? String == key.kid && p["x"] as? String == key.x
    }

    // MARK: HTTP

    private func post(_ url: String, _ body: [String: Any]) async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.serialized(body)
        do {
            let (data, res) = try await session.data(for: req)
            return ((res as? HTTPURLResponse)?.statusCode ?? 0, ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:])
        } catch {
            throw Failure.join(502, "the account server is not answering (\(error.localizedDescription))")
        }
    }

    /// A request of this Mac's own, signed with its link key.
    private func signed(_ r: Record, _ method: String, _ pathQ: String, body: [String: Any]? = nil, timeout: TimeInterval = 15) async throws -> (Int, [String: Any]) {
        let raw = body.map(Self.serialized) ?? Data()
        let ts = Int(now().timeIntervalSince1970)
        guard let sig = sign(r.linkId, wire.computerProofText(r.server, method, pathQ, ts, Self.sha256b64url(raw))) else {
            throw Failure.join(409, "the link key cannot sign as the id this Mac joined with")
        }
        var req = URLRequest(url: URL(string: r.server + pathQ)!)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("\(wire.linkScheme) \(r.linkId).\(ts).\(sig)", forHTTPHeaderField: "Authorization")
        if body != nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = raw
        }
        let (data, res) = try await session.data(for: req)
        return ((res as? HTTPURLResponse)?.statusCode ?? 0, ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:])
    }

    // MARK: The file (the same as @yoyocontrol/account's)

    private func load() {
        guard let data = FileManager.default.contents(atPath: path) else {
            broken = FileManager.default.fileExists(atPath: path)
            return
        }
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], j["v"] as? Int == 1,
              let server = (j["server"] as? String).flatMap(Self.origin), server == j["server"] as? String,
              let account = j["account"] as? [String: Any], let id = account["id"] as? String,
              id.range(of: Self.accountIdPattern, options: .regularExpression) != nil,
              let linkId = j["linkId"] as? String, linkId.utf8.count == 64 else {
            broken = true
            log("account: \(path) is not a membership record (leaving the account clears it)")
            return
        }
        let keys = (j["keys"] as? [Any] ?? []).compactMap { cleanKey($0) }
        guard !keys.isEmpty else { broken = true; return }
        let rv = j["revocations"] as? [String: Any]
        let joinedAt = j["joinedAt"] as? Double ?? 0
        rec = Record(server: server, keys: keys, accountId: id, accountName: account["name"] as? String, linkId: linkId,
                     joinedAt: joinedAt, since: j["since"] as? Double ?? joinedAt, synced: j["synced"] as? Bool == true,
                     version: rv?["version"] as? Int ?? 0, devices: Self.entries(rv?["devices"]) ?? [], disabled: rv?["disabled"] as? Int)
    }

    private func saveLocked() {
        guard let r = rec else { return }
        let body: [String: Any] = [
            "v": 1, "server": r.server,
            "keys": r.keys.map { k -> [String: Any] in
                var j: [String: Any] = ["kty": "OKP", "crv": "Ed25519", "x": k.x, "kid": k.kid, "alg": "EdDSA", "use": "sig"]
                if let e = k.endorsement { j[wire.endorsementField] = e }
                return j
            },
            "account": ["id": r.accountId, "name": r.accountName ?? NSNull()] as [String: Any],
            "linkId": r.linkId, "joinedAt": r.joinedAt, "since": r.since, "synced": r.synced,
            "revocations": ["version": r.version, "devices": r.devices.map { ["id": $0.id, "at": $0.at] as [String: Any] },
                            "disabled": r.disabled ?? NSNull()] as [String: Any],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) else { return }
        do {
            try RemoteIdentity.writePrivate(data, to: path)
        } catch {
            log("account: cannot write \(path): \(error)")
        }
    }

    private func cleanKey(_ any: Any) -> Key? {
        guard let j = any as? [String: Any], j["kty"] as? String == "OKP", j["crv"] as? String == "Ed25519",
              let x = j["x"] as? String, Self.unb64url(x)?.count == 32, let kid = j["kid"] as? String, kid.count <= 64 else { return nil }
        let e = (j[wire.endorsementField] as? String).flatMap { $0.count <= 1024 ? $0 : nil }
        return Key(kid: kid, x: x, endorsement: e)
    }

    // MARK: Helpers

    /// What this Mac says of itself (`/v1/computers/join`, `/v1/computer/update`).
    static func selfBody(_ s: SelfInfo) -> [String: Any] {
        ["name": s.name, "fingerprint": NSNull(), "relays": Array(s.relays.prefix(4)), "direct": Array(s.direct.filter { $0.count <= 64 }.prefix(16)),
         "origins": [String](), "signal": NSNull(), "info": s.info]
    }

    static func serialized(_ body: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    static func entries(_ any: Any?) -> [(id: String, at: Int)]? {
        guard let list = any as? [Any], list.count <= 10_000 else { return nil }
        var out: [(id: String, at: Int)] = []
        for e in list {
            guard let d = e as? [String: Any], let id = d["id"] as? String, id.count <= 128, let at = d["at"] as? Int else { return nil }
            out.append((id, at))
        }
        return out
    }

    /// An account server's address as kept and compared: an https origin (http only on loopback).
    static func origin(_ raw: String) -> String? {
        guard raw.count <= 256, let u = URLComponents(string: raw.trimmingCharacters(in: .whitespaces)), let host = u.host, !host.isEmpty,
              u.user == nil, u.password == nil, u.query == nil, u.fragment == nil, u.path.isEmpty || u.path == "/" else { return nil }
        let local = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard u.scheme == "https" || (u.scheme == "http" && local) else { return nil }
        let h = host.contains(":") ? "[\(host)]" : host.lowercased()
        let defaultPort = u.scheme == "https" ? 443 : 80
        return "\(u.scheme!)://\(h)\(u.port.map { $0 == defaultPort ? "" : ":\($0)" } ?? "")"
    }

    static func kid(_ jwt: String) -> String? {
        jwt.split(separator: ".").first.flatMap { json(String($0)) }?["kid"] as? String
    }

    static func json(_ part: String) -> [String: Any]? {
        unb64url(part).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    static func b64url<D: DataProtocol>(_ d: D) -> String {
        Data(d).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func unb64url(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    static func sha256b64url(_ d: Data) -> String { b64url(Data(SHA256.hash(data: d))) }
}
#endif
