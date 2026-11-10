// uu Link on the Linux server (link.mjs) with the processes faked and a real link client in this process (the native
// addon: vendor/link finds the repository's link/target build, or YOYO_LINK_NATIVE; skipped without one): the binding
// in /status, a paired phone's token bound to its link key, RPC through the remote routes, a video stream (key frame
// first, a key frame again on request), the pointer, input with and without control, audio, a removed device.
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";
import { loadLink, rpcExchange, streamId, withPort } from "../link.mjs";
import { RemoteAccess, adminCall } from "../remote.mjs";
import { YoyoLinux } from "../server.mjs";
import { fakeSpawn } from "./fakes.mjs";

process.env.YOYO_PORTMAP = "off";
const { L } = await loadLink();
const skip = L ? false : "no uu Link native addon (cd link && cargo build -p uu-link-node)";

const fake = fakeSpawn();
const lines = [];
const log = (l) => lines.push(l);
const svc = new YoyoLinux({ token: null, name: "Desktop", spawnFn: fake.spawn, logLine: log, maxFps: 60 });
const home = join(mkdtempSync(join(tmpdir(), "yoyo-link-")), "remote");
let client;
let token;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(f, ms = 3000) {
  const t0 = Date.now();
  for (;;) {
    const v = await f();
    if (v) return v;
    if (Date.now() - t0 > ms) throw new Error("timed out");
    await sleep(10);
  }
}

before(async () => {
  if (skip) return;
  svc.clipboard.start();
  svc.remote = new RemoteAccess({ svc, home, signalUrl: null, name: "Linux box", advertise: ["192.168.50.151:47830"], linkPort: 0, log, lingerMs: 300 });
  await svc.remote.start();
  const j = (await adminCall(home, "POST", "/remote/pairing")).json;
  token = svc.remote.devices.pair(j.pairing.code, "phone-0001", "Test iPhone");
  await until(() => svc.remote.link);
  client = await L.bindEndpoint({ role: "client", secretKey: L.generateLinkKey() });
});
after(async () => {
  if (process.env.LINK_TEST_LOG) console.log(lines.join("\n"));
  await client?.close();
  await svc.remote?.stop();
  svc.close();
});

const hello = (credential, device = { id: "phone-0001", name: "Test iPhone" }) => ({ credential, device, app: { name: "test", version: "1" }, features: ["screen"] });
const dial = (credential = `Bearer ${token}`, ep = client, device) => {
  const l = svc.remote.link.json();
  return ep.dial({ id: l.id, direct: [`127.0.0.1:${l.port}`] }, hello(credential, device));
};
async function nextControl(s, t, ms = 3000) {
  for (;;) {
    const m = await Promise.race([s.recvControl(), sleep(ms).then(() => null)]);
    if (!m) throw new Error(`no ${t}`);
    if (m.t === t) return m;
  }
}
/** The next media event of `type`; the others that come first are kept for later calls. */
const early = new WeakMap();
async function nextEvent(s, type, ms = 3000) {
  const kept = early.get(s) ?? [];
  early.set(s, kept);
  const i = kept.findIndex((e) => e.type === type);
  if (i >= 0) return kept.splice(i, 1)[0];
  for (;;) {
    const e = await Promise.race([s.nextClientEvent(), sleep(ms).then(() => null)]);
    if (!e) throw new Error(`no ${type}`);
    if (e.type === type) return e;
    kept.push(e);
  }
}
async function controlReply(s, rid) {
  for (;;) {
    const m = await nextControl(s, "control");
    if (m.rid === rid) return m;
  }
}

test("helpers: stream ids, ports", () => {
  assert.equal(streamId(1), 1);
  assert.equal(streamId(255), 255);
  assert.equal(streamId(0), null);
  assert.equal(streamId("3"), null);
  assert.equal(withPort("10.0.0.2", 47820), "10.0.0.2:47820");
  assert.equal(withPort("10.0.0.2:47830", 47820), "10.0.0.2:47830");
});

test("rpcExchange: head, body, end; a route's request body", async () => {
  const sent = [];
  const responder = { head: async (s, h) => sent.push(["head", s, h]), write: async (b) => sent.push(["write", b.toString()]), finish: async () => sent.push(["finish"]), stopped: () => new Promise(() => {}) };
  const { req, res, done } = rpcExchange({ method: "post", path: "/x?y=1", headers: { Accept: "a" } }, Buffer.from("{}"), responder);
  assert.equal(req.method, "POST");
  assert.equal(req.headers.accept, "a");
  let body = "";
  for await (const c of req) body += c;
  assert.equal(body, "{}");
  res.writeHead(201, { "Content-Type": "x", "Content-Length": 2, Connection: "close" });
  res.end("ok");
  await done;
  assert.deepEqual(sent, [["head", 201, { "content-type": "x" }], ["write", "ok"], ["finish"]]);
});

