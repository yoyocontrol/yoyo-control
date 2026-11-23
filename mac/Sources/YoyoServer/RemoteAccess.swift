#if os(macOS)
import CryptoKit
import Darwin
import Foundation

/// Remote access (docs/REMOTE.md): paired phones and browsers reach this Mac over uu Link (LinkServer, docs/LINK.md),
/// in the same process as the unix socket and with the same routes (an allowlist of them). Run by the menu bar app's
/// service (`yoyo-control --socket … --remote`), never by a service another program spawns.
///
/// - State in the Yoyo Control home (0700), this process the only writer: `remote.json` (server id, on/off, direct),
///   `devices.json` (RemoteDevices), `account.json` (AccountMembership), `tls-key.der` (RemoteIdentity), `link-key`
///   (LinkServer).
/// - The link listener runs while remote access is on and a phone is paired, a pairing code is shown or the Mac is in an
///   account (and for a while after the last device went: `lingerAfterLastDevice`). Phones pair over it too
///   (`hello.credential = "Pair <code>"`), and the account's devices come in by ticket (`Ticket <ticket>`).
/// - While it runs, the Mac is registered at the signaling server (RemoteSignal): browsers' offers come through it, and
///   phones and browsers ask it for the link binding.
/// - While it runs and direct access from the internet is on (`remote.json` `direct`, on by default), the home router
///   is asked to forward a public UDP port to it (LinkServer's PortMapper): the address goes into the binding.
/// - Removing a device ends its sessions at once; turning remote access off ends all.
public final class RemoteAccess: @unchecked Sendable {
    /// `POST /clipboard`'s 1 MiB of text, as JSON: the most a request body may be over the link.
    static let clipboardBodyMax = 4 * 1024 * 1024
    /// After the last device is removed the listener stays this long, so a removed phone still reconnecting hears
    /// `unauthorized` (and forgets this Mac) instead of nothing.
    static let lingerAfterLastDevice: TimeInterval = 120

    /// The routes a paired phone may use (method, path); everything else is a 404 for it.
    static let allowed: Set<String> = [
        "GET /status", "GET /frame", "GET /stream", "POST /stream/ack", "GET /events", "GET /focus", "GET /audio",
        "POST /input", "POST /control", "GET /clipboard", "POST /clipboard", "GET /clipboard/image", "GET /clipboard/file",
        "GET /account", "POST /account/join", "POST /account/leave",
    ]

    /// The one running in this process (the Router's `/remote*` routes and `/control`).
    nonisolated(unsafe) public static var current: RemoteAccess?

    public let home: String
    public let devices: RemoteDevices
    let control: RemoteControl
    private let lock = NSLock()
    private var settings: RemoteSettings
    private var identity: RemoteIdentity?
    private var identityError: String?
    private var running = false
    private let queue = DispatchQueue(label: "yoyo-control.remote")
    /// The listener stays up until then though nothing else needs it (`lingerAfterLastDevice`).
    private var lingerUntil = Date.distantPast
    private var signal: RemoteSignal?
    /// How many devices were paired at the last change (a removal of the last one starts the lingering).
    private var deviceCount = 0
    /// Called (on any thread) when anything `GET /remote` shows changed.
    public var onChange: (() -> Void)?
    /// `YOYO_PORTMAP=off` (tests, a Mac that must not touch the router): no port mapping.
    var mapsPorts = ProcessInfo.processInfo.environment["YOYO_PORTMAP"] != "off"
    /// Tests: where the Mac registers (nil: no signaling server).
    var signalURL: URL? = RemoteSignal.baseURL
    /// The link listener's options (set before `start`); nil: no remote access. Authority mode runs outside remote
    /// access (ScreenService).
    public var linkOptions: LinkOptions?
    /// The account this Mac is in (docs/ACCOUNT.md), made at `start`.
    public private(set) var membership: AccountMembership?
    /// The account server's wire namespace (the product's; the library's default "yoyo").
    public var accountNamespace = "yoyo"
    #if canImport(YoyoLink)
    private var link: LinkServer?
    #endif

