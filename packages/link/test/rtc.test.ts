// WebRTC (rtc) on loopback: a server endpoint with an rtc socket answering offers (`acceptRtcOffer`), a client
// endpoint dialing it the way a browser does (`dialRtc`), the signaling a direct function call.

import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { after, before, test } from "node:test";
import {
  CloseCode,
  LinkError,
  bindEndpoint,
  generateLinkKey,
  identityFingerprint,
  type AuthRequest,
  type Endpoint,
  type Hello,
  type Listener,
  type Session,
} from "../src/index.js";

let server: Endpoint;
let client: Endpoint;
let listener: Listener;
let fingerprint: string;
const asked: AuthRequest[] = [];

const hello = (credential: string): Hello => ({
  credential,
  device: { id: "web-1", name: "Safari" },
  app: { name: "uu web", version: "1.0" },
  features: [],
});

function identityKey(): Buffer {
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
  const jwk = privateKey.export({ format: "jwk" });
  const b = (s: string | undefined) => Buffer.from(s!, "base64url");
  return Buffer.concat([Buffer.from([4]), b(jwk.x), b(jwk.y), b(jwk.d)]);
}

before(async () => {
  const identity = identityKey();
  fingerprint = identityFingerprint(identity);
  server = await bindEndpoint({ role: "server", secretKey: generateLinkKey(), portmapper: false, rtcPort: 0 });
  client = await bindEndpoint({ role: "client", secretKey: generateLinkKey(), rtcPort: 0 });
  listener = server.listen({
    server: { id: "srv", name: "Test Linux", platform: "linux" },
    identityKey: identity,
    authenticate: (r) => {
      asked.push(r);
      return r.hello.credential === "Bearer good"
        ? { ok: true, principal: { device: r.hello.device } }
        : { ok: false, code: "unauthorized", message: "bad token" };
    },
    rpc: async (_session, req, body, res) => {
      if (req.path === "/echo") return res.respond(200, { "x-method": req.method }, body);
      return res.json(404, { error: "no route" });
    },
  });
});

after(async () => {
  await client.close();
  await server.close();
});

async function dial(credential: string): Promise<[Session, Session]> {
  const c = await client.dialRtc((offer) => listener.acceptRtcOffer(offer, "127.0.0.1"), fingerprint, hello(credential));
  const s = await listener.accept();
  return [c, s!];
}

test("rtc: handshake, RPC, control, datagrams, close", async () => {
  assert.ok(server.rtcPort! > 0);
  const [c, s] = await dial("Bearer good");
  assert.equal(c.transport, "rtc");
  assert.equal(s.transport, "rtc");
  assert.equal(c.welcome.server.name, "Test Linux");
  assert.equal(c.maxDatagramSize, 1200);
  assert.equal(c.remoteId, server.id);
  assert.match(s.remoteId, /^dtls-sha256:[0-9a-f]{64}$/);
  assert.equal(asked.at(-1)?.clientKey, s.remoteId);

  const r = await c.request({ method: "POST", path: "/echo" }, Buffer.from("hello"));
  assert.equal(r.status, 200);
  assert.equal(r.headers["x-method"], "POST");
  assert.equal(await r.text(), "hello");
  const big = Buffer.alloc(1 << 20, 7);
  assert.equal((await (await c.request({ method: "POST", path: "/echo" }, big)).readAll()).length, big.length);

  await c.sendControl({ t: "control.take", rid: 1 });
  assert.deepEqual(await s.recvControl(), { t: "control.take", rid: 1 });

  c.sendDatagram(7, Buffer.from([1, 2, 3]));
  const d = await s.recvDatagram(7);
  assert.deepEqual([...d!], [0x71, 1, 2, 3]);

  await s.close(CloseCode.replaced, "another session");
  const bye = await c.recvControl();
  assert.equal(bye?.t, "bye");
  assert.equal(bye?.code, CloseCode.replaced);
  const end = await c.closed();
  assert.equal(end.code, CloseCode.replaced);
  assert.equal(end.remote, true);
});

test("rtc: denied, bad offers, a wrong pin", async () => {
  await assert.rejects(dial("Bearer bad"), (e: unknown) => e instanceof LinkError && e.kind === "denied" && e.code === "unauthorized");
  await assert.rejects(listener.acceptRtcOffer("{}"), (e: unknown) => e instanceof LinkError && e.kind === "invalid-argument");
  const other = identityFingerprint(identityKey());
  await assert.rejects(
    client.dialRtc((offer) => listener.acceptRtcOffer(offer), other, hello("Bearer good")),
    (e: unknown) => e instanceof LinkError && e.kind === "binding",
  );
});
