import Foundation
import Security
import Testing
@testable import YoyoConnect
@testable import YoyoCore

/// YoyoConnect (ios/README.md「YoyoConnect」): candidates, pins, the happy-eyeballs race, and `YoyoConnector` moving
/// between a fallback and shortcuts — with the network replaced by a fake whose answers and delays the tests set.
@MainActor
@Suite("Connect")
struct ConnectTests {
    // MARK: A fake network

    /// Candidates' answers (by id) and delays, the supplies the source gives, and what was asked, probed and released.
    final class Net: @unchecked Sendable {
        private let lock = NSLock()
        private var reach: [String: ConnectProbe<String>] = [:]
        private var delay: [String: Duration] = [:]
        private var _asked: [ConnectRefresh] = []
        private var _probed: [String] = []
        private var _released: [String] = []
        private var _supply: @Sendable (ConnectRefresh) throws -> ConnectSupply?

        init(_ supply: @escaping @Sendable (ConnectRefresh) throws -> ConnectSupply?) { _supply = supply }

        func answer(_ id: String, _ probe: ConnectProbe<String>, after: Duration = .zero) {
            lock.withLock {
                reach[id] = probe
                delay[id] = after
            }
        }

        func reachable(_ c: ConnectCandidate, after: Duration = .zero) { answer(c.id, .reached("L-\(c.id)-\(c.credential ?? "")"), after: after) }
        func unreachable(_ c: ConnectCandidate) { answer(c.id, .unreachable) }

        func supply(_ s: @escaping @Sendable (ConnectRefresh) throws -> ConnectSupply?) { lock.withLock { _supply = s } }

        var asked: [ConnectRefresh] { lock.withLock { _asked } }
        var probed: [String] { lock.withLock { _probed } }
        var released: [String] { lock.withLock { _released } }

        var source: ConnectSource<String> {
            ConnectSource(
                candidates: { why in
                    let s = self.lock.withLock {
                        self._asked.append(why)
                        return self._supply
                    }
                    return try s(why)
                },
                probe: { c in
                    let (r, d) = self.lock.withLock {
                        self._probed.append(c.id)
                        return (self.reach[c.id] ?? .unreachable, self.delay[c.id] ?? .zero)
                    }
                    if d > .zero { try? await Task.sleep(for: d) }
                    if Task.isCancelled, case .reached(let link, _) = r {
                        // a real probe would have stopped; this one hands back what it got, as a late winner
                        return .reached(link)
                    }
                    return r
                },
                release: { link in self.lock.withLock { self._released.append(link) } })
        }
    }

    nonisolated static let fp = "sha256:" + String(repeating: "ab", count: 32)
    nonisolated static let lan = ConnectCandidate(kind: .lan, host: "192.168.50.10", port: 47821, trust: .certificate(fp), credential: "A")
    nonisolated static let pub = ConnectCandidate(kind: .direct, host: "93.184.216.34", port: 47821, trust: .certificate(fp), credential: "A")
    nonisolated static let tunnel = ConnectCandidate(id: "tunnel", kind: .tunnel)
    nonisolated static let relay = ConnectCandidate(id: "relay", kind: .relay, host: "127.0.0.1")

    nonisolated static let wifi = ConnectPath(online: true, localInterfaces: ["en0"])
    nonisolated static let cellular = ConnectPath(online: true, localInterfaces: [])
    nonisolated static let offline = ConnectPath(online: false, localInterfaces: ["en0"])

    nonisolated static var policy: ConnectPolicy {
        var p = ConnectPolicy()
        p.offsets = [.lan: .zero, .direct: .milliseconds(40), .relay: .milliseconds(80), .tunnel: .milliseconds(80)]
        p.retryInterval = .milliseconds(400)
        p.pathSettle = .zero
        p.keepRetired = .milliseconds(50)
        p.renewBefore = .milliseconds(300)
        return p
    }

    private func connector(_ net: Net, initial: ConnectCandidate = tunnel, fallbacks: [ConnectCandidate] = [],
                           path: ConnectPath = wifi) -> YoyoConnector<String> {
        let ways = ConnectWays(initial: initial, link: "L-\(initial.id)", fallbacks: fallbacks)
        let c = YoyoConnector(ways: ways, source: net.source, policy: Self.policy)
        c.watchesPath = false
        c.pathUpdated(path)
        return c
    }

