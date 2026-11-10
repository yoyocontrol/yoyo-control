#if os(macOS)
import Foundation

// The phone's sound playout, in the video stream's playout report (`report.audio`, `ScreenAudioReport`,
// docs/PROTOCOL.md「播放报告」): sent with the video stream's report while the sound stream (`/audio`) is open.
// For the log only (it steers nothing here). The counts in one report are since the previous report
// that carried `audio`; the helper sums them over the stream's 10 s stats window and adds `audio delay 118 ms
// (buffer 40 output 22) underruns 0` to that stats line.

/// `report.audio`, decoded leniently: not an object → none; a field that isn't a finite number is left out, the rest
/// clamped (only `skewMs` / `stretchMs` may be negative).
struct StreamAudioReport: Sendable, Equatable {
    /// AVAudioSession.outputLatency / ioBufferDuration (ms).
    var outputMs: Double?
    var ioMs: Double?
    /// Bluetooth (A2DP / LE / HFP) or AirPlay output.
    var bluetooth: Bool?
    /// The jitter depth the buffer itself needs; what is buffered now (ms).
    var depthMs: Double?
    var bufferedMs: Double?
    /// What the phone adds to a packet that arrived on time: playout delay + io + output (ms).
    var addedMs: Double?
    /// Sound − picture for the same instant (+ = sound later), only with a real display's video (ms).
    var skewMs: Double?
    /// Extra video delay used for sync (Bluetooth), when > 0 (ms).
    var floorMs: Double?
    var underruns: Int?
    var late: Int?
    var concealed: Int?
    var cuts: Int?
    /// Net time-stretch (+ = played slower, the delay grew; ms).
    var stretchMs: Double?
    var kbps: Double?

    /// The wire's ranges (ScreenAudioReport).
    static let ranges: [String: ClosedRange<Double>] = [
        "outputMs": 0...1000, "ioMs": 0...200, "depthMs": 0...3000, "bufferedMs": 0...3000, "addedMs": 0...5000,
        "skewMs": -3000...3000, "floorMs": 0...1000, "underruns": 0...100_000, "late": 0...100_000,
        "concealed": 0...100_000, "cuts": 0...100_000, "stretchMs": -60_000...60_000, "kbps": 0...100_000,
    ]

    init(outputMs: Double? = nil, ioMs: Double? = nil, bluetooth: Bool? = nil, depthMs: Double? = nil, bufferedMs: Double? = nil,
         addedMs: Double? = nil, skewMs: Double? = nil, floorMs: Double? = nil, underruns: Int? = nil, late: Int? = nil,
         concealed: Int? = nil, cuts: Int? = nil, stretchMs: Double? = nil, kbps: Double? = nil) {
        self.outputMs = outputMs; self.ioMs = ioMs; self.bluetooth = bluetooth; self.depthMs = depthMs
        self.bufferedMs = bufferedMs; self.addedMs = addedMs; self.skewMs = skewMs; self.floorMs = floorMs
        self.underruns = underruns; self.late = late; self.concealed = concealed; self.cuts = cuts
        self.stretchMs = stretchMs; self.kbps = kbps
    }

    /// nil when `json` isn't an object.
    init?(json: Any?) {
        guard let obj = json as? [String: Any] else { return nil }
        func num(_ key: String) -> Double? {
            guard let n = obj[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), let range = Self.ranges[key] else { return nil }
            let d = n.doubleValue
            return d.isFinite ? min(max(d, range.lowerBound), range.upperBound) : nil
        }
        func count(_ key: String) -> Int? { num(key).map { Int($0.rounded()) } }
        var bluetooth: Bool?
        if let b = obj["bluetooth"] as? NSNumber, CFGetTypeID(b) == CFBooleanGetTypeID() { bluetooth = b.boolValue }
        self.init(outputMs: num("outputMs"), ioMs: num("ioMs"), bluetooth: bluetooth, depthMs: num("depthMs"),
                  bufferedMs: num("bufferedMs"), addedMs: num("addedMs"), skewMs: num("skewMs"), floorMs: num("floorMs"),
                  underruns: count("underruns"), late: count("late"), concealed: count("concealed"), cuts: count("cuts"),
                  stretchMs: num("stretchMs"), kbps: num("kbps"))
    }

    /// `later`'s levels (latency, buffer, skew, rate) with this one's counts and stretch added to its own: the log
    /// window's sum.
    func merged(with later: StreamAudioReport) -> StreamAudioReport {
        func add<T: AdditiveArithmetic>(_ a: T?, _ b: T?) -> T? { a == nil && b == nil ? nil : (a ?? .zero) + (b ?? .zero) }
        var m = later
        m.underruns = add(underruns, later.underruns)
        m.late = add(late, later.late)
        m.concealed = add(concealed, later.concealed)
        m.cuts = add(cuts, later.cuts)
        m.stretchMs = add(stretchMs, later.stretchMs)
        return m
    }

    /// The stats line's part: `delay 118 ms (buffer 40 output 22 bluetooth) underruns 0`, what the delay is made of in
    /// brackets: the jitter depth, the output (latency + IO buffer), `bluetooth` for a Bluetooth / AirPlay way out
    /// (missing values left out; `-` when all are).
    var compactLine: String {
        var parts: [String] = []
        if let addedMs {
            var line = String(format: "delay %.0f ms", addedMs)
            var made: [String] = []
            if let depthMs { made.append(String(format: "buffer %.0f", depthMs)) }
            if outputMs != nil || ioMs != nil { made.append(String(format: "output %.0f", (outputMs ?? 0) + (ioMs ?? 0))) }
            if bluetooth == true { made.append("bluetooth") }
            if !made.isEmpty { line += " (" + made.joined(separator: " ") + ")" }
            parts.append(line)
        }
        if let underruns { parts.append("underruns \(underruns)") }
        return parts.isEmpty ? "-" : parts.joined(separator: " ")
    }

    var json: [String: Any] {
        var d: [String: Any] = [:]
        let numbers: [(String, Double?)] = [
            ("outputMs", outputMs), ("ioMs", ioMs), ("depthMs", depthMs), ("bufferedMs", bufferedMs), ("addedMs", addedMs),
            ("skewMs", skewMs), ("floorMs", floorMs), ("stretchMs", stretchMs), ("kbps", kbps),
        ]
        for (k, v) in numbers { if let v { d[k] = (v * 10).rounded() / 10 } }
        let counts: [(String, Int?)] = [("underruns", underruns), ("late", late), ("concealed", concealed), ("cuts", cuts)]
        for (k, v) in counts { if let v { d[k] = v } }
        if let bluetooth { d["bluetooth"] = bluetooth }
        return d
    }
}
#endif
