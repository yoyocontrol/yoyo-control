import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { CloseCode, dialRtc, encodeFrame, LinkError, type DialRtcOptions, type LinkSession } from "../src/index.js";
import { FakePeerConnection, Identity, ScriptedServer } from "./fake.js";

const WASM = readFileSync(fileURLToPath(new URL("../src/wasm/uu_link_wasm_bg.wasm", import.meta.url)));

async function dial(server: ScriptedServer, over: Partial<DialRtcOptions> = {}, id?: Identity): Promise<{ session: LinkSession; pc: FakePeerConnection; offers: unknown[] }> {
  const identity = id ?? (await Identity.create());
  let pc: FakePeerConnection | null = null;
  const offers: unknown[] = [];
  const session = await dialRtc({
    signal: async (offer) => {
      offers.push(offer);
      return identity.answer(offer.offer);
    },
    pinnedFingerprint: identity.fingerprint,
    credential: "Bearer t0ken",
    device: { id: "dev-1", name: "Test Browser" },
    app: { name: "test", version: "1" },
    wasm: WASM,
    iface: "wifi",
    createPeerConnection: (c) => (pc = new FakePeerConnection(server, c)) as unknown as RTCPeerConnection,
    ...over,
  });
  return { session, pc: pc!, offers };
}

test("dial: negotiated channels, a non-trickle offer, hello → welcome", async () => {
  const server = new ScriptedServer();
  const { session, pc, offers } = await dial(server, { iceServers: [{ urls: "stun:stun.example.org:3478" }] });
  assert.deepEqual(pc.config.iceServers, [{ urls: "stun:stun.example.org:3478" }]);
  const [control, dgram] = pc.channels;
  assert.deepEqual([control!.label, control!.id, control!.ordered], ["control", 0, true]);
  assert.deepEqual([dgram!.label, dgram!.id, dgram!.ordered], ["dgram", 1, false]);
  const offer = offers[0] as { v: number; offer: string; device: unknown };
  assert.equal(offer.v, 1);
  assert.match(offer.offer, /a=candidate:/, "the gathered candidates are in the offer");
  assert.deepEqual(offer.device, { id: "dev-1", name: "Test Browser" });
  assert.deepEqual(server.received[0], { t: "hello", v: 1, credential: "Bearer t0ken", device: { id: "dev-1", name: "Test Browser" }, app: { name: "test", version: "1" }, features: ["screen", "audio", "cursor", "input"] });
  assert.deepEqual(session.server, { id: "srv", name: "Test Mac", platform: "macos" });
  assert.deepEqual(session.principal, { device: { id: "d1", name: "Browser" } });
  assert.equal(session.maxDatagramSize, 1200);
  await session.close();
  assert.deepEqual(server.received.at(-1), { t: "bye", code: 0, reason: "" });
  assert.equal((await session.closed()).remote, false);
  assert.equal(pc.connectionState, "closed");
});

test("control messages both ways; frames after welcome in the same message are kept", async () => {
  const server = new ScriptedServer();
  server.onHello = (_h, _send) => {
    const w = encodeFrame({ t: "welcome", v: 1, server: { id: "s", name: "n", platform: "linux" }, principal: null, features: [], maxDatagram: 1100 });
    const c = encodeFrame({ t: "control", granted: false, holder: null });
    const both = new Uint8Array(w.length + c.length);
    both.set(w);
    both.set(c, w.length);
    server.control!.send(both);
  };
  server.onControl = (m, send) => {
    if (m.t === "ping") send({ t: "pong", n: m.n });
  };
  const { session } = await dial(server);
  const early = new Promise((r) => session.onControl(r));
  assert.deepEqual(await early, { t: "control", granted: false, holder: null });
  assert.equal(session.maxDatagramSize, 1100);
  const it = session.controlMessages();
  const seen: unknown[] = [];
  const reading = (async () => {
    for await (const m of it) {
      seen.push(m);
      if (seen.length === 1) break;
    }
  })();
  session.sendControl({ t: "ping", n: 7 });
  await reading;
  assert.deepEqual(seen, [{ t: "pong", n: 7 }]);
  assert.throws(() => session.sendControl({ t: "hello" }), (e: unknown) => e instanceof LinkError && e.kind === "protocol");
  await session.close();
});

