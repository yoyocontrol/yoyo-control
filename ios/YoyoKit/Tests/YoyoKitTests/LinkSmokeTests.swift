#if canImport(YoyoLinkClient)
import AVFoundation
import Foundation
import Testing
import UIKit
@testable import YoyoConnect
@testable import YoyoCore
@testable import YoyoDirect
@testable import YoyoLink
@testable import YoyoLinkClient
@testable import YoyoScreen

/// End to end against a real uu Link server on this Mac, run only when `YOYO_LINK_SMOKE` names its info file
/// (`{fingerprint, binding, token}`; from xcodebuild, `TEST_RUNNER_YOYO_LINK_SMOKE=<path>`). The Mac server's own
/// test serves one: `cd mac && YOYO_LINK_SERVE=<path> swift test --filter LinkServeTests` (its real listener, video
/// loop and encoder, fake pictures, recorded input). Yoyo Control's own backend and routing over it: the connector
/// races the link first and takes it, the page's stream opens there (real H.264 through the decoder), `/status` and
/// `/events` go as RPC, input before control is refused (a 409 back to the page), `control.take` gets it, then moves and
/// keys flow for `YOYO_LINK_SMOKE_SECONDS` (default 3). Behind netem: `TEST_RUNNER_YOYO_LINK_BIND=::1` (docs/LINK.md
/// 「测试工具」). Prints a `link smoke:` summary.
@MainActor
@Suite("Link end to end", .enabled(if: ProcessInfo.processInfo.environment["YOYO_LINK_SMOKE"] != nil), .serialized)
struct LinkSmokeTests {
    struct Info {
        let fingerprint: String
        let binding: ConnectLinkBinding
        let token: String
    }

    static func info() throws -> Info {
        let path = try #require(ProcessInfo.processInfo.environment["YOYO_LINK_SMOKE"])
        let o = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        return Info(fingerprint: try #require(o["fingerprint"] as? String), binding: try #require(ConnectLinkBinding(json: o["binding"])),
                    token: try #require(o["token"] as? String))
    }

    private func settle(seconds: Double = 10, until done: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(seconds)
        while !done(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    nonisolated static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    @Test func aWrongCredentialIsRefused() async throws {
        let info = try Self.info()
        do {
            _ = try await YoyoLinkClient.shared.dial(info.binding, fingerprint: info.fingerprint, credential: "Bearer nope")
            Issue.record("dialed with a token the server doesn't know")
        } catch let YoyoLinkClient.Failure.unauthorized(message) {
            #expect(!message.isEmpty)
        }
    }

    /// The speed test against the real server (docs/LINK.md「测速」): its session sends the filler, the report comes.
    @Test func theSpeedTestRuns() async throws {
        let info = try Self.info()
        let link = try await YoyoLinkClient.shared.dial(info.binding, fingerprint: info.fingerprint, credential: "Bearer \(info.token)")
        defer { link.close() }
        let (r, json) = try await link.speedTest(durationMs: 3000)
        print("link smoke: speed test \(json)")
        #expect(r.frames > 30 && (r.finalMbps ?? 0) > 1)
        #expect(r.server?.reason == "done")
        #expect(r.lostFrames == 0)
    }

    @Test func thePageRunsOnTheLink() async throws {
        let info = try Self.info()
        let mac = YoyoMac(id: "link-smoke", name: "Link Test", fingerprint: info.fingerprint, token: info.token, link: info.binding)
        let located = try await YoyoClient.locate(mac, pro: true)
        let ways = DirectWays(mac: located.mac, pro: true, link: located.link)
        defer { ways.close() }
        let backend = DirectBackend(ways: ways, token: info.token, serverId: mac.id, fingerprint: mac.fingerprint)
        let name = "link-smoke-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(false, forKey: ScreenAudio.defaultsKey)
        let host = ScreenSessionTests.Host()
        let session = ScreenSession(backend: backend, videoOutput: ScreenVideoOutput(renderer: AVSampleBufferDisplayLayer().sampleBufferRenderer),
                                    defaults: defaults)
        session.host = host
        var refusals: [Error] = []
        session.onInputError = { refusals.append($0) }
        let started = ContinuousClock.now
        session.newVisit()
        session.activate()

        // the link is raced first and taken; the stream waited for it and opened there
        await settle { host.videoShown > 0 }
        let firstPicture = Self.ms(ContinuousClock.now - started)
        #expect(session.currentRoute.id == DirectConnect.linkId, "the way is the link")
        #expect(host.videoShown > 0, "a real H.264 picture came over the link and was decoded")
        let connection = try #require(backend.screenLink(for: session.currentRoute) as? YoyoLinkConnection)
        #expect(session.statsText().contains("link lan"), "loopback: the link's path is the local network")

        // the server's routes as RPC on the link
        _ = try await backend.status()
        let (code, lines) = try await backend.lines(backend.request("GET", "events", timeout: 5))
        #expect(code == 200, "/events answered \(code)")
        let firstEvent = Task { () -> String? in
            for try await l in lines { return l }
            return nil
        }

        // input before control: refused, back to the page as a 409
        let send = try #require(session.linkInput(), "input goes on the link")
        try send(.click(display: nil, at: CGPoint(x: 0.5, y: 0.5)))
        await settle(seconds: 5) { !refusals.isEmpty }
        if case YoyoError.http(409, _)? = refusals.first as? YoyoError {} else {
            Issue.record("input without control is refused as a 409: \(refusals)")
        }
        // control, then moves and keys
        _ = try await session.control(.user)
        let event = await Task { await (try? firstEvent.value) ?? nil }.value
        #expect(event?.contains("\"type\"") == true, "/events streams over RPC: \(event ?? "nil")")
        let seconds = Double(ProcessInfo.processInfo.environment["YOYO_LINK_SMOKE_SECONDS"] ?? "3") ?? 3
        let refusedBefore = refusals.count
        let end = ContinuousClock.now + .seconds(seconds)
        var n = 0
        while ContinuousClock.now < end {
            try send(.pointer(.move, display: nil, at: CGPoint(x: Double(n % 100) / 100, y: 0.5)))
            if n % 3 == 0 { try send(ScreenInput(.key, display: nil, key: "a")) }
            n += 1
            try await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(500))
        #expect(refusals.count == refusedBefore, "nothing refused while in control: \(refusals)")

        let counts = connection.frameCounts
        let stats = connection.session.stats()
        let line = session.statsText().replacingOccurrences(of: "\n", with: " / ")
        print(String(format: "link smoke: first picture %.0f ms; frames %d (%d key, %d recovery), decoded %d, decode failures %d; "
                     + "input ack p50 %.1f / p90 %.1f ms (%d); freeze %d / %d ms; lost %d, skipped %d; rtt %.1f/%.1f/%.1f ms",
                     firstPicture, counts.frames, counts.keys, counts.recoveries, counts.decoded, counts.decodeFailures,
                     stats.media.inputP50Ms ?? -1, stats.media.inputP90Ms ?? -1, Int(stats.media.inputN ?? 0),
                     Int(stats.media.freezeCount ?? 0), Int(stats.media.freezeMs ?? 0), Int(stats.media.lostFrames ?? 0),
                     Int(stats.media.skippedFrames ?? 0), stats.rttMinMs, stats.rttP50Ms, stats.rttP90Ms))
        print("link smoke: link line \(stats.line)")
        print("link smoke: stats line \(line)")
        #expect(counts.decoded >= Int(seconds * 10), "pictures keep coming and decode")
        #expect(counts.decodeFailures == 0)
        _ = try? await session.control(.none)
        session.deactivate()
        session.leaveRoute()
    }
}
#endif
