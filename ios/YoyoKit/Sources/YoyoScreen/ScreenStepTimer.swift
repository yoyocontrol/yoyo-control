import Foundation
import OSLog
import QuartzCore
import YoyoCore

/// How long something the session does on the main thread takes, step by step (its stop): a signpost interval around
/// it with an event per step (Instruments' Points of Interest), then one log line with the milliseconds of each step
/// (`screen-stop` in the `ca.sarria.yoyocontrol` subsystem, and to `YoyoHost.log` when the host set one). Cheap: a
/// clock read per step. Main actor.
@MainActor
final class ScreenStepTimer {
    nonisolated static let log = Logger(subsystem: "ca.sarria.yoyocontrol", category: "screen-stop")
    nonisolated static let signposter = OSSignposter(subsystem: "ca.sarria.yoyocontrol", category: .pointsOfInterest)

    private let name: String
    private let start: Double
    private var last: Double
    private var steps: [(name: String, ms: Double)] = []
    private let interval: OSSignpostIntervalState

    init(_ name: String) {
        self.name = name
        start = CACurrentMediaTime()
        last = start
        interval = Self.signposter.beginInterval("screen.session", "\(name, privacy: .public)")
    }

    /// The step just done (since the last mark, or the start).
    func mark(_ step: String) {
        let now = CACurrentMediaTime()
        steps.append((step, (now - last) * 1000))
        last = now
        Self.signposter.emitEvent("screen.step", "\(step, privacy: .public)")
    }

    /// The whole of it: the line logged ("stop 12.3 ms: freeze 0.1 · stream 0.4 · …").
    @discardableResult
    func end() -> String {
        let total = (CACurrentMediaTime() - start) * 1000
        Self.signposter.endInterval("screen.session", interval)
        let line = Self.line(name, total: total, steps: steps)
        Self.log.notice("\(line, privacy: .public)")
        YoyoHost.current.log?("screen-stop", line)
        return line
    }

    /// The steps' times so far (tests).
    var stepNames: [String] { steps.map(\.name) }

    nonisolated static func line(_ name: String, total: Double, steps: [(name: String, ms: Double)]) -> String {
        let parts = steps.map { "\($0.name) " + String(format: "%.1f", $0.ms) }
        return "\(name) " + String(format: "%.1f", total) + " ms: " + parts.joined(separator: " · ")
    }
}
