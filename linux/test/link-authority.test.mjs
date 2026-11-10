// uu Link without remote access (link.mjs authority mode, server.mjs startHeadlessLink): the token listener's client is
// the link's authority — `GET /link/authority`, `POST /link/authority/answer`, `POST /link/control` — and a real link
// client dials it (the native addon: vendor/link finds the repository's link/target build, or YOYO_LINK_NATIVE;
// skipped without one). The binding and its fingerprint in /status, no host = busy, the host's refusal, input only for
// the holder it names, control requests and session / activity lines to the host, RPC limited to /status, the keys
// kept across restarts.
import assert from "node:assert/strict";
import { mkdtempSync, statSync } from "node:fs";
import { request } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";
import { LinkAuthority, authorityDevice, loadLink } from "../link.mjs";
import { YoyoLinux, startHeadlessLink } from "../server.mjs";
import { fakeSpawn } from "./fakes.mjs";

const { L } = await loadLink();
const skip = L ? false : "no uu Link native addon (cd link && cargo build -p uu-link-node)";

const TOKEN = "t".repeat(32);
const fake = fakeSpawn();
const lines = [];
const log = (l) => lines.push(l);
const home = join(mkdtempSync(join(tmpdir(), "yoyo-link-auth-")), "link");
let svc;
let port;
let client;

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

/** One request to the token listener: `{ status, json }`. */
function call(method, path, body, token = TOKEN) {
  return new Promise((resolve, reject) => {
    const data = body === undefined ? null : Buffer.from(JSON.stringify(body));
    const req = request({ host: "127.0.0.1", port, method, path, headers: { authorization: `Bearer ${token}`, ...(data ? { "content-type": "application/json", "content-length": data.length } : {}) } }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const text = Buffer.concat(chunks).toString();
        resolve({ status: res.statusCode, json: text ? JSON.parse(text) : null });
      });
    });
    req.on("error", reject);
    req.end(data);
  });
}

/** The host's channel: its lines as they come (`next(type)`), `close()`. */
function host() {
  return new Promise((resolve, reject) => {
    const got = [];
    const waiters = [];
    const req = request({ host: "127.0.0.1", port, method: "GET", path: "/link/authority", headers: { authorization: `Bearer ${TOKEN}` } }, (res) => {
      let rest = "";
      res.setEncoding("utf8");
      res.on("data", (c) => {
        rest += c;
        let nl;
        while ((nl = rest.indexOf("\n")) >= 0) {
          const line = rest.slice(0, nl).trim();
          rest = rest.slice(nl + 1);
          if (!line) continue;
          got.push(JSON.parse(line));
          for (const w of waiters.splice(0)) w();
        }
      });
      resolve({
        status: res.statusCode,
        lines: got,
        async next(type, ms = 3000) {
          const t0 = Date.now();
          for (;;) {
            const i = got.findIndex((l) => l.type === type);
            if (i >= 0) return got.splice(i, 1)[0];
            if (Date.now() - t0 > ms) throw new Error(`no ${type} line`);
            await Promise.race([new Promise((r) => waiters.push(r)), sleep(50)]);
          }
        },
        close: () => req.destroy(),
      });
    });
    req.on("error", reject);
    req.end();
  });
}

before(async () => {
  if (skip) return;
  svc = new YoyoLinux({ token: TOKEN, name: "Desktop", spawnFn: fake.spawn, logLine: log, maxFps: 60 });
  port = (await svc.listen(0, "127.0.0.1")).port;
  // --link-relay off: no connection to the real relay from a test
  await startHeadlessLink(svc, ["--link", "on", "--link-home", home, "--link-port", "0", "--link-relay", "off", "--advertise", "192.168.50.151:47900"], { log });
  client = await L.bindEndpoint({ role: "client", secretKey: L.generateLinkKey() });
});
after(async () => {
  if (process.env.LINK_TEST_LOG) console.log(lines.join("\n"));
  await client?.close();
  await svc?.link?.stop();
  svc?.close();
});

const hello = (credential, id = "phone-0001") => ({ credential, device: { id, name: "Test iPhone" }, app: { name: "test", version: "1" }, features: ["screen"] });
const dial = (credential, id) => {
  const l = svc.link.json();
  return client.dial({ id: l.id, direct: [`127.0.0.1:${l.port}`] }, hello(credential, id));
};
async function nextControl(s, t, ms = 3000) {
  for (;;) {
    const m = await Promise.race([s.recvControl(), sleep(ms).then(() => null)]);
    if (!m) throw new Error(`no ${t}`);
    if (m.t === t) return m;
  }
}
/** The host's answers: `credential` → principal device `id` (others: unauthorized). */
function answering(h, tickets) {
  let on = true;
  void (async () => {
    while (on) {
      let a;
      try {
        a = await h.next("auth", 500);
      } catch {
        continue;
      }
      const id = tickets[a.credential];
      await call("POST", "/link/authority/answer", id ? { id: a.id, ok: true, principal: { device: { id, name: a.device.name } } } : { id: a.id, ok: false, code: "unauthorized", message: "unknown ticket" });
    }
  })();
  return () => (on = false);
}

