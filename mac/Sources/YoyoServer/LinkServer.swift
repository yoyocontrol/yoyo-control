#if os(macOS) && canImport(YoyoLink)
import CryptoKit
import Foundation
import Network
import YoyoLink

/// The link listener (docs/LINK.md, LinkOptions): a uu Link endpoint on UDP, remote access's only door (docs/REMOTE.md),
/// in the same process as the unix socket and with the same routes, device store and control rules. Its sessions are
/// `LinkPeer`s.
///
/// - Identity: the link key in `<keyDirectory>/link-key` (Ed25519, 0600, made once) and its binding signed with the
///   P-256 identity of remote access (`RemoteIdentity`; `/status` `link`, the signaling server's `link` message): the
///   phone pins the link key through the fingerprint it paired with.
/// - Who enters: `Bearer <token>` of a paired device, bound to the first link key it comes with (`RemoteDevices`),
///   `Pair <code>` with the pairing code being shown (pairs, binds the key, enters as the new device), or the
///   authority's answer (LinkAuthority). The core's guard limits failures per source address (10 in 60 s → 5 min),
///   sessions (32) and unauthenticated ones (4).
/// - Every link log line (sessions, paths, the 10 s `link[server]:` / `link[phone]:` lines) goes to the service's log.
/// - Reachable from the internet: the router is asked to forward a public UDP port to the listener (`PortMapper`:
///   PCP → NAT-PMP → UPnP, renewal, external-port rules, `link: port mapping …` lines); the public `ip:port` is given
///   to the endpoint (`add_external_addr`), so it is in `addr_info().direct`, `/status` `link.direct` and the signaling
///   server's `link` message, and phones dial it. iroh's own port mapper stays off for this endpoint: it only maps
///   after a net report, and two mappers on one port would fight over the router's entry.
/// - Browsers (docs/LINK.md「WebRTC」, `LinkOptions.rtc`): a second UDP socket (the link port + 1) for WebRTC sessions
///   of the same protocol; offers come through `POST /link/rtc` (the unix socket) and the signaling server's `rtc` messages
///   (`LinkRtcSignaling`), answers are signed with the identity. Its port is mapped like the link's
///   (`add_rtc_external_addr`), `/status` `link.rtc = { port, direct? }`.
final class LinkServer: @unchecked Sendable {
    /// Who this server is to the phone (`welcome.server`) and the key its binding is signed with.
    struct Identity {
        var serverId: String
        var name: String
        var key: P256.Signing.PrivateKey
    }

    enum Mode {
        /// Remote access's paired devices and RemoteControl.
        case devices(RemoteDevices)
        /// A local host decides (LinkAuthority).
        case authority(LinkAuthority)
    }

    static let features = ["video", "audio", "cursor", "input", "control", "rpc"]
    /// A taken port is tried again this often (the previous service may still hold it), then any port.
    static let portRetries = 5

    /// The one running in this process.
    nonisolated(unsafe) static var current: LinkServer?

    let options: LinkOptions
    let mode: Mode
    let control: RemoteControl
    let identity: Identity
    let keyPath: String
    private let lock = NSLock()
    private var endpoint: LinkEndpoint?
    private var listener: LinkListener?
    private var binding: Binding?
    private var address: AddrInfo?
    private var peers: [UInt64: LinkPeer] = [:]
    private var stopped = false
    /// The router's UDP mapping (while listening and `mapsPort`) and the public address it gave the endpoint.
    private var mapper: PortMapper?
    private var external: String?
    /// The same for the rtc port.
    private var rtcMapper: PortMapper?
    private var rtcExternal: String?
    private var mapsPort: Bool
    private var pathMonitor: NWPathMonitor?
    private var pathGeneration = 0
    private let queue = DispatchQueue(label: "yoyo-control.link")
    /// Tests: the network the port mapper uses.
    var portMapNetwork: PortMapNetwork = SystemPortMapNetwork()
    /// Called (any thread) when what `/status` `link` says changed (listening, addresses), and when a session opens or
    /// ends.
    var onChange: (() -> Void)?

    init(options: LinkOptions, mode: Mode, identity: Identity, keyDirectory: String, control: RemoteControl = .shared) {
        self.options = options
        self.mode = mode
        self.identity = identity
        self.control = control
        keyPath = keyDirectory + "/link-key"
        mapsPort = options.portMapping ?? (ProcessInfo.processInfo.environment["YOYO_PORTMAP"] != "off")
    }

