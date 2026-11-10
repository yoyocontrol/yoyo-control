import XCTest
import Foundation
@testable import YoyoServer


/// The client's playout report on acks (docs/PROTOCOL.md「播放报告」): lenient decoding, the stats line's part, the
/// JSON, and the stats tail.
final class StreamPlayoutReportTests: XCTestCase {
    private func json(_ text: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(text.utf8)) }

    func testDecodesLenientlyAndFormatsTheLogLine() throws {
        let full = try XCTUnwrap(StreamPlayoutReport(json: json(#"""
            {"mode":"smooth","fps":29.8,"gapP50Ms":33,"gapP90Ms":41,"arrivalGapP50Ms":33.4,"arrivalGapP90Ms":52,
             "hitchesPerSec":0.3,"bufferMs":28,"droppedPerSec":0.5,"decodeMs":2.14,"extra":"ignored"}
            """#)))
        XCTAssertEqual(full, StreamPlayoutReport(mode: "smooth", fps: 29.8, gapP50Ms: 33, gapP90Ms: 41, arrivalGapP50Ms: 33.4,
                                                 arrivalGapP90Ms: 52, hitchesPerSec: 0.3, bufferMs: 28, droppedPerSec: 0.5,
                                                 decodeMs: 2.14))
        XCTAssertEqual(full.compactLine, "smooth 29.8 fps hitch 0.3/s buf 28 ms")
        XCTAssertEqual(full.json["decodeMs"] as? Double, 2.1)
        XCTAssertEqual(full.json["mode"] as? String, "smooth")

        // bad fields are left out, the rest stays
        let partial = try XCTUnwrap(StreamPlayoutReport(json: json(
            #"{"mode":"latency","fps":"30","gapP50Ms":true,"gapP90Ms":-4,"bufferMs":null,"droppedPerSec":[1],"decodeMs":3}"#)))
        XCTAssertEqual(partial, StreamPlayoutReport(mode: "latency", decodeMs: 3))
        XCTAssertEqual(partial.compactLine, "latency")
        // the display's refresh rate and the even pace (later additions), lenient like the rest
        let paced = try XCTUnwrap(StreamPlayoutReport(json: json(#"{"mode":"smooth","fps":30,"refreshHz":60,"paceMs":33.3}"#)))
        XCTAssertEqual(paced.json["paceMs"] as? Double, 33.3)
        XCTAssertEqual(StreamPlayoutReport(json: json(#"{"mode":"smooth","refreshHz":"60","paceMs":-1}"#)), StreamPlayoutReport(mode: "smooth"))
        // the jitter buffer's cap (later still)
        let capped = try XCTUnwrap(StreamPlayoutReport(json: json(#"{"mode":"smooth","bufferMs":32,"bufferCapMs":40}"#)))
        XCTAssertEqual(capped, StreamPlayoutReport(mode: "smooth", bufferMs: 32, bufferCapMs: 40))
        XCTAssertEqual(capped.json["bufferCapMs"] as? Double, 40)
        XCTAssertEqual(StreamPlayoutReport(json: json(#"{"mode":"smooth","bufferCapMs":"40"}"#)), StreamPlayoutReport(mode: "smooth"))
        XCTAssertNil(partial.json["fps"])
        // stalls, jitter and the touch buffer (the automatic mode's additions); `overrides` is not a field any more
        let auto = try XCTUnwrap(StreamPlayoutReport(json: json(#"""
            {"mode":"smooth","fps":59.6,"hitchesPerSec":0.4,"stall150PerSec":0.05,"stall300PerSec":0,"bufferMs":52,
             "jitterP95Ms":47.6,"touchBufferMs":30,"bufferCapMs":100,"overrides":true}
            """#)))
        XCTAssertEqual(auto, StreamPlayoutReport(mode: "smooth", fps: 59.6, hitchesPerSec: 0.4, bufferMs: 52, bufferCapMs: 100,
                                                 stall150PerSec: 0.05, stall300PerSec: 0, jitterP95Ms: 47.6, touchBufferMs: 30,
                                                 ))
        XCTAssertEqual(auto.compactLine, "smooth 59.6 fps hitch 0.4/s stall 0.1/s buf 52 ms jit 48 ms")
        XCTAssertEqual(auto.json["stall150PerSec"] as? Double, 0.1)
        XCTAssertEqual(auto.json["stall300PerSec"] as? Double, 0)
        XCTAssertEqual(auto.json["jitterP95Ms"] as? Double, 47.6)
        XCTAssertEqual(auto.json["touchBufferMs"] as? Double, 30)
        XCTAssertNil(auto.json["overrides"])
        let touch = try XCTUnwrap(StreamPlayoutReport(json: json(
            #"{"mode":"latency","hitchesPerSec":1.2,"stall300PerSec":0.3,"bufferMs":28,"jitterP95Ms":40,"touchBufferMs":28,"overrides":false}"#)))
        XCTAssertEqual(touch.compactLine, "latency hitch 1.2/s buf 28 ms jit 40 ms")
        // bad values are left out
        XCTAssertEqual(StreamPlayoutReport(json: json(
            #"{"mode":"smooth","stall150PerSec":"1","stall300PerSec":-1,"jitterP95Ms":true,"touchBufferMs":null,"overrides":1}"#)),
            StreamPlayoutReport(mode: "smooth"))

        // no report at all: not an object, no / unknown mode
        for bad in [#""smooth""#, "[]", "{}", #"{"mode":"warp"}"#, #"{"mode":1,"fps":30}"#, "null", "3"] {
            XCTAssertNil(StreamPlayoutReport(json: json(bad)), bad)
        }
        XCTAssertNil(StreamPlayoutReport(json: nil))
    }

    func testReportsAreNotLoggedButEndTheStatsLine() {
        final class Clock: @unchecked Sendable { var now: TimeInterval = 100 }
        final class Lines: @unchecked Sendable { var all: [String] = [] }
        let clock = Clock(), lines = Lines()
        let sink = ScreenHost.logSink
        ScreenHost.logSink = { lines.all.append($0) }
        defer { ScreenHost.logSink = sink }
        let flow = StreamFlow(id: "stream-0001", label: "video: display stream stream-0001", controller: StreamFlowController(),
                              clock: { clock.now }, wake: {})
        XCTAssertNil(flow.takePhoneTail(), "no report yet")
        lines.all = []
        for i in 0..<10 {
            clock.now += 2
            flow.received(StreamPlayoutReport(mode: i < 9 ? "smooth" : "latency", fps: 30))
        }
        XCTAssertEqual(lines.all, [], "a report alone is never a log line")
        XCTAssertEqual(flow.playoutReport?.mode, "latency")
        XCTAssertEqual(flow.takePhoneTail(), "phone latency 30.0 fps")
        XCTAssertEqual(flow.takePhoneTail(), "phone latency 30.0 fps", "the latest report stays; no sound: no audio part")
        XCTAssertEqual(flow.label, "video: display stream stream-0001")
        XCTAssertEqual(StreamFlow(id: "abcdefgh", controller: StreamFlowController(), wake: {}).label, "stream abcdefgh")
    }

    func testTheNetGradeIsLoggedWhenItChangesAndAtTheEnd() {
        final class Clock: @unchecked Sendable { var now: TimeInterval = 100 }
        final class Lines: @unchecked Sendable { var all: [String] = [] }
        let clock = Clock(), lines = Lines()
        let sink = ScreenHost.logSink
        ScreenHost.logSink = { lines.all.append($0) }
        defer { ScreenHost.logSink = sink }
        let flow = StreamFlow(id: "stream-0001", label: "s", controller: StreamFlowController(), clock: { clock.now }, wake: {})
        func netLines() -> [String] { lines.all.filter { $0.contains("phone net:") } }
        XCTAssertEqual(flow.netQuality().grade, .unknown)
        XCTAssertEqual(netLines(), [], "unknown at the start: nothing changed")
        flow.received(StreamPlayoutReport(mode: "smooth", net: StreamNetReport(failures: 1)))
        for _ in 0..<5 { clock.now += 1.5; _ = flow.netQuality() }
        XCTAssertEqual(netLines(), ["s phone net: fail 1 → fair (failures, few-samples)"], "unknown → fair: one line")
        flow.received(StreamPlayoutReport(mode: "smooth", net: StreamNetReport(failures: 0)))
        clock.now += 1.5
        _ = flow.netQuality()
        XCTAssertEqual(netLines().count, 2, "fair → unknown")
        XCTAssertTrue(netLines()[1].hasSuffix("→ unknown (few-samples)"), netLines()[1])
        flow.finish()
        XCTAssertEqual(netLines().last, "s ended; last phone net: fail 0 → unknown (few-samples)")
        lines.all = []
        StreamFlow(id: "stream-0002", label: "t", controller: StreamFlowController(), wake: {}).finish()
        XCTAssertEqual(lines.all, [], "no ack ever: no final line")
    }

    func testBitRateLinesOnlyForStepDownsAndCeilings() {
        var c = StreamFlowController()   // 3500 kbps, the ceiling 20000
        XCTAssertTrue(StreamFlow.logsRateChange(c, from: 4000, at: 0), "a step down")
        XCTAssertFalse(StreamFlow.logsRateChange(c, from: 3000, at: 0), "a climb under the ceiling: counted, not logged")
        _ = c.apply(StreamNetProfile.choose(client: StreamNetReport(constrained: true), tuning: c.tuning))  // max 2500
        XCTAssertEqual(c.bitrateKbps, 2500)
        XCTAssertTrue(StreamFlow.logsRateChange(c, from: 2000, at: 0), "a climb that reached the ceiling")
    }
}

/// Network quality (docs/PROTOCOL.md「网络质量」): the client's `report.net` decoded leniently, the grade, the log line.
final class StreamNetQualityTests: XCTestCase {
    private func json(_ text: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(text.utf8)) }
    private func acks(_ ms: [Double]) -> StreamRTTSummary? { StreamRTTSummary(ms: ms) }

    func testDecodesTheClientsReportLeniently() throws {
        let full = try XCTUnwrap(StreamNetReport(json: json(#"""
            {"route":"lan","iface":"cellular","radio":"5g","expensive":true,"constrained":false,
             "inputRttMs":{"p50":12,"p90":30,"n":40},"rxKbps":1600,"failures":2,"extra":1}
            """#)))
        XCTAssertEqual(full, StreamNetReport(route: "lan", iface: "cellular", radio: "5g", expensive: true, constrained: false,
                                             inputRttP50Ms: 12, inputRttP90Ms: 30, inputRttSamples: 40, rxKbps: 1600, failures: 2))
        XCTAssertEqual(StreamNetReport(json: full.json), full)
        // unknown values, wrong types, negatives: left out
        let odd = try XCTUnwrap(StreamNetReport(json: json(#"{"route":"satellite","iface":3,"expensive":"yes","inputRttMs":{"p50":-1,"p90":"x"},"failures":true}"#)))
        XCTAssertEqual(odd, StreamNetReport())
        XCTAssertNil(StreamNetReport(json: "wifi"))
        // inside a playout report; a bad one never loses the report
        let report = try XCTUnwrap(StreamPlayoutReport(json: json(#"{"mode":"smooth","fps":30,"net":"wifi"}"#)))
        XCTAssertNil(report.net)
        XCTAssertEqual(report.fps, 30)
        let withNet = try XCTUnwrap(StreamPlayoutReport(json: json(#"{"mode":"latency","net":{"route":"tunnel"}}"#)))
        XCTAssertEqual(withNet.net, StreamNetReport(route: "tunnel"))
        XCTAssertEqual((withNet.json["net"] as? [String: Any])?["route"] as? String, "tunnel")
    }

    func testRoundTripSummary() throws {
        XCTAssertNil(StreamRTTSummary(ms: []))
        let s = try XCTUnwrap(StreamRTTSummary(ms: [150, 140, 145, 300, 160, 155, 170, 165, 142, 148]))
        XCTAssertEqual(s.minMs, 140)
        XCTAssertEqual(s.p50Ms, 150)
        XCTAssertEqual(s.p90Ms, 170)
        XCTAssertEqual(s.samples, 10)
    }

    func testGrades() {
        let lan = Array(repeating: 10.0, count: 20) + [14, 18]
        XCTAssertEqual(StreamNetQuality.grade(acks: acks(lan), client: nil).grade, .good)
        XCTAssertEqual(StreamNetQuality.grade(acks: acks(lan), client: nil).reasons, [])
        // today's tunnel: min ~140, p90 ~180 → fair on the round trip and the jitter
        let tunnel = (0..<30).map { 140 + Double($0 % 10) * 5 }   // 140…185
        let fair = StreamNetQuality.grade(acks: acks(tunnel), client: StreamNetReport(failures: 0))
        XCTAssertEqual(fair.grade, .fair)
        XCTAssertEqual(fair.reasons, ["rtt", "jitter"])
        XCTAssertEqual(fair.jitterMs, 40)
        // spikes to ~300 → poor on the round trip (p90 past 250) and the jitter (past 80)
        let spiky = (0..<20).map { $0 % 5 == 0 ? 300.0 : 140 }
        let poor = StreamNetQuality.grade(acks: acks(spiky), client: nil)
        XCTAssertEqual(poor.grade, .poor)
        XCTAssertEqual(poor.reasons, ["rtt", "jitter"])
        // failures alone
        XCTAssertEqual(StreamNetQuality.grade(acks: acks(lan), client: StreamNetReport(failures: 1)).reasons, ["failures"])
        XCTAssertEqual(StreamNetQuality.grade(acks: acks(lan), client: StreamNetReport(failures: 3)).grade, .poor)
        // too few ack samples: the client's input round trips, else unknown (failures still count)
        XCTAssertEqual(StreamNetQuality.grade(acks: acks([10, 12]), client: nil).grade, .unknown)
        XCTAssertEqual(StreamNetQuality.grade(acks: acks([10, 12]), client: nil).reasons, ["few-samples"])
        let input = StreamNetReport(inputRttP50Ms: 120, inputRttP90Ms: 160, inputRttSamples: 8)
        let byInput = StreamNetQuality.grade(acks: acks([10, 12]), client: input)
        XCTAssertEqual(byInput.grade, .fair)
        XCTAssertEqual(byInput.reasons, ["rtt", "jitter"])
        XCTAssertNil(byInput.rtt)                       // too few ack round trips: none given…
        XCTAssertTrue(byInput.byInput)                  // …and the log says it went by the input round trips
        XCTAssertEqual(byInput.jitterMs, 40)
        XCTAssertEqual(byInput.line(client: input), "phone net: jitter 40 ms input 120/160 (8) → fair by input (rtt, jitter)")
        XCTAssertNil(StreamNetQuality.grade(acks: acks([10, 12]), client: nil).rtt)   // nor when unknown
        XCTAssertNil(StreamNetQuality.grade(acks: acks([10, 12]), client: nil).json["rttMs"])
        XCTAssertEqual(StreamNetQuality.grade(acks: nil, client: StreamNetReport(inputRttP90Ms: 500, inputRttSamples: 2)).grade, .unknown)
        XCTAssertEqual(StreamNetQuality.grade(acks: nil, client: StreamNetReport(failures: 4)).grade, .poor)
        XCTAssertEqual(StreamNetQuality.grade(acks: nil, client: StreamNetReport(failures: 4)).reasons, ["failures", "few-samples"])
    }

    func testJSONAndLogLine() {
        let tunnel = (0..<30).map { 140 + Double($0 % 10) * 5 }
        let client = StreamNetReport(route: "tunnel", iface: "wifi", inputRttP50Ms: 160, inputRttP90Ms: 190, inputRttSamples: 12,
                                     rxKbps: 1600, failures: 0)
        let q = StreamNetQuality.grade(acks: StreamRTTSummary(ms: tunnel), client: client)
        let j = q.json
        XCTAssertEqual(j["grade"] as? String, "fair")
        XCTAssertEqual(j["reasons"] as? [String], ["rtt", "jitter"])
        XCTAssertEqual(j["jitterMs"] as? Double, 40)
        XCTAssertEqual((j["rttMs"] as? [String: Double])?["p90"], 180)
        XCTAssertEqual(q.line(client: client),
                       "phone net: tunnel wifi rtt 140/160/180 ms jitter 40 ms input 160/190 (12) rx 1.6 Mbps fail 0 → fair (rtt, jitter)")
        XCTAssertEqual(StreamNetQuality.grade(acks: nil, client: nil).line(client: nil), "phone net: → unknown (few-samples)")
    }
}
