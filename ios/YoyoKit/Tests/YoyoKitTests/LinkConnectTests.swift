import Foundation
import Testing
@testable import YoyoConnect
@testable import YoyoCore

/// The `.link` candidate in YoyoConnect (docs/LINK.md「集成」): ranked above everything, it starts alone and the other
/// ways start 250 ms later only when it isn't reached by then; one of them reached first is used meanwhile while the
/// link may still win within `linkGrace`; while on another way the link is tried every `retryInterval`; a link whose
/// session ends is left at once. With the fake network of `ConnectTests`.
@MainActor
@Suite("Link candidate")
struct LinkConnectTests {
    typealias Net = ConnectTests.Net

    nonisolated static let link = ConnectCandidate(id: "link", kind: .link, trust: .publicKey(ConnectTests.fp))
    nonisolated static let lan = ConnectTests.lan
    nonisolated static let pub = ConnectTests.pub
    nonisolated static let tunnel = ConnectTests.tunnel

    /// The test policy, with the link 60 ms ahead of the others and a short grace.
    nonisolated static var policy: ConnectPolicy {
        var p = ConnectTests.policy
        p.offsets[.link] = .milliseconds(-60)
        p.linkGrace = .milliseconds(700)
        return p
    }

    /// Links that end when the test says (`end(_:)`), for `ConnectSource.ended`.
    final class Ends: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
        private var ended: Set<String> = []

        func wait(_ link: String) async -> Bool {
            guard link.hasPrefix("L-link") else { return false }
            await withCheckedContinuation { cont in
                let done = lock.withLock { () -> Bool in
                    if ended.contains(link) { return true }
                    waiting[link, default: []].append(cont)
                    return false
                }
                if done { cont.resume() }
            }
            return true
        }

