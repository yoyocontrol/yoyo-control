import Foundation
import Testing
import UIKit
@testable import YoyoClipboard
@testable import YoyoCore
@testable import YoyoDirect
@testable import YoyoScreen

/// While the Screen page doesn't control, its pill says who holds the screen with an explicit button: "Take Control"
/// when nobody does, "Take Over" from the agent or another phone; a tap takes it (one `control(.user)`), in full screen
/// too (back to the page first). In control there's no pill (ScreenControlPolicy.pill, the page with a fake backend).
@MainActor
@Suite("Screen page take button", .serialized)
struct ScreenTakeButtonTests {
    nonisolated static let ipad = ScreenControlDevice(id: "take-button-tests-ipad", name: "Alex’s iPad")

    /// A Mac that can be shown and controlled, held by `controller` (`device`: another phone's); the control requests
    /// recorded.
    final class Backend: YoyoBackend, @unchecked Sendable {
        let cacheScope = "screen-take-button-tests:\(UUID().uuidString)"
        private let lock = NSLock()
        private var _controller: ScreenController
        private var _device: ScreenControlDevice?
        private var _controls: [ScreenController] = []

        init(controller: ScreenController, device: ScreenControlDevice? = nil) {
            _controller = controller
            _device = device
        }

        var controls: [ScreenController] { lock.withLock { _controls } }

        private var answer: ScreenStatus {
            lock.withLock {
                ScreenStatus(available: true, screenRecording: true, accessibility: true,
                             displays: [ScreenDisplay(id: 1, width: 1512, height: 982, main: true)],
                             controller: _controller, controllerDevice: _device, platform: .mac)
            }
        }

        func status() async throws -> ScreenStatus { answer }
        func streamRequest(display: UInt32?, maxWidth: Int?, quality: Int?, fps: Int?, options: ScreenStreamOptions,
                           route: YoyoRoute) throws -> URLRequest { throw YoyoError.badServerURL }
        func ackRequest(_ ack: ScreenStreamAck, route: YoyoRoute) throws -> URLRequest { throw YoyoError.badServerURL }
        func audioRequest(route: YoyoRoute) throws -> URLRequest { throw YoyoError.badServerURL }
        func input(_ input: ScreenInput, route: YoyoRoute) async throws {}
        func setControl(_ controller: ScreenController, route: YoyoRoute) async throws -> ScreenStatus {
            lock.withLock {
                _controls.append(controller)
                _controller = controller
                // this phone holds it now (a holder that names no device: whoever is "user")
                _device = nil
            }
            return answer
        }
    }

    private func until(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

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

    private func find<T: UIView>(_ type: T.Type, _ id: String, in view: UIView) -> T? {
        if let v = view as? T, v.accessibilityIdentifier == id { return v }
        for sub in view.subviews { if let v = find(type, id, in: sub) { return v } }
        return nil
    }

    private func pill(_ vc: ScreenViewController) -> ScreenControlPill? { find(ScreenControlPill.self, "screen.viewer", in: vc.view) }
    private func button(_ vc: ScreenViewController) -> UIButton? { find(UIButton.self, "screen.takeOver", in: vc.view) }

    @Test func whatThePillSays() {
        typealias P = ScreenControlPolicy
        #expect(P.pill(controlling: false, canControl: true, role: .free) == .free)
        #expect(P.pill(controlling: false, canControl: true, role: .agent) == .agent)
        #expect(P.pill(controlling: false, canControl: true, role: .other(name: "Mia")) == .other(name: "Mia"))
        // full screen after this phone held it: not in control, the button takes it again
        #expect(P.pill(controlling: false, canControl: true, role: .me) == .free)
        // in control: the badge ("You have control"), no pill
        #expect(P.pill(controlling: true, canControl: true, role: .me) == nil)
        // no Accessibility (or no picture): nothing to take, the badge alone
        #expect(P.pill(controlling: false, canControl: false, role: .agent) == nil)
    }

    @Test(arguments: [
        (ScreenController.none, nil, "Take Control"),
        (.agent, nil, "Take Over"),
        (.user, ScreenTakeButtonTests.ipad, "Take Over"),
    ] as [(ScreenController, ScreenControlDevice?, String)])
    func aViewerTapsTheButtonAndControls(_ holder: ScreenController, _ device: ScreenControlDevice?, _ title: String) async {
        let backend = Backend(controller: holder, device: device)
        let vc = await open(backend)
        #expect(pill(vc)?.isHidden == false)
        #expect(pill(vc)?.buttonTitle == title)
        #expect(backend.controls.isEmpty)
        button(vc)?.sendActions(for: .primaryActionTriggered)
        await until { vc.controlling }
        #expect(backend.controls == [.user])
        // in control: the pill goes (the badge says so)
        #expect(pill(vc)?.isHidden == true)
        close(vc)
    }

    @Test func inFullScreenTheButtonLeavesFullScreenIntoControl() async {
        let key = YoyoHost.key("FullScreen")
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let backend = Backend(controller: .agent)
        let vc = await open(backend)
        #expect(vc.fullScreen)
        #expect(pill(vc)?.isHidden == false)
        button(vc)?.sendActions(for: .primaryActionTriggered)
        await until { vc.controlling }
        #expect(!vc.fullScreen)
        #expect(backend.controls == [.user])
        close(vc)
    }
}
