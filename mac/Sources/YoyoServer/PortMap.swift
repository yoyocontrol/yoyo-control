#if os(macOS)
import Darwin
import Foundation
import SystemConfiguration

/// Port mapping on the home router (docs/REMOTE.md「外网直连」): the protocols' pure parts — address classes, NAT-PMP
/// (RFC 6886) and PCP (RFC 6887) packets, UPnP IGD's SSDP / device description / SOAP — and the network they need as a
/// protocol (`PortMapNetwork`, the real one `SystemPortMapNetwork`: BSD sockets, the router from SystemConfiguration).
/// The same behaviour as the TypeScript kit `@yoyocontrol/portmap` (packages/portmap); `PortMapper` keeps one alive.
enum PortMap {
    enum Proto: String, Sendable {
        case tcp, udp
        var upper: String { rawValue.uppercased() }
    }

    enum AddressClass: String, Sendable {
        case `public`, `private`, cgnat, loopback, linkLocal = "link-local", unspecified, reserved
    }

    // MARK: Addresses

    static func ipv4(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber), let v = UInt8(p) else { return nil }
            out.append(v)
        }
        return out
    }

    /// Whether the internet can reach `address` (`public`), and if not, why (another NAT in front: `private` / `cgnat`).
    static func classify(_ address: String) -> AddressClass? {
        guard let o = ipv4(address) else { return nil }
        let (a, b, c) = (o[0], o[1], o[2])
        if a == 0 { return .unspecified }
        if a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) { return .private }
        if a == 100 && (64...127).contains(b) { return .cgnat }
        if a == 127 { return .loopback }
        if a == 169 && b == 254 { return .linkLocal }
        if a >= 224 { return .reserved }
        if (a == 192 && b == 0 && (c == 0 || c == 2)) || (a == 198 && (b == 18 || b == 19)) || (a == 198 && b == 51 && c == 100)
            || (a == 203 && b == 0 && c == 113) { return .reserved }
        return .public
    }

    // MARK: NAT-PMP / PCP

    static let pmpPort: UInt16 = 5351
    /// RFC 6886 §3.1: 250 ms, doubling; three tries are enough on a LAN.
    static let pmpTimeouts: [TimeInterval] = [0.25, 0.5, 1]

    static func pmpExternalAddressRequest() -> Data { Data([0, 0]) }

    /// `(result, address)`; nil when it isn't an answer to that request.
    static func parsePmpExternalAddress(_ d: Data) -> (result: UInt16, address: String)? {
        let b = [UInt8](d)
        guard b.count >= 4, b[0] == 0, b[1] == 128 else { return nil }
        let result = be16(b, 2)
        if result != 0 { return (result, "") }
        guard b.count >= 12 else { return nil }
        return (0, "\(b[8]).\(b[9]).\(b[10]).\(b[11])")
    }

    /// Lifetime 0 with external port 0 deletes the mapping of `internal`.
    static func pmpMapRequest(_ proto: Proto, internal internalPort: UInt16, external: UInt16, lifetime: UInt32) -> Data {
        var b = [UInt8](repeating: 0, count: 12)
        b[1] = proto == .udp ? 1 : 2
        put16(&b, 4, internalPort)
        put16(&b, 6, external)
        put32(&b, 8, lifetime)
        return Data(b)
    }

    struct PmpMap: Equatable {
        var result: UInt16
        var internalPort: UInt16
        var externalPort: UInt16
        var lifetime: UInt32
    }

    static func parsePmpMap(_ d: Data, _ proto: Proto) -> PmpMap? {
        let b = [UInt8](d)
        guard b.count >= 4, b[0] == 0, b[1] == (proto == .udp ? 129 : 130) else { return nil }
        let result = be16(b, 2)
        if result != 0 { return PmpMap(result: result, internalPort: 0, externalPort: 0, lifetime: 0) }
        guard b.count >= 16 else { return nil }
        return PmpMap(result: 0, internalPort: be16(b, 8), externalPort: be16(b, 10), lifetime: be32(b, 12))
    }

    static func ipv4Mapped(_ address: String) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        out[10] = 0xff
        out[11] = 0xff
        if let o = ipv4(address) { out.replaceSubrange(12..<16, with: o) }
        return out
    }

    static func pcpAnnounceRequest(client: String) -> Data {
        var b = [UInt8](repeating: 0, count: 24)
        b[0] = 2
        b.replaceSubrange(8..<24, with: ipv4Mapped(client))
        return Data(b)
    }

    static func pcpMapRequest(nonce: [UInt8], _ proto: Proto, internal internalPort: UInt16, external: UInt16, externalAddress: String?,
                              lifetime: UInt32, client: String) -> Data {
        precondition(nonce.count == 12)
        var b = [UInt8](repeating: 0, count: 60)
        b[0] = 2
        b[1] = 1
        put32(&b, 4, lifetime)
        b.replaceSubrange(8..<24, with: ipv4Mapped(client))
        b.replaceSubrange(24..<36, with: nonce)
        b[36] = proto == .udp ? 17 : 6
        put16(&b, 40, internalPort)
        put16(&b, 42, external)
        b.replaceSubrange(44..<60, with: ipv4Mapped(externalAddress ?? ""))
        return Data(b)
    }

    struct PcpResponse: Equatable {
        var version: UInt8
        var opcode: UInt8
        var result: UInt8
        var lifetime: UInt32
        var nonce: [UInt8] = []
        var externalPort: UInt16 = 0
        var externalAddress: String?
    }

    /// A NAT-PMP-only gateway answers a PCP request with its own header (version 0, result 1): `version == 0`.
    static func parsePcp(_ d: Data) -> PcpResponse? {
        let b = [UInt8](d)
        guard b.count >= 4 else { return nil }
        if b[0] == 0 {
            guard b[1] & 0x80 != 0 else { return nil }
            return PcpResponse(version: 0, opcode: b[1] & 0x7f, result: UInt8(truncatingIfNeeded: be16(b, 2)), lifetime: 0)
        }
        guard b.count >= 24, b[1] & 0x80 != 0 else { return nil }
        var r = PcpResponse(version: b[0], opcode: b[1] & 0x7f, result: b[3], lifetime: be32(b, 4))
        if r.opcode == 1, b.count >= 60 {
            r.nonce = Array(b[24..<36])
            r.externalPort = be16(b, 42)
            if b[44..<54].allSatisfy({ $0 == 0 }), b[54] == 0xff, b[55] == 0xff {
                r.externalAddress = "\(b[56]).\(b[57]).\(b[58]).\(b[59])"
            }
        }
        return r
    }

    // MARK: UPnP IGD

    static let ssdpAddress = "239.255.255.250"
    static let ssdpPort: UInt16 = 1900
    static let ssdpWait: TimeInterval = 2
    static let soapTimeout: TimeInterval = 5
    static let searchTargets = [
        "urn:schemas-upnp-org:device:InternetGatewayDevice:2",
        "urn:schemas-upnp-org:device:InternetGatewayDevice:1",
        "urn:schemas-upnp-org:service:WANIPConnection:2",
        "urn:schemas-upnp-org:service:WANIPConnection:1",
        "urn:schemas-upnp-org:service:WANPPPConnection:1",
    ]
    /// Best first.
    static let wanServiceTypes = [
        "urn:schemas-upnp-org:service:WANIPConnection:2",
        "urn:schemas-upnp-org:service:WANIPConnection:1",
        "urn:schemas-upnp-org:service:WANPPPConnection:1",
    ]

    static func ssdpSearch(_ st: String, host: String = "239.255.255.250:1900") -> String {
        "M-SEARCH * HTTP/1.1\r\nHOST: \(host)\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(st)\r\n\r\n"
    }

    /// An SSDP search answer's LOCATION (http only), or nil.
    static func ssdpLocation(_ text: String) -> String? {
        let lines = text.prefix(8192).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = lines.first, first.uppercased().hasPrefix("HTTP/1."), first.contains(" 200") else { return nil }
        for line in lines.dropFirst() {
            guard let i = line.firstIndex(of: ":") else { continue }
            if line[..<i].trimmingCharacters(in: .whitespaces).lowercased() == "location" {
                let v = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
                return v.lowercased().hasPrefix("http://") ? v : nil
            }
        }
        return nil
    }

    struct WanService: Equatable, Sendable {
        var serviceType: String
        var controlURL: URL
    }

    /// The WAN connection services of a device description, best first.
    static func wanServices(description xml: String, location: URL) -> [WanService] {
        let doc = String(xml.prefix(256 * 1024))
        let base = xmlText(doc, "URLBase").flatMap { URL(string: $0) } ?? location
        var out: [WanService] = []
        for block in xmlBlocks(doc, "service") {
            guard let type = xmlText(block, "serviceType"), wanServiceTypes.contains(type),
                  let control = xmlText(block, "controlURL"), let url = URL(string: control, relativeTo: base)?.absoluteURL,
                  url.scheme == "http" else { continue }
            if !out.contains(where: { $0.controlURL == url }) { out.append(WanService(serviceType: type, controlURL: url)) }
        }
        return out.sorted { (wanServiceTypes.firstIndex(of: $0.serviceType) ?? 9) < (wanServiceTypes.firstIndex(of: $1.serviceType) ?? 9) }
    }

    static func escapeXML(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "&": out += "&amp;"
            case "'": out += "&apos;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }

    static func unescapeXML(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The text of the first `<name>` element, any namespace prefix; nil when absent ("" for `<name/>`).
    static func xmlText(_ xml: String, _ name: String) -> String? {
        let p = "(?:[A-Za-z_][\\w.-]{0,40}:)?"
        guard let re = try? NSRegularExpression(pattern: "<\(p)\(name)(?:\\s[^>]{0,400})?(?:/>|>([\\s\\S]{0,8192}?)</\(p)\(name)\\s{0,8}>)"),
              let m = re.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)) else { return nil }
        guard let r = Range(m.range(at: 1), in: xml) else { return "" }
        return unescapeXML(String(xml[r])).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func xmlBlocks(_ xml: String, _ name: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "<(?:[A-Za-z_][\\w.-]{0,40}:)?\(name)(?:\\s[^>]{0,400})?>([\\s\\S]{0,65536}?)</(?:[A-Za-z_][\\w.-]{0,40}:)?\(name)\\s{0,8}>") else { return [] }
        return re.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).compactMap { m in
            Range(m.range(at: 1), in: xml).map { String(xml[$0]) }
        }
    }

    static func soapEnvelope(_ serviceType: String, _ action: String, _ args: [(String, String)]) -> String {
        let body = args.map { "<\($0.0)>\(escapeXML($0.1))</\($0.0)>" }.joined()
        return "<?xml version=\"1.0\"?>\r\n<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action) xmlns:u=\"\(escapeXML(serviceType))\">\(body)</u:\(action)></s:Body></s:Envelope>\r\n"
    }

    struct UPnPError: Error, CustomStringConvertible, Equatable {
        var action: String
        var code: Int?
        var text: String
        var description: String { "UPnP \(action): \(code.map { "\($0) " } ?? "")\(text)" }
    }

    static let upnpErrors: [Int: String] = [
        401: "invalid action", 402: "invalid args", 501: "action failed", 606: "action not authorized",
        714: "no such entry in array", 718: "conflict in mapping entry", 724: "same port values required",
        725: "only permanent leases supported", 727: "external port only supports wildcard", 728: "no port maps available",
        729: "conflict with other mechanisms",
    ]

    /// A SOAP answer: the values asked for, or the UPnP fault.
    static func parseSOAP(status: Int, body: String, action: String, names: [String] = []) -> Result<[String: String], UPnPError> {
        let doc = String(body.prefix(256 * 1024))
        if status == 200, doc.range(of: "\(action)Response") != nil {
            var values: [String: String] = [:]
            for n in names { if let v = xmlText(doc, n) { values[n] = v } }
            return .success(values)
        }
        let code = xmlText(doc, "errorCode").flatMap { Int($0) }
        let text = xmlText(doc, "errorDescription").flatMap { $0.isEmpty ? nil : $0 } ?? code.flatMap { upnpErrors[$0] } ?? "HTTP \(status)"
        return .failure(UPnPError(action: action, code: code, text: text))
    }

    // MARK: Bytes

    static func be16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) << 8 | UInt16(b[i + 1]) }
    static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
    static func put16(_ b: inout [UInt8], _ i: Int, _ v: UInt16) {
        b[i] = UInt8(v >> 8)
        b[i + 1] = UInt8(v & 0xff)
    }
    static func put32(_ b: inout [UInt8], _ i: Int, _ v: UInt32) {
        for k in 0..<4 { b[i + k] = UInt8((v >> (24 - 8 * UInt32(k))) & 0xff) }
    }
}

