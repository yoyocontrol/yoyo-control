import CoreFoundation
import CoreGraphics
import Foundation
import UIKit

// A computer's screen (docs/PROTOCOL.md): a live view of the console's screen and input into it, through Yoyo Control
// on the computer. Automation on it can drive it too (`agent`); `controller` says who does. Every model decodes
// leniently: a field that is missing, null or of an unknown value never fails the rest.

/// Who is driving the screen. Unknown / missing values are `.none`.
public enum ScreenController: String, Sendable, Equatable, Hashable {
    case none, agent, user

    public init(lenient raw: String?) { self = raw.flatMap(Self.init(rawValue:)) ?? .none }
}

/// A phone that controls the screen (docs/REMOTE.md「控制权」): several phones may watch at once, one controls. A backend
/// tells the computer which phone sends a request (its token, or `current` in a header / body of its own); read back as
/// `ScreenStatus.controllerDevice` and the `screen.control` event's `controllerDevice`. Lenient: without a non-empty
/// string `id` it does not decode (the field reads as nil); a `name` that isn't a non-empty string is nil.
public struct ScreenControlDevice: Sendable, Equatable, Hashable {
    /// This install's id (≤ 128 characters).
    public var id: String
    /// Something to show ("Alex's iPhone", ≤ 80 characters). nil = none given.
    public var name: String?

    public init(id: String, name: String? = nil) {
        self.id = String(id.prefix(Self.idMax))
        self.name = name.flatMap { $0.isEmpty ? nil : String($0.prefix(Self.nameMax)) }
    }

    public static let idMax = 128
    public static let nameMax = 80
    /// `{ id, name? }` (a body naming this phone).
    public var json: [String: Any] { name.map { ["id": id, "name": $0] } ?? ["id": id] }

    /// This phone's id: `YoyoHost.deviceId`, else `installId()`. Any thread.
    public static var currentId: String { YoyoHost.current.deviceId ?? installId() }

    private static let primedName = YoyoLocked<String?>(nil)

    /// This phone: `currentId` and the device's name (once `prime()` ran on the main actor; the pages do). Any thread.
    public static var current: ScreenControlDevice { ScreenControlDevice(id: currentId, name: primedName.withLock { $0 }) }

    /// Reads the device's name for `current` (main actor only).
    @MainActor public static func prime() {
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        primedName.withLock { $0 = name }
    }

    /// `<namespace>DeviceId`.
    public static var installIdKey: String { YoyoHost.key("DeviceId") }

    /// A random id made on first use and kept in `defaults` (a reinstall makes a new one). The same id every time after.
    public static func installId(defaults: UserDefaults = .standard) -> String {
        if let id = defaults.string(forKey: installIdKey), !id.isEmpty, id.count <= idMax { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: installIdKey)
        return id
    }
}

extension ScreenControlDevice: Decodable {
    private enum K: String, CodingKey { case id, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        guard let id = ((try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "device id")
        }
        let name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(id: id, name: name)
    }
}

/// The 409 a phone's `POST /input` gets while another phone holds control:
/// `{ error, code: "controlled-elsewhere", controllerDevice }`. `init?(json:)` is nil for any other body (the plain 409
/// "take control first", or a body without a readable `controllerDevice`).
public struct ScreenControlledElsewhere: Sendable, Equatable {
    public static let code = "controlled-elsewhere"

    /// The phone that holds control.
    public var controllerDevice: ScreenControlDevice
    /// The server's `error` text (English, for logs).
    public var message: String?

    public init(controllerDevice: ScreenControlDevice, message: String? = nil) {
        self.controllerDevice = controllerDevice
        self.message = message
    }

    public init?(json data: Data) {
        struct Body: Decodable {
            public var error: String?
            public var code: String?
            public var controllerDevice: ScreenControlDevice?
            private enum K: String, CodingKey { case error, code, controllerDevice }
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: K.self)
                error = (try? c.decodeIfPresent(String.self, forKey: .error)) ?? nil
                code = (try? c.decodeIfPresent(String.self, forKey: .code)) ?? nil
                controllerDevice = (try? c.decodeIfPresent(ScreenControlDevice.self, forKey: .controllerDevice)) ?? nil
            }
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data), body.code == Self.code, let device = body.controllerDevice else { return nil }
        self.init(controllerDevice: device, message: body.error)
    }
}

/// `POST /input` refused with 409 `controlled-elsewhere` (another phone holds control): thrown by the backend.
extension ScreenControlledElsewhere: Error, LocalizedError {
    public var errorDescription: String? { message }
}

/// What kind of display it is (`ScreenDisplay.kind`). Unknown values decode as nil.
public enum ScreenDisplayKind: String, Sendable, Equatable, Hashable {
    /// The Mac's own panel.
    case builtin
    /// Anything else WindowServer lists.
    case external
}

/// One display: `width` / `height` in points, `scale` pixels per point.
public struct ScreenDisplay: Sendable, Equatable, Hashable, Identifiable {
    public var id: UInt32
    public var width: Double
    public var height: Double
    public var scale: Double = 1
    public var main: Bool = false
    /// The display sleeps (a frame would wake it). Missing: false.
    public var asleep: Bool = false
    /// The display's own name as macOS calls it ("Built-in Retina Display", "LG UltraFine", …); nil when it has none.
    public var name: String?
    /// builtin / external; missing or unknown values: nil.
    public var kind: ScreenDisplayKind?

    /// width / height (1 when unknown).
    public var aspect: Double { width > 0 && height > 0 ? width / height : 1 }

    public init(id: UInt32, width: Double, height: Double, scale: Double = 1, main: Bool = false, asleep: Bool = false, name: String? = nil, kind: ScreenDisplayKind? = nil) {
        self.id = id; self.width = width; self.height = height; self.scale = scale; self.main = main; self.asleep = asleep; self.name = name; self.kind = kind
    }
}

extension ScreenDisplay: Decodable {
    private enum K: String, CodingKey { case id, width, height, scale, main, asleep, name, kind }

