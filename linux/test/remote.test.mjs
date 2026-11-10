// Remote access (remote.mjs, control.mjs) with the processes faked: the listener only while a phone is paired or a
// code is live, the pairing link, control and its 409s for the token listener's client, the admin socket. A phone over
// the link (pairing, its routes, its control): link.test.mjs.
import assert from "node:assert/strict";
import { mkdtempSync, statSync } from "node:fs";
import { request as httpRequest } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";
import { RemoteControl } from "../control.mjs";
import { loadLink } from "../link.mjs";
import { RemoteAccess, REMOTE_ROUTES, adminCall, loadSettings } from "../remote.mjs";
import { YoyoLinux } from "../server.mjs";
import { fakeSpawn } from "./fakes.mjs";

process.env.YOYO_PORTMAP = "off";
const TOKEN = "f".repeat(64);
const { L } = await loadLink();
const fake = fakeSpawn();
const lines = [];
const log = (l) => lines.push(l);
const svc = new YoyoLinux({ token: TOKEN, name: "Desktop", spawnFn: fake.spawn, logLine: log });
const home = join(mkdtempSync(join(tmpdir(), "yoyo-remote-")), "remote");
let localPort;

before(async () => {
  localPort = (await svc.listen(0, "127.0.0.1")).port;
  svc.remote = new RemoteAccess({ svc, home, signalUrl: null, name: "Linux box", advertise: ["192.168.50.151:47830"], linkPort: 0, log, lingerMs: 300 });
  await svc.remote.start();
});
after(async () => {
  await svc.remote?.stop();
  svc.close();
});

function local(method, path, body) {
  return new Promise((resolve, reject) => {
    const b = body === undefined ? undefined : Buffer.from(JSON.stringify(body));
    const req = httpRequest({ host: "127.0.0.1", port: localPort, method, path, headers: { authorization: `Bearer ${TOKEN}`, ...(b ? { "content-type": "application/json", "content-length": b.length } : {}) } }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve({ status: res.statusCode, json: JSON.parse(Buffer.concat(chunks).toString() || "null") }));
    });
    req.on("error", reject);
    req.end(b);
  });
}

const phone = { id: "phone-0001", name: "Alex's iPhone" };

test("no phone paired, no code: nothing listens; remote.json made (0600) with a server id", async () => {
  assert.equal(svc.remote.listening, false);
  assert.equal(statSync(join(home, "remote.json")).mode & 0o777, 0o600);
  assert.equal(statSync(join(home, "tls-key.der")).mode & 0o777, 0o600);
  assert.equal(statSync(home).mode & 0o777, 0o700);
  assert.equal(statSync(join(home, "admin.sock")).mode & 0o777, 0o600);
  assert.ok(loadSettings(join(home, "remote.json")).serverId.length >= 16);
  assert.equal((await local("GET", "/status")).json.candidates, undefined);
  assert.deepEqual((await local("POST", "/control", { controller: "user" })).status, 404);
  assert.ok(REMOTE_ROUTES.has("POST /control") && !REMOTE_ROUTES.has("GET /windows"));
});

test("pair: the admin socket makes a code and starts the link; the pairing link is the Mac's format", async () => {
  const a = await adminCall(home, "POST", "/remote/pairing");
  assert.equal(a.status, 200);
  const j = a.json;
  assert.match(j.fingerprint, /^sha256:[0-9a-f]{64}$/);
  assert.ok(j.pairing.code);
  assert.deepEqual(j.addresses, ["192.168.50.151"]);
  assert.deepEqual(j.signal, { connected: false });
  assert.equal(j.direct.status, "off");
  if (!L) {
    // no native addon here: no link, no pairing link
    assert.equal(j.listening, false);
    assert.equal(j.pairing.url, undefined);
    return;
  }
  assert.equal(j.listening, true);
  const u = new URL(j.pairing.url);
  assert.equal(u.protocol, "yoyocontrol:");
  assert.equal(u.host, "pair");
  assert.equal(u.searchParams.get("v"), "2");
  assert.equal(u.searchParams.get("id"), j.serverId);
  assert.equal(u.searchParams.get("n"), "Linux box");
  assert.equal(u.searchParams.get("a"), "192.168.50.151");
  assert.equal(u.searchParams.get("fp"), j.fingerprint);
  assert.equal(u.searchParams.get("l"), j.link.id);
  assert.equal(u.searchParams.get("lp"), String(j.link.port));
  assert.equal(u.searchParams.get("c"), j.pairing.code);
});

