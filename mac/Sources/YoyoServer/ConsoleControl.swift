#if os(macOS)
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import OpenDirectory

// Locking and unlocking the console (README.md「Console lock」): `POST /console/unlock { password }` types the
// caller's password into the lock screen, `POST /console/lock` locks it. The unix socket's only (a paired phone gets
// 404). One flow at a time (a second request waits for the first, then looks again).
//
// Unlock, the rules that make it safe to type a password at all:
// - Nothing is typed unless `IOConsoleLocked` is true, and it is read again before every character: the moment the
//   console is unlocked (a person at the Mac, Touch ID, an Apple Watch) the typing stops, so the rest of the password
//   never lands in an app's text field. Return is pressed only if it is still locked after the last character.
// - The display is woken first (`IOPMAssertionDeclareUserActivity`, like `caffeinate -u`) and the flow waits for it
//   (≤ 3 s): keystrokes sent to a sleeping display's lock screen are swallowed (and count as a failed attempt).
// - Then one left click on the lock screen's clock (top center, 35 % down the main display), only after reading
//   `IOConsoleLocked` true once more: a lock screen left alone for a while goes idle (macOS 27: clock, avatar and
//   password field hidden, only the wallpaper; the display is on) and neither user activity nor pointer moves bring it
//   back, so the keys would go nowhere; the click does, within ~1.2 s. Never clicked while unlocked (it would land in
//   an app).
// - One attempt, never retried (macOS delays and may disable an account after failed attempts). A wrong password shows
//   as the account's failed-login count moving (`accountPolicyData`), which happens within ~0.5 s.
// - The password lives only in a buffer this file owns, wiped after use; it is never logged, nor is the request body.
// - The keystrokes are this process's own events (its pid), so they are not input from elsewhere (InputElsewhere.swift).

/// A password's UTF-16 units in memory this type owns: wiped (`memset_s`) when done, never copied into a `String`.
final class SecretUnits {
    private let storage: UnsafeMutableBufferPointer<UInt16>
    private(set) var count = 0

    init(capacity: Int) {
        storage = .allocate(capacity: max(capacity, 1))
        storage.initialize(repeating: 0)
    }

    deinit {
        wipe()
        storage.deallocate()
    }

    func append(_ unit: UInt16) {
        precondition(count < storage.count, "SecretUnits overflow")
        storage[count] = unit
        count += 1
    }

    /// The units so far.
    func withUnits<R>(_ body: (UnsafeBufferPointer<UInt16>) throws -> R) rethrows -> R {
        try body(UnsafeBufferPointer(rebasing: storage[0..<count]))
    }

    /// Zero every unit (also the capacity past `count`).
    func wipe() {
        guard let base = storage.baseAddress else { return }
        let bytes = storage.count * MemoryLayout<UInt16>.stride
        _ = memset_s(base, bytes, 0, bytes)
        count = 0
    }
}

/// The unlock request's body, read without Foundation's JSON (whose strings could not be wiped): a JSON object whose
/// `password` member is a string; other members are skipped. Throws 400s that never quote the body.
enum ConsolePasswordBody {
    static let maxUnits = 1024

    static func parse(_ body: Data) throws -> SecretUnits {
        try body.withUnsafeBytes { raw -> SecretUnits in
            var p = Parser(bytes: raw.bindMemory(to: UInt8.self))
            return try p.object()
        }
    }

    private struct Parser {
        let bytes: UnsafeBufferPointer<UInt8>
        var i = 0

        static let bad = HTTPError(400, "body must be a JSON object with a password string")

        init(bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

        var peek: UInt8? { i < bytes.count ? bytes[i] : nil }

        mutating func ws() {
            while let c = peek, c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1 }
        }

        mutating func expect(_ c: UInt8) throws {
            ws()
            guard peek == c else { throw Self.bad }
            i += 1
        }

