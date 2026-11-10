import XCTest
import Darwin
import Foundation
@testable import YoyoServer

// A video stream's request parameters, its part bytes, the cursor part JSON and the ack route.


final class StreamWireTests: XCTestCase {
    private func request(_ q: [String: String]) -> HTTPRequest {
        HTTPRequest(method: "GET", path: "/stream", query: q, headers: [:], body: Data())
    }

    func testRequestOptions() throws {
        // nothing given: a video stream all the same (h264), no id, no acks, the pointer baked in
        XCTAssertEqual(try StreamRequestOptions.parse(request(["fps": "20"])), StreamRequestOptions())
        XCTAssertEqual(try StreamRequestOptions.parse(request(["codecs": ""])), StreamRequestOptions())
        XCTAssertEqual(try StreamRequestOptions.parse(request(["fps": "20"])).codec(), .h264)
        let o = try StreamRequestOptions.parse(request(["codecs": "hevc,h264,vp9", "stream": "abcDEF_12-x", "ack": "1", "cursor": "client"]))
        XCTAssertEqual(o, StreamRequestOptions(codecs: ["hevc", "h264"], streamID: "abcDEF_12-x", ack: true, cursorClient: true))
        XCTAssertThrowsError(try StreamRequestOptions.parse(request(["stream": "short"])))
        XCTAssertThrowsError(try StreamRequestOptions.parse(request(["stream": "has space in it"])))
        XCTAssertThrowsError(try StreamRequestOptions.parse(request(["stream": String(repeating: "a", count: 65)])))
        XCTAssertThrowsError(try StreamRequestOptions.parse(request(["ack": "yes"])))
        XCTAssertThrowsError(try StreamRequestOptions.parse(request(["cursor": "server"])))
        XCTAssertEqual(try StreamRequestOptions.parse(request(["ack": "0", "codecs": "mjpeg"])).ack, false)
        // an unknown token (mjpeg too) is dropped: h264
        XCTAssertEqual(try StreamRequestOptions.parse(request(["codecs": "mjpeg"])).codecs, [])
        // maxKbps (the client's test panel): an integer 100…100000
        XCTAssertEqual(try StreamRequestOptions.parse(request(["codecs": "h264", "maxKbps": "3000"])).maxKbps, 3000)
        XCTAssertEqual(try StreamRequestOptions.parse(request(["codecs": "h264", "maxKbps": "100"])).maxKbps, 100)
        XCTAssertEqual(try StreamRequestOptions.parse(request(["codecs": "h264", "maxKbps": "100000"])).maxKbps, 100_000)
        XCTAssertNil(try StreamRequestOptions.parse(request(["codecs": "h264", "maxKbps": ""])).maxKbps)
        XCTAssertNil(try StreamRequestOptions.parse(request(["codecs": "h264"])).maxKbps)
        XCTAssertEqual(try StreamRequestOptions.parse(request(["maxKbps": "3000"])).maxKbps, 3000)
        for bad in ["99", "100001", "3000.5", "abc", "-3000", "1e4"] {
            XCTAssertThrowsError(try StreamRequestOptions.parse(request(["codecs": "h264", "maxKbps": bad])), bad)
        }
    }

    func testPartBytes() {
        let part = Router.streamPart(contentType: "video/h264", body: Data([0, 0, 0, 1, 0x65]), size: (1600, 1000), seq: 7,
                                     publishedAt: 1_700_000_000_123.4, kind: "delta", codec: "h264")
        XCTAssertEqual(String(decoding: part, as: UTF8.self),
                       "--frame\r\nContent-Type: video/h264\r\nContent-Length: 5\r\nX-Frame-Width: 1600\r\nX-Frame-Height: 1000\r\n"
                       + "X-Frame-Seq: 7\r\nX-Frame-Time: 1700000000123\r\nX-Frame-Kind: delta\r\nX-Stream-Codec: h264\r\n\r\n"
                       + String(decoding: [0, 0, 0, 1, 0x65], as: UTF8.self) + "\r\n")
    }