    nonisolated private static func both(fresh: Bool = true, credential: String = "A", expires: Date? = nil) -> ConnectSupply {
        var l = lan
        var p = pub
        l.credential = credential
        p.credential = credential
        return ConnectSupply(candidates: [l, p], fresh: fresh, expires: expires)
    }

    private func settle(_ until: () -> Bool) async {
        for _ in 0..<400 where !until() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    // MARK: Candidates and pins

    @Test func candidatesAndTheirRoutes() {
        #expect(Self.lan.id == "lan:192.168.50.10:47821" && Self.lan.label == "LAN" && Self.lan.isLocalNetwork)
        #expect(Self.lan.baseURL?.absoluteString == "https://192.168.50.10:47821")
        #expect(ConnectCandidate(kind: .direct, host: "2001:db8::1", port: 1).baseURL?.absoluteString == "https://[2001:db8::1]:1")
        #expect(ConnectCandidate(kind: .lan, host: "10.0.0.1", port: 0).baseURL == nil)
        let r = Self.pub.route(shortcut: true)
        #expect(r.isShortcut && r.isDirect && !r.isLocalNetwork && r.report == .direct && r.label == "direct")
        let t = Self.tunnel.route(shortcut: true)
        #expect(!t.isShortcut && !t.isDirect && t.report == .tunnel, "a fallback is never a shortcut")
        #expect(ConnectCandidate.Kind.allCases.map(\.rank) == [0, 1, 2, 2, -1])
        var renewed = Self.lan
        renewed.credential = "B"
        #expect(renewed != Self.lan && renewed.id == Self.lan.id, "another credential: the same way, another candidate")
        // the ways: a fallback makes every other way a shortcut
        #expect(ConnectWays(initial: Self.tunnel, link: "t").hasFallback)
        #expect(!ConnectWays(initial: Self.lan, link: "l").current.isShortcut, "nothing to fall back to")
        #expect(ConnectWays(initial: Self.lan, link: "l", fallbacks: [Self.relay, Self.pub]).fallbacks == [Self.relay], "fallback kinds only")
    }

    /// The certificate of ScreenKitTests: its key's and its DER's fingerprints.
    @Test func pinsCheckTheKeyOrTheWholeCertificate() throws {
        let der = try #require(Data(base64Encoded: ScreenKitTests.certificate))
        let cert = try #require(SecCertificateCreateWithData(nil, der as CFData))
        var t: SecTrust?
        #expect(SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &t) == errSecSuccess)
        let trust = try #require(t)
        #expect(ConnectTrust.publicKey(ScreenKitTests.keyFingerprint).evaluate(trust))
        #expect(!ConnectTrust.publicKey(ScreenKitTests.certFingerprint).evaluate(trust))
        #expect(ConnectTrust.certificate(ScreenKitTests.certFingerprint).evaluate(trust))
        #expect(ConnectTrust.certificate(ScreenKitTests.certFingerprint.uppercased().replacingOccurrences(of: "SHA256:", with: "")).evaluate(trust))
        #expect(!ConnectTrust.certificate(ScreenKitTests.keyFingerprint).evaluate(trust))
        #expect(!ConnectTrust.system.evaluate(trust), "self-signed: the system doesn't vouch for it")
        #expect(ConnectPin.matches(der: Data("abc".utf8), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
        guard case .custom(let check) = ConnectTrust.certificate(ScreenKitTests.certFingerprint).yoyoTrust(hosts: ["10.0.0.2"]) else {
            Issue.record("a pin is custom")
            return
        }
        #expect(check(trust, "10.0.0.2"))
        #expect(!check(trust, "10.0.0.3"), "only at its host")
        guard case .system = ConnectTrust.system.yoyoTrust(hosts: nil) else { Issue.record("system stays system"); return }
    }

    @Test func failuresAreSortedByWhoseFaultTheyAre() {
        #expect(ConnectFailure.classify(YoyoError.http(401, nil)) == .unauthorized)
        #expect(ConnectFailure.classify(YoyoError.http(409, "take control first")) == .answer)
        #expect(ConnectFailure.classify(YoyoError.http(404, nil)) == .answer)
        #expect(ConnectFailure.classify(YoyoError.http(503, nil)) == .link)
        #expect(ConnectFailure.classify(YoyoError.unauthorized) == .answer, "the host's credential: passed on")
        #expect(ConnectFailure.classify(ScreenControlledElsewhere(controllerDevice: ScreenControlDevice(id: "x"))) == .answer)
        #expect(ConnectFailure.classify(URLError(.timedOut)) == .link)
        #expect(ConnectFailure.classify(URLError(.serverCertificateUntrusted)) == .link)
    }

    // MARK: The race

    @Test func theLanStartsFirstThePublicOneAMomentLaterTheFallbackLast() {
        let p = ConnectRace.plan([Self.tunnel, Self.pub, Self.lan], offsets: Self.policy.offsets)
        #expect(p.map(\.candidate.id) == [Self.lan.id, Self.pub.id, "tunnel"])
        #expect(p.map(\.delay) == [.zero, .milliseconds(40), .milliseconds(80)])
        // 5G: no LAN candidate, the public one at once
        #expect(ConnectRace.plan([Self.pub, Self.tunnel], offsets: Self.policy.offsets).map(\.delay) == [.zero, .milliseconds(40)])
        #expect(ConnectPolicy().offsets[.direct] == .milliseconds(150) && ConnectPolicy().offsets[.relay] == .milliseconds(300))
    }

    @Test func theFirstReachedWinsAndALateOneIsReleased() async {
        let net = Net { _ in nil }
        net.reachable(Self.lan, after: .milliseconds(150))
        net.reachable(Self.pub)
        let out = await ConnectRace.first([Self.lan, Self.pub], offsets: Self.policy.offsets, probe: net.source.probe,
                                          release: net.source.release)
        guard case .reached(let link, let c) = out else { Issue.record("nothing reached"); return }
        #expect(c == Self.pub && link == "L-\(Self.pub.id)-A", "the LAN was slow: the public one answered first")
        await settle { !net.released.isEmpty }
        #expect(net.released == ["L-\(Self.lan.id)-A"], "the LAN's answer came too late: released")
        // a 401 and nothing reached: unauthorized
        let n2 = Net { _ in nil }
        n2.answer(Self.lan.id, .unauthorized)
        guard case .unauthorized = await ConnectRace.first([Self.lan, Self.pub], offsets: Self.policy.offsets, probe: n2.source.probe,
                                                           release: n2.source.release) else { Issue.record("expected unauthorized"); return }
        // one after another: the second only when the first failed
        let n3 = Net { _ in nil }
        n3.reachable(Self.pub)
        guard case .reached(_, let seq) = await ConnectRace.first([Self.pub, Self.lan], offsets: Self.policy.offsets, sequential: true,
                                                                  probe: n3.source.probe, release: n3.source.release) else { return }
        #expect(seq == Self.pub && n3.probed == [Self.lan.id, Self.pub.id])
    }

    // MARK: The connector

    @Test func on5GOnlyThePublicCandidateIsTriedAndUsed() async {
        let net = Net { _ in Self.both() }
        net.reachable(Self.lan)
        net.reachable(Self.pub)
        let c = connector(net, path: Self.cellular)
        c.newVisit()
        c.activate()
        #expect(c.isDeciding, "a stream about to open waits for the race")
        await settle { c.current.id != "tunnel" }
        #expect(c.current.id == Self.pub.id && c.current.isShortcut && !c.current.isLocalNetwork && c.current.report == .direct)
        #expect(net.probed == [Self.pub.id], "no Wi-Fi: the LAN isn't tried")
        #expect(!c.isDeciding)
        #expect(c.ways.link(for: c.current) == "L-\(Self.pub.id)-A")
        c.leave()
        #expect(c.current.id == "tunnel", "left: back on the fallback, chosen afresh next time")
    }

    @Test func allFailingStaysOnTheLastResortAndTriesAgainLater() async {
        let net = Net { _ in Self.both() }
        let c = connector(net)
        c.activate()
        await settle { !c.isDeciding }
        #expect(c.current.id == "tunnel")
        #expect(Set(net.probed) == [Self.lan.id, Self.pub.id])
        c.streamWillOpen()
        #expect(!c.isDeciding, "no race for retryInterval")
        net.reachable(Self.lan)
        await settle { c.current.id != "tunnel" }
        #expect(c.current.id == Self.lan.id, "tried again on its own after retryInterval")
        c.leave()
    }

    @Test func wifiAssistStillTriesTheLanFirst() async {
        // the default path went to cellular (weak Wi-Fi) but the Wi-Fi interface is there
        let assisted = ConnectPath(online: true, localInterfaces: ["en0"])
        #expect(assisted.hasLocal && assisted.signature == Self.wifi.signature)
        #expect(Self.cellular.signature != Self.wifi.signature && Self.offline.signature != Self.cellular.signature)
        #expect(!Self.offline.hasLocal && Self.offline.localInterfaces.isEmpty)
        let net = Net { _ in Self.both() }
        net.reachable(Self.lan, after: .milliseconds(10))
        net.reachable(Self.pub)
        let c = connector(net, path: assisted)
        c.activate()
        await settle { c.current.id != "tunnel" }
        #expect(c.current.id == Self.lan.id && c.current.isLocalNetwork, "the LAN started 40 ms ahead and won")
        c.leave()
    }

    @Test func aRetryPromotesToABetterWay() async {
        let net = Net { _ in Self.both() }
        net.reachable(Self.pub)
        let c = connector(net)
        c.activate()
        await settle { c.current.id != "tunnel" }
        #expect(c.current.id == Self.pub.id, "the LAN didn't answer: the public way")
        net.reachable(Self.lan)
        await settle { c.current.id == Self.lan.id }
        #expect(c.current.id == Self.lan.id, "every retryInterval the better LAN is tried, and taken")
        await settle { net.released.contains("L-\(Self.pub.id)-A") }
        #expect(net.released.contains("L-\(Self.pub.id)-A"), "the public way left behind is let go after keepRetired")
        c.leave()
    }

    @Test func a401GetsAFreshCredentialOnceThenFallsBack() async {
        let net = Net { why in Self.both(credential: why == .unauthorized ? "B" : "A") }
        net.reachable(Self.lan)
        let c = connector(net)
        c.activate()
        await settle { c.current.id == Self.lan.id }
        net.answer(Self.lan.id, .reached("L-fresh"))
        c.streamFailed(on: c.current, unauthorized: true)
        #expect(c.current.id == "tunnel", "the tunnel meanwhile")
        await settle { c.current.id == Self.lan.id }
        #expect(net.asked.contains(.unauthorized))
        #expect(c.ways.currentCandidate.credential == "B" && c.ways.link(for: c.current) == "L-fresh")
        // a second 401: a failure (the tunnel, no race for retryInterval)
        c.ackAnswered(on: c.current, status: 401)
        #expect(c.current.id == "tunnel")
        c.streamWillOpen()
        #expect(!c.isDeciding)
        c.leave()
        // once an ack gets through, a later 401 may get a fresh credential again
        let n2 = Net { why in Self.both(credential: why == .unauthorized ? "B" : "A") }
        n2.reachable(Self.lan)
        let d = connector(n2)
        d.activate()
        await settle { d.current.id == Self.lan.id }
        d.ackAnswered(on: d.current, status: 401)
        await settle { d.ways.currentCandidate.credential == "B" }
        d.ackAnswered(on: d.current, status: 200)
        d.ackAnswered(on: d.current, status: 401)
        #expect(d.current.id == "tunnel")
        await settle { d.current.id == Self.lan.id }
        #expect(d.current.id == Self.lan.id, "fresh again, not a failure")
        d.leave()
    }

    @Test func aNetworkChangeChoosesAgain() async {
        let net = Net { _ in Self.both() }
        net.reachable(Self.lan)
        net.reachable(Self.pub)
        let c = connector(net)
        var seen: [String] = []
        c.onChange = { if seen.last != c.current.id { seen.append(c.current.id) } }
        c.activate()
        await settle { c.current.id == Self.lan.id }
        // off the Wi-Fi: the LAN is gone at once, the public way found
        c.pathUpdated(Self.cellular)
        #expect(c.current.id == "tunnel")
        #expect(c.isDeciding, "the moved stream waits for the race")
        await settle { c.current.id == Self.pub.id }
        #expect(c.current.id == Self.pub.id)
        // back on the Wi-Fi: a better way from where it is (the public way isn't left meanwhile)
        seen = [c.current.id]
        c.pathUpdated(Self.wifi)
        #expect(c.current.id == Self.pub.id)
        await settle { c.current.id == Self.lan.id }
        #expect(seen == [Self.pub.id, Self.lan.id], "straight from the public way to the LAN")
        // offline: back to the fallback, nothing tried
        c.pathUpdated(Self.offline)
        #expect(c.current.id == "tunnel" && !c.isDeciding)
        c.leave()
    }

    @Test func aLateAnswerOfAnOldPathIsIgnored() async {
        let net = Net { _ in Self.both() }
        net.reachable(Self.lan, after: .milliseconds(100))
        let c = connector(net)
        c.activate()
        await settle { net.probed.contains(Self.lan.id) }
        c.pathUpdated(Self.cellular)
        await settle { !c.isDeciding }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(c.current.id == "tunnel", "the LAN answer belonged to the Wi-Fi")
        await settle { net.released.contains("L-\(Self.lan.id)-A") }
        #expect(net.released.contains("L-\(Self.lan.id)-A"))
        c.leave()
    }

    @Test func aHeldSupplyThatFailsIsAskedAnewOnce() async {
        let net = Net { why in why == .held ? Self.both(fresh: false, credential: "old") : Self.both(credential: "new") }
        net.unreachable(Self.lan)
        let c = connector(net)
        // the held one's way is gone (the server restarted: a new port); the fresh one is reached
        net.supply { why in
            if why == .held { return ConnectSupply(candidates: [ConnectCandidate(kind: .lan, host: "192.168.50.10", port: 50001)], fresh: false) }
            return Self.both(credential: "new")
        }
        net.reachable(Self.lan)
        c.activate()
        await settle { c.current.id != "tunnel" }
        #expect(net.asked == [.held, .stale])
        #expect(c.current.id == Self.lan.id && c.ways.currentCandidate.credential == "new")
        c.leave()
        // a fresh supply failing isn't asked again at once
        let n2 = Net { _ in Self.both() }
        let d = connector(n2)
        d.activate()
        await settle { !d.isDeciding }
        #expect(n2.asked == [.held])
        d.leave()
    }

    @Test func aHeldSupplyAboutToExpireIsAskedAnew() async {
        let net = Net { why in why == .held ? Self.both(fresh: false, expires: Date().addingTimeInterval(0.1)) : Self.both(credential: "new") }
        net.reachable(Self.lan)
        let c = connector(net)
        c.activate()
        await settle { c.current.id != "tunnel" }
        #expect(net.asked == [.held, .stale])
        #expect(!net.probed.isEmpty && c.ways.currentCandidate.credential == "new", "the held one wasn't raced")
        c.leave()
    }

    @Test func noOtherWayTurnsRacesOffForTheVisit() async {
        let net = Net { _ in nil }
        let c = connector(net)
        c.activate()
        await settle { !c.isDeciding }
        #expect(!c.supported && c.current.id == "tunnel")
        c.streamWillOpen()
        try? await Task.sleep(for: .milliseconds(450))
        #expect(net.asked == [.held], "not asked again this visit")
        c.leave()
        c.newVisit()
        c.activate()
        await settle { net.asked.count == 2 }
        #expect(net.asked.count == 2, "a new visit asks again")
        c.leave()
    }

    @Test func aSourceThatCantAnswerIsAskedAgainLater() async {
        struct Down: Error {}
        let net = Net { _ in throw Down() }
        let c = connector(net)
        c.activate()
        await settle { !c.isDeciding }
        #expect(c.supported && net.asked == [.held])
        net.supply { _ in Self.both() }
        net.reachable(Self.lan)
        await settle { c.current.id == Self.lan.id }
        #expect(c.current.id == Self.lan.id, "retryInterval on")
        c.leave()
    }

    @Test func threeAcksLostInARowFallBack() async {
        let net = Net { _ in Self.both() }
        net.reachable(Self.lan)
        let c = connector(net)
        c.activate()
        await settle { c.current.id == Self.lan.id }
        let lan = c.current
        c.ackAnswered(on: lan, status: nil)
        c.ackAnswered(on: lan, status: nil)
        c.ackAnswered(on: lan, status: 404)
        c.ackAnswered(on: lan, status: nil)
        c.ackAnswered(on: lan, status: 502)
        #expect(c.current == lan, "not in a row (a 404 is the computer's answer)")
        c.ackAnswered(on: lan, status: nil)
        #expect(c.current.id == "tunnel", "the third in a row")
        #expect(c.ways.link(for: lan) != nil, "its link kept a moment for a last request")
        await settle { c.ways.link(for: lan) == nil }
        #expect(net.released.contains("L-\(Self.lan.id)-A"))
        c.ackAnswered(on: c.current, status: nil)
        c.leave()
    }

    @Test func aRenewalKeepsTheWayOrChoosesAgain() async {
        let net = Net { _ in Self.both(expires: Date().addingTimeInterval(0.5)) }
        net.reachable(Self.lan)
        let c = connector(net)
        c.activate()
        await settle { c.current.id == Self.lan.id }
        // renewed renewBefore (300 ms) before it expires: the same ticket, a fresh expiry
        await settle { net.asked.contains(.renew) }
        #expect(c.current.id == Self.lan.id)
        // the next renewal lists another port: back to the tunnel, then the new one
        let moved = ConnectCandidate(kind: .lan, host: "192.168.50.10", port: 50999, credential: "A")
        net.supply { _ in ConnectSupply(candidates: [moved], fresh: true, expires: Date().addingTimeInterval(60)) }
        net.reachable(moved)
        await settle { c.current.id == moved.id }
        #expect(c.current.id == moved.id)
        c.leave()
    }

    @Test func shortcutsOffLeaveAndStopTrying() async {
        let net = Net { _ in Self.both() }
        net.reachable(Self.lan)
        let c = connector(net)
        c.activate()
        await settle { c.current.id == Self.lan.id }
        c.setShortcutsAllowed(false)
        #expect(c.current.id == "tunnel")
        c.streamWillOpen()
        #expect(!c.isDeciding)
        c.setShortcutsAllowed(true)
        await settle { c.current.id == Self.lan.id }
        #expect(c.current.id == Self.lan.id)
        c.leave()
    }

    @Test func aFailedRequestGoesThroughTheFallbackAnAnswerDoesNot() async {
        let net = Net { _ in Self.both() }
        net.reachable(Self.lan)
        let c = connector(net)
        c.activate()
        await settle { c.current.id == Self.lan.id }
        let lan = c.current
        #expect(await c.fallback(from: lan, after: YoyoError.http(409, nil)) == nil, "the computer's answer is passed on")
        #expect(c.current == lan)
        #expect(await c.fallback(from: lan, after: URLError(.timedOut))?.id == "tunnel")
        #expect(c.current.id == "tunnel")
        #expect(await c.fallback(from: c.current, after: URLError(.timedOut)) == nil, "the fallback falls back no further")
        c.leave()
    }

    @Test func withoutAFallbackHeldItIsReachedFirst() async {
        let net = Net { _ in ConnectSupply(candidates: [Self.lan], fresh: true) }
        net.reachable(Self.relay)
        let c = connector(net, initial: Self.lan, fallbacks: [Self.relay])
        c.activate()
        #expect(c.current.isShortcut && !c.isDeciding, "on the LAN nothing better to look for")
        let next = await c.fallback(from: c.current, after: URLError(.networkConnectionLost))
        #expect(next?.id == "relay")
        await settle { c.current.id == "relay" }
        #expect(c.current.id == "relay" && !c.current.isShortcut)
        c.close()
        #expect(Set(net.released).isSuperset(of: ["L-relay-"]), "the relay's link goes with the page")
    }

    @Test func withoutAnyFallbackAWayIsntAShortcut() async {
        let net = Net { _ in ConnectSupply(candidates: [Self.lan], fresh: true) }
        let c = connector(net, initial: Self.lan)
        c.activate()
        #expect(!c.current.isShortcut)
        c.streamFailed(on: c.current, unauthorized: false)
        #expect(c.current.id == Self.lan.id, "the page retries on it")
        #expect(await c.fallback(from: c.current, after: URLError(.timedOut)) == nil)
        // a network change looks for it again (the same kind)
        net.reachable(ConnectCandidate(kind: .lan, host: "192.168.50.10", port: 47821, trust: .certificate(Self.fp), credential: "A"))
        c.pathUpdated(Self.cellular)
        c.pathUpdated(Self.wifi)
        await settle { net.probed.contains(Self.lan.id) }
        #expect(net.probed.contains(Self.lan.id))
        c.leave()
    }
}
