#if os(macOS)
import CoreGraphics
import Foundation

/// Body of `POST /input`. Coordinates are normalized 0…1 within the display.
struct InputEvent: Decodable {
    var type: String
    var display: Int?
    var x: Double?
    var y: Double?
    var dx: Double?
    var dy: Double?
    var text: String?
    var key: String?
    var modifiers: [String]?
    /// `move` only: the button held while moving (a live drag, between `down` and `up`). Only "left".
    var button: String?
    /// `scroll` only: the two-finger gesture's phase ("began" / "changed" / "ended"; nil: a plain scroll), and on
    /// "ended" the fingers' velocity at lift (points per second, the signs of dx / dy) that momentum goes on with.
    /// Paced and phased (ScrollSynth.swift).
    var phase: String?
    var vx: Double?
    var vy: Double?
    /// `move` only: the phone's move counter (it pipelines moves, up to 3 in flight): a move older than one already
    /// applied is answered `stale` and not applied (`PointerMoveGate`). Other types ignore it. The phone starts it at
    /// the wall clock in ms (~1.76e12) and counts up, so a new page visit or another device continues above: 64 bits.
    var seq: Int64?
}

/// Pointer moves that overtook each other (docs/PROTOCOL.md「输入」, `seq`): the highest `seq` applied in
/// the last `window` is kept (one controller at a time, so one global value); a move with a lower one is stale. A `seq`
/// `restartBelow` or more under the last one, or `window` without a move, starts the count over (a new client, a
/// restarted queue). A move without `seq` (older clients) always applies and leaves the count alone. Pure: the clock is
/// passed in.
struct PointerMoveGate: Sendable {
    static let window: TimeInterval = 2
    static let restartBelow: Int64 = 1000

    private(set) var last: (seq: Int64, at: TimeInterval)?

    /// Whether a move with `seq` at `now` applies (and if so, it is the new highest).
    mutating func admit(seq: Int64, at now: TimeInterval) -> Bool {
        if let l = last, now - l.at < Self.window, seq < l.seq, l.seq - seq < Self.restartBelow { return false }
        last = (seq, now)
        return true
    }

    /// The process-wide gate (`Router.input`), on the stream clock.
    static let shared = Shared()

    final class Shared: @unchecked Sendable {
        private let lock = NSLock()
        private var gate = PointerMoveGate()  // guarded by `lock`

        func admit(seq: Int64, at now: TimeInterval = StreamClock.now()) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return gate.admit(seq: seq, at: now)
        }
    }
}

/// The left button of a live drag (`down` … `move` with `button` … `up`) as CGEvent posts it: one system pointer, so
/// one state. The modifiers given with `down` stay on every event until `up`; the first event after the press waits
/// until `settle` has passed since it (else the press can read as a click).
final class CGButtonState: @unchecked Sendable {
    static let shared = CGButtonState()
    static let settle: TimeInterval = 0.015

    private let lock = NSLock()
    private var flags: CGEventFlags = []
    private var pressedAt: Date?

    func pressed(flags: CGEventFlags) {
        lock.lock(); self.flags = flags; pressedAt = Date(); lock.unlock()
    }

    /// The held flags, after waiting out the settle time of a fresh press.
    func held() -> CGEventFlags {
        lock.lock()
        let (f, at) = (flags, pressedAt)
        lock.unlock()
        if let at {
            let wait = Self.settle - Date().timeIntervalSince(at)
            if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
        }
        return f
    }

    /// Lifted: the held flags (after the settle wait), forgotten.
    func released() -> CGEventFlags {
        let f = held()
        lock.lock(); flags = []; pressedAt = nil; lock.unlock()
        return f
    }
}

