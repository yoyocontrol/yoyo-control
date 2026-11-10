import AVFoundation
import Foundation
import Synchronization
import Testing
import UIKit
@testable import YoyoCore
@testable import YoyoScreen

/// A session's stop is cheap on the main thread: the last video picture becomes a still off it (the display layer
/// shows that picture meanwhile; a picture that comes first wins), the link's streams are closed off it, and the stop
/// logs each step's time (`screen-stop`, `YoyoHost.log`). A stop then a start at once opens a new stream as before.
@MainActor
@Suite("Screen session stop", .serialized)
struct ScreenStopTests {
    typealias FakeLink = LinkScreenSessionTests.FakeLink

    /// A Mac that can be shown, its one way a fake link.
    final class Backend: YoyoBackend, @unchecked Sendable {
        let link = FakeLink()
        let cacheScope = "screen-stop-tests:\(UUID().uuidString)"
        var route: YoyoRoute { YoyoRoute(id: "link", isLocalNetwork: false, label: "link") }
        func screenLink(for route: YoyoRoute) -> (any YoyoScreenLink)? { link }
        func status() async throws -> ScreenStatus {
            ScreenStatus(available: true, screenRecording: true, accessibility: true,
                         displays: [ScreenDisplay(id: 1, width: 1512, height: 982, main: true)], controller: ScreenController.none,
                         platform: .mac)
        }
        func streamRequest(display: UInt32?, maxWidth: Int?, quality: Int?, fps: Int?, options: ScreenStreamOptions,
                           route: YoyoRoute) throws -> URLRequest {
            URLRequest(url: URL(string: "https://link.invalid/stream?display=1")!)
        }
        func ackRequest(_ ack: ScreenStreamAck, route: YoyoRoute) throws -> URLRequest { throw YoyoError.badServerURL }
        func audioRequest(route: YoyoRoute) throws -> URLRequest { URLRequest(url: URL(string: "https://link.invalid/audio")!) }
        func input(_ input: ScreenInput, route: YoyoRoute) async throws {}
        func setControl(_ controller: ScreenController, route: YoyoRoute) async throws -> ScreenStatus { try await status() }
    }

    private func until(_ done: () -> Bool) async {
        for _ in 0..<300 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// A picture the size the phone gets (the stream's widest, 16:10), in the decoder's format.
    private func fullSizePicture() throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 2304, 1440, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) {
                memset(base, plane == 0 ? 0x60 : 0x80, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func window() -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let w = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        w.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        w.isHidden = false
        return w
    }

    /// A picture view in a window showing a full-size video picture of `session`.
    private func showing(_ session: YoyoScreenSession, in window: UIWindow) throws -> YoyoScreenPictureView {
        let picture = YoyoScreenPictureView(session: session)
        picture.frame = window.bounds
        window.addSubview(picture)
        session.videoOutput.show(try fullSizePicture())
        picture.showVideo(size: CGSize(width: 2304, height: 1440))
        picture.layoutIfNeeded()
        #expect(picture.showsVideo)
        return picture
    }

    private static func ms(_ d: Duration) -> Double { Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000 }

    @Test func theStillIsMadeOffTheMainThread() async throws {
        let session = YoyoScreenSession(backend: Backend())
        let w = window()
        let picture = try showing(session, in: w)
        // what the freeze cost on the main thread before (the first still of the process makes the context too)
        let clock = ContinuousClock()
        let first = clock.measure { _ = session.videoOutput.snapshot() }
        let warm = clock.measure { _ = session.videoOutput.snapshot() }
        let done = Mutex(false)
        let freeze = clock.measure { picture.freezeVideo(from: session.videoOutput) { done.withLock { $0 = true } } }
        print(String(format: "screen-stop: still on the main thread %.1f ms (first) / %.1f ms (warm); the freeze now %.2f ms",
                     Self.ms(first), Self.ms(warm), Self.ms(freeze)))
        // meanwhile the video layer shows the same picture
        #expect(picture.showsVideo && picture.image == nil)
        await until { done.withLock { $0 } }
        #expect(!picture.showsVideo)
        #expect(picture.image?.size == CGSize(width: 2304, height: 1440))
        w.isHidden = true
    }

    @Test func aPictureThatComesFirstKeepsTheVideo() async throws {
        let session = YoyoScreenSession(backend: Backend())
        let w = window()
        let picture = try showing(session, in: w)
        let done = Mutex(false)
        picture.freezeVideo(from: session.videoOutput) { done.withLock { $0 = true } }
        // the next stream's first picture, before the still is ready
        picture.showVideo(size: CGSize(width: 2304, height: 1440))
        await until { done.withLock { $0 } }
        #expect(picture.showsVideo && picture.image == nil)
        // another display (the picture cleared) before the still: it stays cleared
        let cleared = Mutex(false)
        picture.freezeVideo(from: session.videoOutput) { cleared.withLock { $0 = true } }
        session.sessionClearPicture()
        await until { cleared.withLock { $0 } }
        #expect(picture.image == nil)
        w.isHidden = true
    }

    @Test func aStopLogsItsStepsAndAStartRightAfterOpensAgain() async throws {
        let lines = Mutex<[String]>([])
        let before = YoyoHost.current
        var host = before
        host.log = { category, line in if category == "screen-stop" { lines.withLock { $0.append(line) } } }
        YoyoHost.current = host
        defer { YoyoHost.current = before }

        let backend = Backend()
        let session = YoyoScreenSession(backend: backend, controlPolicy: .explicit)
        session.start()
        await session.refreshStatus()
        await until { !backend.link.videos.isEmpty }
        let first = try #require(backend.link.videos.first)
        // the stream's picture (the session's first status chose the display: shown after it)
        let w = window()
        let picture = try showing(session, in: w)

        session.stop(release: true)
        let line = try #require(lines.withLock { $0.last })
        print("screen-stop: \(line)")
        #expect(line.hasPrefix("stop "))
        for step in ["freeze", "stream", "decoder", "player", "frames", "audio", "interactive", "events+input", "release",
                     "route", "observers"] {
            #expect(line.contains(" \(step) "), "\(step) in \(line)")
        }
        #expect(!session.isActive)
        // the still comes a moment later; the link's stream is closed off the main thread
        await until { !picture.showsVideo && first.lock.withLock { first.closed } }
        #expect(!picture.showsVideo && picture.image != nil)
        #expect(first.lock.withLock { first.closed })

        // a stop, then a start at once: a new stream, the old one's close not in its way
        session.start()
        await session.refreshStatus()
        await until { backend.link.videos.count >= 2 }
        let second = try #require(backend.link.videos.last)
        session.stop(release: true)
        session.start()
        await session.refreshStatus()
        await until { backend.link.videos.count >= 3 }
        #expect(backend.link.videos.count >= 3)
        await until { second.lock.withLock { second.closed } }
        #expect(second.lock.withLock { second.closed })
        let third = try #require(backend.link.videos.last)
        #expect(third !== second && !third.lock.withLock { third.closed })
        #expect(session.isActive)
        session.stop()
        w.isHidden = true
    }
}
