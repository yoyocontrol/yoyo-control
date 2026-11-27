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

test("an account's computer: let in with Ticket <t>, kept with its Link id; a token that stops working gets a new ticket, then a new token", async () => {
  const tickets: string[] = [];
  let ticketAnswer: () => Promise<string> = async () => "t2";
  const steps: (() => FakeSession | Error)[] = [
    () => new FakeSession(undefined, { id: "srv-9", name: "Lab", platform: "linux" }, { token: "tok1", server: { id: "srv-9", name: "Lab PC" } }),
    () => new LinkError("denied", "unknown token", "unauthorized"),
    () => new FakeSession(undefined, { id: "srv-9", name: "Lab", platform: "linux" }, { token: "tok2" }),
    () => new FakeSession(undefined, { id: "srv-9", name: "Lab", platform: "linux" }),
  ];
  const dialer = new FakeDialer(() => steps.shift()!());
  const store = memoryStore();
  const w = new DirectWeb({
    app: { name: "test", version: "1" }, store, relay: "https://relay.test", deviceName: "Chrome on Mac", dial: dialer.dial, turn: false,
    certificateStore: new FakeCertificates(),
    ticket: (linkId) => (tickets.push(linkId), ticketAnswer()),
  });
  const mac = await w.admit({ id: "srv-9", name: "Lab", fingerprint: fp, linkId: "link-9" }, "t1");
  assert.equal(dialer.dials[0]!.credential, "Ticket t1");
  assert.equal(dialer.dials[0]!.media, false);
  assert.equal(dialer.dials[0]!.pinnedFingerprint, fp);
  assert.equal(mac.token, "tok1");
  assert.equal(mac.account, "link-9");
  assert.equal(mac.name, "Lab PC");
  assert.equal(mac.platform, "linux");
  assert.equal(mac.relay, "https://relay.test");
  // the token is refused: a new ticket, Ticket t2 → tok2, then the dial with tok2; tok2 is kept
  const b = await w.backend(mac);
  await b.connection.session();
  assert.deepEqual(dialer.dials.map((d) => d.credential), ["Ticket t1", "Bearer tok1", "Ticket t2", "Bearer tok2"]);
  assert.deepEqual(tickets, ["link-9"]);
  assert.equal((await w.macs())[0]!.token, "tok2");

  // signed out of the account: the computer no longer takes this browser (not a network failure)
  w.disconnect("srv-9");
  ticketAnswer = async () => {
    throw Object.assign(new Error("account server: 401 invalid_token"), { status: 401 });
  };
  steps.push(() => new LinkError("denied", "unknown token", "unauthorized"));
  const again = await w.backend((await w.macs())[0]!);
  await assert.rejects(again.connection.session(), (e: unknown) => e instanceof DirectError && e.kind === "unpaired");
});

test("a paired computer (no account) whose token is refused is unpaired, no ticket asked", async () => {
  let asked = 0;
  const steps: (() => FakeSession | Error)[] = [
    () => new FakeSession(undefined, { id: "srv-1", name: "Studio", platform: "mac" }, { token: "tok" }),
    () => new LinkError("denied", "unknown token", "unauthorized"),
  ];
  const dialer = new FakeDialer(() => steps.shift()!());
  const w = new DirectWeb({
    app: { name: "test", version: "1" }, store: memoryStore(), relay: "https://relay.test", dial: dialer.dial, turn: false,
    certificateStore: new FakeCertificates(), ticket: async () => (asked++, "t"),
  });
  const mac = await w.pair(link);
  await assert.rejects((await w.backend(mac)).connection.session(), (e: unknown) => e instanceof DirectError && e.kind === "unpaired");
  assert.equal(asked, 0);
});
