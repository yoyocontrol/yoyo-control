import CoreTelephony
import Foundation
import Testing
@testable import YoyoClipboard
@testable import YoyoCore
@testable import YoyoDirect
@testable import YoyoScreen

/// Network quality (PROTOCOL.md「屏幕」的「网络质量」): the phone's `net` in the playout report, the sampler behind it,
/// and the server's grade in the ack answer.
@Suite("Screen network quality")
struct ScreenNetTests {
    // MARK: The report

    private static func roundTrip(_ d: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: d)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func anEmptyReportSaysNothing() throws {
        #expect(ScreenNetReport().json.isEmpty)
        // nor does the playout report carry an empty one
        let report = ScreenPlayoutReport(mode: .smooth, fps: 30, net: ScreenNetReport())
        #expect(report.json["net"] == nil)
        #expect(ScreenPlayoutReport(mode: .smooth).json["net"] == nil)
    }

    @Test func onlyTheFieldsSetAreEncoded() throws {
        let net = ScreenNetReport(route: .tunnel, iface: .cellular, radio: .fiveG, expensive: true, constrained: false,
                                  inputRttMs: .init(p50: 160.04, p90: 190.06, n: 12), rxKbps: 1612.4, failures: 1)
        let d = try Self.roundTrip(ScreenPlayoutReport(mode: .smooth, net: net).json)
        let n = try #require(d["net"] as? [String: Any])
        #expect(n["route"] as? String == "tunnel" && n["iface"] as? String == "cellular" && n["radio"] as? String == "5g")
        #expect(n["expensive"] as? Bool == true && n["constrained"] as? Bool == false)
        let rtt = try #require(n["inputRttMs"] as? [String: Any])
        #expect(rtt["p50"] as? Double == 160 && rtt["p90"] as? Double == 190.1 && rtt["n"] as? Int == 12)
        #expect(n["rxKbps"] as? Double == 1612 && n["failures"] as? Int == 1)

        let few = try Self.roundTrip(ScreenNetReport(route: .lan, iface: .wired).json)
        #expect(Set(few.keys) == ["route", "iface"])
        #expect(few["iface"] as? String == "wired")
    }

    @Test func numbersThatArentFiniteOrAreNegativeAreLeftOut() throws {
        let net = ScreenNetReport(inputRttMs: .init(p50: .nan, p90: .infinity, n: -1), rxKbps: -5, failures: -1)
        #expect(net.json.isEmpty)
        let partly = try Self.roundTrip(ScreenNetReport(inputRttMs: .init(p50: 40, p90: .nan, n: 3), rxKbps: .nan).json)
        #expect(Set(partly.keys) == ["inputRttMs"])
        #expect(Set((partly["inputRttMs"] as? [String: Any] ?? [:]).keys) == ["p50", "n"])
        // the whole ack still serializes
        _ = try JSONSerialization.data(withJSONObject: ScreenStreamAck(stream: "s1", seq: 1, report:
            ScreenPlayoutReport(mode: .latency, net: ScreenNetReport(rxKbps: .infinity, failures: 0))).json)
    }

    // MARK: The ack answer

    private static func quality(_ json: String) -> ScreenNetQuality? { ScreenNetQuality(ackResponse: Data(json.utf8)) }

    @Test func anOlderServersAnswerHasNoGrade() {
        #expect(Self.quality(#"{"ok":true}"#) == nil)
        #expect(Self.quality(#"{"ok":true,"net":null}"#) == nil)
        #expect(Self.quality(#"{"ok":true,"net":"good"}"#) == nil)
        #expect(Self.quality(#"{"ok":true,"net":[1,2]}"#) == nil)
        #expect(Self.quality("") == nil)
        #expect(Self.quality("not json") == nil)
        #expect(Self.quality("[]") == nil)
        #expect(ScreenNetQuality(ackResponse: nil) == nil)
    }

