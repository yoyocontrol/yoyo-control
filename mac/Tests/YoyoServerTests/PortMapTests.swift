import Foundation
import XCTest
@testable import YoyoServer

/// Port mapping (PortMap.swift, PortMapper.swift, docs/REMOTE.md「外网直连」): the packets and messages, and the mapper
/// against a fake router speaking UPnP IGD / NAT-PMP / PCP. `YOYO_PORTMAP_REAL=1` adds one real mapping on this LAN's
/// router (a test port, deleted again).
final class PortMapTests: XCTestCase {
    func testAddressClasses() {
        XCTAssertEqual(PortMap.classify("93.184.216.34"), .public)
        XCTAssertEqual(PortMap.classify("10.0.0.1"), .private)
        XCTAssertEqual(PortMap.classify("172.20.1.1"), .private)
        XCTAssertEqual(PortMap.classify("172.32.1.1"), .public)
        XCTAssertEqual(PortMap.classify("192.168.50.1"), .private)
        XCTAssertEqual(PortMap.classify("100.64.0.1"), .cgnat)
        XCTAssertEqual(PortMap.classify("100.128.0.1"), .public)
        XCTAssertEqual(PortMap.classify("0.0.0.0"), .unspecified)
        XCTAssertEqual(PortMap.classify("169.254.3.3"), .linkLocal)
        XCTAssertEqual(PortMap.classify("239.255.255.250"), .reserved)
        XCTAssertNil(PortMap.classify("256.0.0.1"))
        XCTAssertNil(PortMap.classify("::1"))
    }

    func testNatPmpPackets() {
        XCTAssertEqual([UInt8](PortMap.pmpMapRequest(.tcp, internal: 47820, external: 47820, lifetime: 7200)),
                       [0, 2, 0, 0, 0xba, 0xcc, 0xba, 0xcc, 0, 0, 0x1c, 0x20])
        let addr = PortMap.parsePmpExternalAddress(Data([0, 128, 0, 0, 0, 0, 0, 5, 93, 184, 216, 34]))
        XCTAssertEqual(addr?.result, 0)
        XCTAssertEqual(addr?.address, "93.184.216.34")
        XCTAssertEqual(PortMap.parsePmpMap(Data([0, 130, 0, 0, 0, 0, 0, 7, 0xba, 0xcc, 0xba, 0xcd, 0, 0, 0x0e, 0x10]), .tcp),
                       PortMap.PmpMap(result: 0, internalPort: 47820, externalPort: 47821, lifetime: 3600))
        XCTAssertNil(PortMap.parsePmpMap(Data([0, 129, 0, 0]), .tcp))
    }

    func testPcpPackets() {
        let nonce = (1...12).map { UInt8($0) }
        let m = [UInt8](PortMap.pcpMapRequest(nonce: nonce, .tcp, internal: 47820, external: 47820, externalAddress: nil, lifetime: 7200, client: "192.168.50.151"))
        XCTAssertEqual(m.count, 60)
        XCTAssertEqual(Array(m[0..<8]), [2, 1, 0, 0, 0, 0, 0x1c, 0x20])
        XCTAssertEqual(Array(m[18..<24]), [0xff, 0xff, 192, 168, 50, 151])
        XCTAssertEqual(Array(m[24..<36]), nonce)
        XCTAssertEqual(m[36], 6)
        XCTAssertEqual(Array(m[40..<44]), [0xba, 0xcc, 0xba, 0xcc])
        var r = [UInt8](repeating: 0, count: 60)
        r[0] = 2; r[1] = 0x81; r[7] = 0x10; r[6] = 0x0e
        r.replaceSubrange(24..<36, with: nonce)
        r[42] = 0xc3; r[43] = 0x50
        r.replaceSubrange(54..<60, with: [0xff, 0xff, 93, 184, 216, 34])
        let p = PortMap.parsePcp(Data(r))
        XCTAssertEqual(p?.version, 2)
        XCTAssertEqual(p?.lifetime, 3600)
        XCTAssertEqual(p?.externalPort, 50000)
        XCTAssertEqual(p?.externalAddress, "93.184.216.34")
        XCTAssertEqual(p?.nonce, nonce)
        XCTAssertEqual(PortMap.parsePcp(Data([0, 0x81, 0, 1]))?.version, 0, "a NAT-PMP gateway's answer")
    }

