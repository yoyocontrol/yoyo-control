import Darwin
import Foundation

/// Reads multipart parts (headers + body) from the client end of a socketpair.
final class StreamPartReader {
    let fd: Int32
    private var buffer = [UInt8]()
    init(fd: Int32, timeout: Double = 3) { self.fd = fd; setTimeout(timeout) }

    func setTimeout(_ seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
    private func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard n > 0 else { return false }
        buffer.append(contentsOf: chunk[0..<n])
        return true
    }
    func head() -> String? {
        let sep: [UInt8] = [13, 10, 13, 10]
        while true {
            if buffer.count >= 4, let i = (0...(buffer.count - 4)).first(where: { buffer[$0] == 13 && Array(buffer[$0..<$0 + 4]) == sep }) {
                let s = String(decoding: buffer[0..<i + 4], as: UTF8.self)
                buffer.removeFirst(i + 4)
                return s
            }
            guard fill() else { return nil }
        }
    }
    struct Part {
        let headers: [String: String]
        let names: [String]
        let body: Data
        var kind: String { headers["x-frame-kind"] ?? "" }
        var seq: UInt64 { UInt64(headers["x-frame-seq"] ?? "") ?? 0 }
        var isPicture: Bool { kind != "cursor" }
    }
    func part() -> Part? {
        guard let h = head() else { return nil }
        var headers: [String: String] = [:]
        var names: [String] = []
        for line in h.split(separator: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            names.append(name)
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let n = headers["content-length"].flatMap(Int.init) else { return nil }
        while buffer.count < n + 2 { guard fill() else { return nil } }
        let body = Data(buffer[0..<n])
        buffer.removeFirst(n + 2)
        return Part(headers: headers, names: names, body: body)
    }
    /// The next picture part, skipping cursor parts.
    func picture() -> Part? {
        while let p = part() { if p.isPicture { return p } }
        return nil
    }
}
