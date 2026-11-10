import Foundation
import YoyoLink

/// The speed test's result (docs/LINK.md「测速」): what this connection's path carries the way a picture goes —
/// the computer sends filler frames through the same FEC, NACK, pacing and rate control, the phone counts them.
/// Rates in Mbit/s, times in ms; nil = not measured. `json` is the report as Link wrote it (camelCase), to pass on.
public struct YoyoLinkSpeedTest: Sendable, Equatable, Codable {
    /// "quic" (the app) or "rtc" (a browser).
    public var transport: String
    /// "lan", "direct", "punched", "relay".
    public var path: String
    /// "wifi", "cellular", "wired", "other" (the phone's network as it told Link).
    public var iface: String
    public var durationMs: Int
    /// The idle path's RTT (lowest of the 10 s before), and the RTT under the test's load.
    public var rttIdleMs: Double?
    public var rttP50Ms: Double?
    public var rttP90Ms: Double?
    /// Frames delivered; their payload rate over the whole test, the best second, the last two seconds.
    public var frames: Int
    public var receivedMbps: Double?
    public var peakMbps: Double?
    public var finalMbps: Double?
    /// Frames per second over the last two seconds (the frame-rate cap follows the rate).
    public var finalFps: Double?
    /// Media datagrams lost before FEC (%), and what FEC / NACK got back.
    public var lossPct: Double?
    public var fecRecovered: Int
    public var nackRecovered: Int
    public var lostFrames: Int
    public var skippedFrames: Int
    public var freezes: Int
    public var freezeMs: Int
    /// The computer's half (nil: its report didn't come).
    public var server: Server?

    public struct Server: Sendable, Equatable, Codable {
        /// The rate control's target at the end, and the highest it reached.
        public var targetMbps: Double
        public var maxTargetMbps: Double
        /// The encoder rate at the end (what a picture's encoder would get), and the frame-rate cap at that rate.
        public var encoderMbps: Double
        public var fpsCap: Double
        /// Everything it sent (FEC, retransmits included).
        public var sentMbps: Double?
        public var frames: Int
        public var bytes: Int
        /// Rate decreases: delay-based, loss-based.
        public var rateCuts: Int
        public var rateLossCuts: Int
        public var retransmits: Int
        /// The one-way delay jitter the rate control measured.
        public var jitterMs: Double?
        /// "done" or "stopped".
        public var reason: String
    }

    /// The report from Link's JSON (nil: not a report).
    public init?(json: Data) {
        guard let r = try? JSONDecoder().decode(YoyoLinkSpeedTest.self, from: json) else { return nil }
        self = r
    }
}

extension YoyoLinkConnection {
    /// The speed test (docs/LINK.md「测速」): the computer sends filler frames through this session's video path for
    /// `durationMs` (it keeps it within 1000–20000; 8000 lets the rate control's startup climb reach its ceiling and
    /// shows where it settled) and the report says what the Screen page would get here. Run it on a connection that
    /// shows no picture (open streams share the rate). Throws `YoyoLinkSpeedTestError`: `.unsupported` when the
    /// computer's version has no speed test (after 3 s), `.ended` when the session ends; cancelling the task stops it.
    /// Returns the report and its JSON.
    public func speedTest(durationMs: UInt64 = 8000) async throws -> (report: YoyoLinkSpeedTest, json: String) {
        let r: ProbeReport
        do {
            r = try await session.probe(durationMs: durationMs)
        } catch let e as LinkError {
            switch e {
            case .Timeout: throw YoyoLinkSpeedTestError.unsupported
            case .Closed: throw YoyoLinkSpeedTestError.ended
            default: throw YoyoLinkSpeedTestError.failed(e.localizedDescription)
            }
        }
        guard let report = YoyoLinkSpeedTest(json: Data(r.json.utf8)) else {
            throw YoyoLinkSpeedTestError.badReport
        }
        return (report, r.json)
    }
}

public enum YoyoLinkSpeedTestError: Error, Sendable, Equatable {
    /// The computer's Link has no speed test (an older version: it never answered).
    case unsupported
    /// The session ended during the test.
    case ended
    /// Anything else Link said.
    case failed(String)
    /// Link's report didn't decode (a kit and core of different versions).
    case badReport
}