enum Input {
    /// Validates the event and returns the work that posts it (run after the permission check). `tap`: the HID tap
    /// (the console; `/input`), or this login session's own event stream.
    static func plan(_ e: InputEvent, tap: CGEventTapLocation = .cghidEventTap) throws -> () -> Void {
        let flags = try modifierFlags(e.modifiers ?? [])
        switch e.type {
        case "click":
            let p = try point(e)
            return { click(p, button: .left, flags: flags, count: 1, tap: tap) }
        case "doubleClick":
            let p = try point(e)
            return { click(p, button: .left, flags: flags, count: 2, tap: tap) }
        case "rightClick":
            let p = try point(e)
            return { click(p, button: .right, flags: flags, count: 1, tap: tap) }
        case "move":
            let p = try point(e)
            if try heldButton(e) {
                let state = CGButtonState.shared
                return { post(mouse: .leftMouseDragged, at: p, button: .left, flags: state.held(), tap: tap) }
            }
            return { post(mouse: .mouseMoved, at: p, button: .left, flags: flags, tap: tap) }
        case "down":
            let p = try point(e)
            return { press(at: p, flags: flags, tap: tap) }
        case "up":
            let p = try point(e)
            return { release(at: p, tap: tap) }
        case "drag":
            let display = try Displays.resolve(e.display)
            let from = try point(e)
            guard let dx = e.dx, let dy = e.dy else { throw HTTPError(400, "drag needs dx and dy") }
            let to = globalPoint(display, x: e.x! + dx, y: e.y! + dy)
            return { drag(from: from, to: to, flags: flags, tap: tap) }
        case "scroll":
            let p = e.x != nil || e.y != nil ? try point(e) : nil
            guard e.dx != nil || e.dy != nil else { throw HTTPError(400, "scroll needs dx and/or dy") }
            let phase = try scrollPhase(e)
            // paced (and phased, with momentum) on the tap; the pointer goes there first when it moved
            return {
                ScrollSynth.for(tap).submit(dx: e.dx ?? 0, dy: e.dy ?? 0, phase: phase, vx: e.vx, vy: e.vy, at: p, flags: flags) {
                    post(mouse: .mouseMoved, at: $0, button: .left, flags: [], tap: tap)
                }
            }
        case "type":
            guard let text = e.text, !text.isEmpty else { throw HTTPError(400, "type needs text") }
            return { type(text, tap: tap) }
        case "key":
            guard let name = e.key else { throw HTTPError(400, "key needs key") }
            guard let code = Keys.code(for: name) else { throw HTTPError(400, "unknown key \(name)") }
            return { press(code, flags: flags, tap: tap) }
        default:
            throw HTTPError(400, "unknown input type \(e.type)")
        }
    }

    /// Whether a `move` holds the left button (400 for any other button).
    static func heldButton(_ e: InputEvent) throws -> Bool {
        guard let b = e.button else { return false }
        guard b == "left" else { throw HTTPError(400, "button must be \"left\"") }
        return true
    }

    /// A scroll's gesture phase (400 for an unknown one).
    static func scrollPhase(_ e: InputEvent) throws -> ScrollMotion.Phase? {
        guard let raw = e.phase else { return nil }
        guard let phase = ScrollMotion.Phase(rawValue: raw) else {
            throw HTTPError(400, "phase must be began, changed or ended")
        }
        return phase
    }

    /// Pointer input that stops a scroll on its path first (`ScrollSynth.interrupt`): its rest goes at once, an open
    /// gesture ends, momentum stops.
    static func interruptsScroll(_ type: String) -> Bool {
        ["click", "doubleClick", "rightClick", "down", "move", "drag"].contains(type)
    }

    // MARK: Geometry

    static func point(_ e: InputEvent) throws -> CGPoint {
        guard let x = e.x, let y = e.y, x.isFinite, y.isFinite else {
            throw HTTPError(400, "\(e.type) needs x and y (0…1)")
        }
        return globalPoint(try Displays.resolve(e.display), x: x, y: y)
    }

