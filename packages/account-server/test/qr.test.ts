// Sign-in by QR code (docs/ACCOUNT-LIB.md「扫码登录」): a new device asks with its key, a signed-in app or web page
// looks the code up and approves (or declines), the new device polls for its key-bound session — once; codes expire,
// are one-use, wrong ones are counted; starts and polls are limited; a removed approver approves nothing.
import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { after, afterEach, test } from "node:test";
import { HOSTED_SESSION_MAX_AGE_MS, QR_SIGNIN_TTL_MS } from "../src/service.js";
import { appSignIn, bearer, get, harness, hostedProofText, post, stopAll, type Harness } from "../src/testing/harness.js";

afterEach(stopAll);
after(stopAll);

const json = async (r: Response) => (await r.json()) as Record<string, any>;

function deviceKey() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const raw = (publicKey.export({ format: "jwk" }) as { x: string }).x;
  return {
    raw,
    proof: (server: string, method: string, pathQ: string, body = "") => {
      const ts = Math.floor(Date.now() / 1000);
      const hash = createHash("sha256").update(body).digest("base64url");
      return `${ts}.${hash}.${sign(null, Buffer.from(hostedProofText(server, method, pathQ, ts, hash)), privateKey).toString("base64url")}`;
    },
  };
}

async function start(h: Harness, device: Record<string, unknown>, headers: Record<string, string> = {}) {
  const r = await post(`${h.url}/v1/auth/qr`, { device }, headers);
  return { status: r.status, body: await json(r) };
}
const poll = async (h: Harness, request: string) => {
  const r = await post(`${h.url}/v1/auth/qr/poll`, { request });
  return { status: r.status, body: await json(r) };
};

test("a browser signs in by QR: the app looks the code up, approves, the browser's poll gets a 30-day session bound to its key, once", async () => {
  const h = await harness({ env: { ACCOUNT_WEB_REDIRECTS: "https://web.example.com/account" } });
  const app = await appSignIn(h);
  const k = deviceKey();
  // no key: nothing (the session is bound to one)
  assert.equal((await start(h, { name: "Chrome on Windows" })).status, 400);
  assert.equal((await start(h, { name: "x", key: "short" })).status, 400);
  const s = await start(h, { name: "Chrome on Windows", platform: "web", key: k.raw }, { origin: "https://web.example.com" });
  assert.equal(s.status, 200);
  assert.match(s.body.request, /^[A-Za-z0-9_-]{43}$/);
  assert.match(s.body.code, /^[BCDFGHJKLMNPQRSTVWXZ]{8}$/);
  assert.equal(s.body.user_code, `${s.body.code.slice(0, 4)}-${s.body.code.slice(4)}`);
  assert.equal(s.body.expires_in, QR_SIGNIN_TTL_MS / 1000);
  assert.equal((await json(await get(`${h.url}/v1/config`))).signin.qr, true);
  // waiting
  assert.equal((await poll(h, s.body.request)).body.error, "authorization_pending");
  // too soon after the last poll
  assert.equal((await poll(h, s.body.request)).body.error, "slow_down");
  // the app sees what asks, from where, then approves (the code typed in lower case with its dash is the same code)
  const look = await get(`${h.url}/v1/auth/qr/lookup?code=${s.body.user_code.toLowerCase()}`, bearer(app.session));
  assert.equal(look.status, 200);
  const l = await json(look);
  assert.deepEqual(l.device, { name: "Chrome on Windows", platform: "web" });
  assert.equal(l.from, "127.0.0.1");
  assert.equal(l.status, "pending");
  assert.equal(l.account.id, app.account.id);
  assert.ok(l.expiresIn > 100 && l.expiresIn <= 150);
  const ap = await post(`${h.url}/v1/auth/qr/approve`, { code: s.body.user_code }, bearer(app.session));
  assert.equal(ap.status, 200);
  assert.equal((await json(ap)).device.name, "Chrome on Windows");
  // once
  assert.equal((await post(`${h.url}/v1/auth/qr/approve`, { code: s.body.code }, bearer(app.session))).status, 409);
  h.clock.t = Date.now() + 2_000;
  const done = await poll(h, s.body.request);
  h.clock.t = null;
  assert.equal(done.status, 200);
  assert.equal(done.body.proof, "yoyo-hosted-v1");
  assert.equal(done.body.account.id, app.account.id);
  assert.ok(Math.abs(done.body.expiresAt - (Date.now() + 2_000 + HOSTED_SESSION_MAX_AGE_MS)) < 5_000);
  // the session needs the key's proof: the token alone is nothing
  assert.equal((await get(`${h.url}/v1/me`, bearer(done.body.session))).status, 401);
  const me = await get(`${h.url}/v1/me`, { ...bearer(done.body.session), "yoyo-proof": k.proof(h.url, "GET", "/v1/me") });
  assert.equal(me.status, 200);
  // one session from one code: the poll and the code are used up
  assert.equal((await poll(h, s.body.request)).body.error, "invalid_grant");
  assert.equal((await get(`${h.url}/v1/auth/qr/lookup?code=${s.body.code}`, bearer(app.session))).status, 404);
  // the new device is in the account's list, and the app can remove it
  const devices = (await json(await get(`${h.url}/v1/devices`, bearer(app.session)))).devices as { id: string; name: string; platform: string }[];
  const web = devices.find((d) => d.id === done.body.device.id)!;
  assert.deepEqual([web.name, web.platform], ["Chrome on Windows", "web"]);
  const rm = await fetch(`${h.url}/v1/devices/${web.id}`, { method: "DELETE", headers: bearer(app.session) });
  assert.equal(rm.status, 200);
  assert.equal((await get(`${h.url}/v1/me`, { ...bearer(done.body.session), "yoyo-proof": k.proof(h.url, "GET", "/v1/me") })).status, 401);
  // the logs carry no code, no request, no token
  for (const line of h.logs) for (const secret of [s.body.code, s.body.request, done.body.session]) assert.ok(!line.includes(secret), line);
});