    public init(home: String, control: RemoteControl = .shared) {
        self.home = home
        self.control = control
        devices = RemoteDevices(path: home + "/devices.json")
        settings = RemoteSettings.load(home + "/remote.json")
        deviceCount = devices.list.count
        devices.onChange = { [weak self] in self?.devicesChanged() }
    }

    // MARK: Lifecycle

    /// Loads (or makes) the identity and starts the listener if it should. Errors are logged: the unix socket goes on.
    public func start() {
        lock.lock()
        running = true
        do {
            identity = try RemoteIdentity.loadOrCreate(directory: home)
            identityError = nil
        } catch {
            identityError = "\(error)"
            log("remote: off: no identity (\(error))")
        }
        lock.unlock()
        settings.save(home + "/remote.json")
        startMembership()
        Self.current = self
        update()
    }

    /// The account membership (once), its list followed: what no longer counts is forgotten, the listener follows.
    private func startMembership() {
        guard membership == nil else { return }
        let m = AccountMembership(path: home + "/account.json", linkKeyPath: (linkOptions?.keyDirectory ?? home) + "/link-key",
                                  namespace: accountNamespace) { [weak self] in self?.accountSelf() }
        m.onChange = { [weak self] in self?.accountChanged() }
        membership = m
        m.start()
        // (a sign-in that ran out is no revocation: its tokens go on the hour)
        queue.asyncAfter(deadline: .now() + 3600) { [weak self] in self?.sweepAccountDevices() }
    }

    private func sweepAccountDevices() {
        accountChanged()
        queue.asyncAfter(deadline: .now() + 3600) { [weak self] in self?.sweepAccountDevices() }
    }

    private func accountChanged() {
        guard let m = membership else { return }
        let gone = devices.prune { m.ticketValid($0) }
        if gone > 0 { log("remote: \(gone) device(s) of the account no longer let in") }
        update()
        onChange?()
    }

    /// What this Mac tells its account server about itself: its link, and for the app (`info`) its server id, platform,
    /// identity fingerprint and link binding (what a phone that never paired here needs to dial it).
    private func accountSelf() -> AccountMembership.SelfInfo? {
        guard let (_, linkId) = membership?.linkKey() else { return nil }
        lock.lock()
        #if canImport(YoyoLink)
        let l = link?.statusJSON
        #else
        let l: [String: Any]? = nil
        #endif
        let fp = identity?.fingerprint
        let serverId = settings.serverId
        lock.unlock()
        var info: [String: Any] = ["id": serverId, "platform": "mac"]
        if let fp { info["fp"] = fp }
        if let l, let id = l["id"] as? String, let key = l["key"] as? String, let sig = l["sig"] as? String {
            var b: [String: Any] = ["id": id, "key": key, "sig": sig]
            if let port = l["port"] as? Int { b["port"] = port }
            info["link"] = b
        }
        return .init(linkId: linkId, name: Self.macName, relays: l?["relays"] as? [String] ?? linkOptions?.relays.map { $0.components(separatedBy: "?")[0] } ?? [],
                     direct: (l?["direct"] as? [Any] ?? []).compactMap { $0 as? String }, info: info)
    }

    public func stop() {
        lock.lock()
        running = false
        lock.unlock()
        update()
        if Self.current === self { Self.current = nil }
    }