    func testSsdpDescriptionAndSoap() throws {
        XCTAssertEqual(PortMap.ssdpLocation("HTTP/1.1 200 OK\r\nLOCATION: \(FakeRouter.location)\r\nST: x\r\n\r\n"), FakeRouter.location)
        XCTAssertNil(PortMap.ssdpLocation("NOTIFY * HTTP/1.1\r\nLOCATION: http://x/\r\n\r\n"))
        XCTAssertNil(PortMap.ssdpLocation("HTTP/1.1 200 OK\r\nLOCATION: file:///etc/passwd\r\n\r\n"))
        let services = PortMap.wanServices(description: FakeRouter.description, location: URL(string: FakeRouter.location)!)
        XCTAssertEqual(services, [PortMap.WanService(serviceType: "urn:schemas-upnp-org:service:WANIPConnection:1",
                                                     controlURL: URL(string: "http://192.168.50.1:49152/47495533/upnp/control/WANIPConn1")!)])
        let env = PortMap.soapEnvelope("urn:schemas-upnp-org:service:WANIPConnection:1", "AddPortMapping", [("NewExternalPort", "47820"), ("NewPortMappingDescription", "a<b&")])
        XCTAssertTrue(env.contains("<u:AddPortMapping xmlns:u=\"urn:schemas-upnp-org:service:WANIPConnection:1\"><NewExternalPort>47820</NewExternalPort><NewPortMappingDescription>a&lt;b&amp;</NewPortMappingDescription></u:AddPortMapping>"))
        XCTAssertEqual(PortMap.xmlText(env, "NewPortMappingDescription"), "a<b&")
        let ok = try PortMap.parseSOAP(status: 200, body: "<s:Body><u:GetExternalIPAddressResponse><NewExternalIPAddress>93.184.216.34</NewExternalIPAddress></u:GetExternalIPAddressResponse></s:Body>",
                                       action: "GetExternalIPAddress", names: ["NewExternalIPAddress"]).get()
        XCTAssertEqual(ok["NewExternalIPAddress"], "93.184.216.34")
        guard case .failure(let e) = PortMap.parseSOAP(status: 500, body: "<UPnPError><errorCode>718</errorCode><errorDescription>ConflictInMappingEntry</errorDescription></UPnPError>", action: "AddPortMapping") else {
            return XCTFail("a fault")
        }
        XCTAssertEqual(e.code, 718)
        XCTAssertEqual(e.text, "ConflictInMappingEntry")
    }

