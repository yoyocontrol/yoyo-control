import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { addressKind, dialRtc, ipBytes, MAX_OFFER_CANDIDATES, offerSdp } from "../src/index.js";
import { FakePeerConnection, Identity, ScriptedServer } from "./fake.js";

const WASM = readFileSync(fileURLToPath(new URL("../src/wasm/uu_link_wasm_bg.wasm", import.meta.url)));

test("addresses as the gateway sees them (IPv4-mapped / compatible / NAT64 IPv6 as their IPv4 address)", () => {
  const kinds: [string, ReturnType<typeof addressKind>][] = [
    ["8.8.8.8", "public"],
    ["203.0.113.5", "public"],
    ["10.1.2.3", "private"],
    ["172.16.0.1", "private"],
    ["172.31.255.255", "private"],
    ["172.32.0.1", "public"],
    ["192.168.1.20", "private"],
    ["100.64.0.1", "private"],
    ["100.127.255.255", "private"],
    ["100.128.0.1", "public"],
    ["127.0.0.1", "loopback"],
    ["169.254.10.1", "never"],
    ["0.0.0.0", "never"],
    ["224.0.0.251", "never"],
    ["255.255.255.255", "never"],
    ["::1", "loopback"],
    ["[::1]", "loopback"],
    ["::", "never"],
    ["fe80::1", "never"],
    ["fe80::1%en0", "never"],
    ["ff02::fb", "never"],
    ["fc00::1", "private"],
    ["fd7a:115c:a1e0::1", "private"],
    ["2001:db8::1", "public"],
    ["2a00:1450:4001:82b::200e", "public"],
    ["::ffff:192.168.1.2", "private"],
    ["::ffff:c0a8:0102", "private"],
    ["::FFFF:8.8.8.8", "public"],
    ["::ffff:127.0.0.1", "loopback"],
    ["::ffff:100.64.1.1", "private"],
    ["::10.0.0.1", "private"],
    ["64:ff9b::10.0.0.1", "private"],
    ["64:ff9b::8.8.8.8", "public"],
    ["fec0::1", "private"],
    ["feff:1::2", "private"],
    ["64:ff9b:1::a00:1", "private"],
    ["64:ff9b:1:ffff::8.8.8.8", "private"],
    ["2002:c0a8:0102::1", "private"],
    ["2002:7f00:1::1", "never"],
    ["2002:a9fe:0101::1", "never"],
    ["2002:0808:0808::1", "public"],
    ["64:ff9b::192.168.1.2", "private"],
    ["64:ff9b::127.0.0.1", "never"],
    ["::127.0.0.1", "loopback"],
    ["c0a8b2c3-1234-5678.local", null],
    ["1.2.3", null],
    ["256.1.1.1", null],
    ["1::2::3", null],
    ["12345::", null],
    ["1:2:3:4:5:6:7:8:9", null],
  ];
  for (const [ip, kind] of kinds) assert.equal(addressKind(ip), kind, ip);
  assert.deepEqual([...ipBytes("::ffff:1.2.3.4")!], [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, 1, 2, 3, 4]);
  assert.deepEqual([...ipBytes("2001:db8::")!].slice(0, 4), [0x20, 0x01, 0x0d, 0xb8]);
});

const SDP = [
  "v=0",
  "o=- 1 2 IN IP4 127.0.0.1",
  "s=-",
  "a=fingerprint:sha-256 AA:BB",
  "m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
  "a=candidate:1 1 udp 2122260223 192.168.1.20 50000 typ host generation 0",
  "a=candidate:2 1 udp 2122260222 203.0.113.5 50001 typ host generation 0",
  "a=candidate:3 1 udp 2122129151 0c7a8b9c-aaaa-bbbb.local 50002 typ host generation 0",
  "a=candidate:4 1 udp 1686052607 198.51.100.7 61000 typ srflx raddr 192.168.1.20 rport 50000 generation 0",
  "a=candidate:5 1 udp 41885439 192.0.2.44 3478 typ relay raddr 198.51.100.7 rport 61000 generation 0",
  "a=candidate:6 1 tcp 1518280447 203.0.113.5 9 typ host tcptype active generation 0",
  "a=candidate:7 1 udp 2122260221 203.0.113.6 80 typ host generation 0",
  "a=candidate:8 1 udp 2122197247 ::ffff:10.0.0.5 50003 typ host generation 0",
  "a=candidate:9 1 udp 1686052606 100.72.1.2 61001 typ srflx raddr 192.168.1.20 rport 50000 generation 0",
  "a=candidate:10 1 udp 2122197246 fd00::5 50004 typ host generation 0",
  "a=candidate:11 1 udp 2122197245 2001:db8::5 50005 typ host generation 0",
  "a=candidate:12 1 udp 2122197244 fe80::5 50006 typ host generation 0",
  "a=end-of-candidates",
  "",
].join("\r\n");

