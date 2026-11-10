import AVFoundation
import Foundation
import Testing
import UIKit
@testable import YoyoClipboard
@testable import YoyoCore
@testable import YoyoDirect
@testable import YoyoScreen

/// The Screen page's layers as a host composes them (`YoyoScreenSession`, `YoyoScreenPictureView`,
/// `YoyoTrackpadView`): the control policies (`.explicit` sends nothing until `takeControl()`, and nothing again after
/// `releaseControl()`; `.takeOnInput` takes at the first input, as the page always did), several observers, the
/// picture's coordinates, its video layer for Picture in Picture (and moving the picture view keeps it showing), and the
/// background (stopped by default, running on with `continuesInBackground`). A fake backend records the control requests
/// and the input.
@MainActor
@Suite("Screen layers", .serialized)
struct ScreenLayersTests {
    typealias Backend = ScreenViewerFirstTests.Backend

    private func until(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// A started session with its first status in.
    private func started(_ backend: Backend, _ policy: YoyoControlPolicy) async -> YoyoScreenSession {
        let session = YoyoScreenSession(backend: backend, controlPolicy: policy)
        session.start()
        await session.refreshStatus()
        await until { session.status != nil }
        // the status `start()` asked for is in too (a late one would undo a take, as a stale poll does)
        try? await Task.sleep(for: .milliseconds(50))
        return session
    }

    @Test func explicitSendsNothingUntilTakenAndNothingAfterTheRelease() async throws {
        let backend = Backend(controller: .none)
        let session = await started(backend, .explicit)
        #expect(session.canTakeControl && !session.isControlling)
        // watching: input is dropped, nothing asks for control
        session.send(ScreenInput(.key, key: "escape"))
        session.pressKey("tab")
        session.type("hi")
        #expect(!session.click(at: CGPoint(x: 0.5, y: 0.5)))
        #expect(!session.movePointer(to: CGPoint(x: 0.2, y: 0.2)))
        #expect(!session.beginDrag(at: CGPoint(x: 0.2, y: 0.2)))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(backend.controls.isEmpty)
        #expect(backend.inputs.isEmpty)
        // taken: it goes
        try await session.takeControl()
        #expect(session.isControlling)
        #expect(backend.controls == [.user])
        session.send(ScreenInput(.key, key: "escape"))
        await until { backend.inputs.count == 1 }
        #expect(backend.inputs.map(\.key) == ["escape"])
        // given back: dropped again
        session.releaseControl()
        #expect(!session.isControlling)
        await until { backend.controls.count == 2 }
        #expect(backend.controls == [.user, .none])
        session.send(ScreenInput(.key, key: "tab"))
        session.pressKey("tab")
        try? await Task.sleep(for: .milliseconds(150))
        #expect(backend.inputs.count == 1)
        #expect(backend.controls == [.user, .none])
        session.stop()
    }

    /// The computer says this phone holds the screen (a holder that names no device, from another visit): under
    /// `.explicit` that isn't this session's control.
    @Test func explicitControlIsOnlyWhatThisSessionTook() async {
        let backend = Backend(controller: .user)
        let session = await started(backend, .explicit)
        #expect(!session.isControlling)
        session.send(ScreenInput(.key, key: "escape"))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(backend.inputs.isEmpty && backend.controls.isEmpty)
        session.stop()
    }

    @Test func explicitTrackpadTouchesAskForNothing() async {
        let backend = Backend(controller: .agent)
        let session = await started(backend, .explicit)
        let picture = YoyoScreenPictureView(session: session)
        let trackpad = YoyoTrackpadView(session: session, picture: picture)
        var nudges = 0
        let observation = session.observe { if case .notice(.nudge) = $0 { nudges += 1 } }
        trackpad.touches(true)
        trackpad.touches(false)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(backend.controls.isEmpty)
        #expect(nudges == 1)
        observation.cancel()
        session.stop()
    }

    @Test func takeOnInputTakesAtTheFirstInputAsThePageDoes() async {
        let backend = Backend(controller: .agent)
        let session = await started(backend, .takeOnInput)
        #expect(!session.isControlling)
        // statuses don't take it
        await session.refreshStatus()
        #expect(backend.controls.isEmpty)
        // a key: the take, then the key
        session.pressKey("escape")
        await until { !backend.inputs.isEmpty }
        #expect(backend.controls == [.user])
        #expect(backend.inputs.map(\.key) == ["escape"])
        #expect(session.isControlling)
        // given back as it stops (it took it)
        session.stop()
        await until { backend.controls.count == 2 }
        #expect(backend.controls == [.user, .none])
    }

    @Test func everyObserverHearsTheControlChange() async throws {
        let backend = Backend(controller: .none)
        let session = await started(backend, .explicit)
        var first: [Bool] = []
        var second: [Bool] = []
        var tookNotices = 0
        let a = session.observe { update in
            if case let .changed(c) = update, c.contains(.control) { first.append(session.isControlling) }
        }
        let b = session.observe { update in
            switch update {
            case let .changed(c) where c.contains(.control): second.append(session.isControlling)
            case .notice(.tookControl): tookNotices += 1
            default: break
            }
        }
        try await session.takeControl()
        #expect(first.last == true && second.last == true)
        #expect(tookNotices == 1)
        session.releaseControl()
        #expect(first.last == false && second.last == false)
        // a cancelled observer hears no more
        a.cancel()
        let heard = first.count
        try await session.takeControl()
        #expect(first.count == heard)
        #expect(second.last == true)
        _ = b
        session.stop()
    }

    /// Another phone takes over while this session holds the screen: it says so (and watches).
    @Test func losingControlToAnotherPhoneIsSaid() async throws {
        let backend = Backend(controller: .none)
        let session = await started(backend, .explicit)
        try await session.takeControl()
        var losses: [YoyoScreenControlLoss] = []
        let o = session.observe { if case let .notice(.lostControl(l)) = $0 { losses.append(l) } }
        var s = try #require(session.status)
        s.controller = .user
        s.controllerDevice = ScreenControlDevice(id: "another-phone", name: "Mia’s iPhone")
        s.controllerSince = (s.controllerSince ?? 0) + 1000
        session.apply(s)
        #expect(losses == [.takenOver(by: "Mia’s iPhone")])
        #expect(!session.isControlling && session.controlModel.isViewer)
        o.cancel()
        session.stop()
    }

    @Test func thePictureFitsItsInsetsAndMapsPoints() {
        let session = YoyoScreenSession(backend: Backend(controller: .none))
        let picture = YoyoScreenPictureView(session: session)
        picture.frame = CGRect(x: 0, y: 0, width: 400, height: 800)
        picture.contentInsets = UIEdgeInsets(top: 100, left: 0, bottom: 100, right: 0)
        picture.layoutIfNeeded()
        // before the first picture: 16:10, full width, centered in what the insets leave
        #expect(picture.pictureFrame == CGRect(x: 0, y: 275, width: 400, height: 250))
        picture.showVideo(size: CGSize(width: 1600, height: 1000))
        picture.layoutIfNeeded()
        let mid = picture.viewPoint(fromNormalized: CGPoint(x: 0.5, y: 0.5))
        #expect(mid == CGPoint(x: 200, y: 400))
        #expect(picture.normalizedPoint(fromView: CGPoint(x: 100, y: 337.5)) == CGPoint(x: 0.25, y: 0.25))
        #expect(picture.normalizedPoint(fromView: CGPoint(x: 100, y: 100)) == nil)
        // an area of the picture's own shape is filled to the point
        #expect(YoyoScreenPictureView.fit(area: CGRect(x: 0, y: 0, width: 390, height: 243), aspect: 1.6)
                == CGRect(x: 0, y: 0, width: 390, height: 243))
    }

