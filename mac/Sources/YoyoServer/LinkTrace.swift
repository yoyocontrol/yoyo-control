#if os(macOS)
import Foundation

// A link session's trace (field tests, docs/LINK.md「逐帧跟踪」): one JSON object per line in
// `<LinkOptions.traceDirectory>/<start>-<device>.jsonl`, every record with `t` (its type) and `at` (this Mac's uptime,
// ms: the clock of every Mac-side time in the file). What goes in: each capture callback (`cap`), each encoded picture
// and why the pictures before it were not (`enc`), each frame's way out of the media layer (`tx`), the rate
// controller's targets (`rate`), the session's stats every second (`stats`), and the phone's per-frame records that ride
// its playout report (`rx`: the phone's media layer; `ph`: its decoder and display; phone clocks, see `phone`).
// Old files go when the directory passes `maxBytes`.

final class LinkTrace: @unchecked Sendable {
    /// Traces over this much (all files together) lose their oldest files when a new one starts.
    static let maxBytes: UInt64 = 2 << 30

    let path: String
    private let queue = DispatchQueue(label: "yoyo-control.link.trace", qos: .utility)
    private let handle: FileHandle
    private let lock = NSLock()
    /// Rust's session clock (µs) + this = uptime (µs): both count mach absolute time.
    private var mediaOffsetUs: Double = 0
    private(set) var records = 0

    /// A new trace file in `directory` for `device` (nil: it can't be made; logged).
    init?(directory: String, device: String, session: [String: Any]) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        } catch {
            log("link trace: cannot create \(directory): \(error.localizedDescription)")
            return nil
        }
        Self.prune(directory)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let safe = device.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        let name = "\(f.string(from: Date()))-\(String(safe).prefix(40)).jsonl"
        path = (directory as NSString).appendingPathComponent(name)
        guard fm.createFile(atPath: path, contents: nil), let h = FileHandle(forWritingAtPath: path) else {
            log("link trace: cannot create \(path)")
            return nil
        }
        handle = h
        var head = session
        head["wallMs"] = Date().timeIntervalSince1970 * 1000
        write("session", head)
    }

    // after what is still queued (the writes hold the handle, not the trace)
    deinit { queue.async { [handle] in try? handle.close() } }

    static func uptimeMs() -> Double { StreamClock.now() * 1000 }

    /// Rust's session clock now (µs), measured against uptime: later `mediaMs` calls convert with it.
    func syncClock(mediaNowUs: UInt64) {
        let up = StreamClock.now() * 1e6
        lock.lock()
        mediaOffsetUs = up - Double(mediaNowUs)
        lock.unlock()
        write("clock", ["mediaUs": mediaNowUs, "wallMs": Date().timeIntervalSince1970 * 1000])
    }

    /// A media-layer time (µs, session clock) as uptime ms.
    func mediaMs(_ us: UInt64?) -> Any {
        guard let us else { return NSNull() }
        lock.lock()
        let off = mediaOffsetUs
        lock.unlock()
        return Self.round3((Double(us) + off) / 1000)
    }

    static func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

    /// One record (`at`: now unless given).
    func write(_ type: String, _ fields: [String: Any], at: Double? = nil) {
        var o = fields
        o["t"] = type
        o["at"] = Self.round3(at ?? Self.uptimeMs())
        guard JSONSerialization.isValidJSONObject(o),
              var data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        lock.lock()
        records += 1
        lock.unlock()
        queue.async { [handle] in try? handle.write(contentsOf: data) }
    }

    /// Waits for what was written so far (tests).
    func flush() { queue.sync {} }

    /// Deletes the oldest traces while the directory holds more than `maxBytes`.
    static func prune(_ directory: String, maxBytes: UInt64 = LinkTrace.maxBytes) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return }
        var files: [(path: String, size: UInt64, date: Date)] = names.filter { $0.hasSuffix(".jsonl") }.compactMap { n in
            let p = (directory as NSString).appendingPathComponent(n)
            guard let a = try? fm.attributesOfItem(atPath: p) else { return nil }
            return (p, (a[.size] as? NSNumber)?.uint64Value ?? 0, a[.modificationDate] as? Date ?? .distantPast)
        }
        var total = files.reduce(0) { $0 + $1.size }
        files.sort { $0.date < $1.date }
        while total > maxBytes, let oldest = files.first {
            try? fm.removeItem(atPath: oldest.path)
            total -= oldest.size
            files.removeFirst()
        }
    }
}
#endif
