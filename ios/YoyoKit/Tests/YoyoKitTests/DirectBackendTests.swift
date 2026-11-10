import Foundation
import Testing
@testable import YoyoClipboard
@testable import YoyoConnect
@testable import YoyoCore
@testable import YoyoDirect
@testable import YoyoScreen

/// The direct backend's mapping of a Yoyo Control Mac's answers onto the page's model (Direct/DirectBackend.swift,
/// docs/REMOTE.md), and the pairing URL.
struct DirectBackendTests {
    private let mac: [String: Any] = [
        "ok": true, "screenRecording": true, "accessibility": true,
        "displays": [["id": 1, "width": 1728, "height": 1117, "scale": 2, "main": true, "asleep": false, "kind": "builtin"]],
        "states": [["display": 1, "main": true, "phase": "ready", "since": 1]],
        "console": ["locked": false],
        "agentControl": ["active": false, "esc": false],
        "control": ["controller": "none"],
        "app": "YoyoControl", "api": 1, "version": "dev",
    ]

    @Test func statusMapsOntoThePagesModel() throws {
        let s = try DirectBackend.status(fromMac: mac)
        #expect(s.available)
        #expect(s.screenRecording && s.accessibility)
        #expect(s.displays.map(\.id) == [1])
        #expect(s.states.count == 1)
        #expect(s.controller == .none)
    }

    @Test func aPhoneHoldingControlIsTheUser() throws {
        var m = mac
        m["control"] = ["controller": "remote", "since": 1_800_000_000_000.0, "device": ["id": "phone-1234", "name": "A"]]
        let s = try DirectBackend.status(fromMac: m)
        #expect(s.controller == .user)
        #expect(s.controllerDevice == ScreenControlDevice(id: "phone-1234", name: "A"))
        #expect(s.controllerSince == 1_800_000_000_000)
        #expect(s.controllingDevice(otherThan: "phone-1234") == nil)
        #expect(s.controllingDevice(otherThan: "other-5678")?.name == "A")
    }

    @Test func anAgentWithoutAPhoneIsTheAgent() throws {
        var m = mac
        m["agentControl"] = ["active": true, "esc": true]
        #expect(try DirectBackend.status(fromMac: m).controller == .agent)
        m["ok"] = false
        m["error"] = "no GUI session"
        let s = try DirectBackend.status(fromMac: m)
        #expect(!s.available)
        #expect(s.reason == "no GUI session")
    }

    @Test func automationIsTheAgentAndOlderMacsStillSayAgentControl() throws {
        var m = mac
        m["agentControl"] = nil
        m["automation"] = ["active": true, "esc": false, "label": "Claude"]
        #expect(try DirectBackend.status(fromMac: m).controller == .agent)
        m["automation"] = ["active": false, "esc": false]
        m["agentControl"] = ["active": true, "esc": false]
        #expect(try DirectBackend.status(fromMac: m).controller == .none, "automation wins over the older field")
    }

    @Test func streamsAskForTheYoyoNames() throws {
        let b = DirectBackend(ways: nil, token: "t", serverId: "s", fingerprint: "sha256:00")
        let stream = try b.streamRequest(display: nil, maxWidth: nil, quality: nil, fps: 30, options: ScreenStreamOptions(), route: b.route)
        #expect(stream.value(forHTTPHeaderField: "Accept") == "application/vnd.yoyo-control.stream")
        #expect(try b.audioRequest(route: b.route).value(forHTTPHeaderField: "Accept") == "application/vnd.yoyo-control.audio")
        #expect(ScreenStreamPart.Kind(contentType: "application/vnd.yoyo-control.cursor+json") == .cursor)
        #expect(ScreenStreamPart.Kind(contentType: "application/vnd.yoyo-control.status+json; charset=utf-8") == .status)
        #expect(StreamPartParser.boundary(fromContentType: "application/vnd.yoyo-control.stream; boundary=frame") == "frame")
    }

    @Test func eventLinesBecomeScreenEvents() throws {
        let state = try #require(DirectBackend.event(fromMacLine: ["type": "state", "states": [], "console": NSNull()]))
        #expect(state["type"] as? String == "screen.state")
        #expect(state["console"] == nil)
        let control = try #require(DirectBackend.event(fromMacLine: [
            "type": "control", "control": ["controller": "remote", "since": 5.0, "device": ["id": "phone-1234", "name": "A"]],
        ]))
        let decoded = YoyoEvent(json: try JSONSerialization.data(withJSONObject: control))
        #expect(decoded == .control(controller: .user, since: 5, device: ScreenControlDevice(id: "phone-1234", name: "A")))
        // the clipboard's summary line: a clipboard event
        let clip = try #require(DirectBackend.event(fromMacLine: ["type": "clipboard", "changeCount": 7, "kind": "text", "preview": "hi"]))
        guard case .clipboard(let available, let summary)? = YoyoEvent(json: try JSONSerialization.data(withJSONObject: clip)) else {
            Issue.record("not a clipboard event"); return
        }
        #expect(available == true && summary?.changeCount == 7 && summary?.kind == .text && summary?.preview == "hi")
        #expect(DirectBackend.event(fromMacLine: ["type": "ping"]) == nil)
    }

    @Test func streamRequestCarriesTheOptionsAsQuery() throws {
        let b = DirectBackend(ways: nil, token: "t", serverId: "s", fingerprint: "sha256:00")
        let options = ScreenStreamOptions(codecs: [.hevc, .h264], stream: "abcdefgh12", ack: true, clientCursor: true, status: true)
        let req = try b.streamRequest(display: 1, maxWidth: 3840, quality: nil, fps: 60, options: options, route: b.route)
        #expect(req.httpMethod == "GET")
        #expect(req.url?.path() == "/stream")
        let items = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(q["codecs"] == "hevc,h264")
        #expect(q["cursor"] == "client")
        #expect(q["ack"] == "1" && q["status"] == "1" && q["fps"] == "60" && q["display"] == "1")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        #expect(req.url?.host() == DirectBackend.linkBase.host(), "never dialed: the request goes over the link")
    }
}
