#if os(macOS)
import Foundation

// Screen network quality (docs/PROTOCOL.md「网络质量」): the client's view of its network rides in its playout report
// (`report.net`); the helper grades the stream from its own ack round trips plus that, logs it every 10 s and answers
// every ack with the grade (`{ok: true, net: …}`). For hints and diagnosis only: it doesn't steer the flow control.

/// The client's `report.net`, decoded leniently: unknown enum values and bad numbers are left out.
struct StreamNetReport: Sendable, Equatable {
    var route: String?
    var iface: String?
    var radio: String?
    var expensive: Bool?
    var constrained: Bool?
    var inputRttP50Ms: Double?
    var inputRttP90Ms: Double?
    var inputRttSamples: Int?
    var rxKbps: Double?
    var failures: Int?

    static let routes: Set<String> = ["lan", "direct", "tunnel"]
    static let ifaces: Set<String> = ["wifi", "cellular", "wired", "other"]
    static let radios: Set<String> = ["5g", "lte", "3g", "other"]

    init(route: String? = nil, iface: String? = nil, radio: String? = nil, expensive: Bool? = nil, constrained: Bool? = nil,
         inputRttP50Ms: Double? = nil, inputRttP90Ms: Double? = nil, inputRttSamples: Int? = nil, rxKbps: Double? = nil,
         failures: Int? = nil) {
        self.route = route; self.iface = iface; self.radio = radio; self.expensive = expensive; self.constrained = constrained
        self.inputRttP50Ms = inputRttP50Ms; self.inputRttP90Ms = inputRttP90Ms; self.inputRttSamples = inputRttSamples
        self.rxKbps = rxKbps; self.failures = failures
    }

    /// nil when `json` isn't an object.
    init?(json: Any?) {
        guard let obj = json as? [String: Any] else { return nil }
        func num(_ v: Any?) -> Double? {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let d = n.doubleValue
            return d.isFinite && d >= 0 ? d : nil
        }
        func bool(_ v: Any?) -> Bool? {
            guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
            return n.boolValue
        }
        func pick(_ v: Any?, _ allowed: Set<String>) -> String? { (v as? String).flatMap { allowed.contains($0) ? $0 : nil } }
        let rtt = obj["inputRttMs"] as? [String: Any]
        self.init(route: pick(obj["route"], Self.routes), iface: pick(obj["iface"], Self.ifaces), radio: pick(obj["radio"], Self.radios),
                  expensive: bool(obj["expensive"]), constrained: bool(obj["constrained"]),
                  inputRttP50Ms: num(rtt?["p50"]), inputRttP90Ms: num(rtt?["p90"]),
                  inputRttSamples: num(rtt?["n"]).map { Int(min($0, 100_000).rounded()) },
                  rxKbps: num(obj["rxKbps"]), failures: num(obj["failures"]).map { Int(min($0, 10_000).rounded()) })
    }

    var json: [String: Any] {
        var d: [String: Any] = [:]
        if let route { d["route"] = route }
        if let iface { d["iface"] = iface }
        if let radio { d["radio"] = radio }
        if let expensive { d["expensive"] = expensive }
        if let constrained { d["constrained"] = constrained }
        var rtt: [String: Any] = [:]
        if let inputRttP50Ms { rtt["p50"] = (inputRttP50Ms * 10).rounded() / 10 }
        if let inputRttP90Ms { rtt["p90"] = (inputRttP90Ms * 10).rounded() / 10 }
        if let inputRttSamples { rtt["n"] = inputRttSamples }
        if !rtt.isEmpty { d["inputRttMs"] = rtt }
        if let rxKbps { d["rxKbps"] = rxKbps.rounded() }
        if let failures { d["failures"] = failures }
        return d
    }
}

/// A stream's ack round trips over the grading window (ms).
struct StreamRTTSummary: Sendable, Equatable {
    var minMs: Double
    var p50Ms: Double
    var p90Ms: Double
    var samples: Int

    init(minMs: Double, p50Ms: Double, p90Ms: Double, samples: Int) {
        self.minMs = minMs
        self.p50Ms = p50Ms
        self.p90Ms = p90Ms
        self.samples = samples
    }

    /// nil without samples. Nearest-rank percentiles.
    init?(ms values: [Double]) {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        func q(_ p: Double) -> Double { s[min(s.count - 1, max(0, Int((Double(s.count) * p).rounded(.up)) - 1))] }
        minMs = s[0]; p50Ms = q(0.5); p90Ms = q(0.9); samples = s.count
    }
}

/// The grade a stream's network gets (`ScreenNetQuality`).
struct StreamNetQuality: Sendable, Equatable {
    enum Grade: String, Sendable { case good, fair, poor, unknown }

