import CoreTelephony
import Foundation
import Network
import YoyoClipboard
import YoyoCore

/// The phone's side of the network for the playout report's `net` (PROTOCOL.md「网络质量」), from host times (seconds):
/// the route the stream uses, the network path, `POST /input` round trips of the last `window` seconds on that
/// route (cleared when it changes), input and ack requests that failed on the way in the same window, and the stream's
/// bytes over the playout report's window (`rxWindow`). Pure (`ScreenStreamStats` holds one under its lock).
struct ScreenNetSampler {
    /// What the network path says (`ScreenNetPath.from`).
    struct Path: Sendable, Equatable {
        var iface: ScreenNetReport.Interface?
        var radio: ScreenNetReport.Radio?
        var expensive: Bool?
        var constrained: Bool?
    }

    var window: Double = 10
    var rxWindow: Double = 3
    /// At most this many round trips are kept (inputs come at most one at a time, so this is never reached in 10 s
    /// at a normal pace).
    static let maxSamples = 512

    private(set) var route: ScreenNetReport.Route?
    var path: Path?
    private var rtts: [(at: Double, ms: Double)] = []
    private var failures: [Double] = []
    /// Bytes in buckets of `bucket` seconds (the stream's data arrives in many small pieces).
    private var rx: [(at: Double, bytes: Int)] = []
    private var rxSince: Double?
    private let bucket = 0.1

    init(window: Double = 10, rxWindow: Double = 3) { self.window = window; self.rxWindow = rxWindow }

    /// The stream now goes this way: round trips measured on another one no longer count.
    mutating func setRoute(_ route: ScreenNetReport.Route?) {
        if route != self.route { rtts.removeAll() }
        self.route = route
    }

    /// A new stream: its bytes are counted from `now`.
    mutating func streamStarted(at now: Double) {
        rx.removeAll()
        rxSince = now
    }

    /// An input was answered after `ms` on `route` (one on a route other than the stream's is left out).
    mutating func inputAnswered(route: ScreenNetReport.Route, ms: Double, at now: Double) {
        guard route == self.route, ms.isFinite, ms >= 0 else { return }
        rtts.append((now, ms))
        if rtts.count > Self.maxSamples { rtts.removeFirst(rtts.count - Self.maxSamples) }
        prune(now)
    }

    /// An input or ack request failed on the way (`isNetworkFailure`).
    mutating func failed(at now: Double) {
        failures.append(now)
        if failures.count > Self.maxSamples { failures.removeFirst(failures.count - Self.maxSamples) }
        prune(now)
    }

    mutating func received(bytes: Int, at now: Double) {
        guard bytes > 0 else { return }
        if rxSince == nil { rxSince = now }
        if let last = rx.last, now - last.at < bucket, now >= last.at {
            rx[rx.count - 1].bytes += bytes
        } else {
            rx.append((now, bytes))
        }
        prune(now)
    }

    /// The report at `now`; nil when nothing is known.
    func report(at now: Double) -> ScreenNetReport? {
        let from = now - window
        let ms = rtts.filter { $0.at > from }.map(\.ms)
        var r = ScreenNetReport(route: route, iface: path?.iface, radio: path?.iface == .cellular ? path?.radio : nil,
                                expensive: path?.expensive, constrained: path?.constrained)
        if !ms.isEmpty {
            r.inputRttMs = .init(p50: ScreenPlayout<Void>.percentile(ms, 0.5), p90: ScreenPlayout<Void>.percentile(ms, 0.9),
                                 n: ms.count)
        }
        if let rxSince {
            let rxFrom = now - rxWindow
            let span = max(min(rxWindow, now - rxSince), 0.5)
            let bytes = rx.filter { $0.at > rxFrom }.reduce(0) { $0 + $1.bytes }
            r.rxKbps = Double(bytes) * 8 / 1000 / span
        }
        r.failures = failures.filter { $0 > from }.count
        return r == ScreenNetReport(failures: 0) ? nil : r
    }