    /// Lenient: only `id` is required (a number); the rest fall back.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        func num(_ k: K) -> Double? { (try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil }
        guard let raw = num(.id), raw >= 0, raw <= Double(UInt32.max) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "display id")
        }
        id = UInt32(raw)
        width = num(.width) ?? 0
        height = num(.height) ?? 0
        scale = num(.scale).flatMap { $0 > 0 ? $0 : nil } ?? 1
        main = ((try? c.decodeIfPresent(Bool.self, forKey: .main)) ?? nil) ?? false
        asleep = ((try? c.decodeIfPresent(Bool.self, forKey: .asleep)) ?? nil) ?? false
        func text(_ k: K) -> String? { ((try? c.decodeIfPresent(String.self, forKey: k)) ?? nil).flatMap { $0.isEmpty ? nil : $0 } }
        name = text(.name)
        kind = text(.kind).flatMap(ScreenDisplayKind.init(rawValue:))
    }
}

/// A computer's status (`GET /status`, the answer of a control or permissions request). Lenient: every field may be
/// missing, null or of an unknown value.
public struct ScreenStatus: Sendable, Equatable {
    /// Yoyo Control runs in the console's GUI session and has a display to show.
    public var available: Bool = false
    /// Why not (`available == false`); while available, what permission is missing (if any).
    public var reason: String?
    /// Its TCC grants on a Mac: frames need Screen Recording, input needs Accessibility.
    public var screenRecording: Bool = false
    public var accessibility: Bool = false
    public var displays: [ScreenDisplay] = []
    public var controller: ScreenController = .none
    /// ms since epoch when the current controller took over (nil when `.none`).
    public var controllerSince: Double?
    /// How each display's picture is doing (may name displays not in `displays`). Empty when not said.
    public var states: [ScreenDisplayState] = []
    /// Whether the Mac's console is locked. nil = not known yet.
    public var console: ScreenConsole?
    /// The phone that holds control: only while `controller == .user` and it named itself. nil = an older computer, an
    /// older client holding it, or nobody's phone.
    public var controllerDevice: ScreenControlDevice?
    /// What kind of computer the screen is. nil = not said (an older one, or it isn't answering): the backend's hint
    /// decides, else a Mac (`YoyoComputer.of(platform:hint:)`).
    public var platform: YoyoPlatform?
    /// What the computer can do right now: the clipboard, sound, … nil = not said: the clipboard is the Mac's only and
    /// sound is found out by asking (`YoyoComputer.hasClipboard(_:)`, `ScreenFeatures.soundOff`).
    public var features: ScreenFeatures?
    /// What the page offers while the screen can't be shown (`available == false`): something the backend knows the user
    /// can do about it (install or update the app that serves the screen…). Not decoded: the backend sets it.
    public var unavailableAction: YoyoUnavailableAction?

    public init(available: Bool = false, reason: String? = nil, screenRecording: Bool = false, accessibility: Bool = false,
         displays: [ScreenDisplay] = [], controller: ScreenController = .none, controllerSince: Double? = nil,
         states: [ScreenDisplayState] = [], console: ScreenConsole? = nil, controllerDevice: ScreenControlDevice? = nil,
         platform: YoyoPlatform? = nil, features: ScreenFeatures? = nil, unavailableAction: YoyoUnavailableAction? = nil) {
        self.available = available; self.reason = reason; self.screenRecording = screenRecording
        self.accessibility = accessibility; self.displays = displays; self.controller = controller
        self.controllerSince = controllerSince; self.states = states; self.console = console
        self.controllerDevice = controller == .user ? controllerDevice : nil
        self.platform = platform; self.features = features; self.unavailableAction = unavailableAction
    }

    /// Another phone than `deviceId` controls the screen (this one is a viewer): that phone. nil while nobody, the agent,
    /// this phone, or an unnamed phone (an older client / computer) holds it.
    public func controllingDevice(otherThan deviceId: String) -> ScreenControlDevice? {
        guard controller == .user, let d = controllerDevice, d.id != deviceId else { return nil }
        return d
    }

    /// The main display, else the first.
    public var mainDisplay: ScreenDisplay? { displays.first(where: \.main) ?? displays.first }
}

extension ScreenStatus: Decodable {
    private enum K: String, CodingKey {
        case available, reason, screenRecording, accessibility, displays, controller, controllerSince, states, console
        case controllerDevice, platform, features
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        func bool(_ k: K) -> Bool? { (try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil }
        available = bool(.available) ?? false
        reason = ((try? c.decodeIfPresent(String.self, forKey: .reason)) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        screenRecording = bool(.screenRecording) ?? false
        accessibility = bool(.accessibility) ?? false
        // a malformed display is dropped, not the whole list
        displays = c.lenientList(ScreenDisplay.self, forKey: .displays)
        controller = ScreenController(lenient: (try? c.decodeIfPresent(String.self, forKey: .controller)) ?? nil)
        controllerSince = (try? c.decodeIfPresent(Double.self, forKey: .controllerSince)) ?? nil
        states = c.lenientList(ScreenDisplayState.self, forKey: .states)
        console = (try? c.decodeIfPresent(ScreenConsole.self, forKey: .console)) ?? nil
        // only meaningful while the user holds control
        controllerDevice = controller == .user ? (try? c.decodeIfPresent(ScreenControlDevice.self, forKey: .controllerDevice)) ?? nil : nil
        platform = ((try? c.decodeIfPresent(String.self, forKey: .platform)) ?? nil).flatMap { $0.isEmpty ? nil : YoyoPlatform(rawValue: $0) }
        features = (try? c.decodeIfPresent(ScreenFeatures.self, forKey: .features)) ?? nil
    }
}

/// `ScreenStatus.features` (an open set; unknown keys ignored): what the computer can do right now. Each is three-state: nil = not said (the client's old behaviour), else what the helper reports. Lenient: a
/// value that isn't a boolean reads as not said; a `features` that isn't an object is not said at all.
public struct ScreenFeatures: Sendable, Equatable, Decodable {
    /// This computer's clipboard (`/clipboard`, `clipboard.changed`).
    public var clipboard: Bool?
    /// Its sound (`GET /audio`).
    public var audio: Bool?
    /// The pointer drawn by the client (`cursor=client`).
    public var cursor: Bool?
    /// `GET /focus`.
    public var focus: Bool?