test("/status has the link binding; GET /remote its endpoint", { skip }, async () => {
  const st = svc.status(await svc.features());
  assert.match(st.link.id, /^[0-9a-f]{64}$/);
  assert.equal(L.verifyBinding(st.link, svc.remote.identity.keyFingerprint), st.link.id);
  assert.ok(st.link.direct.includes("192.168.50.151:47830"));
  assert.equal(st.features.link, true);
  const r = (await adminCall(home, "GET", "/remote")).json;
  assert.equal(r.link.id, st.link.id);
  assert.equal(r.link.mapping.status, "off");
});

test("pairing over the link: Pair <code> gives the token, bound to that key; a wrong or used code is refused", { skip }, async () => {
  const other = await L.bindEndpoint({ role: "client", secretKey: L.generateLinkKey() });
  const device = { id: "phone-0002", name: "Second iPhone" };
  try {
    await assert.rejects(dial("Pair nothing-shown", other, device), (e) => e.code === "unauthorized");
    const { code } = svc.remote.devices.startPairing();
    await assert.rejects(dial(`Pair wrong-${code}`, other, device), (e) => e.code === "unauthorized");
    const s = await dial(`Pair ${code}`, other, device);
    assert.deepEqual(s.principal.device, device);
    assert.deepEqual(s.principal.server, { id: svc.remote.settings.serverId, name: "Linux box", platform: "linux" });
    const paired = s.principal.token;
    assert.equal(typeof paired, "string");
    // the session is the device's at once: its routes work
    const st = await s.request({ method: "GET", path: "/status" });
    assert.equal(st.status, 200);
    await s.close();
    await assert.rejects(dial(`Pair ${code}`, other, device), (e) => e.code === "unauthorized", "used once");
    const again = await dial(`Bearer ${paired}`, other, device);
    assert.equal(again.principal.token, undefined, "only pairing hands out the token");
    await again.close();
    // the token is bound to the key it paired with
    await assert.rejects(dial(`Bearer ${paired}`, client, device), (e) => e.code === "unauthorized");
  } finally {
    svc.remote.devices.remove("phone-0002");
    await other.close();
  }
});

test("a wrong token is refused; the first key binds the token, another key is refused", { skip }, async () => {
  await assert.rejects(dial("Bearer nope"), (e) => e.kind === "denied" && e.code === "unauthorized");
  const s = await dial();
  assert.equal(s.welcome.server.platform, "linux");
  assert.deepEqual(s.principal, { device: { id: "phone-0001", name: "Test iPhone" } });
  await s.close();
  const other = await L.bindEndpoint({ role: "client", secretKey: L.generateLinkKey() });
  try {
    const l = svc.remote.link.json();
    await assert.rejects(other.dial({ id: l.id, direct: [`127.0.0.1:${l.port}`] }, hello(`Bearer ${token}`)), (e) => e.code === "unauthorized");
  } finally {
    await other.close();
  }
});

test("RPC: /status through the routes, /events streams, routes outside the allowlist 404", { skip }, async () => {
  const s = await dial();
  try {
    const st = await s.request({ method: "GET", path: "/status" });
    assert.equal(st.status, 200);
    assert.equal((await st.json()).platform, "linux");
    const ev = await s.request({ method: "GET", path: "/events" });
    assert.equal(ev.status, 200);
    const first = JSON.parse((await ev.chunk()).toString().split("\n")[0]);
    assert.equal(first.type, "state");
    ev.cancel();
    assert.equal((await s.request({ method: "GET", path: "/audio/stats" })).status, 404);
    assert.equal((await s.request({ method: "POST", path: "/clipboard" }, Buffer.from(JSON.stringify({ text: "hi" })))).status, 200);
  } finally {
    await s.close();
  }
});

test("video: opened, a key frame first, another on request; the pointer; closed", { skip }, async () => {
  const s = await dial();
  try {
    s.openVideo(1);
    await s.sendControl({ t: "video.open", id: 1, query: "display=1&fps=60&cursor=client&status=1" });
    const opened = await nextControl(s, "video.opened");
    assert.equal(opened.codec, "h264");
    assert.equal(opened.width, 1280);
    assert.equal(opened.headers["X-Stream-Codec"], "h264");
    const f1 = await nextEvent(s, "frame");
    assert.equal(f1.frame.meta.kind, "key");
    assert.ok(f1.frame.au.length > 0);
    s.frameDecoded(1, f1.frame.frame, true);
    const c = await nextEvent(s, "cursor");
    const cur = JSON.parse(c.json.toString());
    assert.equal(cur.x, 640 / 1280);
    // a change → a delta; a keyframe request → a key frame
    fake.state.screenChanges();
    const f2 = await nextEvent(s, "frame");
    assert.equal(f2.frame.meta.kind, "delta");
    // the 3.5 Mbps start caps the frame rate at 30 (frameRateCap): x264, started at --fps 60, gets twice the rate per
    // picture, its buffer the real rate (a key frame no bigger than before)
    const e2 = fake.state.encodes.at(-1);
    assert.ok(e2.buf > 0 && Math.abs(e2.kbps - 2 * e2.buf) <= 1, JSON.stringify(e2));
    await sleep(600);
    await s.sendControl({ t: "keyframe", id: 1 });
    await until(() => fake.state.encodes.slice(-3).some((e) => e.key));
    await s.sendControl({ t: "video.close", id: 1 });
    const closed = await nextControl(s, "video.closed");
    assert.equal(closed.reason, "closed by the phone");
    // a bad id; a bad query
    await s.sendControl({ t: "video.open", id: 0, query: "" });
    assert.equal((await nextControl(s, "video.error")).status, 400);
    await s.sendControl({ t: "video.open", id: 2, query: "display=9" });
    assert.equal((await nextControl(s, "video.error")).status, 404);
  } finally {
    await s.close();
  }
});