    private mutating func prune(_ now: Double) {
        let from = now - window
        if let i = rtts.firstIndex(where: { $0.at > from }) { rtts.removeFirst(i) } else { rtts.removeAll() }
        if let i = failures.firstIndex(where: { $0 > from }) { failures.removeFirst(i) } else { failures.removeAll() }
        let rxFrom = now - rxWindow
        if let i = rx.firstIndex(where: { $0.at > rxFrom }) { rx.removeFirst(i) } else { rx.removeAll() }
    }

    /// A request that failed on the way counts as a failure: a timeout or another network error (`URLError`), or an
    /// answer saying the way to the computer is broken (`isWayDown`). An answer from the computer's server (4xx: 409 not the
    /// controller, 400, 404…; its own 503: no screen), another server error and a cancelled request don't.
    static func isNetworkFailure(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let e = error as? URLError { return e.code != .cancelled }
        if case let YoyoError.http(code, message) = error { return isWayDown(status: code, error: message) }
        return false
    }

    /// An ack's outcome as `isNetworkFailure` sees it: `status` nil = it failed with `error`; `body` its answer.
    static func isNetworkFailure(status: Int?, body: Data? = nil, error: Error?) -> Bool {
        if let error { return isNetworkFailure(error) }
        guard let status else { return false }
        let message = body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["error"] as? String
        return isWayDown(status: status, error: message)
    }

    /// What the backend counts as the way to the computer being down (`YoyoBackend.isUnreachable`; the page's session
    /// sets it): by default a proxy or CDN in front of it couldn't reach it (502, 504, 520–527, 530).
    private static let unreachable = YoyoLocked<@Sendable (Int, String?) -> Bool>({ status, _ in YoyoRoute.isUnreachable(status: status) })

    static func setUnreachable(_ classify: @escaping @Sendable (Int, String?) -> Bool) {
        unreachable.withLock { $0 = classify }
    }

    /// An answer that says the way to the computer is broken (not the computer answering).
    static func isWayDown(status: Int, error message: String?) -> Bool {
        unreachable.withLock { $0 }(status, message)
    }
}

/// The network path for `ScreenNetSampler.Path`: the interface it uses (wired, Wi-Fi, cellular, else other; nil when
/// there is no path), its flags, and on cellular the radio of the data service.
enum ScreenNetPath {
    static func from(_ path: NWPath, radio: @autoclosure () -> ScreenNetReport.Radio?) -> ScreenNetSampler.Path {
        guard path.status == .satisfied else { return .init() }
        let iface: ScreenNetReport.Interface
        if path.usesInterfaceType(.wiredEthernet) { iface = .wired }
        else if path.usesInterfaceType(.wifi) { iface = .wifi }
        else if path.usesInterfaceType(.cellular) { iface = .cellular }
        else { iface = .other }
        return .init(iface: iface, radio: iface == .cellular ? radio() : nil, expensive: path.isExpensive,
                     constrained: path.isConstrained)
    }

    /// The current radio of the data service (nil: none, or no cellular).
    static func currentRadio(_ info: CTTelephonyNetworkInfo) -> ScreenNetReport.Radio? {
        let techs = info.serviceCurrentRadioAccessTechnology ?? [:]
        let tech = info.dataServiceIdentifier.flatMap { techs[$0] } ?? techs.values.sorted().first
        return radio(tech)
    }

    /// A `CTRadioAccessTechnology…` value as the report's radio: NR / NR NSA = 5g, LTE, the 3G ones (WCDMA, HSPA,
    /// EV-DO, eHRPD) = 3g, anything else (GPRS, EDGE, 1x, a newer one) = other.
    static func radio(_ tech: String?) -> ScreenNetReport.Radio? {
        guard let tech, !tech.isEmpty else { return nil }
        switch tech {
        case CTRadioAccessTechnologyNR, CTRadioAccessTechnologyNRNSA: return .fiveG
        case CTRadioAccessTechnologyLTE: return .lte
        case CTRadioAccessTechnologyWCDMA, CTRadioAccessTechnologyHSDPA, CTRadioAccessTechnologyHSUPA,
             CTRadioAccessTechnologyCDMAEVDORev0, CTRadioAccessTechnologyCDMAEVDORevA, CTRadioAccessTechnologyCDMAEVDORevB,
             CTRadioAccessTechnologyeHRPD:
            return .threeG
        default: return .other
        }
    }
}