        mutating func object() throws -> SecretUnits {
            try expect(UInt8(ascii: "{"))
            var password: SecretUnits?
            ws()
            if peek == UInt8(ascii: "}") {
                i += 1
            } else {
                while true {
                    ws()
                    guard peek == UInt8(ascii: "\"") else { throw Self.bad }
                    let key = try string()
                    let isPassword = key.withUnits { Array($0) } == Array("password".utf16)
                    key.wipe()
                    try expect(UInt8(ascii: ":"))
                    ws()
                    if isPassword {
                        guard peek == UInt8(ascii: "\"") else { throw HTTPError(400, "password must be a string") }
                        password = try string()  // a second "password" member replaces the first (wiped by deinit)
                    } else {
                        try skipValue(depth: 0)
                    }
                    ws()
                    if peek == UInt8(ascii: ",") { i += 1; continue }
                    if peek == UInt8(ascii: "}") { i += 1; break }
                    throw Self.bad
                }
            }
            ws()
            guard i == bytes.count else { throw Self.bad }
            guard let password, password.count > 0 else { throw HTTPError(400, "password is required") }
            guard password.count <= ConsolePasswordBody.maxUnits else {
                throw HTTPError(400, "password is too long (max \(ConsolePasswordBody.maxUnits) UTF-16 units)")
            }
            let control = password.withUnits { $0.contains { $0 < 0x20 || $0 == 0x7F } }
            guard !control else { throw HTTPError(400, "password must not contain control characters") }
            return password
        }

        /// A JSON string at `i` (the opening quote) → its UTF-16 units. UTF-16 never needs more units than UTF-8 has
        /// bytes (an escape is ≥ 2 bytes for one unit), so the buffer is sized by the bytes left.
        mutating func string() throws -> SecretUnits {
            i += 1
            let out = SecretUnits(capacity: bytes.count - i)
            while true {
                guard let c = peek else { throw Self.bad }
                i += 1
                switch c {
                case UInt8(ascii: "\""):
                    return out
                case UInt8(ascii: "\\"):
                    guard let e = peek else { throw Self.bad }
                    i += 1
                    switch e {
                    case UInt8(ascii: "\""): out.append(0x22)
                    case UInt8(ascii: "\\"): out.append(0x5C)
                    case UInt8(ascii: "/"): out.append(0x2F)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        guard i + 4 <= bytes.count else { throw Self.bad }
                        var v: UInt16 = 0
                        for _ in 0..<4 {
                            let h = bytes[i]
                            i += 1
                            let d: UInt16
                            switch h {
                            case 0x30...0x39: d = UInt16(h - 0x30)
                            case 0x41...0x46: d = UInt16(h - 0x41 + 10)
                            case 0x61...0x66: d = UInt16(h - 0x61 + 10)
                            default: throw Self.bad
                            }
                            v = v << 4 | d
                        }
                        out.append(v)
                    default:
                        throw Self.bad
                    }
                case 0x00..<0x20:
                    throw Self.bad  // raw control characters are not allowed in JSON strings
                case 0x00..<0x80:
                    out.append(UInt16(c))
                default:
                    // UTF-8: the lead byte says how many continuation bytes follow
                    let (n, initial): (Int, UInt32)
                    switch c {
                    case 0xC2...0xDF: (n, initial) = (1, UInt32(c & 0x1F))
                    case 0xE0...0xEF: (n, initial) = (2, UInt32(c & 0x0F))
                    case 0xF0...0xF4: (n, initial) = (3, UInt32(c & 0x07))
                    default: throw Self.bad
                    }
                    guard i + n <= bytes.count else { throw Self.bad }
                    var scalar = initial
                    for _ in 0..<n {
                        let b = bytes[i]
                        guard b & 0xC0 == 0x80 else { throw Self.bad }
                        scalar = scalar << 6 | UInt32(b & 0x3F)
                        i += 1
                    }
                    let minimum: UInt32 = n == 1 ? 0x80 : n == 2 ? 0x800 : 0x10000
                    guard scalar >= minimum, scalar <= 0x10FFFF, !(0xD800...0xDFFF).contains(scalar) else { throw Self.bad }
                    if scalar >= 0x10000 {
                        let s = scalar - 0x10000
                        out.append(UInt16(0xD800 + (s >> 10)))
                        out.append(UInt16(0xDC00 + (s & 0x3FF)))
                    } else {
                        out.append(UInt16(scalar))
                    }
                }
            }
        }

        /// Skip any JSON value at `i` (other members of the body).
        mutating func skipValue(depth: Int) throws {
            guard depth < 32 else { throw Self.bad }
            ws()
            guard let c = peek else { throw Self.bad }
            switch c {
            case UInt8(ascii: "\""):
                try string().wipe()
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                let close = c == UInt8(ascii: "{") ? UInt8(ascii: "}") : UInt8(ascii: "]")
                i += 1
                ws()
                if peek == close { i += 1; return }
                while true {
                    if c == UInt8(ascii: "{") {
                        ws()
                        guard peek == UInt8(ascii: "\"") else { throw Self.bad }
                        try string().wipe()
                        try expect(UInt8(ascii: ":"))
                    }
                    try skipValue(depth: depth + 1)
                    ws()
                    if peek == UInt8(ascii: ",") { i += 1; continue }
                    if peek == close { i += 1; return }
                    throw Self.bad
                }
            default:
                // a number, true, false or null: its characters up to a delimiter
                let start = i
                while let d = peek, !(d == UInt8(ascii: ",") || d == UInt8(ascii: "}") || d == UInt8(ascii: "]")
                                      || d == 0x20 || d == 0x09 || d == 0x0A || d == 0x0D) {
                    guard (0x2B...0x7A).contains(d) else { throw Self.bad }
                    i += 1
                }
                guard i > start else { throw Self.bad }
            }
        }
    }
}