    func testHttpResponsesPlainAndChunked() throws {
        let plain = try SystemPortMapNetwork.parseHTTPResponse(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi".utf8))
        XCTAssertEqual(plain.0, 200)
        XCTAssertEqual(plain.1, "hi")
        let chunked = try SystemPortMapNetwork.parseHTTPResponse(Data("HTTP/1.1 500 Internal\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8))
        XCTAssertEqual(chunked.0, 500)
        XCTAssertEqual(chunked.1, "hello world")
    }

    // MARK: The mapper

    func testUpnpMapsRenewsAndDeletes() {
        let router = FakeRouter(upnp: true)
        let (m, timers) = mapper(router)
        m.start()
        guard case .mapped(let got) = m.waitState({ $0.name == "mapped" }) else { return XCTFail("\(m.state)") }
        XCTAssertEqual(got, PortMapper.Mapping(method: .upnp, externalAddress: "93.184.216.34", externalPort: 47820, internalAddress: "192.168.50.151", lifetime: 3600))
        XCTAssertEqual(router.upnpTable["TCP:47820"]?.client, "192.168.50.151")
        XCTAssertEqual(timers.delays.last, 1800)
        router.calls.removeAll()
        timers.fireLast()
        m.queue.sync {}
        XCTAssertTrue(router.calls.contains("AddPortMapping 47820"), "\(router.calls)")
        XCTAssertFalse(router.calls.contains("ssdp"), "the IGD is remembered")
        m.stopAndWait(timeout: 2)
        XCTAssertTrue(router.upnpTable.isEmpty)
        XCTAssertEqual(m.state, .idle)
    }

    func testUpnpSkipsAPortAnotherHostHolds() {
        let router = FakeRouter(upnp: true)
        router.upnpTable["TCP:47820"] = ("192.168.50.20", 47820)
        let (m, _) = mapper(router)
        m.start()
        guard case .mapped(let got) = m.waitState({ $0.name == "mapped" }) else { return XCTFail("\(m.state)") }
        XCTAssertNotEqual(got.externalPort, 47820)
        XCTAssertEqual(router.upnpTable["TCP:47820"]?.client, "192.168.50.20")
        m.stopAndWait(timeout: 2)
        XCTAssertEqual(router.upnpTable.count, 1)
    }

    func testUpnpPermanentOnlyAndReadOnly() {
        let permanent = FakeRouter(upnp: true)
        permanent.permanentOnly = true
        let (m, timers) = mapper(permanent)
        m.start()
        guard case .mapped(let got) = m.waitState({ $0.name == "mapped" }) else { return XCTFail("\(m.state)") }
        XCTAssertEqual(got.lifetime, 0)
        XCTAssertEqual(timers.delays.last, PortMapper.permanentRefresh)
        m.stopAndWait(timeout: 2)
        XCTAssertTrue(permanent.upnpTable.isEmpty)

        let readOnly = FakeRouter(upnp: true)
        readOnly.readOnly = true
        let (r, rt) = mapper(readOnly)
        r.start()
        guard case .failed(_, let error) = r.waitState({ $0.name == "failed" }) else { return XCTFail("\(r.state)") }
        XCTAssertTrue(error.contains("606"), error)
        XCTAssertEqual(rt.delays.last, 60)
        r.stopAndWait(timeout: 2)
    }

    func testCgnatIsUnreachableAndLeavesNothing() {
        for kind in ["upnp", "pmp", "pcp"] {
            let router = FakeRouter(upnp: kind == "upnp", pmp: kind == "pmp", pcp: kind == "pcp")
            router.external = "100.72.1.9"
            let (m, _) = mapper(router)
            m.start()
            guard case .unreachable(_, let address, let reason) = m.waitState({ $0.name == "unreachable" }) else { return XCTFail("\(kind): \(m.state)") }
            XCTAssertEqual(address, "100.72.1.9")
            XCTAssertEqual(reason, "cgnat")
            XCTAssertTrue(router.upnpTable.isEmpty && router.pmpTable.isEmpty && router.pcpTable.isEmpty, kind)
            m.stopAndWait(timeout: 2)
        }
    }

    func testNothingAnswersIsUnsupported() {
        let (m, timers) = mapper(FakeRouter())
        m.start()
        XCTAssertEqual(m.waitState({ $0.name == "unsupported" }), .unsupported)
        XCTAssertEqual(timers.delays.last, PortMapper.unsupportedRetry)
        m.stopAndWait(timeout: 2)
    }

    func testNatPmpAndPcp() {
        let pmp = FakeRouter(pmp: true)
        pmp.pcpAsPmp = true
        pmp.assignPort = 61000
        let (m, _) = mapper(pmp)
        m.start()
        guard case .mapped(let got) = m.waitState({ $0.name == "mapped" }) else { return XCTFail("\(m.state)") }
        XCTAssertEqual(got.method, .natpmp)
        XCTAssertEqual(got.externalPort, 61000)
        m.stopAndWait(timeout: 2)
        XCTAssertTrue(pmp.pmpTable.isEmpty)

        let all = FakeRouter(upnp: true, pmp: true, pcp: true)
        let (p, _) = mapper(all)
        p.start()
        guard case .mapped(let viaPcp) = p.waitState({ $0.name == "mapped" }) else { return XCTFail("\(p.state)") }
        XCTAssertEqual(viaPcp.method, .pcp)
        XCTAssertTrue(all.upnpTable.isEmpty)
        p.stopAndWait(timeout: 2)
        XCTAssertTrue(all.pcpTable.isEmpty)
    }

    /// `YOYO_PORTMAP_REAL=1 swift test --filter PortMapTests/testRealRouter`: one mapping of a test port on this LAN's
    /// router, checked with GetSpecificPortMappingEntry, then deleted.
    func testRealRouter() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["YOYO_PORTMAP_REAL"] == "1", "set YOYO_PORTMAP_REAL=1 to map a test port on the real router")
        let m = PortMapper(internalPort: 47998, description: "Yoyo Control test", lifetime: 600)
        m.start()
        let state = m.waitState({ $0.name != "probing" && $0.name != "idle" }, timeout: 20)
        print("real router: \(state)")
        guard case .mapped(let got) = state else {
            m.stopAndWait(timeout: 5)
            return XCTFail("not mapped: \(state)")
        }
        let net = SystemPortMapNetwork()
        let services = PortMapper.discover(net, gateway: net.gateway(), localAddress: got.internalAddress)
        if got.method == .upnp, let svc = services.first {
            let body = PortMap.soapEnvelope(svc.serviceType, "GetSpecificPortMappingEntry", [("NewRemoteHost", ""), ("NewExternalPort", "\(got.externalPort)"), ("NewProtocol", "TCP")])
            let (status, answer) = try net.http(svc.controlURL, method: "POST", headers: ["Content-Type": "text/xml; charset=\"utf-8\"", "SOAPAction": "\"\(svc.serviceType)#GetSpecificPortMappingEntry\""], body: Data(body.utf8), timeout: 5)
            XCTAssertEqual(status, 200)
            XCTAssertEqual(PortMap.xmlText(answer, "NewInternalClient"), got.internalAddress)
            print("real router: entry \(PortMap.xmlText(answer, "NewInternalClient") ?? "?"):\(PortMap.xmlText(answer, "NewInternalPort") ?? "?") lease \(PortMap.xmlText(answer, "NewLeaseDuration") ?? "?")")
            m.stopAndWait(timeout: 5)
            let (after, _) = try net.http(svc.controlURL, method: "POST", headers: ["Content-Type": "text/xml; charset=\"utf-8\"", "SOAPAction": "\"\(svc.serviceType)#GetSpecificPortMappingEntry\""], body: Data(body.utf8), timeout: 5)
            XCTAssertEqual(after, 500, "deleted: 714 NoSuchEntryInArray")
        } else {
            m.stopAndWait(timeout: 5)
        }
    }

    // MARK: Helpers

    final class Timers: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(TimeInterval, DispatchQueue, () -> Void)] = []
        var delays: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return items.map(\.0) }
        func add(_ d: TimeInterval, _ q: DispatchQueue, _ w: @escaping () -> Void) { lock.lock(); items.append((d, q, w)); lock.unlock() }
        func fireLast() {
            lock.lock()
            let last = items.last
            lock.unlock()
            if let last { last.1.async(execute: last.2) }
        }
    }

    private func mapper(_ router: FakeRouter) -> (PortMapper, Timers) {
        let timers = Timers()
        var seed = 0.0
        let m = PortMapper(internalPort: 47820, description: "Test", lifetime: 3600, network: router,
                           random: { seed = (seed * 7 + 0.3).truncatingRemainder(dividingBy: 1); return seed },
                           schedule: { d, q, w in timers.add(d, q, w) })
        return (m, timers)
    }
}