    public init(clipboard: Bool? = nil, audio: Bool? = nil, cursor: Bool? = nil, focus: Bool? = nil) {
        self.clipboard = clipboard; self.audio = audio; self.cursor = cursor; self.focus = focus
    }

    private enum K: String, CodingKey { case clipboard, audio, cursor, focus }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        func bool(_ k: K) -> Bool? { (try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil }
        clipboard = bool(.clipboard)
        audio = bool(.audio)
        cursor = bool(.cursor)
        focus = bool(.focus)
    }

    /// The server says the computer has no sound now: the speaker hides at once (no `GET /audio` to find out).
    /// Not said: the sound is asked for and its answer decides (404 / 503, `ScreenAudioPolicy`).
    public static func soundOff(_ f: ScreenFeatures?) -> Bool { f?.audio == false }
}

/// What a page offers while the computer's screen can't be shown: `title` on a button that opens `url` (install or update
/// the app that serves the screen, open a settings page…), with the words above it.
public struct YoyoUnavailableAction: Sendable, Equatable {
    /// The headline instead of "Screen unavailable" (nil: that).
    public var headline: String?
    /// The line under it (nil: the status's reason).
    public var message: String?
    /// The button's title.
    public var title: String
    public var url: URL
    /// An SF Symbol for it (nil: the page's own).
    public var symbol: String?
    /// A short line for a list row (`YoyoScreenPreview`; nil: the headline).
    public var rowLine: String?

    public init(headline: String? = nil, message: String? = nil, title: String, url: URL, symbol: String? = nil,
                rowLine: String? = nil) {
        self.headline = headline; self.message = message; self.title = title; self.url = url; self.symbol = symbol
        self.rowLine = rowLine
    }
}

/// `GET /focus`: whether the Mac's focused element takes typing; the page brings up the keyboard
/// when it does. Lenient: anything but `editable: true` is not editable, and a body that isn't JSON is too.
public struct ScreenFocus: Sendable, Equatable {
    public var editable: Bool
    /// The focused element's accessibility role ("AXTextField"…), for logs.
    public var role: String?

    public init(editable: Bool, role: String? = nil) {
        self.editable = editable
        self.role = role
    }

    public init(json data: Data) {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        // a JSON `true` only (NSNumber 1 bridges to Bool too)
        let flag = body?["editable"] as? NSNumber
        editable = flag.map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
        role = body?["role"] as? String
    }
}

// MARK: Connection state (`states` / `console`, the `screen.state` event, status parts)

/// Where a display's picture is. Unknown / missing values are `.reconnecting` (the picture isn't there; it may come).
public enum ScreenPhase: String, Sendable, Equatable {
    case connecting, reconnecting, ready, unavailable

    public init(lenient raw: String?) { self = raw.flatMap(Self.init(rawValue:)) ?? .reconnecting }
}

/// One display's connection state (`ScreenDisplayState`). `reason` is a code of an open set (the page turns it into
/// text, a generic one for codes it doesn't know); `detail` is English, for the stats line only. Lenient: only
/// `display` is required (a number); a missing `since` is the time it was decoded; unknown fields are ignored.
public struct ScreenDisplayState: Sendable, Equatable {
    public var display: UInt32
    /// The entry of the account's main (real) screen: it stands in for a main display whose id changed.
    public var main: Bool = false
    public var phase: ScreenPhase
    public var reason: String?
    /// ms (Mac clock) when this phase + reason began.
    public var since: Double
    /// ms (Mac clock) of the next connection attempt.
    public var retryAt: Double?
    public var detail: String?

    public init(display: UInt32, main: Bool = false, phase: ScreenPhase, reason: String? = nil, since: Double = 0,
         retryAt: Double? = nil, detail: String? = nil) {
        self.display = display; self.main = main; self.phase = phase; self.reason = reason
        self.since = since; self.retryAt = retryAt; self.detail = detail
    }

    /// Shows the same thing as `other` (`since`, `retryAt` and `detail` aside).
    public func shows(like other: ScreenDisplayState) -> Bool {
        display == other.display && main == other.main && phase == other.phase && reason == other.reason
    }
}

extension ScreenDisplayState: Decodable {
    private enum K: String, CodingKey { case display, main, phase, reason, since, retryAt, detail }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        func num(_ k: K) -> Double? { ((try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil).flatMap { $0.isFinite ? $0 : nil } }
        func text(_ k: K) -> String? { ((try? c.decodeIfPresent(String.self, forKey: k)) ?? nil).flatMap { $0.isEmpty ? nil : $0 } }
        guard let raw = num(.display), raw >= 0, raw <= Double(UInt32.max), raw == raw.rounded() else {
            throw DecodingError.dataCorruptedError(forKey: .display, in: c, debugDescription: "display id")
        }
        display = UInt32(raw)
        main = ((try? c.decodeIfPresent(Bool.self, forKey: .main)) ?? nil) ?? false
        phase = ScreenPhase(lenient: text(.phase))
        reason = text(.reason)
        since = num(.since) ?? (Date().timeIntervalSince1970 * 1000).rounded()
        retryAt = num(.retryAt)
        detail = text(.detail)
    }
}

/// The Mac's console (`ScreenConsole`): whether it is locked (the picture is the lock screen). Lenient: missing or not
/// a boolean = unlocked.
public struct ScreenConsole: Sendable, Equatable, Decodable {
    public var locked: Bool = false

    public init(locked: Bool = false) { self.locked = locked }

    private enum K: String, CodingKey { case locked }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        locked = ((try? c.decodeIfPresent(Bool.self, forKey: .locked)) ?? nil) ?? false
    }
}

/// The body of a status stream part (`ScreenWire.statusType`): the state of the stream's display, and the console.
public struct ScreenStreamStatus: Sendable, Equatable {
    public var state: ScreenDisplayState
    public var console: ScreenConsole?

    public init(state: ScreenDisplayState, console: ScreenConsole? = nil) { self.state = state; self.console = console }

    private struct Body: Decodable {
        private enum K: String, CodingKey { case console }
        public let status: ScreenStreamStatus
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            status = ScreenStreamStatus(state: try ScreenDisplayState(from: decoder),
                                        console: (try? c.decodeIfPresent(ScreenConsole.self, forKey: .console)) ?? nil)
        }
    }

