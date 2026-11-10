import Foundation
import Testing
@testable import YoyoClipboard
@testable import YoyoCore
@testable import YoyoDirect
@testable import YoyoScreen

/// Several phones on one account: one controls, the others watch with Take Over (ScreenControlModel, the requests).
@Suite("Screen viewers")
struct ScreenViewerTests {
    typealias M = ScreenControlModel
    static let me = "phone-me"
    static let ipad = ScreenControlDevice(id: "ipad-1", name: "Alex’s iPad")

    @Test func whoHoldsIt() {
        #expect(M.role(controller: .none, device: nil, me: Self.me) == .free)
        #expect(M.role(controller: .agent, device: nil, me: Self.me) == .agent)
        #expect(M.role(controller: .user, device: ScreenControlDevice(id: Self.me), me: Self.me) == .me)
        #expect(M.role(controller: .user, device: Self.ipad, me: Self.me) == .other(name: "Alex’s iPad"))
        // an older server (or a holder that named no device): whoever is "user" controls, as before
        #expect(M.role(controller: .user, device: nil, me: Self.me) == .me)
    }

    @Test func anotherPhoneTakingOverFromMeIsSaidOnceAndMakesMeAViewer() {
        var m = M()
        #expect(m.took(controller: .user, device: ScreenControlDevice(id: Self.me), since: 1000, me: Self.me) == nil)
        #expect(m.role == .me && !m.isViewer)
        // the iPad takes over (screen.control / a status)
        #expect(m.status(controller: .user, device: Self.ipad, since: 2000, me: Self.me) == .takenOver(name: "Alex’s iPad"))
        #expect(m.isViewer)
        // said once
        #expect(m.status(controller: .user, device: Self.ipad, since: 2000, me: Self.me) == nil)
        // Take Over: mine again
        #expect(m.took(controller: .user, device: ScreenControlDevice(id: Self.me), since: 3000, me: Self.me) == nil)
        #expect(m.role == .me)
        // the agent takes it, or it is let go: no toast, and not a viewer
        #expect(m.status(controller: .agent, device: nil, since: 4000, me: Self.me) == nil)
        #expect(m.role == .agent && !m.isViewer)
        #expect(m.status(controller: .none, device: nil, since: nil, me: Self.me) == nil && m.role == .free)
    }

    @Test func openingWhileAnotherPhoneControlsIsWatchingWithoutAToast() {
        var m = M()
        #expect(m.status(controller: .user, device: Self.ipad, since: 500, me: Self.me) == nil)
        #expect(m.isViewer && m.role == .other(name: "Alex’s iPad"))
        // the holder let go: free (the page may take it then)
        #expect(m.status(controller: .none, device: nil, since: nil, me: Self.me) == nil && !m.isViewer)
    }

    @Test func aRefusedInputMakesMeAViewer() {
        var m = M()
        _ = m.took(controller: .user, device: ScreenControlDevice(id: Self.me), since: 1000, me: Self.me)
        let refusal = ScreenControlledElsewhere(controllerDevice: Self.ipad, message: "another device controls the screen")
        #expect(m.refused(refusal) == .takenOver(name: "Alex’s iPad"))
        #expect(m.isViewer)
        #expect(m.refused(refusal) == nil, "the inputs queued behind it say nothing more")
    }

    @Test func aStatusFromBeforeMyTakeIsStale() {
        var m = M()
        _ = m.took(controller: .user, device: ScreenControlDevice(id: Self.me), since: 5000, me: Self.me)
        // a poll that left before the take still says the iPad holds it
        #expect(m.status(controller: .user, device: Self.ipad, since: 4000, me: Self.me) == nil)
        #expect(m.role == .me)
        // a later take by the iPad counts (even at the same instant)
        #expect(m.status(controller: .user, device: Self.ipad, since: 5000, me: Self.me) == .takenOver(name: "Alex’s iPad"))
    }

    @Test func anOldServerNeverMakesAViewer() {
        var m = M()
        _ = m.took(controller: .user, device: nil, since: nil, me: Self.me)
        #expect(m.status(controller: .user, device: nil, since: nil, me: Self.me) == nil && m.role == .me)
        #expect(M.displayName(nil) == ("Another device") && M.displayName("") == ("Another device"))
        #expect(M.displayName("iPhone") == ("Another iPhone") && M.displayName("iPad") == ("Another iPad"))
        #expect(M.displayName("Mia’s iPhone") == "Mia’s iPhone")
    }
}