extension PortMapper {
    /// Waits (on the mapper's queue, then polling) until `done` says so.
    func waitState(_ done: (State) -> Bool, timeout: TimeInterval = 5) -> State {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            queue.sync {}
            if done(state) { return state }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return state
    }
}

/// One gateway (192.168.50.1, this Mac 192.168.50.151) speaking any of UPnP IGD / NAT-PMP / PCP.
final class FakeRouter: PortMapNetwork, @unchecked Sendable {
    static let location = "http://192.168.50.1:49152/47495533/gatedesc0b.xml"
    static let description = """
    <?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0"><device>
    <deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType><deviceList><device>
    <serviceList><service><serviceType>urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1</serviceType>
    <controlURL>/47495533/upnp/control/WANCommonIFC1</controlURL></service></serviceList>
    <deviceList><device><serviceList><service>
    <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
    <serviceId>urn:upnp-org:serviceId:WANIPConn1</serviceId>
    <controlURL>/47495533/upnp/control/WANIPConn1</controlURL>
    </service></serviceList></device></deviceList></device></deviceList></device></root>
    """

    let upnp: Bool, pmp: Bool, pcp: Bool
    var pcpAsPmp = false
    var permanentOnly = false
    var readOnly = false
    var assignPort: UInt16?
    var external = "93.184.216.34"
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] {
        get { lock.lock(); defer { lock.unlock() }; return _calls }
        set { lock.lock(); _calls = newValue; lock.unlock() }
    }
    var upnpTable: [String: (client: String, port: UInt16)] = [:]
    var pmpTable: [UInt16: UInt16] = [:]
    var pcpTable: [UInt16: UInt16] = [:]

    init(upnp: Bool = false, pmp: Bool = false, pcp: Bool = false) {
        self.upnp = upnp
        self.pmp = pmp
        self.pcp = pcp
    }

    private func note(_ s: String) { lock.lock(); _calls.append(s); lock.unlock() }

    func gateway() -> String? { "192.168.50.1" }
    func localAddress(towards host: String) -> String? { host == "192.168.50.1" ? "192.168.50.151" : nil }

    func ssdp(_ targets: [(host: String, port: UInt16, payload: Data)], wait: TimeInterval, localAddress: String?, preferFrom: String?) -> [(String, String)] {
        note("ssdp")
        return upnp ? [("192.168.50.1", "HTTP/1.1 200 OK\r\nLOCATION: \(Self.location)\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n")] : []
    }

    func http(_ url: URL, method: String, headers: [String: String], body: Data?, timeout: TimeInterval) throws -> (Int, String) {
        guard upnp, url.host == "192.168.50.1" else { throw PortMapNetworkError(description: "refused") }
        if method == "GET" { return url.absoluteString == Self.location ? (200, Self.description) : (404, "") }
        let action = headers["SOAPAction"].flatMap { $0.split(separator: "#").last.map { String($0.dropLast()) } } ?? ""
        let xml = String(decoding: body ?? Data(), as: UTF8.self)
        func arg(_ n: String) -> String { PortMap.xmlText(xml, n) ?? "" }
        note("\(action) \(arg("NewExternalPort"))".trimmingCharacters(in: .whitespaces))
        func ok(_ inner: String = "") -> (Int, String) { (200, "<s:Envelope><s:Body><u:\(action)Response>\(inner)</u:\(action)Response></s:Body></s:Envelope>") }
        func fault(_ code: Int) -> (Int, String) { (500, "<s:Envelope><s:Body><s:Fault><detail><UPnPError><errorCode>\(code)</errorCode></UPnPError></detail></s:Fault></s:Body></s:Envelope>") }
        let key = "\(arg("NewProtocol")):\(arg("NewExternalPort"))"
        lock.lock()
        defer { lock.unlock() }
        switch action {
        case "GetExternalIPAddress": return ok("<NewExternalIPAddress>\(external)</NewExternalIPAddress>")
        case "GetSpecificPortMappingEntry":
            guard let e = upnpTable[key] else { return fault(714) }
            return ok("<NewInternalPort>\(e.port)</NewInternalPort><NewInternalClient>\(e.client)</NewInternalClient><NewPortMappingDescription>x</NewPortMappingDescription>")
        case "AddPortMapping":
            if readOnly { return fault(606) }
            if permanentOnly && arg("NewLeaseDuration") != "0" { return fault(725) }
            if let e = upnpTable[key], e.client != arg("NewInternalClient") { return fault(718) }
            upnpTable[key] = (arg("NewInternalClient"), UInt16(arg("NewInternalPort")) ?? 0)
            return ok()
        case "DeletePortMapping":
            return upnpTable.removeValue(forKey: key) != nil ? ok() : fault(714)
        default: return fault(401)
        }
    }

    func udp(_ host: String, _ port: UInt16, _ payload: Data, timeouts: [TimeInterval], accept: (Data) -> Bool) -> Data? {
        guard host == "192.168.50.1", port == 5351 else { return nil }
        let p = [UInt8](payload)
        lock.lock()
        let answer = answerPMP(p)
        lock.unlock()
        guard let answer, accept(answer) else { return nil }
        return answer
    }

    private func answerPMP(_ p: [UInt8]) -> Data? {
        let ext = PortMap.ipv4(external)!
        if p[0] == 2 {
            if pcpAsPmp && pmp { return Data([0, 0x80 | (p[1] & 0x7f), 0, 1, 0, 0, 0, 0]) }
            guard pcp else { return nil }
            var b = [UInt8](repeating: 0, count: 60)
            b[0] = 2
            b[1] = 0x80 | (p[1] & 0x7f)
            let lifetime = PortMap.be32(p, 4)
            let internalPort = PortMap.be16(p, 40)
            let port = lifetime == 0 ? 0 : assignPort ?? PortMap.be16(p, 42)
            if lifetime == 0 { pcpTable = pcpTable.filter { $0.value != internalPort } } else { pcpTable[port] = internalPort }
            PortMap.put32(&b, 4, lifetime)
            b.replaceSubrange(24..<40, with: p[24..<40])
            PortMap.put16(&b, 40, internalPort)
            PortMap.put16(&b, 42, port)
            b.replaceSubrange(54..<60, with: [0xff, 0xff] + ext)
            return Data(b)
        }
        guard p[0] == 0, pmp else { return nil }
        if p[1] == 0 { return Data([0, 128, 0, 0, 0, 0, 0, 1] + ext) }
        let internalPort = PortMap.be16(p, 4)
        let lifetime = PortMap.be32(p, 8)
        var b = [UInt8](repeating: 0, count: 16)
        b[1] = 128 + p[1]
        PortMap.put16(&b, 8, internalPort)
        if lifetime == 0 {
            pmpTable = pmpTable.filter { $0.value != internalPort }
            return Data(b)
        }
        let port = assignPort ?? PortMap.be16(p, 6)
        pmpTable[port] = internalPort
        PortMap.put16(&b, 10, port)
        PortMap.put32(&b, 12, lifetime)
        return Data(b)
    }
}

/// `remote.json` (RemoteAccess.swift).
final class RemoteSettingsTests: XCTestCase {
    func testDirectIsOnByDefaultAndRemembered() throws {
        let path = NSTemporaryDirectory() + "remote-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        var s = RemoteSettings.load(path)
        XCTAssertTrue(s.direct)
        XCTAssertTrue(s.enabled)
        s.direct = false
        s.save(path)
        let again = RemoteSettings.load(path)
        XCTAssertFalse(again.direct)
        XCTAssertEqual(again.serverId, s.serverId)
    }
}
