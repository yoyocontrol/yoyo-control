import XCTest
import CoreGraphics
import Darwin
import Foundation
@testable import YoyoServer

// The console (ConsoleWatch.swift, ConsoleControl.swift): where `IOConsoleLocked` is read, a locked console reaching
// `/status` and `/events` through the watcher, the unlock / lock flows on a fake Mac, and the password body.

/// A Mac the flows run against: a lock screen, a display, a fake clock (`sleep` advances it), and a log of what was done.
private final class FakeMac: @unchecked Sendable {
    private let lock = NSLock()
    private var _locked: Bool? = true
    private var _onConsole = true
    private var _asleep = false
    private var _ax = true
    private var _failed: FailedLogins? = FailedLogins(count: 0, timestamp: 0)
    private var _now: TimeInterval = 100
    private var _actions: [String] = []
    private var _typed: [String] = []

    /// The display wakes this long after `wake()` (nil: never).
    var wakeTakes: TimeInterval? = 0.05
    /// The lock screen is idle (no password field) until a click; then its field is back ~0.8 s later.
    var idle = false
    private var clickedAt: TimeInterval?
    /// The console gets unlocked another way just as the click would go out (for the re-check before it).
    var unlocksBeforeClick = false
    var unlocksAtClick = false
    private var wokeAt: TimeInterval?
    /// The console unlocks after this many characters (somebody else unlocked it meanwhile).
    var unlocksAfterCharacters: Int?
    /// What Return does: the password is right (unlocks after `unlockTakes`), wrong (the failed count moves), or nothing.
    enum OnReturn { case unlock, wrong, nothing }
    var onReturn = OnReturn.unlock
    var unlockTakes: TimeInterval = 0.6
    private var returnAt: TimeInterval?
    /// SACLockScreenImmediate: exists, and locks.
    var sacExists = true
    var sacLocks = true
    var shortcutLocks = true
    private var lockAt: TimeInterval?

    func set(locked: Bool? = nil, onConsole: Bool? = nil, asleep: Bool? = nil, ax: Bool? = nil, failed: FailedLogins?? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let locked { _locked = locked }
        if let onConsole { _onConsole = onConsole }
        if let asleep { _asleep = asleep }
        if let ax { _ax = ax }
        if let failed { _failed = failed }
    }
    func setUnreadable() { lock.lock(); _locked = nil; lock.unlock() }

    var actions: [String] { lock.lock(); defer { lock.unlock() }; return _actions }
    var typed: [String] { lock.lock(); defer { lock.unlock() }; return _typed }
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return _now }

    private func note(_ a: String) { _actions.append(a) }

    /// Time passing: the display waking, the password being checked, the lock landing.
    private func advance(_ dt: TimeInterval) {
        _now += dt
        if unlocksBeforeClick, wokeAt != nil, !_actions.contains("click") { _locked = false }
        if let w = wokeAt, let takes = wakeTakes, _now - w >= takes { _asleep = false }
        if let r = returnAt, _now - r >= unlockTakes {
            returnAt = nil
            switch onReturn {
            case .unlock: _locked = false
            case .wrong: _failed = FailedLogins(count: (_failed?.count ?? 0) + 1, timestamp: _now)
            case .nothing: break
            }
        }
        if let l = lockAt, _now - l >= 0.05 { lockAt = nil; _locked = true }
    }

    var system: ConsoleSystem {
        ConsoleSystem(
            onConsole: { self.lock.lock(); defer { self.lock.unlock() }; return self._onConsole },
            locked: { self.lock.lock(); defer { self.lock.unlock() }; return self._locked },
            displayAsleep: { self.lock.lock(); defer { self.lock.unlock() }; return self._asleep },
            wake: { self.lock.lock(); self.note("wake"); self.wokeAt = self._now; self.lock.unlock() },
            canPostInput: { self.lock.lock(); defer { self.lock.unlock() }; return self._ax },
            clickLockScreen: {
                self.lock.lock(); defer { self.lock.unlock() }
                precondition(self._locked == true, "clicked while not locked")
                self.note("click")
                if self.idle { self.clickedAt = self._now }
                if self.unlocksAtClick { self._locked = false }
            },
            typeCharacter: { units in
                self.lock.lock(); defer { self.lock.unlock() }
                precondition(self._locked == true, "typed while not locked")
                precondition(!self._asleep, "typed while the display sleeps")
                if self.idle {
                    // an idle lock screen: keys go nowhere until a click brought the field back (~1 s)
                    guard let c = self.clickedAt, self._now - c >= 0.8 else { self.note("lost"); return }
                }
                self._typed.append(String(decoding: Array(units), as: UTF16.self))
                self.note("type")
                if let n = self.unlocksAfterCharacters, self._typed.count >= n { self._locked = false }
            },
            pressReturn: { self.lock.lock(); self.note("return"); self.returnAt = self._now; self.lock.unlock() },
            failedLogins: { self.lock.lock(); defer { self.lock.unlock() }; return self._failed },
            lockImmediately: {
                self.lock.lock(); defer { self.lock.unlock() }
                guard self.sacExists else { return false }
                self.note("sac")
                if self.sacLocks { self.lockAt = self._now }
                return true
            },
            pressLockKeys: {
                self.lock.lock(); defer { self.lock.unlock() }
                self.note("ctrl-cmd-q")
                if self.shortcutLocks { self.lockAt = self._now }
            },
            sleep: { dt in self.lock.lock(); self.advance(dt); self.lock.unlock() },
            now: { self.lock.lock(); defer { self.lock.unlock() }; return self._now }
        )
    }
}