/// What the port mapper needs from the network (synchronous: it runs on its own queue). Tests inject a fake router.
protocol PortMapNetwork: Sendable {
    /// The IPv4 default router, or nil.
    func gateway() -> String?
    /// This Mac's IPv4 address on the interface towards `host`.
    func localAddress(towards host: String) -> String?
    /// Sends `payload` to `host:port`, retransmitting after each of `timeouts`, until a datagram from there that `accept`
    /// takes comes back; nil when none does.
    func udp(_ host: String, _ port: UInt16, _ payload: Data, timeouts: [TimeInterval], accept: (Data) -> Bool) -> Data?
    /// SSDP searches from one socket; the answers within `wait` (`(from, text)`), sooner once `preferFrom` answered.
    func ssdp(_ targets: [(host: String, port: UInt16, payload: Data)], wait: TimeInterval, localAddress: String?, preferFrom: String?) -> [(String, String)]
    /// One HTTP/1.1 request (`Connection: close`): the status and the body.
    func http(_ url: URL, method: String, headers: [String: String], body: Data?, timeout: TimeInterval) throws -> (Int, String)
}

struct PortMapNetworkError: Error, CustomStringConvertible {
    var description: String
}

/// The real network: BSD sockets (LAN only: the router), the router from SystemConfiguration's global IPv4 state.
struct SystemPortMapNetwork: PortMapNetwork {
    func gateway() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "yoyo-control.portmap" as CFString, nil, nil),
              let v = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let router = v["Router"] as? String, PortMap.ipv4(router) != nil else { return nil }
        return router
    }

    func localAddress(towards host: String) -> String? {
        guard var to = Self.inetAddr(host, 9) else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let ok = withUnsafePointer(to: &to) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
        guard ok else { return nil }
        var me = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &me) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) == 0 }
        }
        guard got else { return nil }
        let a = Self.string(me.sin_addr)
        return a == "0.0.0.0" ? nil : a
    }

    func udp(_ host: String, _ port: UInt16, _ payload: Data, timeouts: [TimeInterval], accept: (Data) -> Bool) -> Data? {
        guard var to = Self.inetAddr(host, port) else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        for wait in timeouts {
            let sent = payload.withUnsafeBytes { buf in
                withUnsafePointer(to: &to) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            guard sent >= 0 else { return nil }
            let deadline = Date().addingTimeInterval(wait)
            while let (data, from, fromPort) = Self.receive(fd, until: deadline) {
                if from == host, fromPort == port, accept(data) { return data }
            }
        }
        return nil
    }

    func ssdp(_ targets: [(host: String, port: UInt16, payload: Data)], wait: TimeInterval, localAddress: String?, preferFrom: String?) -> [(String, String)] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(1))
        if let localAddress, let a = Self.inetAddr(localAddress, 0) {
            var addr = a.sin_addr
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &addr, socklen_t(MemoryLayout<in_addr>.size))
        }
        func sendAll() {
            for t in targets {
                guard var to = Self.inetAddr(t.host, t.port) else { continue }
                _ = t.payload.withUnsafeBytes { buf in
                    withUnsafePointer(to: &to) { p in
                        p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }
        sendAll()
        var answers: [(String, String)] = []
        let start = Date()
        var deadline = start.addingTimeInterval(wait)
        var resent = false
        while true {
            let next = resent ? deadline : min(deadline, start.addingTimeInterval(min(0.5, wait / 3)))
            if let (data, from, _) = Self.receive(fd, until: next) {
                answers.append((from, String(decoding: data, as: UTF8.self)))
                if let preferFrom, from == preferFrom { deadline = min(deadline, Date().addingTimeInterval(0.25)) }
                continue
            }
            if Date() >= deadline { break }
            if !resent {
                resent = true
                sendAll()
            }
        }
        return answers
    }

    func http(_ url: URL, method: String, headers: [String: String], body: Data?, timeout: TimeInterval) throws -> (Int, String) {
        guard url.scheme == "http", let host = url.host, var to = Self.inetAddr(host, UInt16(url.port ?? 80)) else {
            throw PortMapNetworkError(description: "not an http://<IPv4> URL: \(url)")
        }
        let deadline = Date().addingTimeInterval(timeout)
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw PortMapNetworkError(description: "socket: \(errno)") }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let rc = withUnsafePointer(to: &to) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 {
            guard errno == EINPROGRESS, Self.wait(fd, events: Int16(POLLOUT), until: deadline) else {
                throw PortMapNetworkError(description: "connect \(host): timed out or refused")
            }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { throw PortMapNetworkError(description: "connect \(host): \(String(cString: strerror(err)))") }
        }
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?" + q }
        var head = "\(method) \(path) HTTP/1.1\r\nHost: \(host):\(url.port ?? 80)\r\nConnection: close\r\nUser-Agent: YoyoControl portmap\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        if let body { head += "Content-Length: \(body.count)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        if let body { out.append(body) }
        var sent = 0
        while sent < out.count {
            guard Self.wait(fd, events: Int16(POLLOUT), until: deadline) else { throw PortMapNetworkError(description: "send: timed out") }
            let n = out.withUnsafeBytes { send(fd, $0.baseAddress! + sent, out.count - sent, 0) }
            if n < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw PortMapNetworkError(description: "send: \(errno)")
            }
            sent += n
        }
        var response = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while response.count < 512 * 1024 {
            guard Self.wait(fd, events: Int16(POLLIN), until: deadline) else { throw PortMapNetworkError(description: "read: timed out") }
            let n = recv(fd, &buf, buf.count, 0)
            if n < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw PortMapNetworkError(description: "read: \(errno)")
            }
            if n == 0 { break }
            response.append(contentsOf: buf[0..<n])
        }
        return try Self.parseHTTPResponse(response)
    }

    /// `(status, body)` of a whole HTTP/1.x response (chunked bodies joined).
    static func parseHTTPResponse(_ data: Data) throws -> (Int, String) {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { throw PortMapNetworkError(description: "no HTTP header") }
        let head = String(decoding: data[..<split.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let status = lines.first.flatMap { l -> Int? in
            let parts = l.split(separator: " ")
            return parts.count >= 2 && parts[0].hasPrefix("HTTP/") ? Int(parts[1]) : nil
        }
        guard let status else { throw PortMapNetworkError(description: "not an HTTP response") }
        var body = Data(data[split.upperBound...])
        let chunked = lines.dropFirst().contains { $0.lowercased().hasPrefix("transfer-encoding:") && $0.lowercased().contains("chunked") }
        if chunked {
            var out = Data()
            var rest = body[...]
            while let crlf = rest.range(of: Data("\r\n".utf8)) {
                let sizeLine = String(decoding: rest[..<crlf.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
                guard let size = Int(sizeLine.trimmingCharacters(in: .whitespaces), radix: 16), size > 0 else { break }
                let start = crlf.upperBound
                guard rest.distance(from: start, to: rest.endIndex) >= size else { break }
                let end = rest.index(start, offsetBy: size)
                out.append(rest[start..<end])
                rest = rest[end...].dropFirst(2)
            }
            body = out
        }
        return (status, String(decoding: body, as: UTF8.self))
    }

    // MARK: Sockets

    static func inetAddr(_ host: String, _ port: UInt16) -> sockaddr_in? {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &a.sin_addr) == 1 else { return nil }
        return a
    }

    static func string(_ a: in_addr) -> String {
        var a = a
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
        return String(cString: buf)
    }

    static func wait(_ fd: Int32, events: Int16, until deadline: Date) -> Bool {
        while true {
            let ms = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            var p = pollfd(fd: fd, events: events, revents: 0)
            let n = poll(&p, 1, ms)
            if n > 0 { return true }
            if n == 0 { return false }
            if errno != EINTR { return false }
        }
    }

    /// One datagram before `deadline`: its bytes and where it came from.
    static func receive(_ fd: Int32, until deadline: Date) -> (Data, String, UInt16)? {
        guard wait(fd, events: Int16(POLLIN), until: deadline) else { return nil }
        var buf = [UInt8](repeating: 0, count: 2048)
        var from = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) { p in
            p.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
        }
        guard n >= 0 else { return nil }
        return (Data(buf[0..<n]), string(from.sin_addr), UInt16(bigEndian: from.sin_port))
    }
}
#endif