/// The account's failed-login bookkeeping (`dsAttrTypeNative:accountPolicyData`): both move on a wrong password at the
/// lock screen (and reset on a successful login).
struct FailedLogins: Equatable, Sendable {
    var count: Int
    var timestamp: Double

    /// The local node's record of this user. nil when it cannot be read.
    static func current() -> FailedLogins? {
        let attribute = "dsAttrTypeNative:accountPolicyData"
        guard let node = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes)),
              let record = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: [attribute]),
              let values = try? record.values(forAttribute: attribute), let first = values.first else { return nil }
        let data = (first as? Data) ?? (first as? String)?.data(using: .utf8)
        guard let data else { return nil }
        return parse(data)
    }

    /// The policy plist → the two fields (absent = 0, as after a successful login).
    static func parse(_ data: Data) -> FailedLogins? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        let count = (plist["failedLoginCount"] as? NSNumber)?.intValue ?? 0
        let ts = (plist["failedLoginTimestamp"] as? NSNumber)?.doubleValue ?? 0
        return FailedLogins(count: count, timestamp: ts)
    }
}

/// What the flows read and do, injectable for tests (`ConsoleSystem.live`: the real Mac).
struct ConsoleSystem: Sendable {
    /// This process's GUI session is the one on the console (not a fast-user-switched background session).
    var onConsole: @Sendable () -> Bool
    /// `IOConsoleLocked` now; nil = unreadable.
    var locked: @Sendable () -> Bool?
    /// The main display is asleep.
    var displayAsleep: @Sendable () -> Bool
    /// Declare user activity (wakes the display, like `caffeinate -u`).
    var wake: @Sendable () -> Void
    /// Accessibility is granted (posting key events needs it).
    var canPostInput: @Sendable () -> Bool
    /// One left click at a blank spot of the lock screen (the clock: top center of the main display): an idle lock
    /// screen shows its password field again.
    var clickLockScreen: @Sendable () -> Void
    /// Type one character (its UTF-16 units: one, or a surrogate pair).
    var typeCharacter: @Sendable (UnsafeBufferPointer<UInt16>) -> Void
    var pressReturn: @Sendable () -> Void
    var failedLogins: @Sendable () -> FailedLogins?
    /// `SACLockScreenImmediate`; false when it is not there.
    var lockImmediately: @Sendable () -> Bool
    /// Ctrl+Cmd+Q, the system's Lock Screen shortcut.
    var pressLockKeys: @Sendable () -> Void
    var sleep: @Sendable (TimeInterval) -> Void
    var now: @Sendable () -> TimeInterval

    static let live = ConsoleSystem(
        onConsole: {
            guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
            return (dict[kCGSessionOnConsoleKey] as? Bool) ?? (dict[kCGSessionOnConsoleKey] as? NSNumber)?.boolValue ?? false
        },
        locked: { ConsoleState.lockedProperty() },
        displayAsleep: { CGDisplayIsAsleep(CGMainDisplayID()) != 0 },
        wake: {
            var assertion = IOPMAssertionID(0)
            IOPMAssertionDeclareUserActivity("\(ScreenHost.logName) console unlock" as CFString, kIOPMUserActiveLocal, &assertion)
        },
        canPostInput: { AXIsProcessTrusted() },
        clickLockScreen: {
            let at = Input.globalPoint(CGMainDisplayID(), x: ConsoleControl.lockScreenClick.x, y: ConsoleControl.lockScreenClick.y)
            Input.click(at, button: .left, flags: [], count: 1)
        },
        typeCharacter: { units in
            guard let base = units.baseAddress else { return }
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: base)
                event.post(tap: .cghidEventTap)
            }
        },
        pressReturn: { Input.press(Keys.returnKey, flags: []) },
        failedLogins: { FailedLogins.current() },
        lockImmediately: { LoginFramework.lockScreenImmediate() },
        pressLockKeys: { Input.press(Keys.code(for: "q")!, flags: [.maskControl, .maskCommand]) },
        sleep: { usleep(useconds_t(max($0, 0) * 1_000_000)) },
        now: { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
    )
}