test("a signed-in web page approves too (with its key's proof); the same key signs in again as the same device; a desktop's platform is kept", async () => {
  const h = await harness({ env: { ACCOUNT_WEB_REDIRECTS: "https://web.example.com/account" } });
  const app = await appSignIn(h);
  // the first browser, by the app
  const k1 = deviceKey();
  const s1 = await start(h, { name: "Safari", key: k1.raw });
  await post(`${h.url}/v1/auth/qr/approve`, { code: s1.body.code }, bearer(app.session));
  const web1 = (await poll(h, s1.body.request)).body;
  // the second device, a desktop client, approved by that browser
  const k2 = deviceKey();
  const s2 = await start(h, { name: "Desktop", platform: "windows", key: k2.raw });
  const body = JSON.stringify({ code: s2.body.code });
  const as = (method: string, pathQ: string, b = "") => ({ ...bearer(web1.session), "yoyo-proof": k1.proof(h.url, method, pathQ, b) });
  // without the proof: no
  assert.equal((await post(`${h.url}/v1/auth/qr/approve`, body, bearer(web1.session))).status, 401);
  const look = await get(`${h.url}/v1/auth/qr/lookup?code=${s2.body.code}`, as("GET", `/v1/auth/qr/lookup?code=${s2.body.code}`));
  assert.equal((await json(look)).device.platform, "windows");
  assert.equal((await post(`${h.url}/v1/auth/qr/approve`, body, as("POST", "/v1/auth/qr/approve", body))).status, 200);
  const desk = (await poll(h, s2.body.request)).body;
  assert.ok(desk.session);
  const devices = (await json(await get(`${h.url}/v1/devices`, bearer(app.session)))).devices as { id: string; platform: string }[];
  assert.equal(devices.find((d) => d.id === desk.device.id)?.platform, "windows");
  // the first browser's key again: the same device
  const s3 = await start(h, { name: "Safari", key: k1.raw });
  await post(`${h.url}/v1/auth/qr/approve`, { code: s3.body.code }, bearer(app.session));
  assert.equal((await poll(h, s3.body.request)).body.device.id, web1.device.id);
});

