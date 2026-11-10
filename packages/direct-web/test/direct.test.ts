import assert from "node:assert/strict";
import { test } from "node:test";
import { LinkError, type CertificateStore } from "@yoyocontrol/link-web";
import { DirectWeb } from "../src/direct.js";
import { DirectError } from "../src/errors.js";
import { memoryStore } from "../src/store.js";
import { FakeDialer, FakeSession } from "./fakes.js";

const fp = `sha256:${"ef".repeat(32)}`;
const link = { serverId: "srv-1", name: "Studio", fingerprint: fp, code: "c0de" };

const certificate = (days: number) => ({ expires: Date.now() + days * 86_400_000 }) as unknown as RTCCertificate;

/** link-web's certificate store, in memory. */
class FakeCertificates implements CertificateStore {
  saves = 0;
  constructor(public kept: RTCCertificate | null = certificate(300)) {}
  async load() {
    return this.kept ?? undefined;
  }
  async save(c: RTCCertificate) {
    this.saves++;
    this.kept = c;
  }
}

function web(next: () => FakeSession | Error, certificates = new FakeCertificates()) {
  const dialer = new FakeDialer(next);
  const store = memoryStore();
  const w = new DirectWeb({
    app: { name: "test", version: "1" },
    store,
    relay: "https://relay.test",
    deviceName: "Chrome on Mac",
    dial: dialer.dial,
    turn: false,
    certificateStore: certificates,
  });
  return { w, dialer, store, certificates };
}

test("pairing over the link: Pair <code>, no media, the token from welcome.principal kept; the session closes", async () => {
  const session = new FakeSession(undefined, { id: "srv-1", name: "Studio", platform: "mac" }, {
    device: { id: "x", name: "Chrome on Mac" },
    token: "secret-token",
    server: { id: "srv-1", name: "Studio Display Mac" },
  });
  const { w, dialer, certificates } = web(() => session);
  const mac = await w.pair(link);
  const o = dialer.dials[0]!;
  assert.equal(o.credential, "Pair c0de");
  assert.equal(o.media, false);
  assert.equal(o.pinnedFingerprint, fp);
  assert.match(o.device.id, /^[0-9a-f-]{36}$/);
  assert.equal(mac.token, "secret-token");
  assert.equal(mac.name, "Studio Display Mac");
  assert.equal(mac.relay, "https://relay.test");
  assert.equal(mac.platform, "mac");
  assert.equal(session.isClosed, true);
  assert.deepEqual((await w.macs()).map((m) => m.id), ["srv-1"]);

  // the identity is made once and kept: the next dial is the same browser
  const b = await w.backend(mac);
  assert.equal(await w.backend(mac), b, "one backend per Mac");
  await b.connection.session();
  assert.equal(dialer.dials[1]!.device.id, o.device.id);
  assert.equal(dialer.dials[1]!.credential, "Bearer secret-token");
  assert.equal(dialer.dials[1]!.certificates?.[0], certificates.kept, "the certificate store's certificate");

  await w.forget("srv-1");
  assert.deepEqual(await w.macs(), []);
});

test("a refused code is a pairing error; a Mac without link pairing (no token) too", async () => {
  const refused = web(() => new LinkError("denied", "the pairing code is wrong or has expired", "unauthorized"));
  await assert.rejects(refused.w.pair(link), (e: unknown) => e instanceof DirectError && e.kind === "pairing" && /expired/.test(e.message));
  const old = web(() => new FakeSession());
  await assert.rejects(old.w.pair(link), (e: unknown) => e instanceof DirectError && e.kind === "pairing");
  assert.deepEqual(await old.w.macs(), []);
});

test("an earlier build's own certificate moves to link-web's store (the Macs' bindings keep working); the device id is kept", async () => {
  const legacy = certificate(200);
  const empty = new FakeCertificates(null);
  const { w, store } = web(() => new FakeSession(), empty);
  await store.saveIdentity({ deviceId: "kept-device-id", certificate: legacy });
  const id = await w.identity();
  assert.equal(id.deviceId, "kept-device-id");
  assert.equal(id.certificate, legacy);
  assert.equal(empty.kept, legacy);
  assert.deepEqual(await store.identity(), { deviceId: "kept-device-id" }, "dropped from the old record");

  // the certificate store already has one: it wins (it is what link-web dials with by default)
  const current = new FakeCertificates(certificate(300));
  const other = web(() => new FakeSession(), current);
  await other.store.saveIdentity({ deviceId: "x-device-id", certificate: legacy });
  assert.equal((await other.w.identity()).certificate, current.kept);
  assert.equal(current.saves, 0);
});
