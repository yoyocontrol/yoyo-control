import AVFoundation
import Foundation
import Testing
@testable import YoyoClipboard
@testable import YoyoCore
@testable import YoyoDirect
@testable import YoyoScreen

/// What the computer behind the Screen page is and can do: `ScreenStatus.platform` / `features`, decoded leniently;
/// the clipboard and the speaker follow them, and an older computer that says neither behaves as before (the
/// clipboard is the Mac's, sound is found out by asking).
/// The tests run in English.
@Suite("Screen features")
struct ScreenFeaturesTests {
    private func decode(_ json: String) throws -> ScreenStatus { try JSONDecoder().decode(ScreenStatus.self, from: Data(json.utf8)) }

    // MARK: Decoding

    @Test func decodesALinuxDesktopsFeatures() throws {
        let s = try decode(#"""
        {"available":true,"platform":"linux",
         "features":{"clipboard":true,"audio":false,"cursor":true,"focus":false,"ime":true}}
        """#)
        #expect(s.available && s.platform == .linux)
        #expect(s.features == ScreenFeatures(clipboard: true, audio: false, cursor: true, focus: false))
        #expect(try decode(#"{"platform":"mac"}"#).platform == .mac)
    }

    @Test func anOlderServerSaysNeither() throws {
        let s = try decode(#"{"available":true,"screenRecording":true,"accessibility":true}"#)
        #expect(s.platform == nil && s.features == nil)
        #expect(try decode("{}") == ScreenStatus())
    }

    @Test func nullsAndOddValuesNeverFailTheStatus() throws {
        let nulls = try decode(#"{"available":true,"platform":null,"features":null}"#)
        #expect(nulls.available && nulls.platform == nil && nulls.features == nil)
        // an open set: an unknown platform is kept as it is (named generically); an empty one or one that isn't a string
        // is not said
        #expect(try decode(#"{"platform":"windows"}"#).platform == YoyoPlatform(rawValue: "windows"))
        #expect(try decode(#"{"platform":""}"#).platform == nil)
        #expect(try decode(#"{"platform":3}"#).platform == nil)
        // features that aren't an object: not said; a value that isn't a boolean: that one not said
        #expect(try decode(#"{"features":true}"#).features == nil)
        #expect(try decode(#"{"features":[1]}"#).features == nil)
        let odd = try decode(#"{"available":true,"features":{"clipboard":"yes","audio":null,"cursor":1}}"#)
        #expect(odd.available && odd.features == ScreenFeatures())
        #expect(try decode(#"{"features":{}}"#).features == ScreenFeatures())
    }

    // MARK: Whose computer

    @Test func thePlatformDecidesBeforeTheBackendsHint() {
        #expect(YoyoComputer.of(platform: .linux, hint: .mac) == .linux)
        #expect(YoyoComputer.of(platform: .mac, hint: .linux) == .mac)
        // not said: the backend's hint, else the Mac
        #expect(YoyoComputer.of(platform: nil, hint: .linux) == .linux)
        #expect(YoyoComputer.of(platform: nil, hint: nil) == .mac)
        #expect(YoyoComputer.linux.resolved(nil) == .linux && YoyoComputer.linux.resolved(.mac) == .mac)
    }

    // MARK: The clipboard

    @Test func theClipboardIsWhatTheServerSays() {
        // said: as said, whoever's computer it is
        #expect(YoyoComputer.linux.hasClipboard(ScreenFeatures(clipboard: true)))
        #expect(!YoyoComputer.linux.hasClipboard(ScreenFeatures(clipboard: false)))
        #expect(!YoyoComputer.mac.hasClipboard(ScreenFeatures(clipboard: false)))
        // not said (an older server, a features object without the key): the Mac's only
        #expect(YoyoComputer.mac.hasClipboard(nil) && YoyoComputer.mac.hasClipboard(ScreenFeatures(audio: true)))
        #expect(!YoyoComputer.linux.hasClipboard(nil) && !YoyoComputer.linux.hasClipboard(ScreenFeatures(audio: true)))
    }

    @Test func thePasteKeyIsShiftInsertOnLinux() {
        #expect(YoyoComputer.linux.pasteShortcut == ScreenInput(.key, key: "insert", modifiers: [.shift]))
        #expect(YoyoComputer.mac.pasteShortcut == ScreenInput(.key, key: "v", modifiers: [.cmd]))
        // the body the Linux server gets
        let body = YoyoComputer.linux.pasteShortcut.json
        #expect(body["type"] as? String == "key" && body["key"] as? String == "insert")
        #expect(body["modifiers"] as? [String] == ["shift"])
    }

    // MARK: Sound

    @Test func theSpeakerHidesOnlyWhenTheServerSaysNoSound() {
        #expect(ScreenFeatures.soundOff(ScreenFeatures(audio: false)))
        #expect(!ScreenFeatures.soundOff(ScreenFeatures(audio: true)))
        #expect(!ScreenFeatures.soundOff(ScreenFeatures(clipboard: true)), "not said: asked for, the answer decides")
        #expect(!ScreenFeatures.soundOff(nil))
    }

    // MARK: Words

    @Test func theClipboardWordsNameTheComputer() {
        let linux = YoyoComputer.linux
        #expect(linux.pasteLabel == "Paste on Computer" && linux.copyLabel == "Copy from Computer")
        #expect(linux.sendTitle == "Send to Computer" && linux.onYourComputer == "On your computer")
        #expect(linux.pasted == "Pasted on the computer")
        #expect(linux.copiedTakeControl == "Copied to the computer. Take control to paste.")
        #expect(linux.sent(savedIn: "Downloads") == "Sent to the computer · saved in Downloads")
        #expect(linux.sendingFiles(3) == "Sending 3 files to the computer…")
        // every computer-naming word of the desktop's clipboard says nothing of the Mac
        let words = [linux.pasteLabel, linux.copyLabel, linux.sendTitle, linux.onYourComputer, linux.pasted, linux.copiedTakeControl,
                     linux.copiedFrom, linux.clipboardConcealed, linux.clipboardEmptyMessage, linux.clipboardEmpty, linux.clipboardNothing,
                     linux.sendingFiles(2), linux.copiedTo, linux.sent(savedIn: nil), linux.copiedOn(""), linux.copiedOn("just now"),
                     linux.copiedHint("x"), linux.phoneHint("text"), linux.pasteExplained, linux.copyExplained, linux.sendFooter,
                     linux.folderOnComputer, linux.copySomething, linux.watchLine, linux.title, linux.pictureLabel,
                     linux.soundLabel(on: true), linux.soundLabel(on: false)]
        for w in words { #expect(!w.contains("Mac"), "\(w)") }
        // the Mac's stay as they were
        #expect(YoyoComputer.mac.pasteLabel == "Paste on Mac" && YoyoComputer.mac.copiedTo == "Copied to the Mac")
        #expect(YoyoComputer.mac.sent(savedIn: "Downloads") == "Sent to the Mac · saved in Downloads")
    }

    @MainActor @Test func theClipboardsLinesFollowTheHost() {
        let s = ClipboardSummary(changeCount: 1, kind: .text, preview: "hello", source: .mac)
        #expect(ClipboardActions.macHint(s) == "Copied on Mac: “hello” — Copy to iPhone")
        #expect(ClipboardActions.macHint(s, host: .linux) == "Copied on computer: “hello” — Copy to iPhone")
        #expect(ClipboardActions.phoneHint(.text, host: .linux) == "iPhone clipboard: text — Paste on Computer")
        #expect(ClipboardActions.footer(s, host: .linux) == "Copied on the computer")
        #expect(ClipboardActions.copyItem(mac: ClipboardStatus(available: true), host: .linux)
            == .init(enabled: false, subtitle: "The computer’s clipboard is empty"))
        let r = ClipboardPutResponse(status: ClipboardStatus(available: true))
        #expect(ClipboardTransfer.sentMessage(.text("a"), r, computer: .linux) == "Copied to the computer")
        #expect(ClipboardTransfer.sentMessage(.text("a"), r) == "Copied to the Mac")
    }
}

// MARK: What the server said, kept

@MainActor
@Suite("Screen capabilities")
struct ScreenCapabilitiesTests {
    @Test func anAnswerThatDoesntSayKeepsWhatWasSaid() {
        let scope = "screen-capabilities-tests:\(UUID().uuidString)"
        // nothing said yet: nothing kept (an older server)
        let old = YoyoCapabilities.note(ScreenStatus(available: true), scope: scope)
        #expect(old.platform == nil && old.features == nil)
        #expect(YoyoCapabilities.features(scope: scope) == nil)
        // said once …
        let f = ScreenFeatures(clipboard: true, audio: true)
        _ = YoyoCapabilities.note(ScreenStatus(available: true, platform: .linux, features: f), scope: scope)
        // … an answer without them (the helper restarting, a control answer) keeps them
        let quiet = YoyoCapabilities.note(ScreenStatus(available: false), scope: scope)
        #expect(quiet.platform == .linux && quiet.features == f && !quiet.available)
        // a new value replaces the old one
        let off = ScreenFeatures(clipboard: true, audio: false)
        #expect(YoyoCapabilities.note(ScreenStatus(features: off), scope: scope).features == off)
        #expect(YoyoCapabilities.features(scope: scope) == off && YoyoCapabilities.platform(scope: scope) == .linux)
        // per account
        #expect(YoyoCapabilities.features(scope: scope + "-other") == nil)
    }
}

// MARK: The speaker on the page (ScreenSession)

@MainActor
@Suite("Screen sound by the server's features")
struct ScreenSessionSoundFeatureTests {
    typealias T = ScreenSessionTests

    let backend = T.Backend()
    let host = T.Host()
    let net = ScreenSessionSoundTests.Net()
    let session: ScreenSession

    init() {
        let name = "screen-sound-feature-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        session = ScreenSession(backend: backend, videoOutput: ScreenVideoOutput(renderer: AVSampleBufferDisplayLayer().sampleBufferRenderer),
                                defaults: defaults, environment: net.environment)
        session.host = host
    }

    @Test func noSoundSaidBeforeTheStreamAsksForNone() {
        session.statusChanged(ScreenStatus(available: true, platform: .linux, features: ScreenFeatures(clipboard: true, audio: false)))
        #expect(session.audioUnsupported)
        session.activate()
        #expect(net.streams.count == 1 && net.audios.isEmpty, "no sound asked for")
        session.deactivate()
    }

    @Test func soundSaidOffStopsItAtOnceAndSaidAgainBringsItBack() {
        session.activate()
        #expect(net.audios.count == 1 && !session.audioUnsupported)
        let changes = host.audioChanges
        session.statusChanged(ScreenStatus(available: true, features: ScreenFeatures(audio: false)))
        #expect(session.audioUnsupported && net.audios[0].stopped && host.audioChanges == changes + 1)
        // the same again: nothing new
        session.statusChanged(ScreenStatus(available: true, features: ScreenFeatures(audio: false)))
        #expect(host.audioChanges == changes + 1 && net.audios.count == 1)
        // sound back (pulse came up): asked for again
        session.statusChanged(ScreenStatus(available: true, features: ScreenFeatures(audio: true)))
        #expect(!session.audioUnsupported && net.audios.count == 2 && !net.audios[1].stopped)
        session.deactivate()
    }

    @Test func anOlderServerAsksAsBefore() async {
        session.statusChanged(ScreenStatus(available: true))
        session.activate()
        #expect(net.audios.count == 1 && !session.audioUnsupported)
        // the answer decides: 404 hides the speaker for the visit
        net.audios[0].onEnd(YoyoError.http(404, nil))
        for _ in 0..<100 where !session.audioUnsupported { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(session.audioUnsupported && net.audios.count == 1)
        session.deactivate()
    }
}

// MARK: The clipboard gate follows the computer

@Suite("Screen clipboard gate")
struct ScreenClipboardGateTests {
    @Test func aFlipFromOnToOffHidesAndTheOldObserverIsIgnored() {
        var g = ScreenClipboardGate()
        #expect(g.on == nil)
        // the role's guess for a member: no clipboard (the keys and the button hidden, nothing observed)
        #expect(g.update(false) == .stop(wasOn: false))
        #expect(g.update(false) == nil, "the same answer again changes nothing")
        // the server says it has one: observed as epoch 2
        #expect(g.update(true) == .start(epoch: 2))
        #expect(g.isCurrent(2))
        // it stops having one (the helper's clipboard went, a downgraded server): hidden, epoch 2's observer is stale
        #expect(g.update(false) == .stop(wasOn: true))
        #expect(!g.isCurrent(2))
        // back again: a new observer; the one from before still doesn't speak
        #expect(g.update(true) == .start(epoch: 4))
        #expect(g.isCurrent(4) && !g.isCurrent(2))
    }

    @Test func notThisAccountsClipboardHidesLikeNotThere() {
        #expect(ScreenClipboardGate.supported(value: true, error: nil))
        // 404 is the resource's `unsupported` (no value, no error)
        #expect(!ScreenClipboardGate.supported(value: false, error: nil))
        #expect(!ScreenClipboardGate.supported(value: false, error: YoyoError.http(403, "admin only")))
        // other failures keep the keys (a tap says why)
        #expect(ScreenClipboardGate.supported(value: false, error: YoyoError.http(503, nil)))
        #expect(ScreenClipboardGate.supported(value: false, error: URLError(.timedOut)))
    }
}