    func testNames() {
        XCTAssertEqual(StreamWire.current.stream, "application/vnd.yoyo-control.stream; boundary=frame")
        XCTAssertEqual(StreamWire.current.audio, "application/vnd.yoyo-control.audio; boundary=frame")
        XCTAssertFalse(StreamWire.current.stream.hasPrefix("multipart/"), "URLSession would split a multipart/* type")
        let part = Router.streamPart(contentType: StreamWire.current.cursor, body: Data("{}".utf8), size: nil, seq: 8,
                                     publishedAt: nil, kind: "cursor", codec: nil, boundary: StreamWire.current.boundary)
        XCTAssertEqual(String(decoding: part, as: UTF8.self),
                       "--frame\r\nContent-Type: application/vnd.yoyo-control.cursor+json\r\nContent-Length: 2\r\nX-Frame-Seq: 8\r\nX-Frame-Kind: cursor\r\n\r\n{}\r\n")
    }

    func testCursorPartJSON() throws {
        let c = ClientCursor(x: 959.0 / 1918, y: 0, visible: true, shapeId: 0)

        // The built-in arrow: shapeId 0, a PNG, sized like the composited one (26 px per 1600 px of width).
        let shape = try XCTUnwrap(ClientCursorShape.builtinArrow(width: 1600, height: 1000))
        XCTAssertEqual(shape.id, 0)
        XCTAssertEqual([UInt8](shape.png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        let arrow = CursorImage.arrow(visibleHeight: 52)
        XCTAssertEqual(shape.height * 1000 * Double(arrow.visibleHeight) / Double(arrow.height), 26, accuracy: 1.5)
        XCTAssertEqual(shape.hotX, Double(arrow.hotspotX) * (26.0 / 1600) / Double(arrow.visibleHeight), accuracy: 1e-12)
        XCTAssertGreaterThan(shape.width, 0)

        let body = StreamCursorPart.body(c, shape: shape)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["x"] as? Double, c.x)
        XCTAssertEqual(json["y"] as? Double, 0)
        XCTAssertEqual(json["visible"] as? Bool, true)
        XCTAssertEqual(json["shapeId"] as? Int, 0)
        let s = try XCTUnwrap(json["shape"] as? [String: Any])
        XCTAssertEqual(Set(s.keys), ["id", "png", "hotX", "hotY", "width", "height"])
        XCTAssertNotNil(Data(base64Encoded: try XCTUnwrap(s["png"] as? String)))
        // Without a shape change: no shape.
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: StreamCursorPart.body(c, shape: nil)) as? [String: Any])
        XCTAssertNil(plain["shape"])
    }

    func testAckRoute() throws {
        func post(_ body: String) -> (Int, String) {
            var fds = [Int32](repeating: 0, count: 2)
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
            defer { close(fds[1]) }
            let conn = Connection(fd: fds[0])
            do {
                try Router.handle(HTTPRequest(method: "POST", path: "/stream/ack", query: [:], headers: [:], body: Data(body.utf8)), conn)
            } catch let e as HTTPError {
                conn.error(e)
            } catch {
                XCTFail("\(error)")
            }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(fds[1], &buf, buf.count)
            let text = String(decoding: buf[0..<max(n, 0)], as: UTF8.self)
            let status = Int(text.split(separator: " ")[1]) ?? 0
            return (status, text)
        }
        XCTAssertEqual(post("nope").0, 400)
        XCTAssertEqual(post(#"{"stream":"short","seq":1}"#).0, 400)
        XCTAssertEqual(post(#"{"stream":"stream-0001","seq":-1}"#).0, 400)
        XCTAssertEqual(post(#"{"stream":"stream-0001","seq":1.5}"#).0, 400)
        XCTAssertEqual(post(#"{"stream":"stream-0001","seq":true}"#).0, 400)
        XCTAssertEqual(post(#"{"stream":"stream-0001","seq":1,"keyframe":"yes"}"#).0, 400)
        XCTAssertEqual(post(#"{"stream":"stream-0001","seq":1}"#).0, 404)

        let woke = expectation(description: "woken")
        woke.assertForOverFulfill = false   // the acks with reports below wake it again
        let flow = StreamFlow(id: "stream-0001", controller: StreamFlowController(), wake: { woke.fulfill() })
        StreamFlowRegistry.register(flow)
        defer { StreamFlowRegistry.unregister(flow) }
        flow.with { $0.pictureSent(seq: 1, at: StreamClock.now()) }
        func body(_ text: String) -> [String: Any]? {
            guard let r = text.range(of: "\r\n\r\n") else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(text[r.upperBound...].utf8))) as? [String: Any]
        }
        let (status, text) = post(#"{"stream":"stream-0001","seq":1,"keyframe":true}"#)
        XCTAssertEqual(status, 200)
        // the answer carries the stream's network grade: one round trip so far → unknown
        let answer = try XCTUnwrap(body(text))
        XCTAssertEqual(answer["ok"] as? Bool, true)
        let net = try XCTUnwrap(answer["net"] as? [String: Any])
        XCTAssertEqual(net["grade"] as? String, "unknown")
        XCTAssertEqual(net["reasons"] as? [String], ["few-samples"])
        wait(for: [woke], timeout: 1)
        XCTAssertTrue(flow.with { $0.active })
        XCTAssertEqual(flow.with { $0.keyRequests }, 1)
        XCTAssertEqual(flow.with { $0.inFlight }, 0)
        // A playout report rides along: logged; a bad one is ignored and never fails the ack.
        XCTAssertEqual(post(#"{"stream":"stream-0001","seq":1,"report":{"mode":"smooth","fps":29.8,"bufferMs":28}}"#).0, 200)
        XCTAssertEqual(flow.playoutReport, StreamPlayoutReport(mode: "smooth", fps: 29.8, bufferMs: 28))
        XCTAssertEqual(post(#"{"stream":"stream-0001","seq":1,"report":"smooth"}"#).0, 200)
        XCTAssertEqual(post(#"{"stream":"stream-0001","seq":1,"report":{"mode":"warp","fps":1}}"#).0, 200)
        XCTAssertEqual(flow.playoutReport?.fps, 29.8)
        // The client's network rides in the report; with no ack round trips yet, its input round trips grade it.
        Thread.sleep(forTimeInterval: StreamFlow.qualityInterval + 0.05)   // past the cached grade
        let netAck = post(#"{"stream":"stream-0001","seq":1,"report":{"mode":"smooth","net":{"route":"tunnel","iface":"wifi","inputRttMs":{"p50":20,"p90":40,"n":9},"failures":0}}}"#)
        XCTAssertEqual(netAck.0, 200)
        XCTAssertEqual(flow.clientNetReport, StreamNetReport(route: "tunnel", iface: "wifi", inputRttP50Ms: 20, inputRttP90Ms: 40,
                                                             inputRttSamples: 9, failures: 0))
        let graded = try XCTUnwrap(body(netAck.1)?["net"] as? [String: Any])
        XCTAssertEqual(graded["grade"] as? String, "good")
        XCTAssertEqual(graded["reasons"] as? [String], [])
        XCTAssertEqual(flow.lastNetQuality?.grade, .good)
        // A newer stream with the same id replaces it; the old one unregistering doesn't remove the new one.
        let newer = StreamFlow(id: "stream-0001", controller: StreamFlowController(), wake: {})
        StreamFlowRegistry.register(newer)
        StreamFlowRegistry.unregister(flow)
        XCTAssertTrue(StreamFlowRegistry.lookup("stream-0001") === newer)
        StreamFlowRegistry.unregister(newer)
        XCTAssertNil(StreamFlowRegistry.lookup("stream-0001"))
    }
}
