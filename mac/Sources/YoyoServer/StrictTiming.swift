#if os(macOS)
import Foundation

// Precise short sleeps and waits for the stream's fps cap and the scroll pacing.
//
// yoyo-control may run under a LaunchAgent with no ProcessType (launchd "daemon" spawn type; a client that spawns
// the service itself) and then inherits its timer coalescing: there usleep(5 ms), nanosleep, mach_wait_until,
// Thread.sleep and condition/semaphore timeouts all measured 21–24 ms (p50), so every fps-cap wait overslept by up to
// ~20 ms. QoS classes, a latency-critical ProcessInfo activity and PRIO_DARWIN_* do not change it;
// a `.strict` dispatch timer with zero leeway does (measured 5.2 ms for 5 ms). Waits for an fd or
// a signal are unaffected (they are not timers), only timeouts.

public enum StrictTiming {
    static let queue = DispatchQueue(label: "yoyo-strict-timer", qos: .userInteractive)

    /// A strict one-shot timer that runs `handler` at `deadline` (on a private queue). Cancel it
    /// when done. Used to cut a condition wait short on time, since its own timeout is coalesced.
    static func strictTimer(at deadline: Date, _ handler: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now() + max(0, deadline.timeIntervalSinceNow), leeway: .nanoseconds(0))
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }

    /// Block the calling thread for `seconds` on a strict, non-coalesced timer.
    public static func sleep(_ seconds: TimeInterval) {
        guard seconds > 0, seconds.isFinite else { return }
        let done = DispatchSemaphore(value: 0)
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now() + seconds, leeway: .nanoseconds(0))
        timer.setEventHandler { done.signal() }
        timer.resume()
        done.wait()
        timer.cancel()
    }
}
#endif
