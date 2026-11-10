import Foundation
import Testing
import UIKit
@testable import YoyoClipboard
@testable import YoyoCore
@testable import YoyoDirect
@testable import YoyoScreen

/// The Screen page opens as a viewer: opening (and a status, and a `screen.control`) never asks for control; the first
/// real input does (a touch on the trackpad, a key), over the agent too (ScreenControlPolicy, the page with a fake
/// backend that records its control requests).
@MainActor
@Suite("Screen page viewer first")
struct ScreenViewerFirstTests {
    /// A Mac that can be shown and controlled, nobody (or the agent) holding it; the control requests and the input
    /// recorded.
    final class Backend: YoyoBackend, @unchecked Sendable {
        let cacheScope = "screen-viewer-first-tests:\(UUID().uuidString)"
        private let lock = NSLock()
        private var _controller: ScreenController
        private var _controls: [ScreenController] = []
        private var _inputs: [ScreenInput] = []

        init(controller: ScreenController) { _controller = controller }

        var controls: [ScreenController] { lock.withLock { _controls } }
        var inputs: [ScreenInput] { lock.withLock { _inputs } }

        private var answer: ScreenStatus {
            ScreenStatus(available: true, screenRecording: true, accessibility: true,
                         displays: [ScreenDisplay(id: 1, width: 1512, height: 982, main: true)],
                         controller: lock.withLock { _controller }, platform: .mac)
        }

        func status() async throws -> ScreenStatus { answer }
        func streamRequest(display: UInt32?, maxWidth: Int?, quality: Int?, fps: Int?, options: ScreenStreamOptions,
                           route: YoyoRoute) throws -> URLRequest { throw YoyoError.badServerURL }
        func ackRequest(_ ack: ScreenStreamAck, route: YoyoRoute) throws -> URLRequest { throw YoyoError.badServerURL }
        func audioRequest(route: YoyoRoute) throws -> URLRequest { throw YoyoError.badServerURL }
        func input(_ input: ScreenInput, route: YoyoRoute) async throws { lock.withLock { _inputs.append(input) } }
        func setControl(_ controller: ScreenController, route: YoyoRoute) async throws -> ScreenStatus {
            lock.withLock {
                _controls.append(controller)
                _controller = controller
            }
            return answer
        }
    }

    /// Waits (up to 2 s) for `done`.
    private func until(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// The page, shown (as a host's push would: `viewWillAppear` activates it) with its first status in.
    private func open(_ backend: Backend) async -> ScreenViewController {
        let vc = ScreenViewController(backend: backend)
        vc.loadViewIfNeeded()
        vc.beginAppearanceTransition(true, animated: false)
        vc.endAppearanceTransition()
        await vc.refreshStatus()
        await until { vc.status != nil }
        return vc
    }

    private func close(_ vc: ScreenViewController) {
        vc.beginAppearanceTransition(false, animated: false)
        vc.endAppearanceTransition()
    }

    @Test func theRule() {
        typealias P = ScreenControlPolicy
        #expect(P.input(controlling: true, viewer: false, canTake: true) == .go)
        // watching, nobody else's control in the way (free, or the agent's: the user wins)
        #expect(P.input(controlling: false, viewer: false, canTake: true) == .take)
        // another phone holds it: only Take Over takes it
        #expect(P.input(controlling: false, viewer: true, canTake: false) == .nudge)
        // full screen, no Accessibility
        #expect(P.input(controlling: false, viewer: false, canTake: false) == .ignore)
    }

    @Test(arguments: [ScreenController.none, .agent])
    func openingWatchesAndTheFirstTouchTakesTheScreen(_ holder: ScreenController) async {
        let backend = Backend(controller: holder)
        let vc = await open(backend)
        // more statuses (the 10 s poll) don't take it either
        await vc.refreshStatus()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(backend.controls.isEmpty)
        #expect(!vc.controlling)
        // the first finger on the trackpad
        vc.touches(true)
        vc.touches(false)
        await until { vc.controlling }
        #expect(backend.controls == [.user])
        #expect(vc.controlling)
        // given back as the page goes (it took it)
        close(vc)
        await until { backend.controls.count == 2 }
        #expect(backend.controls == [.user, .none])
    }

    @Test func aKeyWhileWatchingTakesTheScreenThenGoes() async {
        let backend = Backend(controller: .none)
        let vc = await open(backend)
        #expect(backend.controls.isEmpty)
        vc.sendKey("escape")
        await until { !backend.inputs.isEmpty }
        #expect(backend.controls == [.user])
        #expect(backend.inputs.map(\.type) == [.key])
        #expect(backend.inputs.first?.key == "escape")
        close(vc)
    }

    @Test func closingAPageThatOnlyWatchedReleasesNothing() async {
        let backend = Backend(controller: .agent)
        let vc = await open(backend)
        close(vc)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(backend.controls.isEmpty)
    }
}
