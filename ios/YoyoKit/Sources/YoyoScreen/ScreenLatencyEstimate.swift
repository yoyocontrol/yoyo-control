import Foundation
import YoyoClipboard
import YoyoCore

/// The client's estimate of how long a touch takes to show on the phone (the stats line's second row and the test
/// panel; never sent to the Mac): the input's way to the Mac (half the input round trip's p50; half the ack round
/// trip's min while no input was answered), the Mac's side (`macMs`: capture 14 + encode ~12 + writing the part), the
/// picture's way back (half the ack round trip's min; half the input p50 while the server hasn't graded the stream),
/// the playout's hold (`ScreenStreamStats.Playout.hold`, 0 on arrival), the decode time and one refresh of the display.
/// Milliseconds; nil when no round trip is known. Pure.
enum ScreenLatencyEstimate {
    /// The Mac's part: capture 14 + encode ~12 + write.
    static let macMs = 30.0
    /// The refresh when the display's isn't measured yet.
    static let defaultRefreshHz = 60.0

    static func estimate(inputRttP50Ms: Double?, ackRttMinMs: Double?, holdMs: Double?, decodeMs: Double?,
                         refreshHz: Double?) -> Double? {
        func ms(_ v: Double?) -> Double? { v.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
        let input = ms(inputRttP50Ms), ack = ms(ackRttMinMs)
        guard let up = input ?? ack, let down = ack ?? input else { return nil }
        let hz = ms(refreshHz).flatMap { $0 > 0 ? $0 : nil } ?? defaultRefreshHz
        return up / 2 + macMs + down / 2 + (ms(holdMs) ?? 0) + (ms(decodeMs) ?? 0) + 1000 / hz
    }

    /// `~84 ms` (a number and a unit: not localized).
    static func text(_ ms: Double) -> String { String(format: "~%.0f ms", ms) }
}