    /// nil when the body isn't a JSON object with a display id.
    public init?(json data: Data) {
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return nil }
        self = body.status
    }
}

/// A modifier held for a pointer event or a key.
public enum ScreenModifier: String, Sendable, Equatable, Hashable, CaseIterable {
    case cmd, shift, alt, ctrl
}

/// `POST /input`. `x` / `y`: normalized 0…1 of the display; `scroll`'s `dx` / `dy` in points (positive `dy` =
/// see content further down).
public struct ScreenInput: Sendable, Equatable {
    /// `down` / `up`: press / lift the LEFT button at x, y — a live drag is `down`, `move`s with
    /// `button: .left`, `up`.
    public enum Kind: String, Sendable, Equatable { case click, doubleClick, rightClick, move, drag, scroll, type, key, down, up }
    /// The button a `move` holds (a live drag). Only the left one.
    public enum Button: String, Sendable, Equatable { case left }
    /// A `scroll`'s place in a two-finger gesture: `began` (its dx / dy the first movement), `changed`,
    /// `ended` (the fingers lifted: dx / dy the last movement not sent yet, `vx` / `vy` the velocity at lift, which the Mac scrolls on with).
    public enum ScrollPhase: String, Sendable, Equatable { case began, changed, ended }

    public var type: Kind
    public var display: UInt32?
    public var x: Double?
    public var y: Double?
    public var dx: Double?
    public var dy: Double?
    public var text: String?
    public var key: String?
    public var modifiers: [ScreenModifier] = []
    /// `move` only: held while moving (between `down` and `up`).
    public var button: Button?
    /// `scroll` only: the gesture's phase (nil: a plain scroll), and on `ended` the fingers' velocity at lift in
    /// display points per second (the signs of dx / dy).
    public var phase: ScrollPhase?
    public var vx: Double?
    public var vy: Double?
    /// `move` only: the sender's count of its moves, increasing (`ScreenInputQueue` sends several at once;
    /// the Mac answers a lower one than it applied last `{ok, stale: true}` and doesn't apply it). nil: not sent (every
    /// move applies, as with an older client).
    public var seq: Int?

    public init(_ type: Kind, display: UInt32? = nil, x: Double? = nil, y: Double? = nil, dx: Double? = nil, dy: Double? = nil,
         text: String? = nil, key: String? = nil, modifiers: [ScreenModifier] = [], button: Button? = nil,
         phase: ScrollPhase? = nil, vx: Double? = nil, vy: Double? = nil) {
        self.type = type; self.display = display; self.x = x; self.y = y; self.dx = dx; self.dy = dy
        self.text = text; self.key = key; self.modifiers = modifiers; self.button = button
        self.phase = phase; self.vx = vx; self.vy = vy
    }

    public static func click(_ type: Kind = .click, display: UInt32?, at p: CGPoint, modifiers: [ScreenModifier] = []) -> ScreenInput {
        ScreenInput(type, display: display, x: Double(p.x), y: Double(p.y), modifiers: modifiers)
    }

    /// A pointer event at `p` (0…1): `move` (with `button`: a held one), `down`, `up`.
    public static func pointer(_ type: Kind, display: UInt32?, at p: CGPoint, button: Button? = nil,
                        modifiers: [ScreenModifier] = []) -> ScreenInput {
        ScreenInput(type, display: display, x: Double(p.x), y: Double(p.y), modifiers: modifiers, button: button)
    }

    public var json: [String: Any] {
        var d: [String: Any] = ["type": type.rawValue]
        if let display { d["display"] = Int(display) }
        if let x { d["x"] = x }
        if let y { d["y"] = y }
        if let dx { d["dx"] = dx }
        if let dy { d["dy"] = dy }
        if let text { d["text"] = text }
        if let key { d["key"] = key }
        if !modifiers.isEmpty {
            // a stable order (the server holds them all the same)
            d["modifiers"] = ScreenModifier.allCases.filter(modifiers.contains).map(\.rawValue)
        }
        if let button { d["button"] = button.rawValue }
        if let phase { d["phase"] = phase.rawValue }
        if let vx { d["vx"] = vx }
        if let vy { d["vy"] = vy }
        if let seq, type == .move, seq >= 0 { d["seq"] = seq }
        return d
    }
}

// MARK: Stream (video, acks, a client-drawn cursor, status parts)

/// The stream's and the sound's media types (Yoyo Control mac/README.md「HTTP API」). Requests still name
/// `streamAccept` / `audioAccept` in `Accept` (a Mac that negotiated the names answers with these then).
public enum ScreenWire {
    public static let streamAccept = "application/vnd.yoyo-control.stream"
    public static let audioAccept = "application/vnd.yoyo-control.audio"
    public static let cursorType = "application/vnd.yoyo-control.cursor+json"
    public static let statusType = "application/vnd.yoyo-control.status+json"
}


/// A codec the phone can take for the screen stream, in `codecs` (the server picks the first it can encode).
public enum ScreenCodec: String, Sendable, Equatable, CaseIterable {
    case hevc, h264
}

/// The stream request's additions to `display` / `maxWidth` / `quality` / `fps` (`live`: what the Screen page asks
/// for). Each is sent only when set.
public struct ScreenStreamOptions: Sendable, Equatable {
    /// Preference order; empty = not sent (the server's default, H.264).
    public var codecs: [ScreenCodec] = []
    /// The client-chosen stream id (8–64 of `[A-Za-z0-9_-]`), needed for acks.
    public var stream: String?
    /// The client will `POST /stream/ack` for this stream.
    public var ack: Bool = false
    /// The client draws the pointer itself (the server sends cursor parts and leaves it out of the pictures).
    public var clientCursor: Bool = false
    /// The client takes status parts (the connection state of the stream's display; `ScreenWire.statusType`).
    public var status: Bool = false

    public init(codecs: [ScreenCodec] = [], stream: String? = nil, ack: Bool = false, clientCursor: Bool = false, status: Bool = false) {
        self.codecs = codecs; self.stream = stream; self.ack = ack; self.clientCursor = clientCursor; self.status = status
    }