test("RPC: head, body, FIN; the answer streams", async () => {
  const server = new ScriptedServer();
  const { session } = await dial(server);
  const body = new Uint8Array(40_000).fill(7);
  const res = await session.request({ method: "post", path: "/clipboard?x=1", headers: { "Content-Type": "text/plain", Host: "x" } }, body);
  assert.equal(res.status, 200);
  assert.equal(res.headers["content-type"], "application/json");
  assert.deepEqual(await res.json(), { m: "POST", p: "/clipboard?x=1", n: 40_000 });
  const r2 = await session.fetch("/status", { method: "GET" });
  assert.equal(r2.status, 200);
  assert.deepEqual(await r2.json(), { m: "GET", p: "/status", n: 0 });
  // a reset (channel closed without the FIN) is an error, not a short body
  server.rpc = (_h, _b, ch) => {
    ch.send(encodeFrame({ s: 200, h: {} }));
    ch.send(new Uint8Array([1, 2, 3]));
    ch.close();
  };
  const r3 = await session.request({ method: "GET", path: "/events" });
  assert.deepEqual([...(await r3.chunk())!], [1, 2, 3]);
  await assert.rejects(r3.chunk(), (e: unknown) => e instanceof LinkError && e.kind === "closed");
  await session.close();
});

test("app datagram channels 6–15", async () => {
  const server = new ScriptedServer();
  const { session } = await dial(server);
  const got = new Promise<Uint8Array>((r) => session.onDatagram(14, r));
  session.sendDatagram(14, new Uint8Array([9, 8, 7]));
  assert.deepEqual([...(await got)], [9, 8, 7]);
  assert.equal(server.datagrams[0]![0], (14 << 4) | 1);
  assert.throws(() => session.sendDatagram(3, new Uint8Array(1)), LinkError);
  session.sendDatagram(15, new Uint8Array(5000));
  assert.equal(session.stats().datagramDrops, 1, "past the max datagram size: dropped");
  await session.close();
});

test("denied, bye codes before welcome, and a bad answer", async () => {
  const denied = new ScriptedServer();
  denied.onHello = (_h, send) => send({ t: "denied", code: "unauthorized", message: "unknown device" });
  await assert.rejects(dial(denied), (e: unknown) => e instanceof LinkError && e.kind === "denied" && e.code === "unauthorized" && e.message === "unknown device");
  const busy = new ScriptedServer();
  busy.onHello = (_h, send) => send({ t: "bye", code: CloseCode.busy, reason: "too many" });
  await assert.rejects(dial(busy), (e: unknown) => e instanceof LinkError && e.kind === "denied" && e.code === "busy");
  const other = await Identity.create();
  await assert.rejects(
    dial(new ScriptedServer(), { pinnedFingerprint: other.fingerprint }),
    (e: unknown) => e instanceof LinkError && e.kind === "verification",
  );
  await assert.rejects(
    dial(new ScriptedServer(), { signal: async () => Promise.reject(new Error("relay offline")) }),
    (e: unknown) => e instanceof LinkError && e.kind === "signal" && /relay offline/.test(e.message),
  );
  const silent = new ScriptedServer();
  silent.onHello = () => {};
  await assert.rejects(dial(silent, { timeoutMs: 200 }), (e: unknown) => e instanceof LinkError && e.kind === "timeout");
  const ctrl = new AbortController();
  ctrl.abort();
  await assert.rejects(dial(new ScriptedServer(), { abortSignal: ctrl.signal }), (e: unknown) => e instanceof LinkError && e.kind === "closed");
});

test("the server's bye ends the session with its code; stats and path from getStats", async () => {
  const server = new ScriptedServer();
  const { session } = await dial(server);
  await new Promise((r) => setTimeout(r, 2100));
  const st = session.stats();
  assert.equal(st.path, "lan");
  assert.equal(st.remote, "192.168.1.10:47821");
  assert.equal(st.iface, "wifi");
  assert.ok(st.rttMinMs > 11 && st.rttMinMs < 13, `rtt ${st.rttMinMs}`);
  assert.match(st.line, /^lan wifi rtt 12/);
  const sent = server.received.find((m) => m.t === "link.stats");
  assert.ok(sent, "link.stats every 2 s");
  assert.equal(sent.path, "lan");
  server.send({ t: "link.stats", path: "lan", iface: "other", rttMinMs: 1, rttP50Ms: 2, rttP90Ms: 3, bytesSent: 0, bytesReceived: 0, packetsLost: 0, datagramsSent: 0, datagramsReceived: 0, datagramDrops: 0 });
  server.send({ t: "bye", code: CloseCode.replaced, reason: "replaced" });
  const info = await session.closed();
  assert.deepEqual([info.code, info.reason, info.remote], [6, "replaced", true]);
  assert.equal(session.peerStats()?.rttP90Ms, 3);
  assert.throws(() => session.sendControl({ t: "x" }), (e: unknown) => e instanceof LinkError && e.kind === "closed");
});
