import XCTest
@testable import YoyoServer

/// The phone's `report.audio` (StreamAudioReport.swift): lenient decoding, the stats line's part, the window per
/// stats line.
final class StreamAudioReportTests: XCTestCase {
    private func json(_ text: String) -> Any? { try? JSONSerialization.jsonObject(with: Data(text.utf8)) }

    func testDecodesLenientlyAndClamps() throws {
        let r = try XCTUnwrap(StreamAudioReport(json: json(#"""
        {"outputMs":12.4,"ioMs":10,"bluetooth":false,"depthMs":40,"bufferedMs":52,"addedMs":118,"skewMs":-8,"floorMs":0,
         "underruns":0,"late":2,"concealed":3,"cuts":1,"stretchMs":-12,"kbps":64.2,"futureField":7}
        """#)))
        XCTAssertEqual(r, StreamAudioReport(outputMs: 12.4, ioMs: 10, bluetooth: false, depthMs: 40, bufferedMs: 52, addedMs: 118,
                                            skewMs: -8, floorMs: 0, underruns: 0, late: 2, concealed: 3, cuts: 1, stretchMs: -12, kbps: 64.2))
        let odd = try XCTUnwrap(StreamAudioReport(json: json(#"{"outputMs":-5,"ioMs":"10","bluetooth":1,"skewMs":-9000,"cuts":2.6,"kbps":1e9,"stretchMs":true}"#)))
        XCTAssertEqual(odd, StreamAudioReport(outputMs: 0, skewMs: -3000, cuts: 3, kbps: 100_000))
        XCTAssertEqual(StreamAudioReport(json: json("{}")), StreamAudioReport())
        XCTAssertNil(StreamAudioReport(json: json("[1]")))
        XCTAssertNil(StreamAudioReport(json: nil))
        // inside the playout report; a bad `audio` doesn't spoil the report
        let p = try XCTUnwrap(StreamPlayoutReport(json: json(#"{"mode":"smooth","fps":30,"audio":{"kbps":64}}"#)))
        XCTAssertEqual(p.audio, StreamAudioReport(kbps: 64))
        XCTAssertEqual((p.json["audio"] as? [String: Any])?["kbps"] as? Double, 64)
        XCTAssertNil(try XCTUnwrap(StreamPlayoutReport(json: json(#"{"mode":"smooth","audio":"loud"}"#))).audio)
    }

    func testCompactLine() {
        let r = StreamAudioReport(outputMs: 12, ioMs: 10, depthMs: 40, bufferedMs: 52, addedMs: 118, skewMs: 8, underruns: 0, late: 0,
                                  concealed: 0, cuts: 1, kbps: 64)
        XCTAssertEqual(r.compactLine, "delay 118 ms (buffer 40 output 22) underruns 0")
        let bt = StreamAudioReport(outputMs: 160.4, ioMs: 10, bluetooth: true, depthMs: 120, addedMs: 279, underruns: 0)
        XCTAssertEqual(bt.compactLine, "delay 279 ms (buffer 120 output 170 bluetooth) underruns 0")
        XCTAssertEqual(StreamAudioReport(addedMs: 118).compactLine, "delay 118 ms")
        XCTAssertEqual(StreamAudioReport().compactLine, "-")
        XCTAssertEqual(StreamAudioReport(underruns: 3).compactLine, "underruns 3")
    }

    func testMergeSumsCountsKeepsTheLatestLevels() {
        let a = StreamAudioReport(outputMs: 12, bufferedMs: 50, underruns: 1, late: 2, cuts: nil, stretchMs: 5, kbps: 60)
        let b = StreamAudioReport(outputMs: 14, bufferedMs: 40, underruns: 0, late: 1, cuts: 1, stretchMs: -2, kbps: 70)
        let m = a.merged(with: b)
        XCTAssertEqual(m, StreamAudioReport(outputMs: 14, bufferedMs: 40, underruns: 1, late: 3, concealed: nil, cuts: 1, stretchMs: 3, kbps: 70))
    }

    func testTheStatsTailSumsTheWindowsSound() {
        final class Clock: @unchecked Sendable { var now: TimeInterval = 100 }
        final class Lines: @unchecked Sendable { var all: [String] = [] }
        let clock = Clock(), lines = Lines()
        let sink = ScreenHost.logSink
        ScreenHost.logSink = { lines.all.append($0) }
        defer { ScreenHost.logSink = sink }
        let flow = StreamFlow(id: "stream-0001", label: "video: display stream stream-0001", controller: StreamFlowController(),
                              clock: { clock.now }, wake: {})
        func report(_ underruns: Int) {
            flow.received(StreamPlayoutReport(mode: "smooth", audio: StreamAudioReport(addedMs: 118, underruns: underruns)))
        }
        lines.all = []
        for _ in 0..<5 { clock.now += 2; report(1) }
        report(2)
        XCTAssertFalse(lines.all.contains { $0.contains("audio") }, "no separate phone audio line")
        XCTAssertEqual(flow.takePhoneTail(), "phone smooth; audio delay 118 ms underruns 7", "the window's counts summed")
        flow.received(StreamPlayoutReport(mode: "smooth"))  // no audio: the next window has none
        XCTAssertEqual(flow.takePhoneTail(), "phone smooth")
        report(0)
        XCTAssertEqual(flow.takePhoneTail(), "phone smooth; audio delay 118 ms underruns 0")
        XCTAssertEqual(flow.playoutReport?.audio, StreamAudioReport(addedMs: 118, underruns: 0))
    }
}
