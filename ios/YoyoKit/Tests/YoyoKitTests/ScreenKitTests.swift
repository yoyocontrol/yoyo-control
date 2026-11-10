import Foundation
import Security
import Testing
@testable import YoyoClipboard
@testable import YoyoConnect
@testable import YoyoCore
@testable import YoyoDirect
@testable import YoyoScreen

/// The package's hooks around the Screen page: the Mac's key pin, the event hooks, the error hook.
@Suite("ScreenKit")
struct ScreenKitTests {
    /// A self-signed P-256 certificate (openssl) and its fingerprints: the key's (SHA-256 of 04 ‖ X ‖ Y, what Yoyo Control's
    /// pairing QR code carries) and the certificate's DER.
    static let certificate = "MIIBaTCCAQ6gAwIBAgIUOA+sMarn4SPwpIhP1AHdjHTpURAwCgYIKoZIzj0EAwIwGjEYMBYGA1UEAwwPTmVzdFNjcmVlbiB0ZXN0MB4XDTI2MTAzMDAwMjIxMFoXDTM2MTAyNzAwMjIxMFowGjEYMBYGA1UEAwwPTmVzdFNjcmVlbiB0ZXN0MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE6pxH7Vg2Xmmx9h7Jcf+Pw2cHf2Wkj9x1zBVDd/z7xlLPcITLRbTl19kIPNi0n8dfsygqSzMEHeaUxlZUz5xjX6MyMDAwHQYDVR0OBBYEFIOtKpVlvudhd6lCHRw+uixES/8EMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSQAwRgIhANHrV6B6k93xAAiv8zuv7eed7xaztfEZDmRd04KH0Zz+AiEAyNSKZmDRghSpatlAC7dvrXCswrXmtPXhtg/aEq+S/vI="
    static let keyFingerprint = "sha256:458a8db7879e0b300df656bd3e76ad7855e1703633f126e449a6fe66c8df6916"
    static let certFingerprint = "sha256:018a57c6f4d58886579f5b721fcb7bf1a73ba9acf7ad10948c95ef708d69f1a9"

    private func trust() throws -> SecTrust {
        let der = try #require(Data(base64Encoded: Self.certificate))
        let cert = try #require(SecCertificateCreateWithData(nil, der as CFData))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        return try #require(trust)
    }

    @Test func theKeyPinIsTheSHA256OfThePublicKey() throws {
        let der = try #require(Data(base64Encoded: Self.certificate))
        let cert = try #require(SecCertificateCreateWithData(nil, der as CFData))
        #expect(ConnectPin.keyFingerprint(certificate: cert) == Self.keyFingerprint)
        #expect(ConnectPin.fingerprint(der: der) == Self.certFingerprint)
        let t = try trust()
        #expect(ConnectPin.matchesKey(trust: t, Self.keyFingerprint))
        #expect(ConnectPin.matchesKey(trust: t, Self.keyFingerprint.uppercased()), "case doesn't matter")
        #expect(!ConnectPin.matchesKey(trust: t, Self.certFingerprint), "the certificate's hash is not the key's")
    }

    @Test func fingerprintsCompareWithoutCasePrefixOrColons() {
        let hex = String(repeating: "ab", count: 32)
        #expect(ConnectPin.normalized("sha256:" + hex) == hex)
        #expect(ConnectPin.normalized(hex) == hex, "no prefix")
        #expect(ConnectPin.normalized("SHA256:" + hex.uppercased()) == hex, "case")
        let colons = stride(from: 0, to: hex.count, by: 2).map { i -> String in
            let a = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[a...hex.index(after: a)])
        }.joined(separator: ":")
        #expect(ConnectPin.normalized(colons) == hex, "openssl's AA:BB:… form")
        #expect(ConnectPin.normalized(String(hex.dropLast())) == nil, "too short")
        #expect(ConnectPin.normalized("") == nil)
        #expect(ConnectPin.normalized("sha1:" + hex) == nil)
        #expect(ConnectPin.normalized("sha256:" + String(repeating: "g", count: 64)) == nil)
    }

    @Test func eventJSONDecodes() {
        let control = #"{"type":"screen.control","controller":"user","controllerSince":5,"controllerDevice":{"id":"ios-B","name":"iPad"}}"#
        #expect(YoyoEvent(json: Data(control.utf8)) == .control(controller: .user, since: 5, device: ScreenControlDevice(id: "ios-B", name: "iPad")))
        let state = #"{"type":"screen.state","states":[{"display":1,"main":true,"phase":"ready","since":7}]}"#
        #expect(YoyoEvent(json: Data(state.utf8)) == .state(states: [ScreenDisplayState(display: 1, main: true, phase: .ready, since: 7)], console: nil))
        let clip = #"{"type":"clipboard.changed","available":true,"item":{"changeCount":3,"kind":"image","width":10,"height":20}}"#
        #expect(YoyoEvent(json: Data(clip.utf8)) == .clipboard(available: true, summary: ClipboardSummary(changeCount: 3, kind: .image, width: 10, height: 20)))
        #expect(YoyoEvent(json: Data(#"{"type":"session.status"}"#.utf8)) == nil, "not one of the kits' events")
        #expect(YoyoEvent(json: Data("nope".utf8)) == nil)
    }

    @Test func aHubHandsEveryEventToEverySubscriber() async {
        let hub = YoyoEventHub()
        let a = hub.subscribe(), b = hub.subscribe()
        #expect(hub.hasSubscribers)
        hub.post(.control(controller: .agent, since: 1, device: nil))
        var ia = a.makeAsyncIterator(), ib = b.makeAsyncIterator()
        #expect(await ia.next() == .control(controller: .agent, since: 1, device: nil))
        #expect(await ib.next() == .control(controller: .agent, since: 1, device: nil))
    }

    @MainActor
    @Test func errorsAreNotHandledByDefault() {
        #expect(!YoyoHost().handleError(YoyoError.unauthorized))
    }

    @Test func theHostNamesTheKitsSettings() {
        // (the tests run with the default host: a host's namespace prefixes every key the same way)
        #expect(YoyoHost().preferencesNamespace == "Yoyo")
        #expect(ScreenAudio.defaultsKey == "YoyoAudio" && ScreenControlDevice.installIdKey == "YoyoDeviceId")
        #expect(YoyoHost.key("GestureCard2Shown") == "YoyoGestureCard2Shown")
    }
}