test("control: the token listener's input is a 409 while a phone holds it; released → it goes again", async () => {
  svc.remote.devices.pair(svc.remote.devices.pairingCode?.code ?? svc.remote.devices.startPairing().code, phone.id, phone.name);
  assert.equal((await local("POST", "/input", { type: "move", x: 0.1, y: 0.1 })).status, 200);
  const events = [];
  const sub = { end: () => {}, send: (line) => events.push(JSON.parse(line)) };
  svc.events.add(sub);
  svc.remote.control.take(phone);
  const blocked = await local("POST", "/input", { type: "move", x: 0.2, y: 0.2 });
  assert.equal(blocked.status, 409);
  assert.equal(blocked.json.code, "controlled-elsewhere");
  assert.deepEqual(blocked.json.controllerDevice, phone);
  assert.equal((await local("GET", "/status")).json.control.controller, "remote");
  const d = await adminCall(home, "POST", "/remote/disconnect");
  assert.deepEqual(d.json.control, { controller: "none" });
  assert.equal((await local("POST", "/input", { type: "move", x: 0.2, y: 0.2 })).status, 200);
  svc.events.delete(sub);
  assert.deepEqual(events.filter((e) => e.type === "control").map((e) => e.control.controller), ["remote", "none"]);
});

test("devices: listed; removing one ends its control; the listener lingers, then stops", async () => {
  svc.remote.devices.stopPairing();
  svc.remote.control.take(phone);
  const list = await adminCall(home, "GET", "/remote");
  assert.deepEqual(list.json.devices.map((d) => [d.id, d.connected]), [[phone.id, false]]);
  assert.equal(list.json.pairing, null);
  assert.equal((await adminCall(home, "POST", "/remote/devices/remove", { id: "nope" })).status, 404);
  const r = await adminCall(home, "POST", "/remote/devices/remove", { id: phone.id });
  assert.equal(r.status, 200);
  assert.deepEqual(r.json.control, { controller: "none" });
  assert.equal(svc.remote.listening, Boolean(L), "lingering after the last device");
  await new Promise((res) => setTimeout(res, 1000));
  assert.equal(svc.remote.listening, false);
});

test("RemoteControl: idle release, the latest taker holds it, release of another's changes nothing", () => {
  let now = 0;
  const changes = [];
  const c = new RemoteControl({ idleMs: 1000, now: () => now, onChange: (j) => changes.push(j.controller) });
  const a = { id: "a", name: "A" };
  const b = { id: "b", name: "B" };
  assert.throws(() => c.admitInput(a), /take control/);
  c.admitInput(null);
  c.take(a);
  c.admitInput(a);
  assert.throws(() => c.admitInput(b), (e) => e.status === 409 && e.extra.code === "controlled-elsewhere");
  assert.throws(() => c.admitInput(null), (e) => e.extra.controllerDevice.id === "a");
  c.take(b);
  assert.equal(c.holder.id, "b");
  assert.equal(c.release(a), false);
  now = 999;
  c.checkIdle();
  assert.equal(c.holder.id, "b");
  now = 1000;
  c.checkIdle();
  assert.equal(c.holder, null);
  c.stop();
  assert.deepEqual(changes, ["remote", "remote", "none"]);
});

test("account: a paired phone puts the computer in its account with a signed statement; leave takes it out", async () => {
  const { createPublicKey, createHash, verify } = await import("node:crypto");
  const r = svc.remote;
  const device = { id: "phone-acct-1", name: "Phone" };
  assert.deepEqual(r.accountRoute("GET /account", null, device).json, { account: null });
  assert.equal(r.accountRoute("POST /account/join", { account: "nope" }, device).status, 400);
  const account = "0a".repeat(16);
  const st = r.accountRoute("POST /account/join", { account }, device).json;
  assert.equal(st.account, account);
  assert.equal(`sha256:${st.fp}`, r.identity.keyFingerprint);
  assert.equal(createHash("sha256").update(Buffer.from(st.key, "base64")).digest("hex"), st.fp);
  const pub = createPublicKey({ key: { kty: "EC", crv: "P-256", x: Buffer.from(st.key, "base64").subarray(1, 33).toString("base64url"), y: Buffer.from(st.key, "base64").subarray(33).toString("base64url") }, format: "jwk" });
  assert.ok(verify("sha256", Buffer.from(`yoyocontrol-account-v1:${account}:${st.fp}`), { key: pub, dsaEncoding: "ieee-p1363" }, Buffer.from(st.sig, "base64")));
  assert.equal(st.platform, "linux");
  assert.equal(loadSettings(join(home, "remote.json")).account.id, account, "remembered");
  assert.equal((await adminCall(home, "GET", "/remote")).json.account.id, account);
  const inv = r.accountRoute("POST /account/invite", { id: "phone-acct-2", name: "New", linkKey: "ab".repeat(32) }, device);
  assert.equal(inv.status, 200);
  assert.equal(inv.json.code.length, 22);
  assert.equal(r.accountRoute("POST /account/invite", { id: "phone-acct-2" }, device).status, 400);
  assert.equal((await adminCall(home, "POST", "/remote/account/leave")).json.account, null);
  assert.equal(loadSettings(join(home, "remote.json")).account, null);
});