/// The private login.framework's `SACLockScreenImmediate` (what the menu bar's Lock Screen calls): locks at once,
/// leaves the display on, needs no permission.
enum LoginFramework {
    nonisolated(unsafe) private static var function: (@convention(c) () -> Int32)?
    private static let once: Void = {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL), let sym = dlsym(handle, "SACLockScreenImmediate") else { return }
        function = unsafeBitCast(sym, to: (@convention(c) () -> Int32).self)
    }()

    /// false when the function is not there (the caller falls back to the shortcut).
    static func lockScreenImmediate() -> Bool {
        _ = once
        guard let f = function else { return false }
        let r = f()
        if r != 0 { log("console: SACLockScreenImmediate returned \(r)") }
        return true
    }
}

/// `POST /console/unlock`'s answer.
enum ConsoleUnlockResult: Equatable {
    /// This call's password unlocked it.
    case unlocked
    /// It was not locked (or got unlocked another way before this call's keystrokes were all in): nothing more typed.
    case already
    /// Still locked: `wrong-password`, `timeout`, `display-asleep`, `not-console`.
    case failed(String)

    var json: [String: Any] {
        switch self {
        case .unlocked: return ["ok": true, "unlocked": true]
        case .already: return ["ok": true, "unlocked": true, "already": true]
        case .failed(let reason): return ["ok": false, "unlocked": false, "reason": reason]
        }
    }
}

/// `POST /console/lock`'s answer.
enum ConsoleLockResult: Equatable {
    case locked
    case already
    /// `not-console`, `no-permission` (no SACLockScreenImmediate and no Accessibility for the shortcut), `timeout`.
    case failed(String)

    var json: [String: Any] {
        switch self {
        case .locked: return ["ok": true, "locked": true]
        case .already: return ["ok": true, "locked": true, "already": true]
        case .failed(let reason): return ["ok": false, "locked": false, "reason": reason]
        }
    }
}

/// The flows. Pure apart from `system`; the timings are constants.
struct ConsoleControl {
    /// How long the display gets to wake.
    static let wakeWait: TimeInterval = 3
    /// After the display woke: until the lock screen is drawn, before the click.
    static let wakeSettle: TimeInterval = 0.5
    /// Where the click goes (normalized on the main display): the clock, a blank spot of the lock screen.
    static let lockScreenClick = (x: 0.5, y: 0.35)
    /// After the click: until the password field is back and takes keys (measured: ~1.2 s from an idle lock screen
    /// to an active field; the typing starts after this, the first character lands by then).
    static let clickSettle: TimeInterval = 1.3
    /// Between two characters.
    static let characterGap: TimeInterval = 0.02
    /// After Return: until the console reports unlocked.
    static let unlockWait: TimeInterval = 5
    /// `POST /console/lock`: until it reports locked; the shortcut goes out after `lockFallbackAfter` without.
    static let lockWait: TimeInterval = 3
    static let lockFallbackAfter: TimeInterval = 1
    static let poll: TimeInterval = 0.1

    /// One flow at a time, process-wide.
    private static let busy = NSLock()

    var system: ConsoleSystem
    /// Told what a flow just did (ConsoleWatcher.force): `/status` and `/events` say so at once.
    var settled: (ConsoleState) -> Void = { ConsoleWatcher.current?.force($0) }

