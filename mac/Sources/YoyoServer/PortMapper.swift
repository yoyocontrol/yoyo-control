#if os(macOS)
import Foundation

/// One port mapping kept alive on the home router (docs/REMOTE.md「外网直连」): PCP, then NAT-PMP, then UPnP IGD — the
/// first that maps wins (UPnP's SSDP search runs while PCP / NAT-PMP wait for an answer); renewed at half the lease
/// (a renewal asks the mechanism holding it first); another external port when the router says the preferred one is
/// taken; `stop()` deletes it. An external address the internet can't reach (private, CGNAT, 0.0.0.0) is
/// `.unreachable` and its mapping removed again. Retries: nothing answered 5 min, a refusal 1 → 30 min, unreachable
/// 30 min; `refresh()` at once (a network change). The same behaviour as `@yoyocontrol/portmap`.
///
/// Everything runs on the mapper's own serial queue; the network is synchronous there (`PortMapNetwork`).
final class PortMapper: @unchecked Sendable {
    enum Method: String, Sendable { case pcp, natpmp, upnp }

    struct Mapping: Equatable, Sendable {
        var method: Method
        var externalAddress: String
        var externalPort: UInt16
        var internalAddress: String
        /// Seconds the router granted; 0 = permanent (UPnP only, re-added every `permanentRefresh`).
        var lifetime: UInt32
    }

    enum State: Equatable, Sendable {
        case idle
        case probing
        case mapped(Mapping)
        case unreachable(method: Method, externalAddress: String, reason: String)
        case unsupported
        case failed(method: Method?, error: String)

        var name: String {
            switch self {
            case .idle: "idle"
            case .probing: "probing"
            case .mapped: "mapped"
            case .unreachable: "unreachable"
            case .unsupported: "unsupported"
            case .failed: "failed"
            }
        }
    }

    typealias Scheduler = (_ after: TimeInterval, _ queue: DispatchQueue, _ work: @escaping () -> Void) -> Void

    static let defaultLifetime: UInt32 = 3600
    static let permanentRefresh: TimeInterval = 1200
    static let unsupportedRetry: TimeInterval = 300
    static let unreachableRetry: TimeInterval = 1800

    let proto: PortMap.Proto
    let internalPort: UInt16
    private(set) var preferredPort: UInt16
    let description: String
    /// The log lines' prefix (`remote`: the TLS door's mapping; `link`: the link listener's).
    let logPrefix: String
    let lifetime: UInt32
    let methods: [Method]
    private let net: PortMapNetwork
    private let schedule: Scheduler
    private let random: () -> Double
    let queue = DispatchQueue(label: "yoyo-control.portmap")

    private var _state: State = .idle
    private let stateLock = NSLock()
    private var current: (mapping: Mapping, gateway: String?, service: PortMap.WanService?)?
    private var nonce: [UInt8] = PortMapper.newNonce()
    private var services: [PortMap.WanService]?
    private var running = false
    private var failures = 0
    /// Scheduled work older than this is stale (a refresh / stop came since).
    private var generation = 0
    /// Called on the mapper's queue when the state changed (a renewal that changes nothing doesn't count).
    var onChange: ((State) -> Void)?

    init(internalPort: UInt16, proto: PortMap.Proto = .tcp, externalPort: UInt16? = nil, description: String,
         logPrefix: String = "remote", lifetime: UInt32 = PortMapper.defaultLifetime, methods: [Method] = [.pcp, .natpmp, .upnp],
         network: PortMapNetwork = SystemPortMapNetwork(), random: @escaping () -> Double = { Double.random(in: 0..<1) },
         schedule: @escaping Scheduler = { after, queue, work in queue.asyncAfter(deadline: .now() + after, execute: work) }) {
        self.internalPort = internalPort
        self.proto = proto
        self.logPrefix = logPrefix
        preferredPort = externalPort.flatMap { $0 > 0 ? $0 : nil } ?? internalPort
        self.description = String(description.prefix(64))
        self.lifetime = max(120, lifetime)
        self.methods = methods
        net = network
        self.random = random
        self.schedule = schedule
    }

    var state: State {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _state
    }

