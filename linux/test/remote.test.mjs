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
  svc.remote = new RemoteAccess({ svc, home, signalUrl: null, name: "Linux box", advertise: ["192.168.1.151:47830"], linkPort: 0, log, lingerMs: 300 });
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

/** The account server's test harness (@yoyocontrol/account-server/testing), built when it is not yet. */
async function accountTesting() {
  const dist = new URL("../../packages/account-server/dist/testing/index.js", import.meta.url);
  const { existsSync } = await import("node:fs");
  if (!existsSync(dist)) {
    const { execFileSync } = await import("node:child_process");
    execFileSync("npm", ["--prefix", new URL("../../packages/account-server", import.meta.url).pathname, "run", "build"], { stdio: "ignore" });
  }
  return import(dist.href);
}

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
  assert.deepEqual(j.addresses, ["192.168.1.151"]);
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
  assert.equal(u.searchParams.get("a"), "192.168.1.151");
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

test("account: a phone paired here joins the computer with its join key; the account's other devices come in by ticket, go when removed, and with the computer's leaving", async () => {
  const { randomBytes, generateKeyPairSync } = await import("node:crypto");
  const { existsSync, writeFileSync } = await import("node:fs");
  const t = await accountTesting();
  const r = svc.remote;
  // (no native addon here: the link key the link would make)
  if (!existsSync(join(home, "link-key"))) writeFileSync(join(home, "link-key"), randomBytes(32), { mode: 0o600 });
  const apple = new t.TestApple();
  const h = await t.harness({ oidc: false, apple, env: { ACCOUNT_APPLE_AUDIENCES: "com.example.remote", ACCOUNT_OPEN: "1" } });
  try {
    const phone = await t.appleSignIn(h, apple);
    const jk = await (await t.post(`${h.url}/v1/join-keys`, {}, t.bearer(phone.session))).json();
    const paired = { id: "phone-acct-1", name: "Phone" };
    assert.deepEqual((await r.accountRoute("GET /account", null, paired)).json, { account: null });
    // only a phone paired here may put it in an account
    assert.equal((await r.accountRoute("POST /account/join", { server: jk.server, key: jk.key }, paired)).status, 403);
    r.devices.startPairing();
    r.devices.pair(r.devices.pairingCode.code, paired.id, paired.name);
    assert.equal((await r.accountRoute("POST /account/join", { account: "0a".repeat(16) }, paired)).status, 400, "an older app's join");
    const joined = await r.accountRoute("POST /account/join", { server: jk.server, key: jk.key }, paired);
    assert.equal(joined.status, 200, JSON.stringify(joined.json));
    assert.equal(joined.json.account.id, phone.account.id);
    assert.equal(statSync(join(home, "account.json")).mode & 0o777, 0o600);
    assert.equal((await adminCall(home, "GET", "/remote")).json.account.account.id, phone.account.id);
    const linkId = r.account.linkKey().id;
    // what the app needs to dial it, in the account's list
    const listed = (await (await t.get(`${h.url}/v1/computers`, t.bearer(phone.session))).json()).computers[0];
    assert.equal(listed.linkId, linkId);
    assert.equal(listed.info.id, r.settings.serverId);
    assert.equal(listed.info.fp, r.identity.keyFingerprint);
    assert.equal(listed.info.platform, "linux");

    // another device of the account: a ticket → this computer's own token, bound to its link key
    const ipad = await t.appleSignIn(h, apple, { device: { name: "iPad", platform: "ios" } });
    const ticket = (await (await t.post(`${h.url}/v1/tickets`, { computer: linkId }, t.bearer(ipad.session))).json()).ticket;
    const clientKey = Buffer.from(generateKeyPairSync("ed25519").publicKey.export({ format: "jwk" }).x, "base64url").toString("hex");
    const hello = { hello: { device: { id: "ipad-device-01", name: "iPad" } }, clientKey };
    const ok = await r.account.redeem(ticket, hello, "test");
    assert.equal(ok.ok, true, JSON.stringify(ok));
    assert.equal(ok.principal.server.id, r.settings.serverId);
    assert.equal(r.devices.authenticateLink(ok.principal.token, clientKey).kind, "accepted");
    assert.equal(r.devices.list.find((d) => d.id === "ipad-device-01").account.dev, ipad.device.id);
    assert.equal((await r.account.redeem(ticket, hello, "test")).ok, false, "once");
    // one let in by the account may not move the computer
    assert.equal((await r.accountRoute("POST /account/leave", null, { id: "ipad-device-01", name: "iPad" })).status, 403);

    // removed from the account: out within the list's wait
    await fetch(`${h.url}/v1/devices/${ipad.device.id}`, { method: "DELETE", headers: t.bearer(phone.session) });
    const end = Date.now() + 10_000;
    while (r.devices.list.some((d) => d.id === "ipad-device-01") && Date.now() < end) await new Promise((res) => setTimeout(res, 50));
    assert.equal(r.devices.list.some((d) => d.id === "ipad-device-01"), false);

    // a second ticket device, then the computer leaves: it goes too; the paired phone stays
    const ipad2 = await t.appleSignIn(h, apple, { device: { name: "iPad 2", platform: "ios" } });
    const t2 = (await (await t.post(`${h.url}/v1/tickets`, { computer: linkId }, t.bearer(ipad2.session))).json()).ticket;
    assert.equal((await r.account.redeem(t2, { hello: { device: { id: "ipad-device-02", name: "iPad 2" } }, clientKey }, "test")).ok, true);
    const left = await adminCall(home, "POST", "/remote/account/leave");
    assert.equal(left.json.account.account, null);
    assert.deepEqual(r.devices.list.map((d) => d.id), [paired.id]);
    assert.equal((await (await t.get(`${h.url}/v1/computers`, t.bearer(phone.session))).json()).computers.length, 0);
    r.devices.remove(paired.id);
  } finally {
    await t.stopAll();
  }
});
