import Foundation
import Testing
@testable import YoyoConnect
@testable import YoyoCore
@testable import YoyoDirect

/// Reaching a Mac on the phone (docs/REMOTE.md): the pairing code, the record kept of a Mac, where its binding is
/// asked for, the link candidate, and finding the Mac at all (YoyoClient.locate) with the network replaced by closures.
@MainActor
struct DirectConnectTests {
    private let binding = ConnectLinkBinding(id: String(repeating: "cd", count: 32), key: "a2V5", sig: "c2ln", port: 47820)
    private var mac: YoyoMac {
        YoyoMac(id: "SERVERID123456789", name: "Mac", addresses: ["192.168.50.151"],
                fingerprint: "sha256:" + String(repeating: "ab", count: 32), token: "t", link: binding)
    }

    @Test func thePairingCodeCarriesTheBinding() throws {
        let url = URL(string: "yoyocontrol://pair?v=2&id=SERVERID123456789&n=Mac&fp=sha256:ab&l=cdcd&lk=a2V5-_w&ls=c2ln&lp=47820&a=192.168.50.151,bad&c=CODE")!
        let invite = try #require(YoyoInvite(url: url))
        #expect(invite.id == "SERVERID123456789")
        #expect(invite.addresses == ["192.168.50.151"])
        #expect(invite.code == "CODE")
        #expect(invite.link == ConnectLinkBinding(id: "cdcd", key: "a2V5+/w=", sig: "c2ln", port: 47820))
        // a code without the binding, or an older one (v=1: the TLS listener's), is not one
        #expect(YoyoInvite(url: URL(string: "yoyocontrol://pair?v=2&id=SERVERID123456789&n=Mac&fp=sha256:ab&c=CODE")!) == nil)
        #expect(YoyoInvite(url: URL(string: "yoyocontrol://pair?v=1&id=SERVERID123456789&n=Mac&a=192.168.50.151&p=47820&fp=sha256:ab&l=cdcd&lk=a2V5&ls=c2ln&c=CODE")!) == nil)
    }

    @Test func theLinksHintsAreTheLocalAddressesOnItsPort() {
        #expect(mac.linkHints == ["192.168.50.151:47820"])
        var none = mac
        none.link = nil
        #expect(none.linkHints.isEmpty)
    }

    @Test func aRecordFromBeforeStillDecodes() throws {
        // the TLS listener's port and candidates are left out; its binding is kept
        let old = #"{"id":"SERVERID123456789","name":"Mac","addresses":["192.168.50.151"],"port":47820,"fingerprint":"sha256:ab","token":"t","endpoints":[{"kind":"public","host":"93.184.216.34","port":47820}]}"#
        let m = try JSONDecoder().decode(YoyoMac.self, from: Data(old.utf8))
        #expect(m.addresses == ["192.168.50.151"])
        #expect(m.link == nil)
        let again = try JSONDecoder().decode(YoyoMac.self, from: JSONEncoder().encode(mac))
        #expect(again == mac)
    }

    @Test func theSignalingServersAddress() {
        let fp = "sha256:" + String(repeating: "ab", count: 32)
        let room = try? #require(SignalLookup.room(fp))
        #expect(room == String(repeating: "ab", count: 32))
        #expect(SignalLookup.room("nope") == nil)
        #expect(SignalLookup.candidatesURL(URL(string: "https://signal.example.com")!, "ab")?.absoluteString == "https://signal.example.com/v1/candidates/ab")
        #expect(YoyoClient.signalURL == nil, "none built in")
        #expect(SignalLookup.candidatesURL(URL(string: "ws://127.0.0.1:8790")!, "ab")?.absoluteString == "http://127.0.0.1:8790/v1/candidates/ab")
    }

    @Test func theStatusUpdatesTheRecord() {
        var other = binding
        other.direct = ["93.184.216.34:47820"]
        let status: [String: Any] = ["platform": "linux", "link": ["id": other.id, "key": other.key, "sig": other.sig, "port": 47820,
                                                                  "direct": ["93.184.216.34:47820"]]]
        let m = YoyoClient.updated(mac, status: status)
        #expect(m.platform == "linux")
        #expect(m.link?.direct == ["93.184.216.34:47820"])
        #expect(YoyoClient.updated(mac, status: [:]) == mac, "nothing said: as it was")
    }

    @Test func theLinkCandidate() {
        let c = DirectConnect.link(mac)
        #expect(c.kind == .link && c.id == DirectConnect.linkId)
        #expect(!c.isLocalNetwork && c.report == .direct)
        let lan = DirectConnect.link(mac, onLan: true)
        #expect(lan.isLocalNetwork && lan.report == .lan)
    }

    @Test func pro() {
        #expect(RemoteAccess.allows(onLocalNetwork: true, pro: false))
        #expect(!RemoteAccess.allows(onLocalNetwork: false, pro: false))
        #expect(RemoteAccess.allows(onLocalNetwork: false, pro: true))
    }

    @Test func locateSaysWhyItGotNowhere() async {
        func failure(_ dialed: YoyoClient.Dialed, pro: Bool = true) async -> YoyoClient.Failure? {
            let probes = DirectProbes(link: { m, p in
                #expect(p == pro)
                #expect(m.token == "t")
                return dialed
            })
            var noBinding = mac
            noBinding.link = nil  // not asked again at the signaling server: the record has none to compare
            do {
                _ = try await YoyoClient.locate(noBinding, pro: pro, probes: probes)
                return nil
            } catch {
                return error as? YoyoClient.Failure
            }
        }
        #expect(await failure(.unauthorized) == .unpaired)
        #expect(await failure(.needsPro, pro: false) == .needsPro("Mac"))
        #expect(await failure(.unreachable) == .unreachable("Mac"))
    }

    @Test func theRoutingsProbe() async {
        func probed(_ dialed: YoyoClient.Dialed) async -> String {
            switch await DirectConnect.probe(mac: mac, pro: false, probes: DirectProbes(link: { _, _ in dialed })) {
            case .reached: "reached"
            case .unauthorized: "unauthorized"
            case .unreachable: "unreachable"
            }
        }
        #expect(await probed(.unauthorized) == "unauthorized")
        #expect(await probed(.needsPro) == "unreachable", "off the local network without Pro: tried again later")
        #expect(await probed(.unreachable) == "unreachable")
    }
}