private func secret(_ s: String) -> SecretUnits {
    let units = SecretUnits(capacity: s.utf16.count)
    for u in s.utf16 { units.append(u) }
    return units
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

final class ConsoleTests: XCTestCase {
    private var logged: [String] = []
    private var savedSink: ((String) -> Void)?
    private var tracker: ScreenStateTracker?

    override func setUp() {
        super.setUp()
        savedSink = ScreenHost.logSink
        logged = []
        ScreenHost.logSink = { [weak self] in self?.logged.append($0) }
    }

    override func tearDown() {
        if let savedSink { ScreenHost.logSink = savedSink }
        tracker?.stop()
        tracker = nil
        super.tearDown()
    }

    private func control(_ mac: FakeMac, settled: Box<[ConsoleState]> = Box([])) -> ConsoleControl {
        var c = ConsoleControl(system: mac.system)
        c.settled = { settled.value.append($0) }
        return c
    }

    // MARK: where IOConsoleLocked is read (the bug)

    /// The property is on the registry's root entry. The service read it at the path `IOService:/`, which is the
    /// platform expert device: no such property there, so `console.locked` was always false.
    func testConsoleLockedIsReadFromTheRegistryRoot() throws {
        guard CGSessionCopyCurrentDictionary() != nil else { throw XCTSkip("no GUI login session: no console properties") }
        XCTAssertNotNil(ConsoleState.lockedProperty(), "IOConsoleLocked is on the registry root while a GUI session exists")
        let platform = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/")
        defer { IOObjectRelease(platform) }
        let there = IORegistryEntryCreateCFProperty(platform, "IOConsoleLocked" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        XCTAssertNil(there, "IOService:/ is not the root (the old read)")
    }

    func testLockedFromProperty() {
        XCTAssertEqual(ConsoleState.locked(fromProperty: kCFBooleanTrue), true)
        XCTAssertEqual(ConsoleState.locked(fromProperty: kCFBooleanFalse), false)
        XCTAssertEqual(ConsoleState.locked(fromProperty: NSNumber(value: 1)), true)
        XCTAssertNil(ConsoleState.locked(fromProperty: nil))
        XCTAssertNil(ConsoleState.locked(fromProperty: "Yes"))
    }

    func testDetectorForceCountsAtOnce() {
        var d = ConsoleChangeDetector()
        XCTAssertNil(d.force(ConsoleState(locked: true)), "nothing settled yet: no change, but settled now")
        XCTAssertEqual(d.settled, ConsoleState(locked: true))
        _ = d.step(ConsoleState(locked: false), now: 0)  // pending
        let change = d.force(ConsoleState(locked: false))
        XCTAssertEqual(change?.to, ConsoleState(locked: false))
        XCTAssertNil(d.pending)
        XCTAssertNil(d.step(ConsoleState(locked: false), now: 10), "already settled")
    }

    // MARK: a locked console reaches /status and /events

    func testLockedConsoleReachesStatusAndEvents() throws {
        let locked = Box(false)
        let clock = Box<TimeInterval>(0)
        let t = ScreenStateTracker()
        tracker = t
        let watcher = ConsoleWatcher(read: { ConsoleState(locked: locked.value) }, clock: { clock.value },
                                     onChange: { _, _ in t.setNeedsRefresh() })
        t.configure(inputs: {
            var i = ScreenStateInputs()
            i.mainDisplay = 7
            i.console = watcher.state
            return i
        })
        watcher.tick()  // settles "unlocked"
        t.start()
        let computed = Date().addingTimeInterval(2)
        while t.version == 0, Date() < computed { usleep(1000) }
        XCTAssertEqual(try statusConsole(), ["locked": false])

        // /events: the first line, then the lock as its own line
        var fds = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let serverFD = fds[0]
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            try? Router.events(Connection(fd: serverFD), pingInterval: 5)
            done.signal()
        }
        let reader = NDJSONReader(fd: fds[1])
        defer { close(fds[1]) }
        _ = try XCTUnwrap(reader.head())
        let first = try XCTUnwrap(reader.json())
        XCTAssertEqual(first["console"] as? NSDictionary, ["locked": false])

        locked.value = true
        clock.value = 0.5
        watcher.tick()
        XCTAssertEqual(watcher.state, ConsoleState(locked: false), "not settled yet")
        clock.value = 2.1
        watcher.tick()
        XCTAssertEqual(watcher.state, ConsoleState(locked: true))
        var line = try XCTUnwrap(reader.json())
        while line["type"] as? String != "state" { line = try XCTUnwrap(reader.json()) }
        XCTAssertEqual(line["console"] as? NSDictionary, ["locked": true])
        XCTAssertEqual(try statusConsole(), ["locked": true])

        // what this process just did counts at once (ConsoleControl tells the watcher)
        watcher.force(ConsoleState(locked: false))
        line = try XCTUnwrap(reader.json())
        while line["type"] as? String != "state" { line = try XCTUnwrap(reader.json()) }
        XCTAssertEqual(line["console"] as? NSDictionary, ["locked": false])

        t.stop()
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
    }

    private func statusConsole() throws -> NSDictionary {
        var fds = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[1]) }
        do { Router.status(Connection(fd: fds[0])) }
        let all = readAll(fds[1])
        let split = try XCTUnwrap(all.range(of: Data("\r\n\r\n".utf8)))
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: all[split.upperBound...]) as? [String: Any])
        return try XCTUnwrap(j["console"] as? NSDictionary)
    }

    // MARK: unlock

    func testUnlockWhenNotLockedTypesNothing() throws {
        let mac = FakeMac()
        mac.set(locked: false, asleep: true)
        let pw = secret("hunter2")
        XCTAssertEqual(try control(mac).unlock(pw), .already)
        XCTAssertEqual(mac.actions, [], "no wake, no keys")
        XCTAssertEqual(pw.count, 0, "wiped")
        XCTAssertEqual(ConsoleUnlockResult.already.json as NSDictionary, ["ok": true, "unlocked": true, "already": true])
    }

    func testUnlockNotOnTheConsole() throws {
        let mac = FakeMac()
        mac.set(onConsole: false)
        XCTAssertEqual(try control(mac).unlock(secret("pw")), .failed("not-console"))
        XCTAssertEqual(mac.actions, [])
        let unreadable = FakeMac()
        unreadable.setUnreadable()
        XCTAssertEqual(try control(unreadable).unlock(secret("pw")), .failed("not-console"))
        XCTAssertEqual(unreadable.actions, [])
        XCTAssertEqual(ConsoleUnlockResult.failed("not-console").json as NSDictionary,
                       ["ok": false, "unlocked": false, "reason": "not-console"])
    }

    func testUnlockWakesASleepingDisplayFirst() throws {
        let mac = FakeMac()
        mac.set(asleep: true)
        let settled = Box<[ConsoleState]>([])
        let pw = secret("pa😀s")
        let start = mac.now
        XCTAssertEqual(try control(mac, settled: settled).unlock(pw), .unlocked)
        XCTAssertEqual(mac.actions, ["wake", "click", "type", "type", "type", "type", "return"])
        XCTAssertEqual(mac.typed, ["p", "a", "😀", "s"], "a surrogate pair is one character")
        XCTAssertGreaterThanOrEqual(mac.now - start, ConsoleControl.wakeSettle + ConsoleControl.clickSettle,
                                    "the lock screen gets its settle times")
        XCTAssertEqual(settled.value, [ConsoleState(locked: false)])
        XCTAssertEqual(pw.count, 0, "wiped")
        XCTAssertFalse(logged.contains { $0.contains("pa") || $0.contains("😀") }, "the password is never logged: \(logged)")
        XCTAssertEqual(ConsoleUnlockResult.unlocked.json as NSDictionary, ["ok": true, "unlocked": true])
    }

    func testUnlockWithTheDisplayOnStillWakesAndClicks() throws {
        let mac = FakeMac()
        let start = mac.now
        XCTAssertEqual(try control(mac).unlock(secret("ab")), .unlocked)
        XCTAssertEqual(mac.actions, ["wake", "click", "type", "type", "return"])
        XCTAssertGreaterThanOrEqual(mac.now - start, ConsoleControl.clickSettle, "the wait after the click is always there")
    }

    /// A lock screen left alone goes idle (no password field; the display on): only a click brings the field back.
    func testUnlockClicksAnIdleLockScreenBackBeforeTyping() throws {
        let mac = FakeMac()
        mac.idle = true
        XCTAssertEqual(try control(mac).unlock(secret("pw")), .unlocked)
        XCTAssertEqual(mac.actions, ["wake", "click", "type", "type", "return"], "no key was lost")
        XCTAssertEqual(mac.typed, ["p", "w"])
    }

    func testUnlockNeverClicksOnceUnlocked() throws {
        let mac = FakeMac()
        mac.set(asleep: true)
        mac.unlocksBeforeClick = true
        let settled = Box<[ConsoleState]>([])
        XCTAssertEqual(try control(mac, settled: settled).unlock(secret("pw")), .already)
        XCTAssertEqual(mac.actions, ["wake"], "re-checked right before the click: no click, no keys")
        XCTAssertEqual(settled.value, [ConsoleState(locked: false)])
    }

    func testUnlockStopsWhenTheClickUnlocked() throws {
        let mac = FakeMac()
        mac.unlocksAtClick = true  // e.g. Touch ID at the same moment
        XCTAssertEqual(try control(mac).unlock(secret("pw")), .already)
        XCTAssertEqual(mac.actions, ["wake", "click"])
    }

    func testUnlockDisplayThatNeverWakes() throws {
        let mac = FakeMac()
        mac.set(asleep: true)
        mac.wakeTakes = nil
        let start = mac.now
        XCTAssertEqual(try control(mac).unlock(secret("pw")), .failed("display-asleep"))
        XCTAssertEqual(mac.actions, ["wake"], "nothing typed")
        XCTAssertLessThanOrEqual(mac.now - start, ConsoleControl.wakeWait + 0.2)
    }

    func testUnlockStopsTheMomentTheConsoleIsUnlockedElsewhere() throws {
        let mac = FakeMac()
        mac.unlocksAfterCharacters = 3
        let settled = Box<[ConsoleState]>([])
        XCTAssertEqual(try control(mac, settled: settled).unlock(secret("abcdefgh")), .already)
        XCTAssertEqual(mac.typed, ["a", "b", "c"], "not one character more")
        XCTAssertFalse(mac.actions.contains("return"), "no Return into whatever is in front now")
        XCTAssertEqual(settled.value, [ConsoleState(locked: false)])
    }

    func testUnlockStopsBeforeReturnWhenUnlockedAfterTheLastCharacter() throws {
        let mac = FakeMac()
        mac.unlocksAfterCharacters = 2
        XCTAssertEqual(try control(mac).unlock(secret("ab")), .already)
        XCTAssertEqual(mac.typed, ["a", "b"])
        XCTAssertFalse(mac.actions.contains("return"))
    }

    func testUnlockWrongPasswordIsOneAttempt() throws {
        let mac = FakeMac()
        mac.onReturn = .wrong
        let start = mac.now
        XCTAssertEqual(try control(mac).unlock(secret("nope")), .failed("wrong-password"))
        XCTAssertEqual(mac.actions.filter { $0 == "return" }.count, 1, "never retried")
        XCTAssertEqual(mac.typed.count, 4)
        XCTAssertLessThan(mac.now - start, ConsoleControl.unlockWait, "the count moving answers early")
    }

    func testUnlockTimeoutWhenNothingMoves() throws {
        let mac = FakeMac()
        mac.onReturn = .nothing
        XCTAssertEqual(try control(mac).unlock(secret("pw")), .failed("timeout"))
        XCTAssertEqual(mac.actions.filter { $0 == "return" }.count, 1)
    }

    func testUnlockWithoutFailedLoginBookkeepingSaysWrongPassword() throws {
        let mac = FakeMac()
        mac.onReturn = .nothing
        mac.set(failed: .some(nil))
        XCTAssertEqual(try control(mac).unlock(secret("pw")), .failed("wrong-password"), "a caller must stop trying")
    }

    func testUnlockWithoutAccessibilityIs403AndTypesNothing() {
        let mac = FakeMac()
        mac.set(ax: false)
        let pw = secret("pw")
        XCTAssertThrowsError(try control(mac).unlock(pw)) { error in
            XCTAssertEqual((error as? HTTPError)?.status, 403)
        }
        XCTAssertEqual(mac.actions, [])
        XCTAssertEqual(pw.count, 0, "wiped on every path")
    }

    // MARK: lock

    func testLock() {
        let mac = FakeMac()
        mac.set(locked: false)
        let settled = Box<[ConsoleState]>([])
        XCTAssertEqual(control(mac, settled: settled).lock(), .locked)
        XCTAssertEqual(mac.actions, ["sac"])
        XCTAssertEqual(settled.value, [ConsoleState(locked: true)])
        XCTAssertEqual(ConsoleLockResult.locked.json as NSDictionary, ["ok": true, "locked": true])
        XCTAssertEqual(control(mac).lock(), .already)
        XCTAssertEqual(mac.actions, ["sac"], "already locked: nothing done")
    }

    func testLockFallsBackToTheShortcut() {
        let missing = FakeMac()
        missing.set(locked: false)
        missing.sacExists = false
        XCTAssertEqual(control(missing).lock(), .locked)
        XCTAssertEqual(missing.actions, ["ctrl-cmd-q"])

        let noEffect = FakeMac()
        noEffect.set(locked: false)
        noEffect.sacLocks = false
        XCTAssertEqual(control(noEffect).lock(), .locked)
        XCTAssertEqual(noEffect.actions, ["sac", "ctrl-cmd-q"])

        let noAX = FakeMac()
        noAX.set(locked: false, ax: false)
        noAX.sacExists = false
        XCTAssertEqual(control(noAX).lock(), .failed("no-permission"))
        XCTAssertEqual(noAX.actions, [])
    }

    func testLockTimeoutAndNotConsole() {
        let mac = FakeMac()
        mac.set(locked: false)
        mac.sacLocks = false
        mac.shortcutLocks = false
        let start = mac.now
        XCTAssertEqual(control(mac).lock(), .failed("timeout"))
        XCTAssertLessThanOrEqual(mac.now - start, ConsoleControl.lockWait + 0.2)
        XCTAssertEqual(ConsoleLockResult.failed("timeout").json as NSDictionary, ["ok": false, "locked": false, "reason": "timeout"])

        let away = FakeMac()
        away.set(locked: false, onConsole: false)
        XCTAssertEqual(control(away).lock(), .failed("not-console"))
        XCTAssertEqual(away.actions, [])
    }

    // MARK: the password body

    private func parse(_ json: String) throws -> String {
        let units = try ConsolePasswordBody.parse(Data(json.utf8))
        return units.withUnits { String(decoding: Array($0), as: UTF16.self) }
    }

    private func status(_ json: String) -> Int? {
        do { _ = try ConsolePasswordBody.parse(Data(json.utf8)); return nil } catch { return (error as? HTTPError)?.status }
    }

    func testPasswordBody() throws {
        XCTAssertEqual(try parse(#"{"password":"hunter2"}"#), "hunter2")
        XCTAssertEqual(try parse(#" { "password" : "a\"b\\c\/d" } "#), #"a"b\c/d"#)
        XCTAssertEqual(try parse(#"{"password":"étÉ"}"#), "étÉ")
        XCTAssertEqual(try parse(#"{"password":"😀x"}"#), "😀x")
        XCTAssertEqual(try parse(#"{"password":"密码😀é"}"#), "密码😀é")
        XCTAssertEqual(try parse(#"{"a":1.5e3,"b":[true,{"c":null}],"password":"p","d":"x"}"#), "p", "other members skipped")
        XCTAssertEqual(try parse(#"{"password":"first","password":"second"}"#), "second")
    }

    func testPasswordBodyErrors() {
        XCTAssertEqual(status(""), 400)
        XCTAssertEqual(status("[]"), 400)
        XCTAssertEqual(status("{}"), 400)
        XCTAssertEqual(status(#"{"password":""}"#), 400)
        XCTAssertEqual(status(#"{"password":12}"#), 400)
        XCTAssertEqual(status(#"{"password":"a\nb"}"#), 400, "control characters")
        XCTAssertEqual(status("{\"password\":\"a\u{1}b\"}"), 400, "raw control characters are not JSON")
        XCTAssertEqual(status(#"{"password":"abc"#), 400, "unterminated")
        XCTAssertEqual(status(#"{"password":"abc"} x"#), 400, "trailing bytes")
        XCTAssertEqual(status(#"{"password":"\x"}"#), 400)
        XCTAssertEqual(status(#"{"password":"\u12"}"#), 400)
        XCTAssertEqual(status(#"{"password":"\#(String(repeating: "a", count: 1025))"}"#), 400)
        XCTAssertNil(status(#"{"password":"\#(String(repeating: "a", count: 1024))"}"#))
        var bad = Data(#"{"password":""#.utf8)
        bad.append(contentsOf: [0xC3, 0x28, 0x22, 0x7D])  // invalid UTF-8
        XCTAssertThrowsError(try ConsolePasswordBody.parse(bad))
        do {
            _ = try ConsolePasswordBody.parse(Data(#"{"password":"secret-value","x":}"#.utf8))
            XCTFail("invalid")
        } catch {
            XCTAssertFalse("\(error)".contains("secret-value"), "errors never quote the body")
        }
    }

    func testSecretUnitsWipe() {
        let s = secret("abc")
        XCTAssertEqual(s.count, 3)
        s.wipe()
        XCTAssertEqual(s.count, 0)
        s.withUnits { XCTAssertEqual($0.count, 0) }
    }

    func testFailedLoginsParse() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
        <key>failedLoginCount</key><integer>2</integer><key>failedLoginTimestamp</key><real>1794079365.31</real>
        </dict></plist>
        """
        XCTAssertEqual(FailedLogins.parse(Data(plist.utf8)), FailedLogins(count: 2, timestamp: 1794079365.31))
        let fresh = #"<?xml version="1.0"?><plist version="1.0"><dict><key>creationTime</key><real>1</real></dict></plist>"#
        XCTAssertEqual(FailedLogins.parse(Data(fresh.utf8)), FailedLogins(count: 0, timestamp: 0))
        XCTAssertNil(FailedLogins.parse(Data("nope".utf8)))
    }

    // MARK: routes

    func testRoutesAreTheUnixSocketsOnly() throws {
        var fds = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[1]) }
        let conn = Connection(fd: fds[0])
        let phone = RemoteDevice(id: "phone-1234", name: "P", pairedAt: Date(), lastSeenAt: nil, tokenHash: "")
        for path in ["/console/unlock", "/console/lock"] {
            var req = HTTPRequest(method: "POST", path: path, query: [:], headers: [:], body: Data(#"{"password":"x"}"#.utf8))
            req.remote = phone
            XCTAssertThrowsError(try Router.handle(req, conn)) { XCTAssertEqual(($0 as? HTTPError)?.status, 404) }
            let get = HTTPRequest(method: "GET", path: path, query: [:], headers: [:], body: Data())
            XCTAssertThrowsError(try Router.handle(get, conn)) { XCTAssertEqual(($0 as? HTTPError)?.status, 405) }
        }
        let bad = HTTPRequest(method: "POST", path: "/console/unlock", query: [:], headers: [:], body: Data("{}".utf8))
        XCTAssertThrowsError(try Router.handle(bad, conn)) { XCTAssertEqual(($0 as? HTTPError)?.status, 400) }
    }
}

private func readAll(_ fd: Int32) -> Data {
    var all = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while true {
        let r = read(fd, &chunk, chunk.count)
        guard r > 0 else { break }
        all.append(contentsOf: chunk[0..<r])
    }
    return all
}

/// Reads an HTTP head, then NDJSON lines (3 s read timeout).
private final class NDJSONReader {
    let fd: Int32
    private var buffer = [UInt8]()
    init(fd: Int32) {
        self.fd = fd
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
    private func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &chunk, chunk.count)
        guard n > 0 else { return false }
        buffer.append(contentsOf: chunk[0..<n])
        return true
    }
    func head() -> String? {
        while true {
            if buffer.count >= 4, let i = (0...(buffer.count - 4)).first(where: { Array(buffer[$0..<$0 + 4]) == [13, 10, 13, 10] }) {
                let s = String(decoding: buffer[0..<i + 4], as: UTF8.self)
                buffer.removeFirst(i + 4)
                return s
            }
            guard fill() else { return nil }
        }
    }
    func json() -> [String: Any]? {
        while true {
            if let i = buffer.firstIndex(of: 10) {
                let line = Data(buffer[0..<i])
                buffer.removeFirst(i + 1)
                return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
            }
            guard fill() else { return nil }
        }
    }
}
