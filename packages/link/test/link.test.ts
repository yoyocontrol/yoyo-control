// Loopback: a server endpoint and a client endpoint in this process, over 127.0.0.1 — handshake (accepted and
// denied), RPC (whole and streamed), control messages, datagram channels, the binding helpers.

import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { after, before, test } from "node:test";
import {
  Channel,
  CloseCode,
  LinkError,
  bindEndpoint,
  generateLinkKey,
  identityFingerprint,
  linkPublicKey,
  setLogSink,
  signBinding,
  verifyBinding,
  type Endpoint,
  type Hello,
  type Session,
} from "../src/index.js";

let server: Endpoint;
let client: Endpoint;
const sessions: Session[] = [];
const waiting: ((s: Session) => void)[] = [];
const logs: string[] = [];

function nextServerSession(): Promise<Session> {
  const s = sessions.shift();
  return s ? Promise.resolve(s) : new Promise((resolve) => waiting.push(resolve));
}

const hello = (credential: string, device = "phone-1"): Hello => ({
  credential,
  device: { id: device, name: `${device}'s iPhone` },
  app: { name: "uu", version: "1.0" },
  features: ["link"],
});

const target = () => ({ id: server.id, direct: [`127.0.0.1:${server.port}`] });

before(async () => {
  setLogSink((_level, message) => logs.push(message));
  server = await bindEndpoint({ role: "server", secretKey: generateLinkKey(), portmapper: false });
  client = await bindEndpoint({ role: "client", secretKey: generateLinkKey() });
  const listener = server.listen({
    server: { id: "srv", name: "Test Linux", platform: "linux" },
    features: ["link"],
    authenticate: async (r) => {
      await new Promise((resolve) => setTimeout(resolve, 5));
      if (r.hello.credential !== "Bearer good") return { ok: false, code: "unauthorized", message: "bad token" };
      return { ok: true, principal: { device: r.hello.device, key: r.clientKey, path: r.path } };
    },
    rpc: async (session, req, body, res) => {
      if (req.path === "/echo") return res.respond(200, { "x-method": req.method }, body);
      if (req.path.startsWith("/events")) {
        await res.head(200, { "content-type": "application/x-ndjson" });
        for (let i = 0; i < 5; i++) await res.write(JSON.stringify({ i, who: (session.principal as any).device.id }) + "\n");
        return res.finish();
      }
      if (req.path === "/throw") throw new Error("handler broke");
      return res.json(404, { error: "no route" });
    },
  });
  void (async () => {
    for await (const s of listener) {
      const w = waiting.shift();
      if (w) w(s);
      else sessions.push(s);
    }
  })();
});

after(async () => {
  setLogSink(null);
  await client.close();
  await server.close();
});

test("handshake: welcome, principal, hello on the server", async () => {
  const c = await client.dial(target(), hello("Bearer good"));
  const s = await nextServerSession();
  assert.equal(c.welcome.server.name, "Test Linux");
  assert.deepEqual(c.welcome.features, ["link"]);
  assert.equal((c.principal as any).device.id, "phone-1");
  assert.equal((c.principal as any).key, client.id);
  assert.equal((c.principal as any).path, "lan");
  assert.equal(s.hello.device.name, "phone-1's iPhone");
  assert.equal(s.isServer, true);
  assert.equal(c.remoteId, server.id);
  assert.equal(c.path().kind, "lan");
  assert.ok(c.maxDatagramSize > 1000);
  await c.close();
});

test("denied: unauthorized", async () => {
  await assert.rejects(client.dial(target(), hello("Bearer bad")), (e: unknown) => {
    assert.ok(e instanceof LinkError);
    assert.equal(e.kind, "denied");
    assert.equal(e.code, "unauthorized");
    assert.equal(e.message, "bad token");
    return true;
  });
});

test("rpc: whole, streamed, blocked, failing handler", async () => {
  const c = await client.dial(target(), hello("Bearer good", "phone-rpc"));
  await nextServerSession();
  const r = await c.request({ method: "POST", path: "/echo" }, Buffer.from("hello"));
  assert.equal(r.status, 200);
  assert.equal(r.headers["x-method"], "POST");
  assert.equal(await r.text(), "hello");

  const ev = await c.request({ method: "GET", path: "/events?x=1" });
  let text = "";
  for await (const chunk of ev) text += chunk.toString();
  const lines = text.trim().split("\n").map((l) => JSON.parse(l));
  assert.equal(lines.length, 5);
  assert.equal(lines[4].who, "phone-rpc");

  assert.equal((await c.request({ method: "GET", path: "/stream?display=1" })).status, 404);
  const broken = await c.request({ method: "GET", path: "/throw" });
  assert.equal(broken.status, 500);
  assert.deepEqual(await broken.json(), { error: "handler broke" });

  const big = Buffer.alloc(2 << 20, 9);
  assert.equal((await (await c.request({ method: "POST", path: "/echo" }, big)).readAll()).length, big.length);
  await c.close();
});