    /// A fresh stream id within the spec's alphabet (a UUID: 36 characters of hex digits and `-`).
    public static func newStreamId() -> String { UUID().uuidString }

    /// Whether `id` is a stream id the server accepts.
    public static func isValidStreamId(_ id: String) -> Bool {
        (8...64).contains(id.count) && id.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
        }
    }

    /// Adds the set fields to a stream request's JSON body.
    public func add(to body: inout [String: Any]) {
        if !codecs.isEmpty { body["codecs"] = codecs.map(\.rawValue).joined(separator: ",") }
        if let stream, Self.isValidStreamId(stream) { body["stream"] = stream }
        if ack, stream != nil { body["ack"] = 1 }
        if clientCursor { body["cursor"] = "client" }
        if status { body["status"] = 1 }
    }

    /// The stream request's `maxWidth`: the widest picture to ask for. The Mac sizes it itself (two thirds of its
    /// display's pixels, at most 2560: 2304 for a 3456-px Retina Mac).
    public static let videoMaxWidth = 3840
}

/// `POST /stream/ack {stream, seq, keyframe?, report?}`: every part up to `seq` arrived (cumulative); `keyframe`
/// asks for a key picture (the decoder lost its place); `report` (on about one ack every 2 s) says how playout goes,
/// for the Mac's log. The answer (`{ ok: true, net? }`) carries the server's grade of the network (`ScreenNetQuality`).
public struct ScreenStreamAck: Sendable, Equatable {
    public var stream: String
    public var seq: Int
    public var keyframe: Bool = false
    public var report: ScreenPlayoutReport? = nil

    public var json: [String: Any] {
        var d: [String: Any] = ["stream": stream, "seq": seq]
        if keyframe { d["keyframe"] = true }
        if let report { d["report"] = report.json }
        return d
    }

    public init(stream: String, seq: Int, keyframe: Bool = false, report: ScreenPlayoutReport? = nil) {
        self.stream = stream; self.seq = seq; self.keyframe = keyframe; self.report = report
    }
}

/// How video pictures are shown: at an even pace from a small jitter buffer (`ScreenPlayout`, `smooth`), or interactive
/// (a finger / keys: the interactive depth, `latency`). The `mode` of a playout report.
public enum ScreenPlayoutMode: String, Sendable, CaseIterable {
    case smooth, latency

    /// The stats line's word: `smooth` / `responsive` (the wire keeps `latency`).
    public var label: String { self == .smooth ? "smooth" : "responsive" }
}

/// `ScreenStreamAck.report` (PROTOCOL.md「播放报告」): the last ~3 s of playout. Numbers only; nil ones are left out.
public struct ScreenPlayoutReport: Sendable, Equatable {
    public var mode: ScreenPlayoutMode
    /// Pictures shown per second.
    public var fps: Double?
    /// Gaps between shown pictures.
    public var gapP50Ms: Double?
    public var gapP90Ms: Double?
    /// Gaps between arrived picture parts.
    public var arrivalGapP50Ms: Double?
    public var arrivalGapP90Ms: Double?
    /// Shown gaps over twice the median, per second.
    public var hitchesPerSec: Double?
    /// How long a picture that came on time waits: the jitter buffer's depth plus one display refresh (smooth only).
    public var bufferMs: Double?
    /// Decoded pictures never shown, per second.
    public var droppedPerSec: Double?
    /// Average decode time.
    public var decodeMs: Double?
    /// The display's refresh rate as the playout's display link measures it (smooth only).
    public var refreshHz: Double?
    /// Even pace: how far apart shown pictures are (absent when not pacing).
    public var paceMs: Double?
    /// The jitter buffer's cap (smooth only).
    public var bufferCapMs: Double?
    /// Shown gaps longer than the gap between the two pictures' `X-Frame-Time` by ≥ 150 / ≥ 300 ms (the picture froze
    /// while the Mac's content moved), per second.
    public var stall150PerSec: Double?
    public var stall300PerSec: Double?
    /// The p95 of (delay − base) in the playout's estimate: what the buffer would need.
    public var jitterP95Ms: Double?
    /// `latency` (a finger / keys): the interactive depth in use; 0 = shown on arrival.
    public var touchBufferMs: Double?
    /// How the phone's network looks (`ScreenNetSampler`); left out when it says nothing.
    public var net: ScreenNetReport?
    /// The Mac's sound on the phone (`ScreenAudioReport`), while its stream is open.
    public var audio: ScreenAudioReport? = nil

    public init(mode: ScreenPlayoutMode, fps: Double? = nil, gapP50Ms: Double? = nil, gapP90Ms: Double? = nil,
         arrivalGapP50Ms: Double? = nil, arrivalGapP90Ms: Double? = nil, hitchesPerSec: Double? = nil,
         bufferMs: Double? = nil, droppedPerSec: Double? = nil, decodeMs: Double? = nil, refreshHz: Double? = nil,
         paceMs: Double? = nil, bufferCapMs: Double? = nil, stall150PerSec: Double? = nil, stall300PerSec: Double? = nil,
         jitterP95Ms: Double? = nil, touchBufferMs: Double? = nil, net: ScreenNetReport? = nil) {
        self.mode = mode; self.fps = fps; self.gapP50Ms = gapP50Ms; self.gapP90Ms = gapP90Ms
        self.arrivalGapP50Ms = arrivalGapP50Ms; self.arrivalGapP90Ms = arrivalGapP90Ms; self.hitchesPerSec = hitchesPerSec
        self.bufferMs = bufferMs; self.droppedPerSec = droppedPerSec; self.decodeMs = decodeMs
        self.refreshHz = refreshHz; self.paceMs = paceMs; self.bufferCapMs = bufferCapMs
        self.stall150PerSec = stall150PerSec; self.stall300PerSec = stall300PerSec; self.jitterP95Ms = jitterP95Ms
        self.touchBufferMs = touchBufferMs; self.net = net
    }