const ids = (sdp: string) => sdp.split("\r\n").filter((l) => l.startsWith("a=candidate:")).map((l) => l.slice(12).split(" ")[0]!);

test('"public": only UDP host / srflx / relay candidates on public addresses and ports ≥ 1024; raddr blanked; the rest as it was', () => {
  const out = offerSdp(SDP, "public");
  assert.deepEqual(ids(out), ["2", "4", "5", "11"]);
  assert.ok(out.includes("a=candidate:4 1 udp 1686052607 198.51.100.7 61000 typ srflx raddr 0.0.0.0 rport 0 generation 0"), out);
  assert.ok(!/192\.168|10\.0\.0|100\.72|fd00|fe80|\.local/.test(out), out);
  assert.ok(out.startsWith("v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n") && out.endsWith("a=end-of-candidates\r\n"));
  assert.equal(offerSdp(SDP, "all"), SDP, '"all" changes nothing under the cap');
  assert.equal(offerSdp(SDP), SDP);
});

test("at most 32 candidates: the highest priority ones, in their order", () => {
  const many = [...Array(40).keys()].map((i) => `a=candidate:${i} 1 udp ${1000 + ((i * 7) % 40)} 203.0.113.${i + 1} ${40000 + i} typ host`);
  const sdp = ["v=0", "m=application 9 UDP/DTLS/SCTP webrtc-datachannel", ...many, ""].join("\r\n");
  for (const policy of ["all", "public"] as const) {
    const out = ids(offerSdp(sdp, policy));
    assert.equal(out.length, MAX_OFFER_CANDIDATES);
    const prio = (id: string) => 1000 + ((Number(id) * 7) % 40);
    assert.ok(out.every((id) => prio(id) >= 1008), "the 8 lowest priorities went");
    assert.deepEqual(out, [...out].sort((a, b) => Number(a) - Number(b)), "in their order");
  }
});

/** A peer connection whose gathered candidates are `SDP`'s. */
class GatheringPeerConnection extends FakePeerConnection {
  override async setLocalDescription(d: RTCSessionDescriptionInit): Promise<void> {
    await super.setLocalDescription(d);
    const lines = SDP.split("\r\n").filter((l) => l.startsWith("a=candidate:"));
    this.localDescription = { ...d, sdp: `${d.sdp}${lines.join("\r\n")}\r\n` };
  }
}

test('dialRtc({ candidates: "public" }): the offer sent has no private candidate, and the answer is checked against what was sent', async () => {
  const identity = await Identity.create();
  const sent: string[] = [];
  const server = new ScriptedServer();
  const dial = (candidates?: "all" | "public") =>
    dialRtc({
      // the server signs the offer it got
      signal: async (offer) => {
        sent.push(offer.offer);
        return identity.answer(offer.offer);
      },
      pinnedFingerprint: identity.fingerprint,
      credential: "Bearer t0ken",
      device: { id: "dev-1", name: "Test Browser" },
      app: { name: "test", version: "1" },
      wasm: WASM,
      iface: "wifi",
      candidates,
      createPeerConnection: (c) => new GatheringPeerConnection(server, c) as unknown as RTCPeerConnection,
    });
  const s = await dial("public");
  assert.deepEqual(ids(sent[0]!), ["2", "4", "5", "11"]);
  for (const l of sent[0]!.split("\r\n").filter((x) => x.startsWith("a=candidate:"))) {
    const f = l.slice(12).split(" ");
    assert.equal(addressKind(f[4]!), "public", l);
  }
  await s.close();
  const all = await dial();
  assert.equal(ids(sent[1]!).length, 12, "every one gathered");
  await all.close();
});