    static func globalPoint(_ display: CGDirectDisplayID, x: Double, y: Double) -> CGPoint {
        let b = CGDisplayBounds(display)
        let cx = min(max(x, 0), 1), cy = min(max(y, 0), 1)
        // Keep the far edge inside the display (x == 1 would land on the next screen).
        return CGPoint(x: b.minX + min(cx * b.width, b.width - 1), y: b.minY + min(cy * b.height, b.height - 1))
    }

    static func modifierFlags(_ names: [String]) throws -> CGEventFlags {
        var flags: CGEventFlags = []
        for name in names {
            switch name.lowercased() {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: throw HTTPError(400, "unknown modifier \(name)")
            }
        }
        return flags
    }

    // MARK: Mouse

    static func post(mouse type: CGEventType, at p: CGPoint, button: CGMouseButton, flags: CGEventFlags, clickState: Int64 = 1,
                     tap: CGEventTapLocation = .cghidEventTap) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        event.flags = flags
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.post(tap: tap)
    }

    static func click(_ p: CGPoint, button: CGMouseButton, flags: CGEventFlags, count: Int, tap: CGEventTapLocation = .cghidEventTap) {
        let (down, up): (CGEventType, CGEventType) = button == .right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
        post(mouse: .mouseMoved, at: p, button: button, flags: flags, tap: tap)
        usleep(10_000)
        for state in 1...count {
            post(mouse: down, at: p, button: button, flags: flags, clickState: Int64(state), tap: tap)
            usleep(15_000)
            post(mouse: up, at: p, button: button, flags: flags, clickState: Int64(state), tap: tap)
            if state < count { usleep(60_000) }
        }
    }

    /// A live drag's `down`: to the point, then the left button pressed there (with `flags` held until `up`).
    static func press(at p: CGPoint, flags: CGEventFlags, tap: CGEventTapLocation = .cghidEventTap) {
        post(mouse: .mouseMoved, at: p, button: .left, flags: flags, tap: tap)
        usleep(10_000)
        post(mouse: .leftMouseDown, at: p, button: .left, flags: flags, tap: tap)
        CGButtonState.shared.pressed(flags: flags)
    }

    /// A live drag's `up` (or the button lifted for it: the stall guard, the last stream closing).
    static func release(at p: CGPoint, tap: CGEventTapLocation = .cghidEventTap) {
        post(mouse: .leftMouseUp, at: p, button: .left, flags: CGButtonState.shared.released(), tap: tap)
    }

    static func drag(from: CGPoint, to: CGPoint, flags: CGEventFlags, tap: CGEventTapLocation = .cghidEventTap) {
        post(mouse: .mouseMoved, at: from, button: .left, flags: flags, tap: tap)
        usleep(10_000)
        post(mouse: .leftMouseDown, at: from, button: .left, flags: flags, tap: tap)
        usleep(30_000)
        let steps = 10
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            post(mouse: .leftMouseDragged, at: p, button: .left, flags: flags, tap: tap)
            usleep(15_000)
        }
        post(mouse: .leftMouseUp, at: to, button: .left, flags: flags, tap: tap)
    }

    // MARK: Keyboard

    static func press(_ code: CGKeyCode, flags: CGEventFlags, tap: CGEventTapLocation = .cghidEventTap) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: tap)
            usleep(5_000)
        }
    }

    /// Types text as unicode keyboard events in chunks of ≤ 20 UTF-16 units; newlines press Return. `tap`: the HID
    /// tap (the console), or this login session's own event stream.
    static func type(_ text: String, tap: CGEventTapLocation = .cghidEventTap) {
        var chunk: [UniChar] = []
        func flush() {
            guard !chunk.isEmpty else { return }
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event.post(tap: tap)
            }
            chunk.removeAll()
            usleep(10_000)
        }
        for ch in text {
            if ch.isNewline {  // "\n", "\r\n", "\r"
                flush()
                press(Keys.returnKey, flags: [], tap: tap)
                continue
            }
            let units = Array(String(ch).utf16)
            if chunk.count + units.count > 20 { flush() }
            chunk.append(contentsOf: units)
        }
        flush()
    }
}
#endif