test("declined, expired, unknown: the poll says so; nobody signed in approves nothing", async () => {
  const h = await harness();
  const app = await appSignIn(h);
  const s = await start(h, { name: "B", key: deviceKey().raw });
  assert.equal((await post(`${h.url}/v1/auth/qr/decline`, { code: s.body.code }, bearer(app.session))).status, 200);
  assert.equal((await poll(h, s.body.request)).body.error, "access_denied");
  assert.equal((await post(`${h.url}/v1/auth/qr/approve`, { code: s.body.code }, bearer(app.session))).status, 404);
  // unknown request
  assert.equal((await poll(h, "A".repeat(43))).status, 400);
  // expired: neither looked up nor polled
  const e = await start(h, { name: "B", key: deviceKey().raw });
  h.clock.t = Date.now() + QR_SIGNIN_TTL_MS + 1_000;
  assert.equal((await get(`${h.url}/v1/auth/qr/lookup?code=${e.body.code}`, bearer(app.session))).status, 404);
  assert.equal((await poll(h, e.body.request)).body.error, "expired_token");
  h.clock.t = null;
  // nobody signed in: no lookup, no approval
  const r = await start(h, { name: "B", key: deviceKey().raw });
  assert.equal((await get(`${h.url}/v1/auth/qr/lookup?code=${r.body.code}`)).status, 401);
  assert.equal((await post(`${h.url}/v1/auth/qr/approve`, { code: r.body.code })).status, 401);
});

test("an approver removed before the new device polls approves nothing", async () => {
  const h = await harness();
  const app = await appSignIn(h);
  // approved by a device that is removed before the new one polls: refused
  const other = await appSignIn(h, { device: { name: "Old iPad", platform: "ipados" } });
  const r = await start(h, { name: "B", key: deviceKey().raw });
  assert.equal((await post(`${h.url}/v1/auth/qr/approve`, { code: r.body.code }, bearer(other.session))).status, 200);
  assert.equal((await fetch(`${h.url}/v1/devices/${other.device.id}`, { method: "DELETE", headers: bearer(app.session) })).status, 200);
  assert.equal((await poll(h, r.body.request)).body.error, "access_denied");
});

test("limits: starts per address, open ones per address, wrong codes per session, polls per address", async () => {
  const h = await harness({ limits: { qrBurst: 3, qrOpenPerAddress: 2, codeFailuresPerSession: 3, qrPollBurst: 4, qrPollEveryMs: 60_000 } });
  const app = await appSignIn(h);
  const a = await start(h, { name: "B", key: deviceKey().raw });
  const b = await start(h, { name: "B", key: deviceKey().raw });
  assert.deepEqual([a.status, b.status], [200, 200]);
  // two open from here: a third waits
  const c = await start(h, { name: "B", key: deviceKey().raw });
  assert.equal(c.status, 429);
  // three a burst: the fourth is over the rate whatever is open
  assert.equal((await start(h, { name: "B", key: deviceKey().raw })).status, 429);
  // wrong codes: three, then the session waits even for the right one
  for (let i = 0; i < 3; i++) assert.equal((await get(`${h.url}/v1/auth/qr/lookup?code=BBBBBBBB`, bearer(app.session))).status, 404);
  const blocked = await get(`${h.url}/v1/auth/qr/lookup?code=${a.body.code}`, bearer(app.session));
  assert.equal(blocked.status, 429);
  assert.ok(Number(blocked.headers.get("retry-after")) > 0);
  // polls: four, then 429
  const codes: number[] = [];
  for (let i = 0; i < 5; i++) codes.push((await post(`${h.url}/v1/auth/qr/poll`, { request: a.body.request })).status);
  assert.deepEqual(codes, [400, 400, 400, 400, 429]);
});