    @Test func aFullAnswer() throws {
        let q = try #require(Self.quality(#"""
            {"ok":true,"net":{"grade":"fair","rttMs":{"min":137,"p50":165.4,"p90":210},"jitterMs":73,"reasons":["rtt","jitter"]}}
            """#))
        #expect(q.grade == .fair)
        #expect(q.rttMs == .init(min: 137, p50: 165.4, p90: 210))
        #expect(q.jitterMs == 73)
        #expect(q.reasons == [.rtt, .jitter])
        #expect(q.line == "net fair (rtt, jitter) · rtt 165/210 · jitter 73")
        let good = try #require(Self.quality(#"{"ok":true,"net":{"grade":"good","rttMs":{"min":30,"p50":35,"p90":41},"jitterMs":11,"reasons":[]}}"#))
        #expect(good.line == "net good · rtt 35/41 · jitter 11")
    }

    @Test func unknownGradesAndReasons() throws {
        let q = try #require(Self.quality(#"{"ok":true,"net":{"grade":"stellar","reasons":["few-samples","loss",7,null,""]}}"#))
        #expect(q.grade == .unknown)
        // unknown codes are kept as they came; what isn't a string is dropped
        #expect(q.reasons == [.fewSamples, ScreenNetQuality.Reason(rawValue: "loss")])
        #expect(q.rttMs == nil && q.jitterMs == nil)
        #expect(q.line == "net unknown (few-samples, loss)")
        // a missing grade is unknown too
        #expect(Self.quality(#"{"net":{}}"#) == ScreenNetQuality(grade: .unknown))
        #expect(Self.quality(#"{"net":{"grade":3,"reasons":"rtt"}}"#) == ScreenNetQuality(grade: .unknown))
    }

    @Test func garbageNumbersAreDropped() throws {
        let q = try #require(Self.quality(#"""
            {"net":{"grade":"poor","rttMs":{"min":-1,"p50":"165","p90":true},"jitterMs":-3,"reasons":["failures"]}}
            """#))
        #expect(q.grade == .poor && q.reasons == [.failures])
        #expect(q.rttMs == nil && q.jitterMs == nil)
        let partly = try #require(Self.quality(#"{"net":{"grade":"poor","rttMs":{"p90":300},"jitterMs":"73"}}"#))
        #expect(partly.rttMs == .init(min: nil, p50: nil, p90: 300))
        #expect(partly.jitterMs == nil)
        #expect(partly.line == "net poor · rtt -/300")
        // not an object
        #expect(Self.quality(#"{"net":{"grade":"good","rttMs":[1,2,3]}}"#)?.rttMs == nil)
    }

    @Test func reasonsAreBounded() throws {
        let many = (0..<20).map { "\"r\($0)\"" }.joined(separator: ",")
        let long = String(repeating: "x", count: 40)
        let q = try #require(Self.quality(#"{"net":{"grade":"poor","reasons":["\#(long)",\#(many)]}}"#))
        #expect(q.reasons.count == ScreenNetQuality.maxReasons)
        #expect(q.reasons.first?.rawValue == "r0")
    }

    @Test func onlyASuccessfulAckIsRead() {
        let body = Data(#"{"ok":true,"net":{"grade":"good","reasons":[]}}"#.utf8)
        #expect(ScreenStream.Reply(status: 200, body: body).netQuality?.grade == .good)
        #expect(ScreenStream.Reply(status: 404, body: body).netQuality == nil)
        #expect(ScreenStream.Reply(status: 200, body: Data(#"{"ok":true}"#.utf8)).netQuality == nil)
        #expect(ScreenStream.Reply(error: URLError(.timedOut)).netQuality == nil)
        // and only one that failed on the way is a failure
        #expect(ScreenStream.Reply(error: URLError(.timedOut)).isNetworkFailure)
        #expect(!ScreenStream.Reply(error: URLError(.cancelled)).isNetworkFailure)
        #expect(!ScreenStream.Reply(status: 409).isNetworkFailure)
        #expect(!ScreenStream.Reply().isNetworkFailure)
        // a proxy or CDN on the way couldn't reach the Mac; not the Mac's own answers (its 503: no screen)
        for code in [502, 504, 520, 523, 527, 530] { #expect(ScreenStream.Reply(status: code).isNetworkFailure) }
        for code in [500, 501, 503, 528, 529] { #expect(!ScreenStream.Reply(status: code).isNetworkFailure) }
        #expect(!ScreenNetSampler.isNetworkFailure(YoyoError.http(503, "no screen")))
        #expect(ScreenNetSampler.isNetworkFailure(YoyoError.http(502, nil)))
        #expect(!ScreenNetSampler.isNetworkFailure(YoyoError.http(409, nil)))
    }

    @Test func theBackendSaysWhatElseMeansTheWayIsDown() {
        // a backend whose relay answers 503 with a reason of its own when the computer isn't connected
        ScreenNetSampler.setUnreachable { status, message in
            YoyoRoute.isUnreachable(status: status) || (status == 503 && message == "computer offline")
        }
        defer { ScreenNetSampler.setUnreachable { status, _ in YoyoRoute.isUnreachable(status: status) } }
        #expect(ScreenNetSampler.isNetworkFailure(YoyoError.http(503, "computer offline")))
        #expect(!ScreenNetSampler.isNetworkFailure(YoyoError.http(503, "no screen")))
        #expect(ScreenStream.Reply(status: 503, body: Data(#"{"error":"computer offline"}"#.utf8)).isNetworkFailure)
        #expect(!ScreenStream.Reply(status: 503, body: Data(#"{"error":"no screen"}"#.utf8)).isNetworkFailure)
    }

    // MARK: The sampler

    @Test func roundTripsOfTheLastTenSeconds() throws {
        var s = ScreenNetSampler()
        s.setRoute(.tunnel)
        for (i, ms) in [100.0, 120, 140, 160, 180, 200, 220, 240, 260, 280].enumerated() {
            s.inputAnswered(route: .tunnel, ms: ms, at: 100 + Double(i))
        }
        var r = try #require(s.report(at: 109.5))
        #expect(r.route == .tunnel)
        // nearest rank: p50 of 10 = the 5th, p90 = the 9th
        #expect(r.inputRttMs == .init(p50: 180, p90: 260, n: 10))
        // the first three fall out of the window
        r = try #require(s.report(at: 112.5))
        #expect(r.inputRttMs?.n == 7)
        #expect(r.inputRttMs?.p50 == 220)
        // nothing left: no round trips at all
        #expect(s.report(at: 125)?.inputRttMs == nil)
    }

    @Test func roundTripsAreOfTheCurrentRouteOnly() {
        var s = ScreenNetSampler()
        s.setRoute(.lan)
        s.inputAnswered(route: .lan, ms: 20, at: 100)
        // an input the tunnel answered after the LAN failed isn't the LAN's round trip
        s.inputAnswered(route: .tunnel, ms: 150, at: 100.5)
        #expect(s.report(at: 101)?.inputRttMs == .init(p50: 20, p90: 20, n: 1))
        // the same route again keeps them
        s.setRoute(.lan)
        #expect(s.report(at: 101)?.inputRttMs?.n == 1)
        // another route starts over
        s.setRoute(.tunnel)
        #expect(s.report(at: 101)?.inputRttMs == nil)
        #expect(s.report(at: 101)?.route == .tunnel)
        s.inputAnswered(route: .tunnel, ms: 150, at: 101.5)
        #expect(s.report(at: 102)?.inputRttMs?.p90 == 150)
        // no route yet: nothing is kept
        var none = ScreenNetSampler()
        none.inputAnswered(route: .tunnel, ms: 40, at: 1)
        #expect(none.report(at: 2) == nil)
        // garbage times are dropped
        s.inputAnswered(route: .tunnel, ms: .nan, at: 102)
        s.inputAnswered(route: .tunnel, ms: -4, at: 102)
        #expect(s.report(at: 102.5)?.inputRttMs?.n == 1)
    }

    @Test func failuresOfTheLastTenSeconds() {
        var s = ScreenNetSampler()
        s.setRoute(.tunnel)
        #expect(s.report(at: 100)?.failures == 0)
        s.failed(at: 100)
        s.failed(at: 104)
        s.failed(at: 108)
        #expect(s.report(at: 109)?.failures == 3)
        #expect(s.report(at: 111)?.failures == 2)
        // a route change doesn't forget them (they are about the network)
        s.setRoute(.lan)
        #expect(s.report(at: 111)?.failures == 2)
        #expect(s.report(at: 119)?.failures == 0)
    }

    @Test func failureClassification() {
        #expect(ScreenNetSampler.isNetworkFailure(URLError(.timedOut)))
        #expect(ScreenNetSampler.isNetworkFailure(URLError(.notConnectedToInternet)))
        #expect(ScreenNetSampler.isNetworkFailure(URLError(.networkConnectionLost)))
        #expect(ScreenNetSampler.isNetworkFailure(URLError(.cannotConnectToHost)))
        #expect(ScreenNetSampler.isNetworkFailure(URLError(.secureConnectionFailed)))
        #expect(ScreenNetSampler.isNetworkFailure(YoyoError.http(502, nil)))
        #expect(ScreenNetSampler.isNetworkFailure(YoyoError.http(504, nil)))
        // answers, cancellations and the rest aren't
        #expect(!ScreenNetSampler.isNetworkFailure(URLError(.cancelled)))
        #expect(!ScreenNetSampler.isNetworkFailure(CancellationError()))
        for code in [400, 401, 403, 404, 409, 413, 500, 503] {
            #expect(!ScreenNetSampler.isNetworkFailure(YoyoError.http(code, nil)))
        }
        #expect(!ScreenNetSampler.isNetworkFailure(YoyoError.unauthorized))
        #expect(!ScreenNetSampler.isNetworkFailure(YoyoError.decoding("x")))
        // an ack: status or error
        #expect(ScreenNetSampler.isNetworkFailure(status: nil, error: URLError(.timedOut)))
        #expect(ScreenNetSampler.isNetworkFailure(status: 502, error: nil))
        #expect(!ScreenNetSampler.isNetworkFailure(status: 200, error: nil))
        #expect(!ScreenNetSampler.isNetworkFailure(status: 404, error: nil))
        // no stream to send on: not the network
        #expect(!ScreenNetSampler.isNetworkFailure(status: nil, error: nil))
    }

    @Test func bytesOverTheReportsWindow() throws {
        var s = ScreenNetSampler()
        s.setRoute(.lan)
        s.streamStarted(at: 100)
        // 1 s in: 25 000 bytes over one second = 200 kbit/s
        for i in 0..<10 { s.received(bytes: 2_500, at: 100 + Double(i) * 0.1) }
        #expect(try #require(s.report(at: 101)?.rxKbps) == 200)
        // the first half second counts as half a second at least
        var early = ScreenNetSampler()
        early.streamStarted(at: 100)
        early.received(bytes: 1_000, at: 100.1)
        #expect(early.report(at: 100.1)?.rxKbps == 16)
        // after 3 s the window slides: 4 s in, only the last 3 s count (here, nothing)
        #expect(s.report(at: 104)?.rxKbps == 0)
        s.received(bytes: 37_500, at: 104.5)
        #expect(s.report(at: 105)?.rxKbps == 100)
        // a new stream starts over
        s.streamStarted(at: 106)
        #expect(s.report(at: 106.5)?.rxKbps == 0)
    }

    @Test func thePathRidesTheReport() {
        var s = ScreenNetSampler()
        s.path = .init(iface: .cellular, radio: .lte, expensive: true, constrained: true)
        let r = s.report(at: 1)
        #expect(r == ScreenNetReport(iface: .cellular, radio: .lte, expensive: true, constrained: true, failures: 0))
        // a radio off cellular isn't reported
        s.path = .init(iface: .wifi, radio: .lte, expensive: false, constrained: false)
        #expect(s.report(at: 1)?.radio == nil)
    }

    @Test func theStatsCarryTheSamplerAndTheGrade() throws {
        let stats = ScreenStreamStats()
        stats.streamStarted(mode: .smooth, route: .tunnel, at: 100)
        stats.netPath(.init(iface: .wifi, expensive: false, constrained: false))
        stats.inputAnswered(route: .tunnel, ms: 140, at: 100.2)
        stats.requestFailed(at: 100.3)
        stats.received(bytes: 12_500, at: 100.4)
        stats.shown(decodeMs: 1, at: 100.5)
        let report = try #require(stats.takeReport(at: 102.1))
        let net = try #require(report.net)
        #expect(net.route == .tunnel && net.iface == .wifi && net.failures == 1)
        #expect(net.inputRttMs == .init(p50: 140, p90: 140, n: 1))
        #expect(try #require(net.rxKbps) > 0)
        #expect(stats.take(host: 102.2).net == nil)
        stats.netQuality(ScreenNetQuality(grade: .fair, reasons: [.rtt]))
        #expect(stats.take(host: 102.3).net?.grade == .fair)
        // a new stream on another route: the grade and the round trips start over
        stats.streamStarted(mode: .smooth, route: .lan, at: 103)
        #expect(stats.take(host: 103.1).net == nil)
        #expect(stats.netReport(at: 103.2)?.inputRttMs == nil)
        #expect(stats.netReport(at: 103.2)?.failures == 1)
    }

    // MARK: Radio

    @Test func radioMapping() {
        #expect(ScreenNetPath.radio(CTRadioAccessTechnologyNR) == .fiveG)
        #expect(ScreenNetPath.radio(CTRadioAccessTechnologyNRNSA) == .fiveG)
        #expect(ScreenNetPath.radio(CTRadioAccessTechnologyLTE) == .lte)
        for tech in [CTRadioAccessTechnologyWCDMA, CTRadioAccessTechnologyHSDPA, CTRadioAccessTechnologyHSUPA,
                     CTRadioAccessTechnologyCDMAEVDORev0, CTRadioAccessTechnologyCDMAEVDORevA,
                     CTRadioAccessTechnologyCDMAEVDORevB, CTRadioAccessTechnologyeHRPD] {
            #expect(ScreenNetPath.radio(tech) == .threeG)
        }
        for tech in [CTRadioAccessTechnologyGPRS, CTRadioAccessTechnologyEdge, CTRadioAccessTechnologyCDMA1x, "CTRadioAccessTechnology6G"] {
            #expect(ScreenNetPath.radio(tech) == .other)
        }
        #expect(ScreenNetPath.radio(nil) == nil)
        #expect(ScreenNetPath.radio("") == nil)
        #expect(ScreenNetReport.Radio.fiveG.rawValue == "5g" && ScreenNetReport.Radio.threeG.rawValue == "3g")
    }
}
