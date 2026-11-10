import XCTest
import Foundation
@testable import YoyoServer

// Codec negotiation (`/stream?codecs=`: h264 / hevc, the client's order) and the frame-rate clamp.

final class StreamCodecNegotiationTests: XCTestCase {
    private let all: (VideoCodec) -> Bool = { _ in true }
    private let both: Set<VideoCodec> = [.h264, .hevc]

    private func choose(_ client: [String], _ allowed: Set<VideoCodec>? = nil,
                        _ available: ((VideoCodec) -> Bool)? = nil) throws -> VideoCodec {
        try StreamCodecs.choose(client: client, allowed: allowed ?? both, available: available ?? all)
    }

    private func status(_ body: () throws -> VideoCodec) -> Int? {
        do { _ = try body(); return nil } catch { return (error as? HTTPError)?.status }
    }

    func testTheClientsOrderAmongVideoCodecs() throws {
        XCTAssertEqual(StreamCodecs.parse("hevc, H264,mjpeg,av1,h264"), ["hevc", "h264"])
        XCTAssertEqual(StreamCodecs.parse("mjpeg"), [])
        XCTAssertEqual(StreamCodecs.parse(nil), [])
        XCTAssertEqual(try choose(["hevc", "h264"]), .hevc)
        XCTAssertEqual(try choose(["h264", "hevc"]), .h264)
        XCTAssertEqual(try choose(["hevc"]), .hevc)
        // No list (or only unknown tokens): h264.
        XCTAssertEqual(try choose([]), .h264)
    }

    func testNotAllowedOrNotEncodableFallsBackToAnotherVideoCodec() throws {
        XCTAssertEqual(try choose(["hevc", "h264"], [.h264]), .h264)
        XCTAssertEqual(try choose(["hevc"], [.h264]), .h264)
        XCTAssertEqual(try choose(["h264"], [.hevc]), .hevc)
        XCTAssertEqual(try choose(["hevc", "h264"], both, { $0 == .h264 }), .h264)
        XCTAssertEqual(try choose(["h264", "hevc"], both, { $0 == .hevc }), .hevc)
        XCTAssertEqual(try choose([], both, { $0 == .hevc }), .hevc)
        XCTAssertEqual(status { try choose(["h264"], [.h264], { _ in false }) }, 503)
        // The whitelist: default both, unknown tokens dropped, order irrelevant; naming neither = both.
        XCTAssertEqual(StreamCodecs.serverAllowed(environment: [:]), both)
        XCTAssertEqual(StreamCodecs.serverAllowed(environment: ["YOYO_VIDEO_CODECS": "hevc, x"]), [.hevc])
        XCTAssertEqual(StreamCodecs.serverAllowed(environment: ["YOYO_VIDEO_CODECS": "HEVC,h264"]), both)
        XCTAssertEqual(StreamCodecs.serverAllowed(environment: ["YOYO_VIDEO_CODECS": ""]), both)
        XCTAssertEqual(StreamCodecs.serverAllowed(environment: ["YOYO_VIDEO_CODECS": "mjpeg"]), both)
    }
}

final class StreamFrameRateTests: XCTestCase {
    func testTheFrameRateIsClampedToOneToSixty() {
        XCTAssertEqual(Router.videoFPS(requested: 60), 60)
        XCTAssertEqual(Router.videoFPS(requested: nil), 2)
        XCTAssertEqual(Router.videoFPS(requested: 4), 4)
        XCTAssertEqual(Router.videoFPS(requested: 0), 1)
        XCTAssertEqual(Router.videoFPS(requested: 120), 60)
    }
}