    /// Unlock with `password` (wiped before this returns). Throws 403 without Accessibility when it would have to type.
    func unlock(_ password: SecretUnits) throws -> ConsoleUnlockResult {
        defer { password.wipe() }
        Self.busy.lock()
        defer { Self.busy.unlock() }
        let s = system
        let start = s.now()
        guard s.onConsole() else { return .failed("not-console") }
        guard let locked = s.locked() else { return .failed("not-console") }
        guard locked else { return .already }
        guard s.canPostInput() else {
            throw HTTPError(403, "Accessibility permission is not granted to \(ScreenHost.appName)")
        }
        let before = s.failedLogins()
        // wake the display and wait for it: a sleeping lock screen swallows keys
        let asleep = s.displayAsleep()
        s.wake()
        if asleep {
            let deadline = s.now() + Self.wakeWait
            while s.displayAsleep() {
                guard s.now() < deadline else {
                    log("console: unlock: the display did not wake in \(Int(Self.wakeWait)) s; nothing typed")
                    return .failed("display-asleep")
                }
                s.sleep(Self.poll)
            }
        }
        if asleep { s.sleep(Self.wakeSettle) }
        // bring an idle lock screen's password field back; a click only onto the lock screen
        guard s.locked() == true else { return unlockedMeanwhile(typed: 0) }
        s.clickLockScreen()
        s.sleep(Self.clickSettle)
        // every character only while still locked
        var typed = 0
        let finished = password.withUnits { units -> Bool in
            var k = 0
            while k < units.count {
                guard s.locked() == true else { return false }
                let pair = UTF16.isLeadSurrogate(units[k]) && k + 1 < units.count && UTF16.isTrailSurrogate(units[k + 1])
                let n = pair ? 2 : 1
                s.typeCharacter(UnsafeBufferPointer(rebasing: units[k..<(k + n)]))
                k += n
                typed += 1
                s.sleep(Self.characterGap)
            }
            return true
        }
        let stillLocked = s.locked()
        guard finished, stillLocked == true else {
            guard stillLocked == false || !finished else { return .failed("not-console") }
            return unlockedMeanwhile(typed: typed)
        }
        s.pressReturn()
        let deadline = s.now() + Self.unlockWait
        while true {
            s.sleep(Self.poll)
            if s.locked() == false {
                log("console: unlocked in \(String(format: "%.1f", s.now() - start)) s")
                settled(ConsoleState(locked: false))
                return .unlocked
            }
            let after = s.failedLogins()
            if let before, let after, after != before {
                log("console: unlock: wrong password (the failed-login count moved); not retried")
                return .failed("wrong-password")
            }
            guard s.now() < deadline else { break }
        }
        // still locked and the count did not move. Unreadable bookkeeping: say wrong-password (a caller stops trying).
        let after = s.failedLogins()
        let reason = (before != nil && after != nil) ? "timeout" : "wrong-password"
        log("console: unlock: still locked after \(Int(Self.unlockWait)) s (\(reason)); not retried")
        return .failed(reason)
    }

    /// The console got unlocked another way mid-flow: stop (no click, no more keys, no Return).
    private func unlockedMeanwhile(typed: Int) -> ConsoleUnlockResult {
        guard system.locked() == false else { return .failed("not-console") }
        log("console: unlock: unlocked meanwhile, stopped (\(typed) character(s) in, no Return)")
        settled(ConsoleState(locked: false))
        return .already
    }

    func lock() -> ConsoleLockResult {
        Self.busy.lock()
        defer { Self.busy.unlock() }
        let s = system
        let start = s.now()
        guard s.onConsole(), let locked = s.locked() else { return .failed("not-console") }
        guard !locked else { return .already }
        var shortcut = false
        if !s.lockImmediately() {
            guard s.canPostInput() else { return .failed("no-permission") }
            s.pressLockKeys()
            shortcut = true
        }
        let deadline = start + Self.lockWait
        while true {
            s.sleep(Self.poll)
            if s.locked() == true {
                log("console: locked in \(String(format: "%.1f", s.now() - start)) s\(shortcut ? " (Ctrl+Cmd+Q)" : "")")
                settled(ConsoleState(locked: true))
                return .locked
            }
            if !shortcut, s.now() - start >= Self.lockFallbackAfter, s.canPostInput() {
                log("console: lock: SACLockScreenImmediate did not lock; Ctrl+Cmd+Q")
                s.pressLockKeys()
                shortcut = true
            }
            guard s.now() < deadline else { break }
        }
        log("console: lock: still unlocked after \(Int(Self.lockWait)) s")
        return .failed("timeout")
    }
}

extension Router {
    /// `POST /console/unlock { password }` (README.md「Console lock」). The body is never logged or echoed.
    static func consoleUnlock(_ req: HTTPRequest, _ conn: Connection) throws {
        guard req.remote == nil else { throw HTTPError(404, "no such endpoint \(req.path)") }
        let password = try ConsolePasswordBody.parse(req.body)
        conn.json(200, try ConsoleControl(system: .live).unlock(password).json)
    }

    /// `POST /console/lock` (README.md「Console lock」).
    static func consoleLock(_ req: HTTPRequest, _ conn: Connection) throws {
        guard req.remote == nil else { throw HTTPError(404, "no such endpoint \(req.path)") }
        conn.json(200, ConsoleControl(system: .live).lock().json)
    }
}
#endif
