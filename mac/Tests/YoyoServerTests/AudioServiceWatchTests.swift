import CoreAudio
import XCTest
@testable import YoyoServer

/// AudioWatchdog.swift's process helpers and the coreaudiod-restart hand-over (the deaf watchdog's policy and cache
/// are in AudioPerfTests).
final class AudioServiceWatchTests: XCTestCase {
    func testOwnProcessFacts() throws {
        let me = try XCTUnwrap(ProcessFacts.of(getpid()))
        XCTAssertEqual(me.uid, getuid())
        XCTAssertNil(ProcessFacts.of(-5))
    }

    // MARK: - coreaudiod restart

    func testServiceRestartGoesToTheHostHookElseRebuilds() {
        let before = AudioServiceWatch.restarts
        var hooked = 0, rebuilt = 0
        AudioServiceWatch.serviceRestarted(hook: { hooked += 1 }, rebuild: { rebuilt += 1 })
        XCTAssertEqual([hooked, rebuilt], [1, 0], "yoyo-control: the hook (it exits), no in-process rebuild")
        AudioServiceWatch.serviceRestarted(hook: nil, rebuild: { rebuilt += 1 })
        XCTAssertEqual([hooked, rebuilt], [1, 1], "no hook: rebuilt in-process")
        XCTAssertEqual(AudioServiceWatch.restarts, before + 2)
    }

    func testServiceRestartWithoutACaptureIsHarmless() {
        AudioCapture.serviceRestarted()  // nothing running: only the settle hold
        XCTAssertEqual(AudioCapture.statsJSON()["running"] as? Bool, false)
    }

    func testListenerInstalls() throws {
        let status = AudioServiceWatch.install()
        guard status == noErr else { throw XCTSkip("no Core Audio here (\(AudioCapture.osStatus(status)))") }
        XCTAssertEqual(AudioServiceWatch.install(), noErr, "idempotent")
    }

    /// Plays an inaudible tone through afplay and taps it: YOYO_AUDIO_LIVE_TESTS=1 only (Core Audio, a few seconds).
    func testTapCheckHearsAFreshClient() throws {
        guard ProcessInfo.processInfo.environment["YOYO_AUDIO_LIVE_TESTS"] == "1" else { throw XCTSkip("YOYO_AUDIO_LIVE_TESTS=1 runs it") }
        guard #available(macOS 14.2, *) else { throw XCTSkip("no process taps") }
        let (result, detail) = AudioTapCheck.run()
        XCTAssertEqual(result, .hears, detail)
    }

    func testStatsShape() {
        XCTAssertNotNil(AudioCapture.statsJSON()["serviceRestarts"])
        XCTAssertNotNil(AudioCapture.statsJSON()["watchdog"])
        XCTAssertNil(AudioCapture.statsJSON()["revive"])
    }
}