    var authority: LinkAuthority? {
        if case .authority(let a) = mode { return a }
        return nil
    }

    // MARK: Lifecycle

    func start() {
        Self.routeLogs()
        Self.current = self
        LinkStatus.current = { [weak self] in self?.statusJSON }
        Task { await self.run() }
    }

    /// Ends every session and closes the endpoint.
    func stop() {
        lock.lock()
        stopped = true
        let ep = endpoint
        endpoint = nil
        listener = nil
        let all = Array(peers.values)
        let m = mapper
        let rm = rtcMapper
        mapper = nil
        rtcMapper = nil
        external = nil
        rtcExternal = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        lock.unlock()
        m?.stop()
        rm?.stop()
        if Self.current === self {
            Self.current = nil
            LinkStatus.current = nil
            LinkRtcSignaling.answer = nil
        }
        Task {
            for p in all { await p.session.close(.shuttingDown, reason: "link listener stopped") }
            await ep?.close()
        }
        if ep != nil { log("link: listener stopped") }
        onChange?()
    }

    /// The process is about to exit: the router's mapping goes now (at most `timeout`).
    func prepareForExit(timeout: TimeInterval = 2) {
        lock.lock()
        let m = mapper
        let rm = rtcMapper
        mapper = nil
        rtcMapper = nil
        lock.unlock()
        m?.stopAndWait(timeout: timeout)
        rm?.stopAndWait(timeout: timeout)
    }