test("authorityDevice and the authority's answers, holder and refusals", () => {
  assert.deepEqual(authorityDevice({ id: "a" }), { id: "a", name: "a" });
  assert.equal(authorityDevice({ id: "" }), null);
  assert.equal(authorityDevice(null), null);
  const a = new LinkAuthority({ timeoutMs: 50 });
  assert.deepEqual(a.admitInput({ id: "a" }).code, "no-control");
  a.setHolder({ id: "b", name: "B" });
  const r = a.admitInput({ id: "a" });
  assert.equal(r.code, "controlled-elsewhere");
  assert.deepEqual(r.controllerDevice, { id: "b", name: "B" });
  assert.equal(a.admitInput({ id: "b" }), null);
  assert.throws(() => a.answer({ id: "x" }), /body must be/);
  assert.throws(() => a.answer({ id: "x", ok: false, code: "nope" }), /code must be/);
  assert.throws(() => a.answer({ id: "x", ok: true, principal: {} }), /principal must be/);
  assert.throws(() => a.answer({ id: "x", ok: false }), (e) => e.status === 404);
});

test("/status has the binding with its fingerprint; the keys are 0600 in a 0700 folder", { skip }, async () => {
  const st = (await call("GET", "/status")).json;
  assert.match(st.link.id, /^[0-9a-f]{64}$/);
  assert.match(st.link.fingerprint, /^sha256:[0-9a-f]{64}$/);
  assert.equal(L.verifyBinding(st.link, st.link.fingerprint), st.link.id);
  assert.ok(st.link.direct.includes("192.168.50.151:47900"), st.link.direct.join(","));
  assert.equal(st.features.link, true);
  assert.equal(statSync(home).mode & 0o777, 0o700);
  for (const f of ["link-key", "tls-key.der"]) assert.equal(statSync(join(home, f)).mode & 0o077, 0, f);
});

test("the authority routes: the token listener only; one host at a time; bad bodies", { skip }, async () => {
  assert.equal((await call("GET", "/link/authority", undefined, "x".repeat(32))).status, 401);
  assert.equal((await call("POST", "/link/control", { nope: 1 })).status, 400);
  assert.equal((await call("POST", "/link/control", { holder: { name: "x" } })).status, 400);
  assert.equal((await call("POST", "/link/authority/answer", { id: "missing", ok: false })).status, 404);
  // a paired phone (remote access's client) never reaches them
  const res = { headersSent: false, writeHead() {}, end() {} };
  let status;
  res.writeHead = (s) => (status = s);
  await svc.handle({ method: "GET", url: "/link/authority", headers: {} }, res, { kind: "remote", device: { id: "d", name: "d" } });
  assert.equal(status, 404);
  const h = await host();
  assert.equal(h.status, 200);
  assert.equal((await call("GET", "/link/authority")).status, 409);
  h.close();
  await until(() => !svc.linkAuthority.hasHost);
});

test("no host: busy; the host's refusal: unauthorized; its principal in welcome", { skip }, async () => {
  await assert.rejects(dial("Bearer ticket-1"), (e) => e.kind === "denied" && e.code === "busy");
  const h = await host();
  const stop = answering(h, { "Bearer ticket-1": "phone-0001" });
  try {
    await assert.rejects(dial("Bearer wrong"), (e) => e.kind === "denied" && e.code === "unauthorized");
    const s = await dial("Bearer ticket-1");
    assert.equal(s.welcome.server.platform, "linux");
    assert.deepEqual(s.principal, { device: { id: "phone-0001", name: "Test iPhone" } });
    const opened = await h.next("session");
    assert.equal(opened.event, "opened");
    assert.equal(opened.device.id, "phone-0001");
    // RPC: /status only
    const st = await s.request({ method: "GET", path: "/status" });
    assert.equal(st.status, 200);
    assert.equal((await st.json()).platform, "linux");
    assert.equal((await s.request({ method: "GET", path: "/clipboard" })).status, 404);
    assert.equal((await s.request({ method: "GET", path: "/events" })).status, 404);
    await s.close();
    assert.equal((await h.next("session")).event, "closed");
  } finally {
    stop();
    h.close();
    await until(() => !svc.linkAuthority.hasHost);
  }
});

