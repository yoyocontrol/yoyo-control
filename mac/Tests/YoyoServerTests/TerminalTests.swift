import Foundation
import XCTest
@testable import YoyoServer

/// A sink that keeps what it got.
private final class Collect: TerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private(set) var attached: TerminalSession.Attached?
    private(set) var end: TerminalEnd?
    var backlog = 0

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: out, as: UTF8.self)
    }

    var ended: TerminalEnd? {
        lock.lock(); defer { lock.unlock() }
        return end
    }

    func terminalAttached(_ a: TerminalSession.Attached) {
        lock.lock()
        attached = a
        out.append(a.replay)
        lock.unlock()
    }

    func terminalOutput(_ data: Data) {
        lock.lock()
        out.append(data)
        lock.unlock()
    }

    func terminalEnded(_ e: TerminalEnd) {
        lock.lock()
        end = e
        lock.unlock()
    }

    var terminalBacklog: Int { backlog }
}

final class TerminalTests: XCTestCase {
    private func wait(_ what: String, timeout: TimeInterval = 5, _ cond: () -> Bool) {
        let until = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > until { XCTFail("timed out waiting for \(what)"); return }
            usleep(10_000)
        }
    }

    private func env() -> [String: String] {
        ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8", "HOME": NSTemporaryDirectory()]
    }

    func testRunsOnAPseudoTerminalAndExits() throws {
        let t = try TerminalSession(id: "t1", cols: 100, rows: 30, cwd: "/tmp", device: ("d", "iPhone"),
                                    command: ["/bin/sh", "-c", "stty size; pwd; test -t 0 && echo tty; read x; echo got:$x; exit 3"],
                                    environment: env())
        let sink = Collect()
        // a new one: its copy starts at byte 0 (no redraw)
        XCTAssertTrue(t.attach(sink, since: 0))
        XCTAssertEqual(sink.attached?.offset, 0)
        XCTAssertEqual(sink.attached?.reset, false)
        wait("the size") { sink.text.contains("30 100") && sink.text.contains("tty") }
        XCTAssertTrue(sink.text.contains("/tmp") || sink.text.contains("/private/tmp"), sink.text)
        t.write(Data("hello\r".utf8))
        wait("the answer") { sink.text.contains("got:hello") }
        wait("the exit") { sink.ended != nil }
        XCTAssertEqual(sink.ended, .exited(3))
        XCTAssertFalse(t.attach(Collect(), since: nil))
    }

    func testComingBackGetsWhatWasMissed() throws {
        let t = try TerminalSession(id: "t2", cols: 80, rows: 24, cwd: nil, device: nil,
                                    command: ["/bin/sh", "-c", "echo one; read x; echo two-$x; read y"], environment: env())
        defer { t.end(.killed) }
        let first = Collect()
        XCTAssertTrue(t.attach(first, since: nil))
        wait("one") { first.text.contains("one") }
        let seen = UInt64(first.text.utf8.count)
        t.detach(first)
        t.write(Data("b\r".utf8))
        // nobody attached: it goes on into the ring
        usleep(300_000)
        let second = Collect()
        XCTAssertTrue(t.attach(second, since: seen))
        XCTAssertEqual(second.attached?.reset, false)
        XCTAssertEqual(second.attached?.offset, seen)
        wait("two") { second.text.contains("two-b") }
        XCTAssertFalse(second.text.contains("one"))

        // a third takes it over; the second hears so
        let third = Collect()
        XCTAssertTrue(t.attach(third, since: nil))
        XCTAssertEqual(third.attached?.reset, true)
        XCTAssertEqual(second.ended, .replaced)
        XCTAssertTrue(third.text.contains("two-b"))
    }

    func testEndingIt() throws {
        let t = try TerminalSession(id: "t3", cols: 80, rows: 24, cwd: nil, device: nil,
                                    command: ["/bin/sh", "-c", "sleep 30"], environment: env())
        let sink = Collect()
        XCTAssertTrue(t.attach(sink, since: nil))
        wait("the command") { t.foregroundCommand == "sleep" }
        t.end(.killed)
        wait("the end") { sink.ended != nil }
        XCTAssertEqual(sink.ended, .killed)
        XCTAssertTrue(t.hasEnded)
    }

    func testTheLoginShellsEnvironment() {
        let env = TerminalSession.environment(home: "/Users/x", shell: "/bin/zsh", user: "x")
        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertEqual(env["COLORTERM"], "truecolor")
        XCTAssertEqual(env["HOME"], "/Users/x")
        XCTAssertNil(env.keys.first { $0.hasPrefix("YOYO_") })
        XCTAssertTrue(TerminalSession.utf8Locale().hasSuffix(".UTF-8"))
    }
}
