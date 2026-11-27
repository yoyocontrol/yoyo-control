import Foundation
import Testing
import UIKit
@testable import YoyoCore
@testable import YoyoScreen

/// A trackpad with no picture (the computer's screen in front of the user): the session's pointer-only stream
/// (`YoyoScreenStreamMode.pointer`: the smallest picture at 1 fps), `YoyoTrackpadView(session:)` measuring the finger
/// against the display fitted into its panel, the host's keys (`YoyoScreenKey`, `press`), and the Screen page's
/// trackpad mode.
@MainActor
@Suite("Screen trackpad mode", .serialized)
struct ScreenTrackpadModeTests {
    /// A Mac that can be shown and controlled; every stream request's width and rate, and the input, recorded (the
    /// stream itself fails: nothing here needs pictures).
    final class Backend: YoyoBackend, @unchecked Sendable {
        let cacheScope = "screen-trackpad-mode-tests:\(UUID().uuidString)"
        private let lock = NSLock()
        private var _streams: [(maxWidth: Int?, fps: Int?)] = []
        private var _inputs: [ScreenInput] = []
        private var _controller = ScreenController.none

        var streams: [(maxWidth: Int?, fps: Int?)] { lock.withLock { _streams } }
        var inputs: [ScreenInput] { lock.withLock { _inputs } }

        private var answer: ScreenStatus {
            ScreenStatus(available: true, screenRecording: true, accessibility: true,
                         displays: [ScreenDisplay(id: 1, width: 1512, height: 982, main: true)],
                         controller: lock.withLock { _controller }, platform: .mac)
        }

        func status() async throws -> ScreenStatus { answer }
        func streamRequest(display: UInt32?, maxWidth: Int?, quality: Int?, fps: Int?, options: ScreenStreamOptions,
                           route: YoyoRoute) throws -> URLRequest {
            lock.withLock { _streams.append((maxWidth, fps)) }
            throw YoyoError.badServerURL
        }
        func ackRequest(_ ack: ScreenStreamAck, route: YoyoRoute) throws -> URLRequest { throw YoyoError.badServerURL }
        func audioRequest(route: YoyoRoute) throws -> URLRequest { throw YoyoError.badServerURL }
        func input(_ input: ScreenInput, route: YoyoRoute) async throws { lock.withLock { _inputs.append(input) } }
        func setControl(_ controller: ScreenController, route: YoyoRoute) async throws -> ScreenStatus {
            lock.withLock { _controller = controller }
            return answer
        }
    }

    private func until(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func started(_ backend: Backend, mode: YoyoScreenStreamMode = .picture) async -> YoyoScreenSession {
        let session = YoyoScreenSession(backend: backend)
        session.streamMode = mode
        session.start()
        await session.refreshStatus()
        await until { session.status != nil && !backend.streams.isEmpty }
        return session
    }

    @Test func thePointerModeAsksForTheSmallestStream() async {
        let backend = Backend()
        let session = await started(backend, mode: .pointer)
        #expect(backend.streams.first?.maxWidth == 160)
        #expect(backend.streams.first?.fps == 1)
        session.stop()
    }

    @Test func switchingTheModeReplacesTheStream() async {
        let backend = Backend()
        let session = await started(backend)
        #expect(backend.streams.first?.maxWidth == ScreenStreamOptions.videoMaxWidth)
        #expect(backend.streams.first?.fps == 60)
        session.streamMode = .pointer
        await until { backend.streams.count >= 2 }
        #expect(backend.streams.last?.maxWidth == 160 && backend.streams.last?.fps == 1)
        session.streamMode = .picture
        await until { backend.streams.count >= 3 }
        #expect(backend.streams.last?.maxWidth == ScreenStreamOptions.videoMaxWidth && backend.streams.last?.fps == 60)
        session.stop()
    }

    @Test func aKeyTakesItsOwnModifiersWithTheArmedOnes() async throws {
        let backend = Backend()
        let session = await started(backend)
        try await session.takeControl()
        session.press(YoyoScreenKey("⌘⇥", key: "tab", modifiers: [.cmd]))
        session.toggleModifier(.shift)
        session.press(YoyoScreenKey("⌘⇥", key: "tab", modifiers: [.cmd]))
        session.toggleModifier(.cmd)
        session.press(.pageDown)
        await until { backend.inputs.count == 3 }
        #expect(backend.inputs.map(\.key) == ["tab", "tab", "pageDown"])
        #expect(backend.inputs.map { Set($0.modifiers) } == [[.cmd], [.shift, .cmd], [.cmd]])
        #expect(session.modifiers.isEmpty)
        session.stop()
    }

    @Test func theStandardKeysAreTheBarsAsBefore() {
        #expect(YoyoScreenKey.standard.map(\.key) == ["escape", "tab", "left", "up", "down", "right"])
        #expect(YoyoScreenKey.standard.map(\.identifier).first == "screen.key.escape")
        #expect(YoyoScreenKey("⌘⇥", key: "tab", modifiers: [.cmd]).identifier == "screen.key.cmd-tab")
        #expect(YoyoScreenKey.function(5).key == "f5" && YoyoScreenKey.function(5).title == "F5")
        let keyboard = YoyoScreenKeyboard(session: YoyoScreenSession(backend: Backend()))
        #expect(keyboard.keys == YoyoScreenKey.standard)
        keyboard.keys = [.pageUp, .pageDown]
        #expect(keyboard.keyBar.keys.map(\.key) == ["pageUp", "pageDown"])
    }

    /// No picture on the screen: the panel stands for the display (fitted into it), so a finger across the panel goes
    /// across the display about as it would across a picture of that width.
    @Test func aTrackpadWithoutAPictureMeasuresAgainstItsPanel() async {
        let backend = Backend()
        let session = await started(backend, mode: .pointer)
        let pad = YoyoTrackpadView(session: session)
        pad.frame = CGRect(x: 0, y: 0, width: 360, height: 300)
        #expect(!pad.showsPicture)
        let fitted = YoyoScreenPictureView.fit(area: pad.bounds, aspect: 1512.0 / 982.0).size
        #expect(pad.movePicture == fitted)
        #expect(fitted.width >= 358 && fitted.width <= 360)
        session.stop()
    }

    @Test func thePageTurnsTrackpadModeOnAndOff() async {
        let key = YoyoHost.key("TrackpadOnly")
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        let backend = Backend()
        let vc = ScreenViewController(backend: backend, keys: [.left, .right])
        vc.loadViewIfNeeded()
        vc.beginAppearanceTransition(true, animated: false)
        vc.endAppearanceTransition()
        await vc.refreshStatus()
        await until { vc.status != nil }
        #expect(!vc.trackpadOnly && vc.session.streamMode == .picture)
        vc.setTrackpadOnly(true)
        #expect(vc.trackpadOnly && vc.session.streamMode == .pointer)
        #expect(UserDefaults.standard.bool(forKey: key))
        vc.beginAppearanceTransition(false, animated: false)
        vc.endAppearanceTransition()
        // the next page opens as this one was left
        let next = ScreenViewController(backend: Backend())
        #expect(next.trackpadOnly && next.session.streamMode == .pointer)
        vc.setTrackpadOnly(false)
        #expect(!UserDefaults.standard.bool(forKey: key))
    }
}