test("input: only for the holder the host names; control requests go to the host; activity lines", { skip }, async () => {
  const h = await host();
  const stop = answering(h, { "Bearer ticket-1": "phone-0001", "Bearer ticket-2": "phone-0002" });
  const s = await dial("Bearer ticket-1");
  try {
    const n = fake.state.xdotool.length;
    const seq = s.sendInput("discrete", { type: "click", x: 0.5, y: 0.5 });
    const r = await nextControl(s, "input.rejected");
    assert.equal(r.seq, seq);
    assert.equal(r.code, "no-control");
    // a take goes to the host, which gives it: the reply carries the rid
    await s.sendControl({ t: "control.take", rid: 7 });
    const want = await h.next("control");
    assert.equal(want.want, "take");
    assert.equal(want.device.id, "phone-0001");
    assert.deepEqual((await call("POST", "/link/control", { holder: { id: "phone-0001", name: "Test iPhone" } })).json, { ok: true, holder: { id: "phone-0001", name: "Test iPhone" } });
    const c = await nextControl(s, "control");
    assert.equal(c.granted, true);
    assert.equal(c.rid, 7);
    s.sendInput("discrete", { type: "click", x: 0.5, y: 0.5 });
    await until(() => fake.state.xdotool.length > n);
    assert.equal((await h.next("activity")).device.id, "phone-0001");
    // another phone holds it now: controlled-elsewhere
    await call("POST", "/link/control", { holder: { id: "phone-0002", name: "Other" } });
    const c2 = await nextControl(s, "control");
    assert.equal(c2.granted, false);
    assert.deepEqual(c2.holder, { id: "phone-0002", name: "Other" });
    s.sendInput("discrete", { type: "click", x: 0.5, y: 0.5 });
    const r2 = await nextControl(s, "input.rejected");
    assert.equal(r2.code, "controlled-elsewhere");
    assert.deepEqual(r2.controllerDevice, { id: "phone-0002", name: "Other" });
    // a release the host ignores is answered after the timeout with the holder as it is
    await s.sendControl({ t: "control.release", rid: "r" });
    const c3 = await nextControl(s, "control", 5000);
    assert.equal(c3.rid, "r");
    assert.equal(c3.granted, false);
    // the token listener's own input is not the link's business
    const before = fake.state.xdotool.length;
    assert.equal((await call("POST", "/input", { type: "click", x: 0.1, y: 0.1 })).status, 200);
    await until(() => fake.state.xdotool.length > before);
  } finally {
    stop();
    await s.close();
    h.close();
    await until(() => !svc.linkAuthority.hasHost);
  }
  // the host gone: nobody holds control
  assert.equal(svc.linkAuthority.holder, null);
});

test("video over the authority-mode link: a key frame first", { skip }, async () => {
  const h = await host();
  const stop = answering(h, { "Bearer ticket-1": "phone-0001" });
  const s = await dial("Bearer ticket-1");
  try {
    s.openVideo(1);
    await s.sendControl({ t: "video.open", id: 1, query: "display=1&fps=30&cursor=client" });
    const opened = await nextControl(s, "video.opened");
    assert.equal(opened.codec, "h264");
    for (;;) {
      const e = await Promise.race([s.nextClientEvent(), sleep(3000).then(() => null)]);
      assert.ok(e, "no frame");
      if (e.type !== "frame") continue;
      assert.equal(e.frame.meta.kind, "key");
      break;
    }
  } finally {
    stop();
    await s.close();
    h.close();
  }
});

test("the keys survive a restart: the same binding id and fingerprint", { skip }, async () => {
  const before = svc.link.json();
  const other = new YoyoLinux({ token: TOKEN, name: "Desktop", spawnFn: fake.spawn, logLine: log });
  const link = await startHeadlessLink(other, ["--link", "on", "--link-home", home, "--link-port", "0", "--link-relay", "off"], { log });
  try {
    const j = link.json();
    assert.equal(j.id, before.id);
    assert.equal(j.fingerprint, before.fingerprint);
  } finally {
    await link.stop();
    other.close();
  }
});

test("--link on without --remote needs --link-home", async () => {
  const other = new YoyoLinux({ token: TOKEN, spawnFn: fake.spawn, logLine: log });
  try {
    await assert.rejects(startHeadlessLink(other, ["--link", "on"], { log }), /--link-home/);
  } finally {
    other.close();
  }
});