    /// Remote access's「allow direct connections from the internet」: the UDP mappings on or off (off deletes them).
    func setPortMapping(_ on: Bool) {
        lock.lock()
        mapsPort = on
        lock.unlock()
        updateMapping()
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    /// Binds (the port, else any after `portRetries` tries 1 s apart), listens and accepts until stopped.
    private func run() async {
        let key: Data
        do {
            key = try loadOrCreateLinkKey(path: keyPath)
        } catch {
            log("link: off: no link key at \(keyPath) (\(error))")
            return
        }
        // never iroh's own mapper: see the type's comment (ours: `updateMapping`)
        let portmap = false
        var port = options.port
        var attempts = 0
        var ep: LinkEndpoint?
        while ep == nil, !isStopped {
            do {
                ep = try await bindEndpoint(config: EndpointConfig(role: .server, secretKey: key, port: port, relays: options.relays,
                                                                   portmapper: portmap, guard: nil, bindIps: options.bindAddresses,
                                                                   rtcPort: options.rtc ? options.rtcPort(forLinkPort: port) : nil,
                                                                   rtcStunServers: options.stunServers, rtcExternalOnly: false))
            } catch {
                attempts += 1
                let next: UInt16 = attempts < Self.portRetries ? port : 0
                log("link: cannot bind udp port \(port) (\(error)); trying \(next == 0 ? "any port" : "again") in 1 s")
                port = next
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        guard let ep else { return }
        let listener: LinkListener
        do {
            let b = try ep.binding(identityKey: identity.key.x963Representation)
            let settings = ServerSettings(server: ServerInfo(id: identity.serverId, name: identity.name, platform: "mac"),
                                          features: Self.features, rpcBlockedPaths: nil,
                                          maxRequestBody: UInt64(RemoteAccess.clipboardBodyMax),
                                          // VideoToolbox long-term references make a recovery frame a cheap P-frame
                                          recoveryOnNack: true,
                                          // signs the rtc answers (and the binding in them)
                                          identityKey: identity.key.x963Representation)
            listener = try ep.listen(settings, authenticate: { [weak self] request in
                await self?.authenticate(request) ?? .deny(.busy, message: "shutting down")
            }, rpc: { [weak self] session, request, body, responder in
                await self?.rpc(session, request, body, responder)
            })
            guard install(ep, listener, b) else {
                await ep.close()
                return
            }
        } catch {
            log("link: off: \(error)")
            await ep.close()
            return
        }
        log("link: listening on udp port \(ep.port()) (id \(ep.id().prefix(16))…, relays \(options.relays.isEmpty ? "none" : options.relays.map(Self.publicRelayURL).joined(separator: " ")))"
            + (ep.rtcPort().map { ", rtc on udp port \($0)" } ?? ""))
        ep.watchAddr(observer: LinkAddrObserver { [weak self] info in self?.addressChanged(info) })
        updateMapping()
        onChange?()
        for await session in listener.sessions {
            accept(session)
        }
    }

    /// The endpoint is up (false: stopped meanwhile).
    private func install(_ ep: LinkEndpoint, _ listener: LinkListener, _ b: Binding) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return false }
        endpoint = ep
        self.listener = listener
        binding = b
        address = ep.addrInfo()
        if ep.rtcPort() != nil, Self.current === self {
            LinkRtcSignaling.answer = { [weak self] offer, source in
                guard let self else { throw LinkRtcSignaling.Failure(status: 404, message: "uu Link is not running") }
                return try await self.acceptRtcOffer(offer, sourceIP: source)
            }
        }
        return true
    }

    private func currentListener() -> LinkListener? {
        lock.lock(); defer { lock.unlock() }
        return listener
    }

    /// A browser's offer → the signed answer (`LinkRtcSignaling`); failures carry the HTTP status to answer.
    func acceptRtcOffer(_ offer: String, sourceIP: String?) async throws -> String {
        guard let l = currentListener() else { throw LinkRtcSignaling.Failure(status: 404, message: "uu Link is not running") }
        do {
            return try await l.acceptRtcOffer(offerJson: offer, sourceIp: sourceIP)
        } catch LinkError.InvalidArgument(let message) {
            throw LinkRtcSignaling.Failure(status: 400, message: message)
        } catch LinkError.Denied(let code, let message) {
            throw LinkRtcSignaling.Failure(status: code == .rateLimited ? 429 : 503, message: message)
        } catch {
            throw LinkRtcSignaling.Failure(status: 503, message: "\(error)")
        }
    }

    // MARK: The router's mapping

    /// Starts or stops the UDP mappings (the link port, the rtc port) to match: listening and `mapsPort`.
    private func updateMapping() {
        lock.lock()
        let port = stopped ? nil : endpoint.map { $0.port() }
        let rtcPort = stopped ? nil : endpoint.flatMap { $0.rtcPort() }
        var stale: [(PortMapper, Bool)] = []
        var fresh: [PortMapper] = []
        for rtc in [false, true] {
            let p = rtc ? rtcPort : port
            let want = mapsPort && p != nil
            let current = rtc ? rtcMapper : mapper
            var next = current
            if let m = current, !want || m.internalPort != p {
                stale.append((m, rtc))
                next = nil
            }
            if want, next == nil, let p {
                let m = PortMapper(internalPort: p, proto: .udp, description: "\(ScreenHost.appName) link\(rtc ? " rtc" : "")",
                                   logPrefix: rtc ? "link rtc" : "link", network: portMapNetwork)
                m.onChange = { [weak self] state in self?.mappingChanged(state, rtc: rtc) }
                next = m
                fresh.append(m)
            }
            if rtc { rtcMapper = next } else { mapper = next }
        }
        if mapper != nil, pathMonitor == nil {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] _ in self?.networkChanged() }
            monitor.start(queue: queue)
            pathMonitor = monitor
        } else if mapper == nil, let monitor = pathMonitor {
            monitor.cancel()
            pathMonitor = nil
        }
        lock.unlock()
        for (m, rtc) in stale {
            m.stop()
            mappingChanged(.idle, rtc: rtc)
        }
        for m in fresh { m.start() }
    }

    /// A mapping changed: the endpoint advertises the new public address (and no longer the old one); `rtc`: the rtc
    /// port's, offered in rtc answers.
    private func mappingChanged(_ state: PortMapper.State, rtc: Bool = false) {
        lock.lock()
        var address: String?
        if case .mapped(let m) = state, (rtc ? rtcMapper : mapper) != nil {
            address = m.externalAddress.contains(":") ? "[\(m.externalAddress)]:\(m.externalPort)" : "\(m.externalAddress):\(m.externalPort)"
        }
        let old = rtc ? rtcExternal : external
        if rtc { rtcExternal = address } else { external = address }
        let ep = endpoint
        lock.unlock()
        guard old != address, let ep else { return }
        if rtc {
            if let old { _ = try? ep.removeRtcExternalAddr(addr: old) }
            if let address { _ = try? ep.addRtcExternalAddr(addr: address) }
            onChange?()
            return
        }
        Task {
            if let old { _ = try? await ep.removeExternalAddr(addr: old) }
            if let address { try? await ep.addExternalAddr(addr: address) }
            // the address info follows (watchAddr); read it now too, for a `/status` right after
            self.addressChanged(ep.addrInfo())
        }
    }

    /// The network changed: map again once it settled (2 s), and the endpoint re-probes its addresses.
    private func networkChanged() {
        lock.lock()
        pathGeneration += 1
        let g = pathGeneration
        let ep = endpoint
        lock.unlock()
        if let ep { Task { await ep.networkChanged(iface: nil) } }
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let m = self.pathGeneration == g ? [self.mapper, self.rtcMapper] : []
            self.lock.unlock()
            for mapper in m { mapper?.refresh() }
        }
    }

    /// `GET /remote`'s `link.mapping`: the UDP mapping's state (`off`, `probing`, `mapped` + `address`, …).
    var mappingJSON: [String: Any] {
        lock.lock()
        let m = mapper
        let on = mapsPort
        lock.unlock()
        guard on, let state = m?.state else { return ["status": "off"] }
        var j: [String: Any] = ["status": state.name == "idle" ? "probing" : state.name]
        if case .mapped(let mapping) = state {
            j["address"] = mapping.externalAddress
            j["port"] = Int(mapping.externalPort)
            j["method"] = mapping.method.rawValue
        }
        return j
    }

    private func addressChanged(_ info: AddrInfo) {
        lock.lock()
        let changed = address != info
        address = info
        lock.unlock()
        if changed { onChange?() }
    }

    /// `/status`'s `link`: `{ id, key, sig, port, relays, direct, rtc? }` (nil while not listening); `rtc` =
    /// `{ port, direct? }` (`direct`: the router's mapping of the rtc port) while browsers can connect.
    var statusJSON: [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        guard let ep = endpoint, let b = binding else { return nil }
        var j: [String: Any] = ["id": b.id, "key": b.key, "sig": b.sig, "port": Int(ep.port()), "relays": options.relays.map(Self.publicRelayURL),
                                "direct": address?.direct ?? []]
        if let p = ep.rtcPort() {
            var rtc: [String: Any] = ["port": Int(p)]
            if let e = rtcExternal { rtc["direct"] = [e] }
            j["rtc"] = rtc
        }
        return j
    }

    /// A relay's URL as the binding gives it: without its `?token=` (each side has its own; an older phone matches the
    /// bare URL against its own relays).
    static func publicRelayURL(_ url: String) -> String {
        guard var c = URLComponents(string: url), c.query != nil else { return url }
        c.query = nil
        return c.string ?? url
    }

    /// The signaling server's `link` message (docs/RELAY.md「候选」): the binding, relays and direct addresses.
    var signalJSON: [String: Any]? {
        guard var j = statusJSON else { return nil }
        j["port"] = nil
        return j
    }

    // MARK: Sessions

    /// Who enters (the `hello`'s credential): see the type's comment.
    func authenticate(_ request: AuthRequest) async -> LinkAuthDecision {
        let hello = request.hello
        let source = request.sourceAddr ?? request.sourceRelay.map { "relay \($0)" } ?? "?"
        switch mode {
        case .devices(let devices):
            let parts = hello.credential.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "pair" {
                return pair(devices, code: parts[1].trimmingCharacters(in: .whitespaces), request: request, source: source)
            }
            guard parts.count == 2, parts[0].lowercased() == "bearer" else {
                log("link: unauthorized hello from \(source): no token")
                return .deny(.unauthorized, message: "unauthorized")
            }
            switch devices.authenticateLink(token: parts[1].trimmingCharacters(in: .whitespaces), key: request.clientKey) {
            case .accepted(let d):
                return .accept(principalJSON: Self.principal(id: d.id, name: d.name))
            case .otherKey(let d):
                log("link: \(d.name)'s token from another link key (\(request.clientKey.prefix(16))…, from \(source)); unauthorized until it pairs again")
                return .deny(.unauthorized, message: "this device's token belongs to another installation; pair again")
            case .unknownToken:
                log("link: unauthorized hello from \(source): unknown token")
                return .deny(.unauthorized, message: "unauthorized")
            }
        case .authority(let authority):
            let device: [String: Any] = ["id": hello.device.id, "name": hello.device.name]
            let decision: LinkAuthority.Decision = await withCheckedContinuation { c in
                authority.authorize(credential: hello.credential, device: device, source: source) { c.resume(returning: $0) }
            }
            switch decision {
            case .accept(let principal, _):
                return .accept(principalJSON: principal)
            case .deny(let code, let message):
                let c: DenyCode = code == "unauthorized" ? .unauthorized : code == "rate-limited" ? .rateLimited : .busy
                return .deny(c, message: message)
            }
        }
    }

    /// `hello.credential = "Pair <code>"` (docs/LINK.md「配对」): pairing over the link. The code checks and
    /// device rules (`RemoteDevices.pair`); the new token is bound to this session's client key and handed back in
    /// `welcome.principal.token` (with `server: {id, name}`), and the session goes on as that device.
    private func pair(_ devices: RemoteDevices, code: String, request: AuthRequest, source: String) -> LinkAuthDecision {
        let hello = request.hello
        do {
            let token = try devices.pair(code: code, id: hello.device.id, name: hello.device.name, linkKey: request.clientKey)
            let name = devices.list.first { $0.id == hello.device.id }?.name ?? hello.device.name
            log("link: paired \(name) (from \(source))")
            return .accept(principalJSON: Self.principal(id: hello.device.id, name: name,
                                                         pairing: (token, identity.serverId, identity.name)))
        } catch RemoteDevices.PairError.badDevice(let why) {
            log("link: pairing from \(source) refused: \(why)")
            return .deny(.unauthorized, message: why)
        } catch RemoteDevices.PairError.full {
            log("link: pairing from \(source) refused: too many paired devices")
            return .deny(.busy, message: "too many paired devices; remove one on the Mac first")
        } catch {
            log("link: a wrong or expired pairing code from \(source)")
            return .deny(.unauthorized, message: "the pairing code is wrong or has expired; show a new one on the Mac")
        }
    }

    /// `welcome.principal`: `{device: {id, name}}`; after pairing over the link also `token` and `server: {id, name}`.
    static func principal(id: String, name: String, pairing: (token: String, serverId: String, serverName: String)? = nil) -> String {
        var j: [String: Any] = ["device": ["id": id, "name": name]]
        if let pairing {
            j["token"] = pairing.token
            j["server"] = ["id": pairing.serverId, "name": pairing.serverName]
        }
        let data = (try? JSONSerialization.data(withJSONObject: j, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func accept(_ session: LinkSession) {
        let principal = (try? JSONSerialization.jsonObject(with: Data(session.welcome().principalJson.utf8))) as? [String: Any]
        guard let who = LinkAuthority.Device(json: principal?["device"]) else {
            Task { await session.close(.protocol, reason: "no device in the principal") }
            return
        }
        var remote: RemoteDevice?
        if case .devices(let devices) = mode {
            remote = devices.list.first { $0.id == who.id }
            guard remote != nil else {
                Task { await session.close(.unauthorized, reason: "the device is no longer paired") }
                return
            }
        }
        let peer = LinkPeer(session: session, server: self, device: who, remote: remote)
        lock.lock()
        if stopped {
            lock.unlock()
            Task { await session.close(.shuttingDown, reason: "link listener stopped") }
            return
        }
        peers[session.id()] = peer
        lock.unlock()
        onChange?()
        peer.start { [weak self] in
            self?.lock.lock()
            self?.peers[session.id()] = nil
            self?.lock.unlock()
            self?.onChange?()
        }
    }

    /// The device as it is paired now (nil: removed since the session began; authority mode: nil).
    func pairedDevice(_ id: String) -> RemoteDevice? {
        guard case .devices(let devices) = mode else { return nil }
        return devices.list.first { $0.id == id }
    }

    /// The sessions of devices no longer paired end (`unauthorized`).
    func devicesChanged(paired ids: Set<String>) {
        lock.lock()
        let gone = peers.values.filter { !ids.contains($0.device.id) }
        lock.unlock()
        for p in gone { Task { await p.session.close(.unauthorized, reason: "the device was removed") } }
    }

    var sessionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return peers.count
    }

    /// The devices with a session open now (`GET /remote`'s `connected`).
    var connectedDevices: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(peers.values.map(\.device.id))
    }

    private func rpc(_ session: LinkSession, _ request: RpcRequest, _ body: Data, _ responder: RpcResponder) async {
        guard let peer = peer(session.id()) else {
            try? await responder.respond(status: 401, headers: ["content-type": "application/json"], body: Data(#"{"error":"unauthorized"}"#.utf8))
            return
        }
        await peer.rpc(request, body, responder)
    }

    private func peer(_ id: UInt64) -> LinkPeer? {
        lock.lock(); defer { lock.unlock() }
        return peers[id]
    }

    // MARK: Logs

    private static let logOnce: Void = {
        LinkLog.setHandler { level, message in
            if level != .debug { log(message) }
        }
    }()

    /// The core's lines (sessions, paths, `link[server]:` / `link[phone]:`, the guard) into the service's log.
    static func routeLogs() { _ = logOnce }
}
#endif