    /// The page made of the layers: a touch on the trackpad's panel is the trackpad's, one on the picture the
    /// picture's, one between them neither's (the page's swipe back may take it).
    @Test func thePageHandsTouchesToItsLayers() async {
        let backend = Backend(controller: .none)
        let vc = ScreenViewController(backend: backend)
        vc.loadViewIfNeeded()
        vc.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        vc.beginAppearanceTransition(true, animated: false)
        vc.endAppearanceTransition()
        await vc.refreshStatus()
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()
        let picture = vc.view.subviews.compactMap { $0 as? YoyoScreenPictureView }.first
        let trackpad = vc.view.subviews.compactMap { $0 as? YoyoTrackpadView }.first
        #expect(picture != nil && trackpad != nil)
        guard let picture, let trackpad else { return }
        #expect(!trackpad.isHidden && trackpad.frame.minY > picture.pictureFrame.maxY)
        func owner(_ p: CGPoint) -> UIView? {
            var v = vc.view.hitTest(p, with: nil)
            while let view = v, view !== picture, view !== trackpad { v = view.superview }
            return v
        }
        #expect(owner(CGPoint(x: trackpad.frame.midX, y: trackpad.frame.midY)) === trackpad)
        #expect(owner(CGPoint(x: picture.pictureFrame.midX, y: picture.pictureFrame.midY)) === picture)
        #expect(owner(CGPoint(x: trackpad.frame.midX, y: picture.pictureFrame.maxY + 4)) == nil)
        vc.beginAppearanceTransition(false, animated: false)
        vc.endAppearanceTransition()
    }