    var grade: Grade
    /// The ack round trips the grade went by (nil when there were too few: then it went by the client's input round
    /// trips, `byInput`, or had nothing to go by).
    var rtt: StreamRTTSummary?
    var jitterMs: Double?
    /// Why it isn't good: "rtt", "jitter", "failures", "few-samples".
    var reasons: [String]
    /// Graded by the client's input round trips (jitter = their p90 − p50) instead of the stream's acks (p90 − min):
    /// the two aren't comparable, so the log says which (`by input`).
    var byInput = false

    /// Thresholds (ms / count): poor above the first, fair above the second.
    static let rttPoorMs = 250.0, rttFairMs = 100.0
    static let jitterPoorMs = 80.0, jitterFairMs = 30.0
    static let failuresPoor = 3, failuresFair = 1
    /// Fewer samples than this (ack round trips, or the client's input round trips) → unknown.
    static let minSamples = 5

    /// Grade from the stream's ack round trips over the window and the client's latest network report (nil if none or
    /// stale).
    static func grade(acks: StreamRTTSummary?, client: StreamNetReport?) -> StreamNetQuality {
        let ackUsable = (acks?.samples ?? 0) >= minSamples ? acks : nil
        let failures = client?.failures ?? 0
        var rttMs: Double?
        var jitterMs: Double?
        var byInput = false
        if let a = ackUsable {
            rttMs = a.p90Ms
            jitterMs = a.p90Ms - a.minMs
        } else if let c = client, (c.inputRttSamples ?? 0) >= minSamples, let p90 = c.inputRttP90Ms {
            rttMs = p90
            jitterMs = c.inputRttP50Ms.map { max(0, p90 - $0) }
            byInput = true
        }
        guard let rtt = rttMs else {
            // failures alone still say something
            if failures >= failuresFair {
                return StreamNetQuality(grade: failures >= failuresPoor ? .poor : .fair, rtt: nil, jitterMs: nil,
                                        reasons: ["failures", "few-samples"])
            }
            return StreamNetQuality(grade: .unknown, rtt: nil, jitterMs: nil, reasons: ["few-samples"])
        }
        let jitter = jitterMs ?? 0
        let poor = (rtt > rttPoorMs, jitter > jitterPoorMs, failures >= failuresPoor)
        let fair = (rtt > rttFairMs, jitter > jitterFairMs, failures >= failuresFair)
        let grade: Grade = poor.0 || poor.1 || poor.2 ? .poor : fair.0 || fair.1 || fair.2 ? .fair : .good
        let level = grade == .poor ? poor : fair
        var reasons: [String] = []
        if grade != .good {
            if level.0 { reasons.append("rtt") }
            if level.1 { reasons.append("jitter") }
            if level.2 { reasons.append("failures") }
        }
        return StreamNetQuality(grade: grade, rtt: ackUsable, jitterMs: jitterMs, reasons: reasons, byInput: byInput)
    }

    /// The ack response's `net`.
    var json: [String: Any] {
        func r(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        var d: [String: Any] = ["grade": grade.rawValue, "reasons": reasons]
        if let rtt { d["rttMs"] = ["min": r(rtt.minMs), "p50": r(rtt.p50Ms), "p90": r(rtt.p90Ms)] }
        if let jitterMs { d["jitterMs"] = r(jitterMs) }
        return d
    }

    /// `phone net: tunnel wifi rtt 137/165/210 ms jitter 73 ms input 160/190 (12) rx 1.6 Mbps fail 0 → fair (rtt, jitter)`
    /// (what the client didn't send is left out; `→ fair by input (…)` when graded by the input round trips).
    func line(client: StreamNetReport?) -> String {
        var s = "phone net:"
        if let c = client {
            if let route = c.route { s += " \(route)" }
            if let iface = c.iface { s += " \(iface)" }
            if let radio = c.radio { s += " \(radio)" }
            if c.constrained == true { s += " low-data" }
        }
        if let rtt { s += String(format: " rtt %.0f/%.0f/%.0f ms", rtt.minMs, rtt.p50Ms, rtt.p90Ms) }
        if let jitterMs { s += String(format: " jitter %.0f ms", jitterMs) }
        if let c = client {
            if c.inputRttP50Ms != nil || c.inputRttP90Ms != nil {
                let pair = [c.inputRttP50Ms, c.inputRttP90Ms].map { $0.map { String(format: "%.0f", $0) } ?? "-" }.joined(separator: "/")
                s += " input \(pair)" + (c.inputRttSamples.map { " (\($0))" } ?? "")
            }
            if let rx = c.rxKbps { s += String(format: " rx %.1f Mbps", rx / 1000) }
            if let f = c.failures { s += " fail \(f)" }
        }
        s += " → \(grade.rawValue)"
        if byInput { s += " by input" }
        if !reasons.isEmpty { s += " (\(reasons.joined(separator: ", ")))" }
        return s
    }
}
#endif