    /// Starts mapping and keeps it alive until `stop()`.
    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            attempt()
        }
    }

    /// Maps again now (the network changed).
    func refresh() {
        queue.async { [self] in
            guard running else { return }
            services = nil
            attempt()
        }
    }

    /// Deletes the mapping and stops; `done` on the mapper's queue.
    func stop(done: (() -> Void)? = nil) {
        queue.async { [self] in
            running = false
            generation += 1
            release()
            setState(.idle)
            done?()
        }
    }

    /// `stop()`, waiting at most `timeout` for the router (a process about to exit).
    func stopAndWait(timeout: TimeInterval) {
        let done = DispatchSemaphore(value: 0)
        stop { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    // MARK: On the queue

    private func setState(_ s: State) {
        stateLock.lock()
        let changed = _state != s
        _state = s
        stateLock.unlock()
        if changed { onChange?(s) }
    }

    private func later(_ seconds: TimeInterval) {
        guard running else { return }
        generation += 1
        let g = generation
        schedule(max(1, seconds), queue) { [weak self] in
            guard let self, self.running, self.generation == g else { return }
            self.attempt()
        }
    }

    private enum Outcome {
        case mapped(Mapping, PortMap.WanService?)
        case unreachable(Method, String, String)
        case failed(Method, String)
        case none
    }

    /// One try of every mechanism (the holder's first), then the state and the next try.
    func attempt() {
        guard running else { return }
        generation += 1
        if case .idle = state { setState(.probing) }
        let gateway = net.gateway()
        let internalAddress = gateway.flatMap { net.localAddress(towards: $0) }
        if let cur = current, cur.gateway != gateway || (internalAddress != nil && cur.mapping.internalAddress != internalAddress) {
            release()  // another network: the old router may be gone (best effort)
        }
        // UPnP's discovery (SSDP, ~2 s) runs while PCP / NAT-PMP wait for their answers
        let discovered = Discovered()
        let discovery = DispatchGroup()
        if methods.contains(.upnp), services == nil {
            discovery.enter()
            let net = self.net
            DispatchQueue.global(qos: .utility).async {
                discovered.services = Self.discover(net, gateway: gateway, localAddress: internalAddress)
                discovery.leave()
            }
        }
        var order = methods
        if let held = current?.mapping.method { order = [held] + methods.filter { $0 != held } }
        var outcomes: [Outcome] = []
        for method in order {
            let o: Outcome
            switch method {
            case .pcp: o = gateway != nil && internalAddress != nil ? tryPCP(gateway!, internalAddress!) : .none
            case .natpmp: o = gateway != nil && internalAddress != nil ? tryPMP(gateway!, internalAddress!) : .none
            case .upnp:
                if services == nil {
                    discovery.wait()
                    services = discovered.services ?? []
                }
                o = tryUPnP(gateway, internalAddress)
            }
            outcomes.append(o)
            if case .mapped = o { break }
            if case .unreachable = o { break }
        }
        guard running else {
            for case .mapped(let m, let svc) in outcomes { current = (m, gateway, svc); release() }
            return
        }
        for case .mapped(let m, let svc) in outcomes {
            if let prev = current, prev.mapping.method != m.method { release() }
            let changed = current?.mapping.externalPort != m.externalPort || current?.mapping.externalAddress != m.externalAddress
            current = (m, gateway, svc)
            failures = 0
            preferredPort = m.externalPort
            if changed {
                log("\(logPrefix): port mapping \(m.method.rawValue) \(m.externalAddress):\(m.externalPort) → \(m.internalAddress):\(internalPort) (\(m.lifetime > 0 ? "lease \(m.lifetime) s" : "permanent"))")
            }
            setState(.mapped(m))
            later(m.lifetime > 0 ? TimeInterval(m.lifetime) / 2 : Self.permanentRefresh)
            return
        }
        release()
        failures += 1
        for case .unreachable(let method, let address, let reason) in outcomes {
            if state.name != "unreachable" { log("\(logPrefix): port mapping: the router's external address \(address.isEmpty ? "(none)" : address) is \(reason): not reachable from the internet") }
            setState(.unreachable(method: method, externalAddress: address, reason: reason))
            later(Self.unreachableRetry)
            return
        }
        for case .failed(let method, let error) in outcomes {
            log("\(logPrefix): port mapping \(method.rawValue) failed: \(error)")
            setState(.failed(method: method, error: error))
            later(min(1800, 60 * pow(2, Double(min(5, failures - 1)))))
            return
        }
        if state != .unsupported { log("\(logPrefix): port mapping: no PCP / NAT-PMP / UPnP router answered") }
        setState(.unsupported)
        later(Self.unsupportedRetry)
    }

    private func reachability(_ method: Method, _ address: String) -> Outcome? {
        let c = PortMap.classify(address)
        if c == .public { return nil }
        return .unreachable(method, address, c?.rawValue ?? "unknown")
    }

    // MARK: PCP

    private func pcp(_ gateway: String, _ client: String, external: UInt16, lifetime: UInt32, externalAddress: String?) -> PortMap.PcpResponse? {
        let nonce = self.nonce
        let req = PortMap.pcpMapRequest(nonce: nonce, proto, internal: internalPort, external: external, externalAddress: externalAddress,
                                        lifetime: lifetime, client: client)
        let data = net.udp(gateway, PortMap.pmpPort, req, timeouts: PortMap.pmpTimeouts) { d in
            guard let r = PortMap.parsePcp(d) else { return false }
            return r.version == 0 || (r.opcode == 1 && r.nonce == nonce)
        }
        return data.flatMap(PortMap.parsePcp)
    }

    private func tryPCP(_ gateway: String, _ client: String) -> Outcome {
        let same = current?.mapping.method == .pcp ? current?.mapping : nil
        guard let r = pcp(gateway, client, external: same?.externalPort ?? preferredPort, lifetime: lifetime,
                          externalAddress: same?.externalAddress), r.version == 2 else { return .none }
        guard r.result == 0 else { return .failed(.pcp, "PCP result \(r.result)") }
        let m = Mapping(method: .pcp, externalAddress: r.externalAddress ?? "", externalPort: r.externalPort, internalAddress: client, lifetime: r.lifetime)
        if let bad = reachability(.pcp, m.externalAddress) {
            current = (m, gateway, nil)
            release()
            return bad
        }
        return .mapped(m, nil)
    }

    // MARK: NAT-PMP

    private func tryPMP(_ gateway: String, _ client: String) -> Outcome {
        guard let a = net.udp(gateway, PortMap.pmpPort, PortMap.pmpExternalAddressRequest(), timeouts: PortMap.pmpTimeouts,
                              accept: { PortMap.parsePmpExternalAddress($0) != nil }),
              let ext = PortMap.parsePmpExternalAddress(a) else { return .none }
        guard ext.result == 0 else { return .failed(.natpmp, "NAT-PMP result \(ext.result)") }
        if let bad = reachability(.natpmp, ext.address) { return bad }
        let same = current?.mapping.method == .natpmp ? current?.mapping : nil
        let proto = self.proto
        guard let d = net.udp(gateway, PortMap.pmpPort, PortMap.pmpMapRequest(proto, internal: internalPort, external: same?.externalPort ?? preferredPort, lifetime: lifetime),
                              timeouts: PortMap.pmpTimeouts, accept: { PortMap.parsePmpMap($0, proto) != nil }),
              let r = PortMap.parsePmpMap(d, proto) else { return .failed(.natpmp, "NAT-PMP: no answer to the mapping request") }
        guard r.result == 0 else { return .failed(.natpmp, "NAT-PMP result \(r.result)") }
        return .mapped(Mapping(method: .natpmp, externalAddress: ext.address, externalPort: r.externalPort, internalAddress: client, lifetime: r.lifetime), nil)
    }

    // MARK: UPnP

    static func discover(_ net: PortMapNetwork, gateway: String?, localAddress: String?) -> [PortMap.WanService] {
        var targets: [(host: String, port: UInt16, payload: Data)] = []
        for st in PortMap.searchTargets {
            if let gateway { targets.append((gateway, PortMap.ssdpPort, Data(PortMap.ssdpSearch(st, host: "\(gateway):1900").utf8))) }
            targets.append((PortMap.ssdpAddress, PortMap.ssdpPort, Data(PortMap.ssdpSearch(st).utf8)))
        }
        var locations: [String] = []
        for (from, text) in net.ssdp(targets, wait: PortMap.ssdpWait, localAddress: localAddress, preferFrom: gateway) {
            guard let l = PortMap.ssdpLocation(text), !locations.contains(l) else { continue }
            if from == gateway { locations.insert(l, at: 0) } else { locations.append(l) }
        }
        var out: [PortMap.WanService] = []
        for l in locations {
            guard let url = URL(string: l), let (status, body) = try? net.http(url, method: "GET", headers: [:], body: nil, timeout: PortMap.soapTimeout),
                  status == 200 else { continue }
            for s in PortMap.wanServices(description: body, location: url) where !out.contains(s) { out.append(s) }
        }
        return out
    }

    private func soap(_ svc: PortMap.WanService, _ action: String, _ args: [(String, String)], _ names: [String] = []) throws -> [String: String] {
        let headers = ["Content-Type": "text/xml; charset=\"utf-8\"", "SOAPAction": "\"\(svc.serviceType)#\(action)\""]
        let (status, body) = try net.http(svc.controlURL, method: "POST", headers: headers,
                                          body: Data(PortMap.soapEnvelope(svc.serviceType, action, args).utf8), timeout: PortMap.soapTimeout)
        return try PortMap.parseSOAP(status: status, body: body, action: action, names: names).get()
    }

    private func externalIP(_ svc: PortMap.WanService) throws -> String {
        try soap(svc, "GetExternalIPAddress", [], ["NewExternalIPAddress"])["NewExternalIPAddress"] ?? ""
    }

    /// `(client, internal port, description)` of the mapping on `port`, nil when there is none (714) or the router
    /// can't say.
    private func entry(_ svc: PortMap.WanService, _ port: UInt16) -> (String, UInt16, String)? {
        guard let v = try? soap(svc, "GetSpecificPortMappingEntry", [("NewRemoteHost", ""), ("NewExternalPort", "\(port)"), ("NewProtocol", proto.upper)],
                                ["NewInternalClient", "NewInternalPort", "NewPortMappingDescription"]) else { return nil }
        return (v["NewInternalClient"] ?? "", UInt16(v["NewInternalPort"] ?? "") ?? 0, v["NewPortMappingDescription"] ?? "")
    }

    private func tryUPnP(_ gateway: String?, _ knownClient: String?) -> Outcome {
        guard let services, !services.isEmpty else {
            self.services = nil  // look again next time
            return .none
        }
        var lastError: String?
        for svc in services {
            let host = svc.controlURL.host ?? ""
            guard let client = (host == gateway ? knownClient : nil) ?? net.localAddress(towards: host) else { continue }
            let address: String
            do { address = try externalIP(svc) } catch { lastError = "\(error)"; continue }
            if let bad = reachability(.upnp, address) {
                if PortMap.classify(address) == .unspecified { continue }  // this connection is down: another may be up
                return bad
            }
            do {
                let (port, lease) = try upnpMap(svc, client)
                return .mapped(Mapping(method: .upnp, externalAddress: address, externalPort: port, internalAddress: client, lifetime: lease), svc)
            } catch {
                lastError = "\(error)"
            }
        }
        self.services = nil
        return lastError.map { .failed(.upnp, $0) } ?? .none
    }

    /// AddPortMapping on the preferred port, then on others while the router says it's taken.
    private func upnpMap(_ svc: PortMap.WanService, _ client: String) throws -> (UInt16, UInt32) {
        let same = current?.mapping.method == .upnp && current?.service == svc ? current?.mapping : nil
        var ports: [UInt16] = [same?.externalPort ?? preferredPort]
        if !ports.contains(internalPort) { ports.append(internalPort) }
        while ports.count < 7 {
            let p = UInt16(10_000 + Int(random() * 55_000))
            if !ports.contains(p) { ports.append(p) }
        }
        var lease = same?.lifetime ?? lifetime
        var last: Error = PortMap.UPnPError(action: "AddPortMapping", code: nil, text: "no external port could be mapped")
        var i = 0
        while i < ports.count {
            let port = ports[i]
            if let e = entry(svc, port), !(e.0 == client && e.1 == internalPort) {
                log("\(logPrefix): port mapping: external port \(port) is taken by \(e.0):\(e.1) (\(e.2))")
                i += 1
                continue
            }
            do {
                _ = try soap(svc, "AddPortMapping", [
                    ("NewRemoteHost", ""), ("NewExternalPort", "\(port)"), ("NewProtocol", proto.upper),
                    ("NewInternalPort", "\(internalPort)"), ("NewInternalClient", client), ("NewEnabled", "1"),
                    ("NewPortMappingDescription", description), ("NewLeaseDuration", "\(lease)"),
                ])
                return (port, lease)
            } catch let e as PortMap.UPnPError {
                last = e
                switch e.code {
                case 725 where lease != 0:
                    lease = 0  // only permanent leases: refreshed by us, deleted on stop
                    continue
                case 724:
                    if port == internalPort { throw e }
                    ports = Array(ports[...i]) + [internalPort]
                case 718, 729, 501: break
                default: throw e
                }
            }
            i += 1
        }
        throw last
    }

    /// Deletes what we hold, each mechanism its own way (best effort).
    private func release() {
        guard let cur = current else { return }
        current = nil
        let m = cur.mapping
        var ok = true
        switch m.method {
        case .upnp:
            if let svc = cur.service {
                ok = (try? soap(svc, "DeletePortMapping", [("NewRemoteHost", ""), ("NewExternalPort", "\(m.externalPort)"), ("NewProtocol", proto.upper)])) != nil
            }
        case .natpmp:
            if let g = cur.gateway {
                let proto = self.proto
                ok = net.udp(g, PortMap.pmpPort, PortMap.pmpMapRequest(proto, internal: internalPort, external: 0, lifetime: 0),
                             timeouts: PortMap.pmpTimeouts, accept: { PortMap.parsePmpMap($0, proto) != nil }) != nil
            }
        case .pcp:
            if let g = cur.gateway { ok = pcp(g, m.internalAddress, external: m.externalPort, lifetime: 0, externalAddress: nil) != nil }
        }
        log("\(logPrefix): port mapping \(m.method.rawValue) \(m.externalAddress):\(m.externalPort) \(ok ? "deleted" : "not deleted (the router didn't answer)")")
        nonce = Self.newNonce()
    }

    /// What the background discovery found (read after the group's wait).
    private final class Discovered: @unchecked Sendable {
        var services: [PortMap.WanService]?
    }

    static func newNonce() -> [UInt8] { (0..<12).map { _ in UInt8.random(in: 0...255) } }
}
#endif