    /// The JSON object; numbers rounded to 0.1, non-finite ones left out.
    public var json: [String: Any] {
        var d: [String: Any] = ["mode": mode.rawValue]
        let fields: [(String, Double?)] = [
            ("fps", fps), ("gapP50Ms", gapP50Ms), ("gapP90Ms", gapP90Ms), ("arrivalGapP50Ms", arrivalGapP50Ms),
            ("arrivalGapP90Ms", arrivalGapP90Ms), ("hitchesPerSec", hitchesPerSec), ("bufferMs", bufferMs),
            ("droppedPerSec", droppedPerSec), ("decodeMs", decodeMs), ("refreshHz", refreshHz), ("paceMs", paceMs),
            ("bufferCapMs", bufferCapMs), ("stall150PerSec", stall150PerSec), ("stall300PerSec", stall300PerSec),
            ("jitterP95Ms", jitterP95Ms), ("touchBufferMs", touchBufferMs),
        ]
        for (key, value) in fields {
            if let value, value.isFinite { d[key] = (value * 10).rounded() / 10 }
        }
        if let net = net?.json, !net.isEmpty { d["net"] = net }
        if let audio { d["audio"] = audio.json }
        return d
    }

    /// The stats line's second line: `smooth · 60 Hz · pace 33 · gap 33/41 · arr 33/52 · hitch 0.3/s · stall 0.3/0.0/s ·
    /// buf 28 ms · jit 24 · cap 100 · drop 0.5/s`; while interactive it starts `responsive` and has `touch 21 ms` (the
    /// interactive depth; `buf` is what an on-time picture waits). Numbers and units only: not localized.
    public var line: String {
        func ms(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "-" }
        var parts = [mode.label]
        if let refreshHz { parts.append(String(format: "%.0f Hz", refreshHz)) }
        if let paceMs { parts.append(String(format: "pace %.0f", paceMs)) }
        parts += ["gap \(ms(gapP50Ms))/\(ms(gapP90Ms))", "arr \(ms(arrivalGapP50Ms))/\(ms(arrivalGapP90Ms))"]
        if let hitchesPerSec { parts.append(String(format: "hitch %.1f/s", hitchesPerSec)) }
        if let stall150PerSec {
            parts.append(String(format: "stall %.1f/%.1f/s", stall150PerSec, stall300PerSec ?? 0))
        }
        if let bufferMs { parts.append(String(format: "buf %.0f ms", bufferMs)) }
        if let jitterP95Ms { parts.append(String(format: "jit %.0f", jitterP95Ms)) }
        if let bufferCapMs { parts.append(String(format: "cap %.0f", bufferCapMs)) }
        if let touchBufferMs { parts.append(String(format: "touch %.0f ms", touchBufferMs)) }
        if let droppedPerSec { parts.append(String(format: "drop %.1f/s", droppedPerSec)) }
        return parts.joined(separator: " · ")
    }
}

/// `ScreenPlayoutReport.audio` (PROTOCOL.md「声音」): how the Mac's sound plays on the phone, for the Mac's log
/// (`phone audio: speaker out 12 ms io 10 · delay 118 ms (buf 52) · skew +8 ms · …`). Encode-only (the phone never
/// reads one): milliseconds rounded to 0.1 and clamped to the protocol's ranges, non-finite numbers left out (a
/// required one as 0), optional fields left out when nil (`bluetooth` when false, `floorMs` when 0). Counts are since
/// the previous report that carried `audio`.
public struct ScreenAudioReport: Sendable, Equatable, Encodable {
    /// `AVAudioSession.outputLatency`, `ioBufferDuration`.
    public var outputMs: Double
    public var ioMs: Double
    /// The way out is Bluetooth (A2DP / LE / HFP) or AirPlay.
    public var bluetooth: Bool = false
    /// The jitter depth the buffer itself needs (its floor and bump included; not the output's lead or the A/V sync).
    public var depthMs: Double
    public var bufferedMs: Double
    /// What the phone adds to a packet that arrived on time: the playout delay (the output's lead included) + the
    /// output latency.
    public var addedMs: Double
    /// Sound − picture for the same instant (+ = sound later); only with a real display's smooth video.
    public var skewMs: Double? = nil
    /// Extra video delay used for sync, when > 0.
    public var floorMs: Double? = nil
    public var underruns: Int = 0
    public var late: Int = 0
    public var concealed: Int = 0
    public var cuts: Int = 0
    /// Net time-stretch (+ = played slower, the delay grew; cuts make it negative).
    public var stretchMs: Double? = nil
    public var kbps: Double = 0

    private enum K: String, CodingKey {
        case outputMs, ioMs, bluetooth, depthMs, bufferedMs, addedMs, skewMs, floorMs, underruns, late, concealed, cuts,
             stretchMs, kbps
    }

    private enum Value { case number(Double), count(Int), flag(Bool) }

    /// The fields as sent, in order (nil: left out).
    private var fields: [(K, Value?)] {
        func ms(_ v: Double?, _ lo: Double, _ hi: Double) -> Double? {
            v.flatMap { $0.isFinite ? (min(max($0, lo), hi) * 10).rounded() / 10 : nil }
        }
        func required(_ v: Double, _ lo: Double, _ hi: Double) -> Value { .number(ms(v, lo, hi) ?? 0) }
        func count(_ n: Int) -> Value { .count(min(max(n, 0), 100_000)) }
        return [
            (.outputMs, required(outputMs, 0, 1_000)), (.ioMs, required(ioMs, 0, 200)),
            (.bluetooth, bluetooth ? .flag(true) : nil), (.depthMs, required(depthMs, 0, 3_000)),
            (.bufferedMs, required(bufferedMs, 0, 3_000)), (.addedMs, required(addedMs, 0, 5_000)),
            (.skewMs, ms(skewMs, -3_000, 3_000).map(Value.number)),
            (.floorMs, floorMs.flatMap { $0 > 0 ? ms($0, 0, 1_000) : nil }.map(Value.number)),
            (.underruns, count(underruns)), (.late, count(late)), (.concealed, count(concealed)), (.cuts, count(cuts)),
            (.stretchMs, ms(stretchMs, -60_000, 60_000).map(Value.number)),
            (.kbps, .number((ms(kbps, 0, 100_000) ?? 0).rounded())),
        ]
    }