test("input: refused without control, applied with it; control messages", { skip }, async () => {
  const s = await dial();
  try {
    const n = fake.state.xdotool.length;
    const seq = s.sendInput("discrete", { type: "click", x: 0.5, y: 0.5 });
    const r = await nextControl(s, "input.rejected");
    assert.equal(r.seq, seq);
    assert.equal(r.status, 409);
    assert.equal(r.code, "no-control");
    await s.sendControl({ t: "control.take", rid: 1 });
    const c = await controlReply(s, 1);
    assert.equal(c.granted, true);
    assert.equal(c.rid, 1);
    assert.deepEqual(c.holder, { id: "phone-0001", name: "Test iPhone" });
    s.sendInput("discrete", { type: "click", x: 0.5, y: 0.5 });
    await until(() => fake.state.xdotool.length > n);
    await nextEvent(s, "inputAcked");
    await s.sendControl({ t: "control.release", rid: "r" });
    const c2 = await controlReply(s, "r");
    assert.equal(c2.granted, false);
  } finally {
    await s.close();
  }
});

test("audio: opened, opus packets, closed", { skip }, async () => {
  const s = await dial();
  try {
    s.openAudio(1);
    await s.sendControl({ t: "audio.open", id: 1, query: "" });
    const o = await nextControl(s, "audio.opened");
    assert.equal(o.codec, "opus");
    assert.equal(o.rate, 48000);
    const a = await nextEvent(s, "audio");
    assert.ok(a.audio.data.length > 0);
    await s.sendControl({ t: "audio.close", id: 1 });
    assert.equal((await nextControl(s, "audio.closed")).reason, "closed by the phone");
  } finally {
    await s.close();
  }
});

test("a removed device's session ends", { skip }, async () => {
  const s = await dial();
  svc.remote.devices.remove("phone-0001");
  const info = await Promise.race([s.closed(), sleep(3000).then(() => null)]);
  assert.ok(info, "the session did not end");
  assert.equal(info.code, L.CloseCode.unauthorized);
});

/** `POST /link/rtc` through the service's routes, as the token listener's client (a host relaying a browser's offer). */
async function postRtc(offer, client) {
  const { Readable } = await import("node:stream");
  const req = Object.assign(Readable.from([Buffer.from(offer)]), { method: "POST", url: "/link/rtc", headers: {} });
  return new Promise((resolve) => {
    let status = 0;
    const res = {
      writeHead(s) {
        status = s;
        return res;
      },
      setHeader() {},
      end(body) {
        resolve({ status, body: String(body ?? "") });
      },
      on() {},
      once() {},
    };
    void svc.handle(req, res, client);
  });
}

test("a browser over WebRTC: POST /link/rtc signals, the token binds to its DTLS certificate", { skip }, async () => {
  const l = svc.remote.link.json();
  assert.ok(l.rtc?.port > 0, JSON.stringify(l));
  const LOCAL = { kind: "local" };
  assert.equal((await postRtc("{}", LOCAL)).status, 400);
  assert.equal((await postRtc("{}", { kind: "remote", device: { id: "phone-0001" } })).status, 404);
  const browser = await L.bindEndpoint({ role: "client", secretKey: L.generateLinkKey(), rtcPort: 0 });
  try {
    const signal = async (offer) => {
      const r = await postRtc(offer, LOCAL);
      if (r.status !== 200) throw new Error(`${r.status} ${r.body}`);
      return r.body;
    };
    const fp = svc.remote.identity.keyFingerprint;
    // the phone's token is bound to its link key: another installation (a browser) is refused
    await assert.rejects(browser.dialRtc(signal, fp, hello(`Bearer ${token}`)), (e) => e.code === "unauthorized");
    const j = (await adminCall(home, "POST", "/remote/pairing")).json;
    const webToken = svc.remote.devices.pair(j.pairing.code, "browser-0001", "Safari");
    const s = await browser.dialRtc(signal, fp, { ...hello(`Bearer ${webToken}`), device: { id: "browser-0001", name: "Safari" } });
    assert.equal(s.transport, "rtc");
    assert.equal(s.welcome.server.platform, "linux");
    const r = await s.request({ method: "GET", path: "/status" });
    assert.equal(r.status, 200);
    assert.equal((await r.json()).link.rtc.port, l.rtc.port);
    await s.close();
  } finally {
    await browser.close();
  }
});