    @Test func aVideoSinkGetsPicturesUntilCancelled() throws {
        let output = ScreenVideoOutput()
        final class Count: @unchecked Sendable { var n = 0 }
        let count = Count()
        let id = output.addSink(active: true) { _ in count.n += 1 }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pb)
        let image = try #require(pb)
        output.show(image)
        #expect(count.n == 1)
        // a sink added later starts with the newest picture
        let late = Count()
        let lateId = output.addSink(active: true) { _ in late.n += 1 }
        #expect(late.n == 1)
        output.removeSink(id)
        output.show(image)
        #expect(count.n == 1 && late.n == 2)
        // an inactive one gets nothing until it starts (then the newest at once)
        let idle = Count()
        let idleId = output.addSink(active: false) { _ in idle.n += 1 }
        output.show(image)
        #expect(idle.n == 0)
        output.setSink(idleId, active: true)
        #expect(idle.n == 1)
        output.removeSink(lateId)
    }

    // MARK: Picture in Picture

    private func pixelBuffer() throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 160, 100, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        return try #require(pb)
    }

    @Test func theVideoLayerIsTheOneThePicturesGoInto() throws {
        let session = YoyoScreenSession(backend: Backend(controller: .none))
        let picture = YoyoScreenPictureView(session: session)
        #expect(picture.videoDisplayLayer === picture.videoView.layer)
        #expect(session.videoOutput.attachedRenderer === picture.videoDisplayLayer.sampleBufferRenderer)
        // the same layer for as long as the view lives
        #expect(picture.videoDisplayLayer === picture.videoDisplayLayer)
        // a picture view made later shows the session (and its layer is the one fed)
        let later = YoyoScreenPictureView(session: session)
        #expect(session.picture === later)
        #expect(session.videoOutput.attachedRenderer === later.videoDisplayLayer.sampleBufferRenderer)
        #expect(later.videoDisplayLayer !== picture.videoDisplayLayer)
    }

    /// A host keeps one picture view for a whole call and moves it between a small window and a full page (another
    /// superview, a new frame, even another window): it stays the session's picture, its layer stays the one fed and
    /// keeps its picture, the video stays shown.
    @Test func movingThePictureKeepsItTheSessionsAndItsPicture() async throws {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        func makeWindow() -> UIWindow {
            let w = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
            w.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
            w.isHidden = false
            return w
        }
        let window = makeWindow()
        let small = UIView(frame: CGRect(x: 250, y: 600, width: 140, height: 90))
        let page = UIView(frame: window.bounds)
        window.addSubview(page)
        window.addSubview(small)
        let session = YoyoScreenSession(backend: Backend(controller: .none))
        let picture = YoyoScreenPictureView(session: session)
        picture.frame = small.bounds
        small.addSubview(picture)
        let layer = picture.videoDisplayLayer
        let renderer = layer.sampleBufferRenderer
        session.videoOutput.show(try pixelBuffer())
        picture.showVideo(size: CGSize(width: 160, height: 100))
        picture.layoutIfNeeded()
        // (a test without a scene renders nothing: what the layer displays can't be read back here; what this checks
        // is that nothing of the kit touches the layer as the view moves: no new attach, no clear, no flush)
        let attaches = session.videoOutput.attachCount
        func check(_ step: Comment) {
            #expect(session.picture === picture, step)
            #expect(session.videoOutput.attachedRenderer === renderer, step)
            #expect(picture.videoDisplayLayer === layer && layer.sampleBufferRenderer === renderer, step)
            #expect(picture.showsVideo && picture.image == nil, step)
            #expect(session.videoOutput.attachCount == attaches, step)
            #expect(renderer.status != .failed && !renderer.requiresFlushToResumeDecoding, step)
            // not cleared (a clear drops the newest picture and empties the layer)
            #expect(session.videoOutput.snapshot() != nil, step)
        }
        // small → full page: another superview and frame, animated as a host's flight would be
        page.addSubview(picture)
        UIView.animate(withDuration: 0.2) {
            picture.frame = page.bounds
            picture.layoutIfNeeded()
        }
        check("to the page")
        #expect(picture.pictureFrame.width == 402)
        // back, through no superview at all for a moment
        picture.removeFromSuperview()
        small.addSubview(picture)
        picture.frame = small.bounds
        picture.layoutIfNeeded()
        check("back to the small window")
        // into another window
        let other = makeWindow()
        other.addSubview(picture)
        check("to another window")
        other.isHidden = true
        window.isHidden = true
    }

    // MARK: Background

    /// Counts what the session asks of its way (a new visit, the page showing, leaving it).
    @MainActor
    final class CountingRouting: YoyoRouting {
        static let route = YoyoRoute(id: "tunnel", isLocalNetwork: false, isDirect: false, label: "tunnel")
        var current = CountingRouting.route
        var isDeciding = false
        var decisionWait: Duration = .milliseconds(10)
        var openTimeout: Duration = .seconds(3)
        var onChange: (@MainActor () -> Void)?
        var visits = 0, activations = 0, leaves = 0
        func newVisit() { visits += 1 }
        func activate() { activations += 1 }
        func streamWillOpen() {}
        func leave() { leaves += 1 }
        func streamFailed(on route: YoyoRoute, unauthorized: Bool) {}
        func ackAnswered(on route: YoyoRoute, status: Int?) {}
        func fallback(from route: YoyoRoute, after error: Error) async -> YoyoRoute? { nil }
    }

    /// A started session over `routing`, holding the screen (it took it).
    private func controlling(_ backend: Backend, _ routing: CountingRouting) async throws -> YoyoScreenSession {
        let inner = ScreenSession(backend: backend, videoOutput: ScreenVideoOutput(), routing: .some(routing))
        let session = YoyoScreenSession(backend: backend, controlPolicy: .explicit, inner: inner)
        session.start()
        await session.refreshStatus()
        await until { session.status != nil }
        try? await Task.sleep(for: .milliseconds(50))
        try await session.takeControl()
        #expect(session.isControlling)
        return session
    }

    /// The default (the kit's Screen page): the background stops it and gives control back, coming back starts it
    /// again on a way chosen afresh.
    @Test func theBackgroundStopsTheSessionByDefault() async throws {
        let backend = Backend(controller: .none)
        let routing = CountingRouting()
        let session = try await controlling(backend, routing)
        #expect(!session.continuesInBackground)
        #expect(routing.visits == 1 && routing.activations == 1 && routing.leaves == 0)
        session.appDidEnterBackground()
        #expect(!session.isActive && session.isStarted)
        #expect(!session.isControlling)
        await until { backend.controls.count == 2 }
        #expect(backend.controls == [.user, .none])
        #expect(routing.leaves == 1)
        #expect(!session.inner.background)
        session.appWillEnterForeground()
        #expect(session.isActive)
        #expect(routing.activations == 2 && routing.visits == 1)
        session.stop()
    }

    /// `continuesInBackground`: the background leaves it running (on the same way), only control goes back; coming
    /// back starts nothing again.
    @Test func continuesInBackgroundKeepsItRunning() async throws {
        let backend = Backend(controller: .none)
        let routing = CountingRouting()
        let session = try await controlling(backend, routing)
        session.continuesInBackground = true
        var activity = 0
        let o = session.observe { if case let .changed(c) = $0, c.contains(.activity) { activity += 1 } }
        session.appDidEnterBackground()
        #expect(session.isActive && session.inBackground && session.inner.background)
        #expect(!session.isControlling)
        await until { backend.controls.count == 2 }
        #expect(backend.controls == [.user, .none])
        #expect(routing.leaves == 0)
        // a second background (another scene's notice) changes nothing
        session.appDidEnterBackground()
        #expect(backend.controls == [.user, .none])
        session.appWillEnterForeground()
        #expect(session.isActive && !session.inBackground && !session.inner.background)
        #expect(routing.activations == 1 && routing.visits == 1 && routing.leaves == 0)
        #expect(activity == 0)
        // the session can be controlled again
        try await session.takeControl()
        #expect(session.isControlling)
        // turned off in the background: it stops there as it would have, and starts again coming back
        session.appDidEnterBackground()
        #expect(session.isActive)
        session.continuesInBackground = false
        #expect(!session.isActive && !session.inBackground && !session.inner.background)
        #expect(routing.leaves == 1)
        session.appWillEnterForeground()
        #expect(session.isActive && routing.activations == 2)
        // stopped while running in the background: nothing of it stays
        session.continuesInBackground = true
        session.appDidEnterBackground()
        session.stop()
        #expect(!session.isActive && !session.inBackground && !session.inner.background)
        o.cancel()
    }

    /// In the background (no display link) smooth playback shows every picture as it comes; back, at its time again.
    @Test func aPlayerInTheBackgroundShowsPicturesAsTheyCome() throws {
        final class Count: @unchecked Sendable { var n = 0 }
        let shown = Count()
        let output = ScreenVideoOutput()
        let player = ScreenPlayer(output: output, stats: nil, evenPace: true, onShown: { _, _ in shown.n += 1 })
        let image = try pixelBuffer()
        let picture = ScreenPlayer.Picture(image: image, size: CGSize(width: 160, height: 100), decodeMs: 1)
        player.setShowsOnArrival(true)
        let now = CACurrentMediaTime()
        for i in 0..<5 {
            player.push(picture, macTime: 1000 + Double(i) / 60, sample: true, arrival: now + Double(i) / 60)
            #expect(shown.n == i + 1)
        }
        #expect(output.snapshot() != nil)
        player.setShowsOnArrival(false)
        player.stop()
    }
}