    /// The JSON object (the ack's body is made with JSONSerialization).
    public var json: [String: Any] {
        var d: [String: Any] = [:]
        for (key, value) in fields {
            switch value {
            case .number(let v)?: d[key.rawValue] = v
            case .count(let n)?: d[key.rawValue] = n
            case .flag(let b)?: d[key.rawValue] = b
            case nil: break
            }
        }
        return d
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        for (key, value) in fields {
            switch value {
            case .number(let v)?: try c.encode(v, forKey: key)
            case .count(let n)?: try c.encode(n, forKey: key)
            case .flag(let b)?: try c.encode(b, forKey: key)
            case nil: break
            }
        }
    }

    public init(outputMs: Double, ioMs: Double, bluetooth: Bool = false, depthMs: Double, bufferedMs: Double, addedMs: Double, skewMs: Double? = nil, floorMs: Double? = nil, underruns: Int = 0, late: Int = 0, concealed: Int = 0, cuts: Int = 0, stretchMs: Double? = nil, kbps: Double = 0) {
        self.outputMs = outputMs; self.ioMs = ioMs; self.bluetooth = bluetooth; self.depthMs = depthMs; self.bufferedMs = bufferedMs; self.addedMs = addedMs; self.skewMs = skewMs; self.floorMs = floorMs; self.underruns = underruns; self.late = late; self.concealed = concealed; self.cuts = cuts; self.stretchMs = stretchMs; self.kbps = kbps
    }
}

/// `ScreenPlayoutReport.net` (PROTOCOL.md「网络质量」): the phone's side of the network, for the Mac to grade it. Every
/// field is optional and left out when nil; numbers that aren't finite or are negative are left out too.
public struct ScreenNetReport: Sendable, Equatable {
    /// The path the stream uses right now: straight to the computer on the local network (or a VPN like Tailscale), straight
    /// to it over the internet (`direct`: a public address the computer's router forwards), or through a relay / tunnel.
    /// A reader that doesn't know a value ignores it.
    public enum Route: String, Sendable, Equatable {
        case lan, direct, tunnel
    }

    /// The interface of the phone's network path.
    public enum Interface: String, Sendable, Equatable {
        case wifi, cellular, wired, other
    }

    /// The cellular radio (only with `Interface.cellular`).
    public enum Radio: String, Sendable, Equatable {
        case fiveG = "5g", lte, threeG = "3g", other
    }

    /// `POST /input` round trips (sent → answered) of the last 10 s on the current route.
    public struct Rtt: Sendable, Equatable {
        public var p50: Double?
        public var p90: Double?
        /// Samples.
        public var n: Int?

        public init(p50: Double? = nil, p90: Double? = nil, n: Int? = nil) {
            self.p50 = p50; self.p90 = p90; self.n = n
        }
    }

    public var route: Route?
    public var iface: Interface?
    public var radio: Radio?
    /// `NWPath.isExpensive`.
    public var expensive: Bool?
    /// `NWPath.isConstrained` (Low Data Mode).
    public var constrained: Bool?
    public var inputRttMs: Rtt?
    /// Stream bytes received over the playout report's window, kbit/s.
    public var rxKbps: Double?
    /// Input and ack requests that failed (timeouts, network errors) in the last 10 s.
    public var failures: Int?

    public init(route: Route? = nil, iface: Interface? = nil, radio: Radio? = nil, expensive: Bool? = nil,
         constrained: Bool? = nil, inputRttMs: Rtt? = nil, rxKbps: Double? = nil, failures: Int? = nil) {
        self.route = route; self.iface = iface; self.radio = radio; self.expensive = expensive
        self.constrained = constrained; self.inputRttMs = inputRttMs; self.rxKbps = rxKbps; self.failures = failures
    }

    /// The JSON object (empty when nothing is known); milliseconds rounded to 0.1, kbit/s to whole numbers.
    public var json: [String: Any] {
        func ms(_ v: Double?) -> Double? { v.flatMap { $0.isFinite && $0 >= 0 ? ($0 * 10).rounded() / 10 : nil } }
        var d: [String: Any] = [:]
        if let route { d["route"] = route.rawValue }
        if let iface { d["iface"] = iface.rawValue }
        if let radio { d["radio"] = radio.rawValue }
        if let expensive { d["expensive"] = expensive }
        if let constrained { d["constrained"] = constrained }
        if let rtt = inputRttMs {
            var r: [String: Any] = [:]
            if let p50 = ms(rtt.p50) { r["p50"] = p50 }
            if let p90 = ms(rtt.p90) { r["p90"] = p90 }
            if let n = rtt.n, n >= 0 { r["n"] = n }
            if !r.isEmpty { d["inputRttMs"] = r }
        }
        if let rxKbps, rxKbps.isFinite, rxKbps >= 0 { d["rxKbps"] = rxKbps.rounded() }
        if let failures, failures >= 0 { d["failures"] = failures }
        return d
    }
}

/// The server's grade of the stream's network: `net` of the `POST /stream/ack` answer (PROTOCOL.md「网络质量」).
/// Lenient: an answer without `net` (`{ok: true}`) is nil, as is a `net` that is null or not an object; an
/// unknown grade is `.unknown`, unknown reasons are kept, and numbers that aren't finite or are negative are dropped.
public struct ScreenNetQuality: Sendable, Equatable {
    public enum Grade: String, Sendable, Equatable {
        case good, fair, poor, unknown
    }

