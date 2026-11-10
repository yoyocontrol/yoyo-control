import Foundation
import Testing
@testable import YoyoClipboard
@testable import YoyoCore
@testable import YoyoDirect
@testable import YoyoScreen

/// Several phones on one account's screen (PROTOCOL.md「屏幕」`POST /screen/control`, v2 additive): the holder's device in
/// `ScreenStatus.controllerDevice` and the `screen.control` event, the 409 `controlled-elsewhere` body, this install's id.
/// Every field is lenient: missing / null / junk reads as nil (an older server: today's behaviour).
@Suite("Screen control device")
struct ScreenControlDeviceTests {
    private func status(_ json: String) throws -> ScreenStatus { try JSONDecoder().decode(ScreenStatus.self, from: Data(json.utf8)) }
    private func event(_ json: String) throws -> YoyoEvent? { YoyoEvent(json: Data(json.utf8)) }

    // MARK: ScreenStatus.controllerDevice

    @Test func statusCarriesTheHolder() throws {
        let s = try status(#"{"available":true,"controller":"user","controllerSince":5,"controllerDevice":{"id":"ios-A","name":"Alex’s iPhone"}}"#)
        #expect(s.controllerDevice == ScreenControlDevice(id: "ios-A", name: "Alex’s iPhone"))
        #expect(s.controllingDevice(otherThan: "ios-B") == ScreenControlDevice(id: "ios-A", name: "Alex’s iPhone"))
        #expect(s.controllingDevice(otherThan: "ios-A") == nil, "this phone holds it")
        let noName = try status(#"{"controller":"user","controllerDevice":{"id":"ios-A"}}"#)
        #expect(noName.controllerDevice == ScreenControlDevice(id: "ios-A") && noName.controllerDevice?.name == nil)
    }

    @Test func anOlderServerWithoutTheFieldIsTodaysBehaviour() throws {
        let s = try status(#"{"available":true,"controller":"user","controllerSince":5}"#)
        #expect(s.controller == .user && s.controllerDevice == nil)
        #expect(s.controllingDevice(otherThan: "ios-B") == nil, "an unnamed holder: nobody is a viewer")
        #expect(try status("{}") == ScreenStatus())
    }

    @Test func junkDevicesReadAsNil() throws {
        for junk in [#"null"#, #""ios-A""#, #"42"#, #"[]"#, #"{}"#, #"{"id":""}"#, #"{"id":"   "}"#, #"{"id":7}"#, #"{"name":"x"}"#] {
            let s = try status(#"{"available":true,"controller":"user","controllerDevice":"# + junk + "}")
            #expect(s.controllerDevice == nil, "\(junk)")
            #expect(s.available && s.controller == .user, "the rest still decodes: \(junk)")
        }
        // a bad name is dropped, the id kept (trimmed)
        let s = try status(#"{"controller":"user","controllerDevice":{"id":" ios-A ","name":3}}"#)
        #expect(s.controllerDevice == ScreenControlDevice(id: "ios-A"))
        let blank = try status(#"{"controller":"user","controllerDevice":{"id":"ios-A","name":"  "}}"#)
        #expect(blank.controllerDevice?.name == nil)
    }

    @Test func onlyWhileTheUserHoldsControl() throws {
        for controller in ["agent", "none", "martian"] {
            let s = try status(#"{"controller":"\#(controller)","controllerDevice":{"id":"ios-A"}}"#)
            #expect(s.controllerDevice == nil && s.controllingDevice(otherThan: "ios-B") == nil, "\(controller)")
        }
        #expect(ScreenStatus(controller: .agent, controllerDevice: ScreenControlDevice(id: "ios-A")).controllerDevice == nil)
    }

    // MARK: screen.control

    @Test func screenControlEventCarriesTheHolder() throws {
        #expect(try event(#"{"type":"screen.control","ts":1,"controller":"user","controllerSince":9,"controllerDevice":{"id":"ios-B","name":"iPad"}}"#)
                == .control(controller: .user, since: 9, device: ScreenControlDevice(id: "ios-B", name: "iPad")))
        // an older server: no field
        #expect(try event(#"{"type":"screen.control","ts":1,"controller":"user","controllerSince":9}"#)
                == .control(controller: .user, since: 9, device: nil))
        // null / junk / not the user's
        #expect(try event(#"{"type":"screen.control","controller":"user","controllerDevice":null}"#) == .control(controller: .user, since: nil))
        #expect(try event(#"{"type":"screen.control","controller":"user","controllerDevice":{"id":5}}"#) == .control(controller: .user, since: nil))
        #expect(try event(#"{"type":"screen.control","controller":"none","controllerDevice":{"id":"ios-B"}}"#) == .control(controller: .none, since: nil))
    }

    // MARK: The 409

    @Test func controlledElsewhereBody() {
        let body = #"{"error":"another device controls the screen","code":"controlled-elsewhere","controllerDevice":{"id":"ios-A","name":"Alex’s iPhone"}}"#
        let e = ScreenControlledElsewhere(json: Data(body.utf8))
        #expect(e == ScreenControlledElsewhere(controllerDevice: ScreenControlDevice(id: "ios-A", name: "Alex’s iPhone"), message: "another device controls the screen"))
        // an older server's plain 409, other codes, no readable device, not JSON: nil
        for other in [#"{"error":"take control of the screen first (POST /screen/control)"}"#,
                      #"{"error":"x","code":"something-else","controllerDevice":{"id":"ios-A"}}"#,
                      #"{"error":"x","code":"controlled-elsewhere"}"#,
                      #"{"error":"x","code":"controlled-elsewhere","controllerDevice":{"id":""}}"#,
                      "not json", ""] {
            #expect(ScreenControlledElsewhere(json: Data(other.utf8)) == nil, "\(other)")
        }
    }

    // MARK: This phone

    @Test func limits() {
        #expect(ScreenControlDevice(id: "ios-A", name: "").name == nil)
        #expect(ScreenControlDevice(id: String(repeating: "x", count: 200)).id.count == ScreenControlDevice.idMax)
        #expect(ScreenControlDevice(id: "a", name: String(repeating: "n", count: 100)).name?.count == ScreenControlDevice.nameMax)
    }

    @Test func installIdIsMadeOnceAndKept() throws {
        let suite = "ScreenControlDeviceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ScreenControlDevice.installId(defaults: defaults)
        #expect(!first.isEmpty && first.count <= ScreenControlDevice.idMax)
        #expect(ScreenControlDevice.installId(defaults: defaults) == first)
        #expect(defaults.string(forKey: ScreenControlDevice.installIdKey) == first)
        // another install (fresh defaults) gets another id
        let otherSuite = "\(suite)-other"
        let other = try #require(UserDefaults(suiteName: otherSuite))
        defer { other.removePersistentDomain(forName: otherSuite) }
        #expect(ScreenControlDevice.installId(defaults: other) != first)
    }

    @Test func thisPhoneIsTheAppsIdElseTheInstallId() {
        #expect(ScreenControlDevice.currentId == ScreenControlDevice.installId())
        let before = YoyoHost.current
        var host = before
        host.deviceId = "app-id"
        YoyoHost.current = host
        defer { YoyoHost.current = before }
        #expect(ScreenControlDevice.currentId == "app-id")
    }
}