    /// Starts or stops the link listener and the signaling registration to match: on, with a paired phone or a pairing
    /// code (or for a while after the last phone went), `linkOptions` set (default mode).
    private func update() {
        #if canImport(YoyoLink)
        lock.lock()
        let want = running && settings.enabled && identity != nil && needsListenerLocked() && linkOptions.map { !$0.authority } == true
        var stale: (LinkServer, RemoteSignal?)?
        var fresh: (LinkServer, RemoteSignal?)?
        if !want, let l = link {
            stale = (l, signal)
            link = nil
            signal = nil
        }
        if want, link == nil, let id = identity, var options = linkOptions {
            options.portMapping = (options.portMapping ?? mapsPorts) && settings.direct
            let l = LinkServer(options: options, mode: .devices(devices),
                               identity: .init(serverId: settings.serverId, name: Self.macName, key: id.signingKey),
                               keyDirectory: options.keyDirectory ?? home, control: control)
            l.onChange = { [weak self] in self?.linkChanged() }
            l.membership = membership
            let s = signalURL.map { RemoteSignal(key: id.signingKey, base: $0) }
            s?.onChange = { [weak self] in self?.onChange?() }
            link = l
            signal = s
            fresh = (l, s)
        }
        lock.unlock()
        if let (l, s) = stale {
            s?.stop()
            l.stop()
            log("remote: listener stopped")
        }
        if let (l, s) = fresh {
            l.start()
            s?.start()
        }
        if stale != nil || fresh != nil { onChange?() }
        #else
        if running, settings.enabled { log("remote: off: this build has no YoyoLink (scripts/link-apple.sh build)") }
        #endif
    }

    /// The link listener's binding, addresses or sessions changed: the signaling server hears of it.
    private func linkChanged() {
        #if canImport(YoyoLink)
        lock.lock()
        let s = signal
        let j = link?.signalJSON
        lock.unlock()
        s?.link = j
        #endif
        onChange?()
    }

    /// `GET /remote`'s `link`: the link listener's `/status` `link` and its UDP mapping (`mapping`), null while it
    /// doesn't run.
    private func linkJSONLocked() -> Any {
        #if canImport(YoyoLink)
        guard let l = link, var j = l.statusJSON else { return NSNull() }
        j["mapping"] = l.mappingJSON
        return j
        #else
        return NSNull()
        #endif
    }

    private func needsListenerLocked() -> Bool {
        !devices.isEmpty || devices.pairingCode != nil || membership?.joined == true || Date() < lingerUntil
    }

    private func devicesChanged() {
        let ids = Set(devices.list.map(\.id))
        lock.lock()
        let removedLast = ids.isEmpty && deviceCount > 0
        deviceCount = ids.count
        #if canImport(YoyoLink)
        let l = link
        let up = l != nil
        #else
        let up = false
        #endif
        if removedLast && up {
            lingerUntil = Date().addingTimeInterval(Self.lingerAfterLastDevice)
            queue.asyncAfter(deadline: .now() + Self.lingerAfterLastDevice + 0.5) { [weak self] in self?.update() }
        }
        lock.unlock()
        #if canImport(YoyoLink)
        l?.devicesChanged(paired: ids)
        #endif
        if let h = control.holder, !ids.contains(h.id) { control.deviceRemoved(h.id) }
        update()
        onChange?()
    }

    // MARK: Management (the unix socket's `/remote*` routes)

    /// `GET /remote`.
    var json: [String: Any] {
        lock.lock()
        let s = settings
        let fp = identity?.fingerprint
        let error = identityError
        let signalUp = signal?.isRegistered ?? false
        #if canImport(YoyoLink)
        let listening = link?.statusJSON != nil
        let active = link?.connectedDevices ?? []
        let mapping = link?.mappingJSON
        #else
        let listening = false
        let active: Set<String> = []
        let mapping: [String: Any]? = nil
        #endif
        let linkJSON = linkJSONLocked()
        lock.unlock()
        var direct = mapping ?? ["status": "off"]
        if !s.direct { direct = ["status": "off"] }
        direct["enabled"] = s.direct
        var j: [String: Any] = [
            "enabled": s.enabled,
            "listening": listening,
            "serverId": s.serverId,
            "name": Self.macName,
            "addresses": Self.addresses(),
            "devices": devices.list.map { d -> [String: Any] in
                var dj = d.json
                dj["connected"] = active.contains(d.id)
                return dj
            },
            "control": control.json,
            "signal": ["connected": signalUp],
            "direct": direct,
            "link": linkJSON,
            "account": membership?.json ?? ["account": NSNull()],
        ]
        if let fp { j["fingerprint"] = fp }
        if let error { j["error"] = error }
        if let code = devices.pairingCode {
            var p: [String: Any] = ["code": code.code, "expiresAt": code.expiresAt.timeIntervalSince1970 * 1000]
            if let url = pairingURL(code) { p["url"] = url }
            if let web = webPairingURL(code) { p["webUrl"] = web }
            j["pairing"] = p
        } else {
            j["pairing"] = NSNull()
        }
        return j
    }