        func end(_ link: String) {
            let conts = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                ended.insert(link)
                return waiting.removeValue(forKey: link) ?? []
            }
            for c in conts { c.resume() }
        }
    }

    private func connector(_ net: Net, ends: Ends = Ends(), initial: ConnectCandidate = tunnel,
                           path: ConnectPath = ConnectTests.wifi, linkPossible: Bool = true) -> YoyoConnector<String> {
        let ways = ConnectWays(initial: initial, link: "L-\(initial.id)")
        let base = net.source
        let source = ConnectSource(candidates: base.candidates, probe: base.probe, release: base.release,
                                   ended: { await ends.wait($0) })
        let c = YoyoConnector(ways: ways, source: source, policy: Self.policy)
        c.watchesPath = false
        c.linkPossible = linkPossible
        c.pathUpdated(path)
        return c
    }

    nonisolated static func all(fresh: Bool = true) -> ConnectSupply {
        ConnectSupply(candidates: [link, lan, pub], fresh: fresh)
    }

    private func settle(_ until: () -> Bool) async {
        for _ in 0..<400 where !until() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func theLinkRanksAboveEverythingAndStartsAhead() {
        #expect(ConnectCandidate.Kind.link.rank < ConnectCandidate.Kind.lan.rank)
        #expect(!ConnectCandidate.Kind.link.isFallback)
        #expect(Self.link.label == "link" && Self.link.report == .direct && !Self.link.isLocalNetwork)
        #expect(Self.link.route(shortcut: true).isShortcut, "with a fallback the link is a shortcut like any direct way")
        // the default policy: the link at once, the others 250 ms later (relative to it), only when it is there
        let d = ConnectPolicy()
        let p = ConnectRace.plan([ConnectTests.relay, Self.pub, Self.lan, Self.link], offsets: d.offsets)
        #expect(p.map(\.candidate.id) == [Self.link.id, Self.lan.id, Self.pub.id, "relay"])
        #expect(p.map(\.delay) == [.zero, .milliseconds(250), .milliseconds(400), .milliseconds(550)])
        #expect(ConnectRace.plan([Self.lan, Self.pub], offsets: d.offsets).map(\.delay) == [.zero, .milliseconds(150)],
                "without a link nothing moves")
        #expect(d.linkGrace == .milliseconds(1500))
    }

    @Test func aQuickLinkWinsAloneTheOthersNeverStart() async {
        let net = Net { _ in Self.all() }
        net.reachable(Self.link, after: .milliseconds(10))
        net.reachable(Self.lan)
        let c = connector(net)
        c.activate()
        #expect(c.isDeciding, "a stream about to open waits for the link")
        await settle { c.current.id == "link" }
        #expect(c.current.id == "link" && c.current.isShortcut)
        #expect(net.probed == ["link"], "reached within its head start: the LAN and the public way never started")
        #expect(!c.isDeciding)
        c.leave()
    }

    @Test func aSlowLinkStillWinsWithinItsGrace() async {
        let net = Net { _ in Self.all() }
        net.reachable(Self.link, after: .milliseconds(250))
        net.reachable(Self.lan)
        let c = connector(net)
        var seen: [String] = []
        c.onChange = { if seen.last != c.current.id { seen.append(c.current.id) } }
        c.activate()
        await settle { c.current.id == Self.lan.id }
        #expect(c.current.id == Self.lan.id, "the LAN after the link's head start: used meanwhile")
        #expect(c.isDeciding, "the link may still win: a stream about to open waits for it")
        await settle { c.current.id == "link" }
        #expect(seen == ["tunnel", Self.lan.id, "link"], "then the link, reached within its grace")
        await settle { net.released.contains("L-\(Self.lan.id)-A") }
        #expect(net.released.contains("L-\(Self.lan.id)-A"), "the LAN left behind is let go")
        c.leave()
    }

    @Test func aLinkTooLateIsLetGoAndTriedAgainLater() async {
        let net = Net { _ in Self.all() }
        net.reachable(Self.link, after: .milliseconds(1100))
        net.reachable(Self.lan)
        let c = connector(net)
        c.activate()
        await settle { c.current.id == Self.lan.id }
        await settle { net.released.contains("L-link-") }
        #expect(c.current.id == Self.lan.id, "past its grace the link doesn't take over")
        #expect(net.released.contains("L-link-"), "its late session is released")
        // on the LAN, the link is tried again after retryInterval, and taken when it answers
        net.reachable(Self.link)
        await settle { c.current.id == "link" }
        #expect(c.current.id == "link")
        #expect(net.probed.filter { $0 == "link" }.count == 2)
        c.leave()
    }

    @Test func aFailedLinkLetsTheOthersStartAtOnce() async {
        let net = Net { _ in Self.all() }
        net.unreachable(Self.link)
        net.reachable(Self.lan)
        let c = connector(net)
        c.activate()
        await settle { c.current.id == Self.lan.id }
        #expect(c.current.id == Self.lan.id && net.probed.first == "link")
        c.leave()
    }

    @Test func withoutTheLinkNothingIsRacedFromTheBestOtherWay() async {
        let net = Net { _ in Self.all() }
        net.reachable(Self.link)
        let c = connector(net, initial: Self.lan, linkPossible: false)
        c.activate()
        c.streamWillOpen()
        #expect(!c.isDeciding && net.asked.isEmpty, "on the LAN with no link possible: nothing better to race for")
        // with the link possible, the LAN isn't the best any more
        let n2 = Net { _ in Self.all() }
        n2.reachable(Self.link)
        let d = connector(n2, initial: Self.lan)
        d.activate()
        await settle { d.current.id == "link" }
        #expect(d.current.id == "link" && n2.probed == ["link"], "only better candidates race: the link")
        c.leave()
        d.leave()
    }

    @Test func aLinkWhoseSessionEndsIsLeftAndRacedAgain() async {
        let net = Net { _ in Self.all() }
        let ends = Ends()
        net.reachable(Self.link)
        let c = connector(net, ends: ends)
        c.activate()
        await settle { c.current.id == "link" }
        // the session ends (idle timeout, the Mac quit): the tunnel at once, and every candidate again
        net.unreachable(Self.link)
        net.reachable(Self.lan)
        ends.end("L-link-")
        await settle { c.current.id != "link" }
        #expect(c.current.id == "tunnel" || c.current.id == Self.lan.id)
        await settle { c.current.id == Self.lan.id }
        #expect(c.current.id == Self.lan.id)
        #expect(net.released.contains("L-link-"), "the ended link is released")
        c.leave()
    }

    @Test func withoutAFallbackAnEndedLinkIsDialedAgain() async {
        let net = Net { _ in Self.all() }
        let ends = Ends()
        net.reachable(Self.link)
        let c = connector(net, ends: ends, initial: Self.lan)
        c.activate()
        await settle { c.current.id == "link" }
        // its session ends with nothing to fall back to: it stays the way, and a race may replace it with anything —
        // here a new session of the same link
        net.answer("link", .reached("L-link-2"))
        ends.end("L-link-")
        await settle { c.ways.link(for: c.current) == "L-link-2" }
        #expect(c.current.id == "link" && c.ways.link(for: c.current) == "L-link-2", "a new session on the same way")
        await settle { net.released.contains("L-link-") }
        #expect(net.released.contains("L-link-"), "the ended one is released")
        c.leave()
    }

    @Test func aNetworkChangeDoesNotLeaveTheLink() async {
        let net = Net { _ in Self.all() }
        net.reachable(Self.link)
        let c = connector(net)
        c.activate()
        await settle { c.current.id == "link" }
        // Wi-Fi → 5G: the link moves its own paths; only offline loses it
        c.pathUpdated(ConnectTests.cellular)
        #expect(c.current.id == "link")
        c.pathUpdated(ConnectTests.offline)
        #expect(c.current.id == "tunnel")
        c.leave()
    }

    @Test func withoutAFallbackANetworkChangeDialsNoSecondSession() async {
        let net = Net { _ in Self.all() }
        net.reachable(Self.link)
        let c = connector(net, initial: Self.lan)
        c.activate()
        c.pathUpdated(ConnectTests.wifi)  // the monitor's first answer
        await settle { c.current.id == "link" }
        let dialed = net.probed.filter { $0 == "link" }.count
        // 5G → Wi-Fi → 5G, online all along: the session moves its own paths, nothing is raced
        c.pathUpdated(ConnectTests.cellular)
        c.pathUpdated(ConnectTests.wifi)
        c.pathUpdated(ConnectTests.cellular)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(net.probed.filter { $0 == "link" }.count == dialed, "no second session")
        #expect(c.ways.link(for: c.current) == "L-link-" && !net.released.contains("L-link-"), "the same session")
        // back online after being offline: the link is raced again
        c.pathUpdated(ConnectTests.offline)
        c.pathUpdated(ConnectTests.cellular)
        await settle { net.probed.filter { $0 == "link" }.count > dialed }
        #expect(net.probed.filter { $0 == "link" }.count > dialed, "raced on coming back")
        c.leave()
    }
}
