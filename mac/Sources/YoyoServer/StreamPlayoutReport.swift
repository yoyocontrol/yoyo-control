#if os(macOS)
import Foundation

/// The client's playout report on an ack (`report`, docs/PROTOCOL.md「播放报告」): how its pictures are shown, for the
/// log only (it doesn't steer anything). Decoded leniently: not an object or an unknown `mode` → none;
/// a field that isn't a finite, non-negative number is left out.
struct StreamPlayoutReport: Sendable, Equatable {
    var mode: String
    var fps: Double?
    var gapP50Ms: Double?
    var gapP90Ms: Double?
    var arrivalGapP50Ms: Double?
    var arrivalGapP90Ms: Double?
    var hitchesPerSec: Double?
    var bufferMs: Double?
    var droppedPerSec: Double?
    var decodeMs: Double?
    /// The phone's display refresh rate, and its even pace (ms between shown pictures; nil: not pacing).
    var refreshHz: Double?
    var paceMs: Double?
    /// The phone's jitter buffer cap (ms; smooth only).
    var bufferCapMs: Double?
    /// Shown gaps ≥ 150 / ≥ 300 ms longer than the Mac's gap between the two pictures, per second.
    var stall150PerSec: Double?
    var stall300PerSec: Double?
    /// p95 of (delay − base) in the playout estimate (ms): what the jitter buffer would need.
    var jitterP95Ms: Double?
    /// `latency` (a finger / key input): the touch buffer cap in use (ms; 0 = shown on arrival).
    var touchBufferMs: Double?
    /// The client's network (`report.net`; StreamNetQuality.swift).
    var net: StreamNetReport?
    /// The client's sound playout (`report.audio`; StreamAudioReport.swift), while its sound stream is open.
    var audio: StreamAudioReport?

    static let modes: Set<String> = ["smooth", "latency"]

    init(mode: String, fps: Double? = nil, gapP50Ms: Double? = nil, gapP90Ms: Double? = nil, arrivalGapP50Ms: Double? = nil,
         arrivalGapP90Ms: Double? = nil, hitchesPerSec: Double? = nil, bufferMs: Double? = nil, droppedPerSec: Double? = nil,
         decodeMs: Double? = nil, refreshHz: Double? = nil, paceMs: Double? = nil, bufferCapMs: Double? = nil,
         stall150PerSec: Double? = nil, stall300PerSec: Double? = nil, jitterP95Ms: Double? = nil,
         touchBufferMs: Double? = nil, net: StreamNetReport? = nil, audio: StreamAudioReport? = nil) {
        self.mode = mode; self.fps = fps; self.gapP50Ms = gapP50Ms; self.gapP90Ms = gapP90Ms
        self.arrivalGapP50Ms = arrivalGapP50Ms; self.arrivalGapP90Ms = arrivalGapP90Ms; self.hitchesPerSec = hitchesPerSec
        self.bufferMs = bufferMs; self.droppedPerSec = droppedPerSec; self.decodeMs = decodeMs
        self.refreshHz = refreshHz; self.paceMs = paceMs; self.bufferCapMs = bufferCapMs
        self.stall150PerSec = stall150PerSec; self.stall300PerSec = stall300PerSec; self.jitterP95Ms = jitterP95Ms
        self.touchBufferMs = touchBufferMs; self.net = net; self.audio = audio
    }

    init?(json: Any?) {
        guard let obj = json as? [String: Any], let mode = obj["mode"] as? String, Self.modes.contains(mode) else { return nil }
        func num(_ key: String) -> Double? {
            guard let n = obj[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let d = n.doubleValue
            return d.isFinite && d >= 0 ? d : nil
        }
        self.init(mode: mode, fps: num("fps"), gapP50Ms: num("gapP50Ms"), gapP90Ms: num("gapP90Ms"),
                  arrivalGapP50Ms: num("arrivalGapP50Ms"), arrivalGapP90Ms: num("arrivalGapP90Ms"),
                  hitchesPerSec: num("hitchesPerSec"), bufferMs: num("bufferMs"), droppedPerSec: num("droppedPerSec"),
                  decodeMs: num("decodeMs"), refreshHz: num("refreshHz"), paceMs: num("paceMs"),
                  bufferCapMs: num("bufferCapMs"), stall150PerSec: num("stall150PerSec"), stall300PerSec: num("stall300PerSec"),
                  jitterP95Ms: num("jitterP95Ms"), touchBufferMs: num("touchBufferMs"),
                  net: StreamNetReport(json: obj["net"]), audio: StreamAudioReport(json: obj["audio"]))
    }

    /// The stats line's part: `smooth 59.6 fps hitch 0.4/s stall 0.1/s buf 52 ms jit 48 ms` (`stall`: gaps ≥ 150 ms;
    /// missing values left out).
    var compactLine: String {
        var s = mode
        if let fps { s += String(format: " %.1f fps", fps) }
        if let hitchesPerSec { s += String(format: " hitch %.1f/s", hitchesPerSec) }
        if let stall150PerSec { s += String(format: " stall %.1f/s", stall150PerSec) }
        if let bufferMs { s += String(format: " buf %.0f ms", bufferMs) }
        if let jitterP95Ms { s += String(format: " jit %.0f ms", jitterP95Ms) }
        return s
    }

    var json: [String: Any] {
        var d: [String: Any] = ["mode": mode]
        let fields: [(String, Double?)] = [
            ("fps", fps), ("gapP50Ms", gapP50Ms), ("gapP90Ms", gapP90Ms), ("arrivalGapP50Ms", arrivalGapP50Ms),
            ("arrivalGapP90Ms", arrivalGapP90Ms), ("hitchesPerSec", hitchesPerSec), ("bufferMs", bufferMs),
            ("droppedPerSec", droppedPerSec), ("decodeMs", decodeMs), ("refreshHz", refreshHz), ("paceMs", paceMs),
            ("bufferCapMs", bufferCapMs), ("stall150PerSec", stall150PerSec), ("stall300PerSec", stall300PerSec),
            ("jitterP95Ms", jitterP95Ms), ("touchBufferMs", touchBufferMs),
        ]
        for (k, v) in fields { if let v { d[k] = (v * 10).rounded() / 10 } }
        if let net { d["net"] = net.json }
        if let audio { d["audio"] = audio.json }
        return d
    }
}
#endif