    /// The QR code's content: `yoyocontrol://pair?v=2&id=&n=&fp=&l=&lk=&ls=[&lp=][&a=]&c=` (docs/REMOTE.md「配对」): the
    /// uu Link binding (`l` hex id, `lk` / `ls` base64url identity key and signature, `lp` UDP port) and the Mac's
    /// local addresses; nil until the link listener is up.
    func pairingURL(_ code: PairingCode) -> String? {
        lock.lock()
        #if canImport(YoyoLink)
        let link = self.link?.statusJSON
        #else
        let link: [String: Any]? = nil
        #endif
        let s = settings
        let fp = identity?.fingerprint ?? ""
        lock.unlock()
        guard let l = link, let id = l["id"] as? String, let key = l["key"] as? String, let sig = l["sig"] as? String else { return nil }
        var c = URLComponents()
        c.scheme = "yoyocontrol"
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "v", value: "2"),
            URLQueryItem(name: "id", value: s.serverId),
            URLQueryItem(name: "n", value: Self.macName),
            URLQueryItem(name: "fp", value: fp),
            URLQueryItem(name: "l", value: id),
            URLQueryItem(name: "lk", value: Self.base64url(key)),
            URLQueryItem(name: "ls", value: Self.base64url(sig)),
        ]
        if let p = l["port"] as? Int { c.queryItems?.append(URLQueryItem(name: "lp", value: "\(p)")) }
        let addresses = Self.addresses()
        if !addresses.isEmpty { c.queryItems?.append(URLQueryItem(name: "a", value: addresses.joined(separator: ","))) }
        c.queryItems?.append(URLQueryItem(name: "c", value: code.code))
        return c.string
    }

    /// base64 → base64url without padding (shorter in a QR code, nothing to escape).
    static func base64url(_ b64: String) -> String {
        b64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// The web app's address (`YOYO_WEBAPP_URL`); none is built in: unset = no browser pairing link.
    static var webAppURL: String? {
        let env = (ProcessInfo.processInfo.environment["YOYO_WEBAPP_URL"] ?? "").trimmingCharacters(in: .whitespaces)
        if env.isEmpty || env == "off" { return nil }
        return env.hasSuffix("/") ? env : env + "/"
    }

    /// The browser's pairing link (docs/REMOTE.md「配对」): `<web app>/pair#v=1&id=&n=&fp=&c=`, everything in the
    /// fragment (never sent to a server). Only while a browser can get in: the link listener takes WebRTC and the Mac is
    /// registered at a signaling server (where its offer goes).
    func webPairingURL(_ code: PairingCode) -> String? {
        lock.lock()
        let s = settings
        let fp = identity?.fingerprint
        let signals = signal != nil
        #if canImport(YoyoLink)
        let rtc = link?.statusJSON?["rtc"] != nil
        #else
        let rtc = false
        #endif
        lock.unlock()
        guard rtc, signals, let fp, let webApp = Self.webAppURL else { return nil }
        var c = URLComponents()
        c.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "id", value: s.serverId),
            URLQueryItem(name: "n", value: Self.macName),
            URLQueryItem(name: "fp", value: fp),
            URLQueryItem(name: "c", value: code.code),
        ]
        // the fragment is form-encoded like a query (`&` and `=` inside a value escaped)
        let fragment = (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        return webApp + "pair#" + fragment
    }

    func startPairing() -> [String: Any] {
        lock.lock()
        let enabled = settings.enabled
        lock.unlock()
        if !enabled { setEnabled(true) }
        devices.startPairing()
        Self.postPairing(open: true)
        return json
    }

    func stopPairing() {
        devices.stopPairing()
        Self.postPairing(open: false)
    }

    /// `{"type":"pairing","open":…}` on `/events` (docs/PROTOCOL.md): the pairing window opened / closed. It stays out of
    /// every capture (`sharingType = .none`), so a remote picture can say it's there. Never the code.
    static func postPairing(open: Bool) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": "pairing", "open": open], options: [.sortedKeys]) else { return }
        ScreenStateTracker.current?.post(data + Data("\n".utf8))
    }

    func setEnabled(_ on: Bool) {
        lock.lock()
        guard settings.enabled != on else { lock.unlock(); return }
        settings.enabled = on
        settings.save(home + "/remote.json")
        if !on { lingerUntil = .distantPast }
        lock.unlock()
        log("remote: access turned \(on ? "on" : "off")")
        if !on {
            devices.stopPairing()
            control.releaseAny(why: "remote access turned off")
        }
        update()
        onChange?()
    }

    /// Direct access from the internet on or off (`POST /remote/direct`): off deletes the router's mappings at once.
    func setDirect(_ on: Bool) {
        lock.lock()
        guard settings.direct != on else { lock.unlock(); return }
        settings.direct = on
        settings.save(home + "/remote.json")
        #if canImport(YoyoLink)
        let l = link
        let maps = linkOptions?.portMapping ?? mapsPorts
        #endif
        lock.unlock()
        log("remote: direct access from the internet turned \(on ? "on" : "off")")
        #if canImport(YoyoLink)
        l?.setPortMapping(on && maps)
        #endif
        onChange?()
    }

    // MARK: The account (docs/ACCOUNT.md)

    /// `POST /account/join { server, key }` (a phone paired here, signed in): this Mac joins that account by itself.
    func joinAccount(server: String, key: String) async throws {
        guard let m = membership else { throw HTTPError(503, "remote access is not running") }
        do {
            try await m.joinWithKey(server: server, key: key)
        } catch AccountMembership.Failure.join(let status, let why) {
            throw HTTPError(status, why)
        }
    }

    /// Leaves the account (the menu's, or a phone paired here): the account's devices are let in no more. Paired phones
    /// stay paired.
    func leaveAccount() async {
        _ = await membership?.leave()
    }

    // MARK: Helpers

    /// This Mac's name as people know it (System Settings → General → About).
    static var macName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    /// The Mac's IPv4 addresses a phone may reach: every interface's but loopback and link-local, in interface order.
    static func addresses() -> [String] {
        var out: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            if address.hasPrefix("169.254.") || address.hasPrefix("127.") || out.contains(address) { continue }
            out.append(address)
        }
        return out
    }
}

/// `remote.json`: who this server is (`serverId`, which the phone remembers), whether remote access is on (on by
/// default: nothing listens before a phone is paired or a code is shown), whether the router is asked for a public
/// port (`direct`, on by default). (An `account` there is from before the account library: not read, not written again.)
struct RemoteSettings: Equatable {
    var serverId: String
    var enabled: Bool
    var direct = true

    static func load(_ path: String) -> RemoteSettings {
        let json = FileManager.default.contents(atPath: path).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        let id = (json["serverId"] as? String).flatMap { $0.count >= 16 ? $0 : nil } ?? RemoteDevices.random(16)
        return RemoteSettings(serverId: id, enabled: json["enabled"] as? Bool ?? true, direct: json["direct"] as? Bool ?? true)
    }

    func save(_ path: String) {
        let body: [String: Any] = ["version": 2, "serverId": serverId, "enabled": enabled, "direct": direct]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? RemoteIdentity.writePrivate(data, to: path)
    }
}
#endif