test("control messages both ways, bye and close code", async () => {
  const c = await client.dial(target(), hello("Bearer good", "phone-ctl"));
  const s = await nextServerSession();
  await c.sendControl({ t: "control.take", rid: 7 });
  assert.deepEqual(await s.recvControl(), { t: "control.take", rid: 7 });
  await s.sendControl({ t: "control", rid: 7, granted: true, holder: { id: "phone-ctl" } });
  assert.equal((await c.recvControl())?.granted, true);
  await assert.rejects(c.sendControl({ rid: 1 } as any), (e: unknown) => e instanceof LinkError && e.kind === "invalid-argument");

  await s.close(CloseCode.replaced, "another session");
  assert.deepEqual(await c.recvControl(), { t: "bye", reason: "another session" });
  const end = await c.closed();
  assert.equal(end.code, CloseCode.replaced);
  assert.equal(end.remote, true);
});

test("datagram channels", async () => {
  const c = await client.dial(target(), hello("Bearer good", "phone-dg"));
  const s = await nextServerSession();
  // the app's own channels (1–5 are the media layer's)
  for (let i = 0; i < 20; i++) {
    c.sendDatagram(7, Buffer.from([i]));
    s.sendDatagram(8, Buffer.from([i, i]));
  }
  for (let i = 0; i < 20; i++) {
    const d = await s.recvDatagram(7);
    assert.equal(d?.[0], 0x71);
    assert.equal(d?.length, 2);
    const v = await c.recvDatagram(8);
    assert.equal(v?.[0], 0x81);
    assert.equal(v?.length, 3);
  }
  assert.throws(() => c.sendDatagram(0, Buffer.from("x")), (e: unknown) => e instanceof LinkError && e.kind === "invalid-argument");
  c.targetBitrate = 6_000_000;
  assert.equal(c.targetBitrate, 6_000_000);
  const st = c.stats();
  assert.equal(st.path, "lan");
  assert.ok(st.line.startsWith("lan "), st.line);
  await c.close();
  assert.equal(await s.recvDatagram(8), null);
});

test("media: frames, cursor, input", async () => {
  const c = await client.dial(target(), hello("Bearer good", "phone-media"));
  const s = await nextServerSession();
  s.openVideo(Channel.video);
  c.openVideo(Channel.video);
  const au = Buffer.alloc(50_000, 3);
  assert.equal(s.canSendFrame(1), true);
  assert.equal(s.sendFrame(1, { codec: "hevc", kind: "key", width: 1920, height: 1080 }, au), 1);
  s.sendCursor(1, { x: 5, y: 6, visible: true, shapeId: "arrow" });
  let frame = null;
  let cursor = null;
  for await (const e of c.clientEvents()) {
    if (e.type === "frame") {
      frame = e.frame;
      c.frameDecoded(e.frame.stream, e.frame.frame);
    }
    if (e.type === "cursor") cursor = JSON.parse(e.json.toString());
    if (frame && cursor) break;
  }
  assert.equal(frame?.meta.kind, "key");
  assert.deepEqual(frame?.au, au);
  assert.equal(cursor?.x, 5);
  c.sendInput("discrete", { type: "click", x: 1 });
  const seen = new Set<string>();
  for await (const e of s.serverEvents()) {
    seen.add(e.type);
    if (e.type === "input") assert.deepEqual(JSON.parse(e.input.json.toString()), { type: "click", x: 1 });
    if (seen.has("input") && seen.has("frameDelivered")) break;
  }
  assert.throws(() => c.sendFrame(1, { codec: "h264", kind: "key", width: 1, height: 1 }, au), LinkError);
  await c.close();
});

test("binding helpers", () => {
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = privateKey.export({ format: "jwk" });
  const b = (s: string | undefined) => Buffer.from(s!, "base64url");
  const identity = Buffer.concat([Buffer.from([4]), b(jwk.x), b(jwk.y), b(jwk.d)]);
  const fp = identityFingerprint(identity);
  const binding = server.binding(identity);
  assert.equal(binding.id, server.id);
  assert.equal(verifyBinding(binding, fp), server.id);
  const other = signBinding(identity, linkPublicKey(generateLinkKey()));
  assert.notEqual(other.id, server.id);
  assert.throws(() => verifyBinding({ ...binding, id: other.id }, fp), (e: unknown) => e instanceof LinkError && e.kind === "binding");
});

test("logs go to the sink", () => {
  assert.ok(logs.some((l) => l.startsWith("link session opened")), logs.join("\n"));
});
