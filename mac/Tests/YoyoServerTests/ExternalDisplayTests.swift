import XCTest
import CoreVideo
import Darwin
import Foundation
@testable import YoyoServer

// External displays (ExternalDisplay.swift): an embedder's pictures listed, streamed and served as stills like a
// display's, without Screen Recording or a GUI session.
final class ExternalDisplayTests: XCTestCase {
    private func request(_ path: String, _ query: [String: String]) -> HTTPRequest {
        HTTPRequest(method: "GET", path: path, query: query, headers: [:], body: Data())
    }

    func testListedOnceItHasAPictureAndGoneWhenRemoved() throws {
        let d = ExternalDisplay(id: 4_000_000_101, name: "Phone", kind: "simulator", scale: 3)
        XCTAssertTrue(ExternalDisplays.add(d))
        defer { ExternalDisplays.remove(id: d.id) }
        XCTAssertFalse(ExternalDisplays.add(ExternalDisplay(id: d.id)), "an id is one display's")
        XCTAssertTrue(ExternalDisplays.json.isEmpty, "no picture yet: not listed")
        XCTAssertThrowsError(try d.source(maxWidth: 1280)) { XCTAssertEqual(($0 as? HTTPError)?.status, 503) }

        d.publish(fakeDesktopPicture(0, width: 600, height: 1200))
        let entry = try XCTUnwrap(ExternalDisplays.json.first)
        XCTAssertEqual(entry["id"] as? Int, 4_000_000_101)
        XCTAssertEqual(entry["width"] as? Double, 200)
        XCTAssertEqual(entry["height"] as? Double, 400)
        XCTAssertEqual(entry["scale"] as? Double, 3)
        XCTAssertEqual(entry["kind"] as? String, "simulator")
        XCTAssertEqual(entry["name"] as? String, "Phone")
        XCTAssertEqual(entry["main"] as? Bool, false)
        XCTAssertNotNil(try ExternalDisplays.requested(request("/stream", ["display": "4000000101"])))
        XCTAssertNil(try ExternalDisplays.requested(request("/stream", [:])), "no display named: WindowServer's main")

        ExternalDisplays.remove(id: d.id)
        XCTAssertNil(ExternalDisplays.find(4_000_000_101))
        XCTAssertTrue(ExternalDisplays.json.isEmpty)
    }

    func testStill() throws {
        let d = ExternalDisplay(id: 4_000_000_102)
        d.publish(fakeDesktopPicture(0, width: 600, height: 1200))
        let small = try Router.frameExternal(request("/frame", ["display": "4000000102", "maxWidth": "300"]), d)
        XCTAssertEqual(small.width, 300)
        XCTAssertEqual(small.height, 600)
        XCTAssertEqual(small.display, 4_000_000_102)
        XCTAssertEqual(small.data.prefix(2), Data([0xFF, 0xD8]))
        let full = try Router.frameExternal(request("/frame", ["display": "4000000102", "maxWidth": "3000"]), d)
        XCTAssertEqual(full.width, 600, "never larger than the display")
        XCTAssertThrowsError(try Router.frameExternal(request("/frame", ["display": "4000000102", "visible": "all"]), d)) {
            XCTAssertEqual(($0 as? HTTPError)?.status, 400)
        }
    }

    /// `GET /stream?display=<id>&status=1`: the head, one `ready` status part, a key frame at the asked width, a delta
    /// when the picture changes, and the end when the display is removed.
    func testStream() throws {
        try XCTSkipUnless(VideoEncoder.isAvailable(.h264))
        let d = ExternalDisplay(id: 4_000_000_103)
        XCTAssertTrue(ExternalDisplays.add(d))
        defer { ExternalDisplays.remove(id: d.id) }
        let live = fakeDesktopPicture(0, width: 600, height: 1200)
        d.publish(live)

        var pair = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let serverFD = pair[0]
        let done = DispatchSemaphore(value: 0)
        let req = request("/stream", ["display": "4000000103", "maxWidth": "300", "fps": "30", "status": "1"])
        Thread.detachNewThread {
            try? Router.stream(req, Connection(fd: serverFD))
            close(serverFD)
            done.signal()
        }
        defer { close(pair[1]) }
        let reader = StreamPartReader(fd: pair[1])
        let head = try XCTUnwrap(reader.head())
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(head.lowercased().contains("x-display: 4000000103"))

        let status = try XCTUnwrap(reader.part())
        XCTAssertEqual(status.kind, "status")
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: status.body) as? [String: Any])
        XCTAssertEqual(state["phase"] as? String, "ready")
        XCTAssertEqual(state["display"] as? Int, 4_000_000_103)

        let dec = AnnexBDecoder(codec: .h264)
        let key = try XCTUnwrap(reader.picture())
        XCTAssertEqual(key.kind, "key")
        XCTAssertEqual(key.headers["x-frame-width"], "300")
        XCTAssertEqual(key.headers["x-frame-height"], "600")
        XCTAssertNotNil(dec.decode(key.body))

        // the live surface is drawn into: the next picture is the new content
        paintDesktop(live, scroll: 40)
        d.changed()
        var delta: StreamPartReader.Part?
        while let p = reader.picture() {
            if p.kind == "delta" { delta = p; break }
        }
        XCTAssertNotNil(dec.decode(try XCTUnwrap(delta).body))
        XCTAssertEqual(dec.errors, 0)

        ExternalDisplays.remove(id: d.id)
        XCTAssertEqual(done.wait(timeout: .now() + 3), .success, "the stream ends with its display")
    }
}