    /// Why the grade isn't `good`: an open set (a code this build doesn't know is kept as it came).
    public struct Reason: RawRepresentable, Sendable, Hashable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public static let rtt = Reason(rawValue: "rtt")
        public static let jitter = Reason(rawValue: "jitter")
        public static let failures = Reason(rawValue: "failures")
        public static let fewSamples = Reason(rawValue: "few-samples")
    }

    /// The stream's own ack round trips (picture written → its ack arrived), last 10 s.
    public struct Rtt: Sendable, Equatable {
        public var min: Double?
        public var p50: Double?
        public var p90: Double?

        public init(min: Double? = nil, p50: Double? = nil, p90: Double? = nil) {
            self.min = min; self.p50 = p50; self.p90 = p90
        }
    }

    public var grade: Grade
    public var rttMs: Rtt?
    /// `rttMs.p90 − rttMs.min`.
    public var jitterMs: Double?
    public var reasons: [Reason]

    public init(grade: Grade, rttMs: Rtt? = nil, jitterMs: Double? = nil, reasons: [Reason] = []) {
        self.grade = grade; self.rttMs = rttMs; self.jitterMs = jitterMs; self.reasons = reasons
    }

    /// At most this many reasons are kept, each at most `maxReasonLength` characters.
    public static let maxReasons = 8
    public static let maxReasonLength = 32

    /// From the ack answer's body; nil when it carries no `net` object.
    public init?(ackResponse data: Data?) {
        guard let data, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let net = o["net"] as? [String: Any] else { return nil }
        func num(_ v: Any?) -> Double? {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let d = n.doubleValue
            return d.isFinite && d >= 0 ? d : nil
        }
        grade = (net["grade"] as? String).flatMap(Grade.init(rawValue:)) ?? .unknown
        if let r = net["rttMs"] as? [String: Any] {
            let rtt = Rtt(min: num(r["min"]), p50: num(r["p50"]), p90: num(r["p90"]))
            rttMs = rtt.min == nil && rtt.p50 == nil && rtt.p90 == nil ? nil : rtt
        }
        jitterMs = num(net["jitterMs"])
        reasons = ((net["reasons"] as? [Any]) ?? []).compactMap { $0 as? String }
            .filter { !$0.isEmpty && $0.count <= Self.maxReasonLength }.prefix(Self.maxReasons).map(Reason.init(rawValue:))
    }

    /// The stats line's part: `net fair (rtt, jitter) · rtt 165/210 · jitter 73` (codes and numbers only: not localized).
    public var line: String {
        var head = "net \(grade.rawValue)"
        if !reasons.isEmpty { head += " (\(reasons.map(\.rawValue).joined(separator: ", ")))" }
        var parts = [head]
        if let rtt = rttMs {
            func ms(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "-" }
            parts.append("rtt \(ms(rtt.p50))/\(ms(rtt.p90))")
        }
        if let jitterMs { parts.append(String(format: "jitter %.0f", jitterMs)) }
        return parts.joined(separator: " · ")
    }
}

/// A cursor part (`ScreenWire.cursorType`). Positions and sizes are in `/input`'s space: 0…1 of the
/// display. Lenient: every field may be missing, null or malformed (that field is then nil, the rest still counts).
public struct ScreenCursorUpdate: Sendable, Equatable {
    /// The pointer's image; sent only when it changed (and first): later parts refer to it by `shapeId`.
    public struct Shape: Sendable, Equatable {
        public var id: Int
        public var png: Data
        /// The hotspot inside the image and the image's size, 0…1 of the display. A size of 0 = not given.
        public var hotX: Double
        public var hotY: Double
        public var width: Double
        public var height: Double

        public init(id: Int, png: Data, hotX: Double, hotY: Double, width: Double, height: Double) {
            self.id = id; self.png = png; self.hotX = hotX; self.hotY = hotY; self.width = width; self.height = height
        }
    }

    public var x: Double?
    public var y: Double?
    public var visible: Bool?
    public var shapeId: Int?
    public var shape: Shape?

    public init(x: Double? = nil, y: Double? = nil, visible: Bool? = nil, shapeId: Int? = nil, shape: Shape? = nil) {
        self.x = x; self.y = y; self.visible = visible; self.shapeId = shapeId; self.shape = shape
    }

    /// A PNG larger than this isn't a pointer: the shape is dropped.
    public static let maxPNGBytes = 512 * 1024

    /// nil when the body isn't a JSON object.
    public init?(json data: Data) {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func num(_ v: Any?) -> Double? {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let d = n.doubleValue
            return d.isFinite && abs(d) < 1e6 ? d : nil
        }
        // ids aren't coordinates: a system cursor's shapeId is ≥ 1000000 (any whole number a Double holds exactly counts)
        func int(_ v: Any?) -> Int? {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let d = n.doubleValue
            return d.isFinite && d == d.rounded() && abs(d) <= 9_007_199_254_740_992 ? Int(d) : nil
        }
        x = num(o["x"])
        y = num(o["y"])
        visible = (o["visible"] as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil }
        shapeId = int(o["shapeId"])
        if let s = o["shape"] as? [String: Any], let b64 = s["png"] as? String, b64.utf8.count <= Self.maxPNGBytes * 4 / 3 + 4,
           let png = Data(base64Encoded: b64, options: .ignoreUnknownCharacters), !png.isEmpty,
           let id = int(s["id"]) ?? shapeId {
            shape = Shape(id: id, png: png, hotX: num(s["hotX"]) ?? 0, hotY: num(s["hotY"]) ?? 0,
                          width: max(0, num(s["width"]) ?? 0), height: max(0, num(s["height"]) ?? 0))
        }
    }
}

/// The pointer as the cursor parts so far describe it. A part without a shape keeps the shape it names by
/// `shapeId` (or, without one, the current one); a shape id never seen keeps the last image drawn.
public struct ScreenCursorState: Sendable, Equatable {
    public var x: Double = 0.5
    public var y: Double = 0.5
    public var visible: Bool = false
    public private(set) var shapeId: Int?
    /// The image drawn (the one of `shapeId` when known).
    public private(set) var shape: ScreenCursorUpdate.Shape?
    private var shapes: [Int: ScreenCursorUpdate.Shape] = [:]
    /// A cursor part arrived (a stream without them has the pointer in its pictures).
    public private(set) var received = false

    /// At most this many shapes are remembered.
    public static let maxShapes = 32

    public init() {}

    public mutating func apply(_ u: ScreenCursorUpdate) {
        received = true
        if let x = u.x { self.x = min(max(x, 0), 1) }
        if let y = u.y { self.y = min(max(y, 0), 1) }
        if let v = u.visible { visible = v }
        if let s = u.shape {
            if shapes.count >= Self.maxShapes, shapes[s.id] == nil { shapes.removeAll() }
            shapes[s.id] = s
        }
        if let id = u.shapeId ?? u.shape?.id { shapeId = id }
        if let id = shapeId, let s = shapes[id] { shape = s }
    }
}
