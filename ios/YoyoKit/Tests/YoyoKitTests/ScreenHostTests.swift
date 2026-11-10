import Foundation
import Testing
@testable import YoyoClipboard
@testable import YoyoCore
@testable import YoyoDirect
@testable import YoyoScreen

/// Whose screen the Screen page and a preview row show (`YoyoComputer`): a Mac's, or another computer's (a Linux desktop)
/// without the Mac's own pieces.
/// The tests run in English.
@Suite("Whose computer")
struct ScreenHostTests {
    @Test func onlyTheMacHasItsOwnPieces() {
        #expect(YoyoComputer.mac.hasMacPermissions)
        #expect(!YoyoComputer.linux.hasMacPermissions && !YoyoComputer(YoyoPlatform(rawValue: "windows")).hasMacPermissions)
        // nothing said about the clipboard (an older computer): the Mac's only
        #expect(YoyoComputer.mac.hasClipboard(nil) && !YoyoComputer.linux.hasClipboard(nil))
    }

    @Test func theWordsSayDesktopForAUser() {
        #expect(YoyoComputer.mac.title == "Screen")
        #expect(YoyoComputer.linux.title == "Desktop")
        #expect(YoyoComputer.mac.unavailableTitle == "Screen unavailable")
        #expect(YoyoComputer.linux.unavailableTitle == "Desktop unavailable")
        #expect(YoyoComputer.linux.unavailableDetail == "The desktop can’t be shown right now.")
        #expect(YoyoComputer.mac.watchLine == "Watch the Mac, or take control")
        #expect(YoyoComputer.linux.watchLine == "Watch the desktop, or take control")
        #expect(YoyoComputer.mac.soundLabel(on: true) == "Mute Mac sound")
        #expect(YoyoComputer.linux.soundLabel(on: false) == "Play sound")
        #expect(!YoyoComputer.linux.pictureLabel.contains("Mac"))
    }

    // MARK: Status

    private let install = YoyoUnavailableAction(headline: "Needs an update", title: "Update", url: URL(string: "https://example.com/y.zip")!)

    @Test func theLinuxDesktopNeedsNoInstallNorPermissions() {
        // stubbed off or missing: an available desktop can be shown and controlled
        let bare = ScreenStatus(available: true, displays: [ScreenDisplay(id: 1, width: 1280, height: 832, main: true)])
        let s = YoyoComputer.linux.normalized(bare)
        #expect(s.screenRecording && s.accessibility)
        #expect(YoyoScreenPreview.state(for: s) == .live(.none))
        // plainly unavailable
        let down = ScreenStatus(available: false, reason: "starting")
        #expect(YoyoScreenPreview.state(for: YoyoComputer.linux.normalized(down)) == .unavailable(reason: "starting"))
    }

    @Test func theMacsStatusIsUntouched() {
        let offered = ScreenStatus(available: false, unavailableAction: install)
        #expect(YoyoComputer.mac.normalized(offered) == offered)
        #expect(YoyoScreenPreview.state(for: YoyoComputer.mac.normalized(offered)) == .action(install))
        let noRecording = ScreenStatus(available: true, displays: [ScreenDisplay(id: 1, width: 1512, height: 982, main: true)])
        #expect(YoyoScreenPreview.state(for: YoyoComputer.mac.normalized(noRecording)) == .needsPermission)
    }

    // MARK: Connection words

    @Test func theMacsConnectionWordsStay() {
        #expect(ScreenConnectionText.title(.unavailable(reason: nil, retryAt: nil)) == "Screen unavailable")
        #expect(ScreenConnectionText.detail(.unavailable(reason: "no-session", retryAt: nil))
            == "This account isn’t logged in on the Mac")
        #expect(ScreenConnectionText.detail(.reconnecting(reason: "helper-restart"), host: .mac) == "The screen helper is restarting")
    }

    @Test func thePasteKeyByPlatform() {
        #expect(YoyoComputer.mac.pasteShortcut == ScreenInput(.key, key: "v", modifiers: [.cmd]))
        #expect(YoyoComputer.linux.pasteShortcut == ScreenInput(.key, key: "insert", modifiers: [.shift]))
        #expect(YoyoComputer(YoyoPlatform(rawValue: "windows")).pasteShortcut == ScreenInput(.key, key: "v", modifiers: [.ctrl]))
    }

    @Test func theDesktopsConnectionWordsSayNothingOfTheMac() {
        let host = YoyoComputer.linux
        #expect(ScreenConnectionText.title(.unavailable(reason: nil, retryAt: nil), host: host) == "Desktop unavailable")
        #expect(ScreenConnectionText.title(.reconnecting(reason: "starting"), host: host) == "Connecting…")
        #expect(ScreenConnectionText.detail(.reconnecting(reason: "helper-restart"), host: host) == "The desktop is restarting")
        #expect(ScreenConnectionText.detail(.unavailable(reason: "helper-down", retryAt: nil), host: host) == "The desktop can’t start")
        #expect(ScreenConnectionText.detail(.unavailable(reason: "timeout", retryAt: nil), host: host) == "The desktop isn’t responding")
        // the Mac's own codes have no meaning on Linux: the generic words
        for code in ["no-session", "no-permission", "warp"] {
            #expect(ScreenConnectionText.detail(.unavailable(reason: code, retryAt: nil), host: host)
                == "The desktop can’t be shown right now.", "\(code)")
            #expect(ScreenConnectionText.detail(.reconnecting(reason: code), host: host) == nil, "\(code)")
        }
    }

    // MARK: Missing routes degrade quietly

    @Test func soundThatIsNotThisAccountsIsNotTriedAgain() {
        var p = ScreenAudioPolicy()
        #expect(p.ended(error: YoyoError.http(403, "admin only"), lifetime: .zero) == .giveUp)
        #expect(p.ended(error: YoyoError.http(501, nil), lifetime: .zero) == .giveUp)
        #expect(p.ended(error: YoyoError.http(404, nil), lifetime: .zero) == .giveUp)
    }
}
