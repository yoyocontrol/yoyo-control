// An app's own way into an account server, without a web sign-in: the native Sign in with Apple (no IdP needed), the
// app's join key for a computer it is paired with, what a computer says of itself for the app (`info`), App Store
// purchases, and the account deleted from the app (its computers leave, its Apple grant revoked).
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, afterEach, test } from "node:test";
import { AccountMember, type ComputerSelf } from "@yoyocontrol/account";
import { configFromEnv, ConfigError } from "../src/config.js";
import { TestApple } from "../src/testing/apple.js";
import { appleSignIn, bearer, get, harness, linkKey, post, stopAll, type Harness, type LinkKey } from "../src/testing/harness.js";

const dirs: string[] = [];
const members: AccountMember[] = [];
afterEach(async () => {
  for (const m of members.splice(0)) m.stop();
  await stopAll();
});
after(() => {
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true });
});

const AUD = "com.example.remote";
const APPLE_ENV = { ACCOUNT_APPLE_AUDIENCES: AUD, ACCOUNT_OPEN: "1" };
const json = async (r: Response) => (await r.json()) as Record<string, any>;

async function appleHarness(o: { appleFetch?: typeof fetch; env?: Record<string, string> } = {}) {
  const apple = new TestApple();
  const h = await harness({ oidc: false, apple, env: { ...APPLE_ENV, ...o.env }, ...(o.appleFetch ? { appleFetch: o.appleFetch } : {}) });
  return { h, apple };
}

function member(h: Harness, k: LinkKey, info?: Record<string, unknown>) {
  const dir = mkdtempSync(join(tmpdir(), "account-apple-"));
  dirs.push(dir);
  const self: ComputerSelf = { linkId: k.id, name: "Studio", relays: [], direct: ["192.168.1.5:7840"], origins: [], ...(info ? { info } : {}) };
  const m = new AccountMember({ file: join(dir, "account.json"), self: () => self, sign: (id, t) => (id === k.id ? k.sign(t) : null), log: () => {}, timing: { waitS: 1, retryMinMs: 50, retryMaxMs: 200 } });
  members.push(m);
  return m;
}

async function until(what: string, ok: () => boolean, ms = 5_000) {
  const end = Date.now() + ms;
  while (!ok()) {
    if (Date.now() > end) throw new Error(`timed out: ${what}`);
    await new Promise((r) => setTimeout(r, 20));
  }
}

test("settings: Apple alone needs no IdP, but says anyone may sign in (ACCOUNT_OPEN or ACCOUNT_ALLOW); the revoke key goes whole", () => {
  const base = { ACCOUNT_PUBLIC_URL: "https://account.example.com", ACCOUNT_APPLE_AUDIENCES: AUD };
  assert.throws(() => configFromEnv(base), /lets anyone sign in/);
  const cfg = configFromEnv({ ...base, ACCOUNT_OPEN: "1" });
  assert.equal(cfg.oidc, false);
  assert.equal(cfg.issuer, "https://appleid.apple.com");
  assert.deepEqual(cfg.apple, { audiences: [AUD], client: null });
  assert.throws(() => configFromEnv({ ...base, ACCOUNT_OPEN: "1", ACCOUNT_APPLE_TEAM_ID: "ABCDE12345" }), ConfigError);
  assert.throws(() => configFromEnv({ ...base, ACCOUNT_OPEN: "1", ACCOUNT_APPSTORE_BUNDLE_ID: AUD }), /go together/);
  assert.deepEqual(configFromEnv({ ...base, ACCOUNT_OPEN: "1", ACCOUNT_APPSTORE_BUNDLE_ID: AUD, ACCOUNT_APPSTORE_PRODUCTS: "pro.monthly,pro.yearly" }).appstore, { bundleId: AUD, products: ["pro.monthly", "pro.yearly"] });
  // nothing of Apple without the audiences
  assert.throws(() => configFromEnv({ ACCOUNT_PUBLIC_URL: "https://account.example.com" }), /ACCOUNT_OIDC_ISSUER is needed/);
});

test("Sign in with Apple: the app's token → a device session; the same Apple ID is the same account; wrong ones refused", async () => {
  const { h, apple } = await appleHarness();
  const cfg = await json(await get(`${h.url}/v1/config`));
  assert.equal(cfg.signin.apple, true);
  assert.equal(cfg.signin.oidc, false);
  assert.equal((await get(`${h.url}/v1/signin?redirect_uri=x`)).status, 404);

  const s1 = await appleSignIn(h, apple, { name: "Alice Liddell", device: { name: "Alice's iPhone", platform: "ios" } });
  assert.match(s1.session, /^yoyo_as_/);
  assert.equal(s1.account.name, "Alice Liddell");
  const me = await json(await get(`${h.url}/v1/me`, bearer(s1.session)));
  assert.equal(me.account.iss, "https://appleid.apple.com");
  assert.equal(me.account.sub, "apple-alice");
  assert.deepEqual(me.entitlements, {});
  // a second phone of the same Apple ID (Apple gives the name only the first time: it stays)
  const s2 = await appleSignIn(h, apple, { device: { name: "iPad", platform: "ios" } });
  assert.equal(s2.account.id, s1.account.id);
  assert.equal(s2.account.name, "Alice Liddell");
  // somebody else: another account, named by the email when the app had no name
  const s3 = await appleSignIn(h, apple, { sub: "apple-bob", email: "bob@privaterelay.appleid.com" });
  assert.notEqual(s3.account.id, s1.account.id);
  assert.equal(s3.account.name, "bob@privaterelay.appleid.com");

  const nonce = "n-0123456789abcdef";
  const refused = async (body: Record<string, unknown>) => (await post(`${h.url}/v1/auth/apple`, body)).status;
  assert.equal(await refused({ identityToken: apple.token({ sub: "x", nonce, aud: "com.other.app" }), nonce }), 401);
  assert.equal(await refused({ identityToken: apple.token({ sub: "x", nonce, aud: AUD }), nonce: "another-nonce" }), 401);
  assert.equal(await refused({ identityToken: apple.token({ sub: "x", nonce, aud: AUD, exp: Math.floor(Date.now() / 1000) - 60 }), nonce }), 401);
  assert.equal(await refused({ identityToken: apple.token({ sub: "x", nonce, aud: AUD, iss: "https://evil.example.com" }), nonce }), 401);
  assert.equal(await refused({ identityToken: new TestApple().token({ sub: "x", nonce, aud: AUD }), nonce }), 401);
  assert.equal(await refused({ nonce }), 400);
});

test("an allow-list narrows Apple sign-ins too", async () => {
  const { h, apple } = await appleHarness({ env: { ACCOUNT_OPEN: "", ACCOUNT_ALLOW: "apple-alice" } });
  await appleSignIn(h, apple);
  await assert.rejects(appleSignIn(h, apple, { sub: "apple-bob" }), /403/);
});

test("the app's join key: a computer it is paired with joins by itself, says what the app needs (info), and takes the account's tickets", async () => {
  const { h, apple } = await appleHarness();
  const phone = await appleSignIn(h, apple);
  const r = await post(`${h.url}/v1/join-keys`, {}, bearer(phone.session));
  assert.equal(r.status, 200);
  const jk = await json(r);
  assert.match(jk.key, /^yoyo_jk_/);
  assert.equal(jk.server, h.url);

  const k = linkKey();
  const info = { id: "server-1", platform: "mac", fp: `sha256:${"ab".repeat(32)}` };
  const m = member(h, k, info);
  await m.joinWithKey(jk.server, jk.key);
  m.start();
  // one use
  await assert.rejects(member(h, linkKey()).joinWithKey(jk.server, jk.key), /refused the key/);

  const list = await json(await get(`${h.url}/v1/computers`, bearer(phone.session)));
  assert.equal(list.computers.length, 1);
  assert.deepEqual(list.computers[0].info, info);
  assert.deepEqual(list.computers[0].direct, ["192.168.1.5:7840"]);
  // a second phone of the account sees it and gets in
  const ipad = await appleSignIn(h, apple, { device: { name: "iPad", platform: "ios" } });
  const t = await json(await post(`${h.url}/v1/tickets`, { computer: k.id }, bearer(ipad.session)));
  const claims = await m.redeem(t.ticket);
  assert.equal(claims.sub, phone.account.id);
  assert.equal(claims.dev.id, ipad.device.id);
});

test("join keys: an app's own (not a web page's), a few at a time; info is a small object", async () => {
  const { h, apple } = await appleHarness();
  const phone = await appleSignIn(h, apple);
  for (let i = 0; i < 16; i++) assert.equal((await post(`${h.url}/v1/join-keys`, {}, bearer(phone.session))).status, 200);
  assert.equal((await post(`${h.url}/v1/join-keys`, {}, bearer(phone.session))).status, 429);
  assert.equal((await post(`${h.url}/v1/join-keys`, {})).status, 401);

  const k = linkKey();
  const big = { blob: "x".repeat(3000) };
  const key = h.store.createJoinKey(phone.account.id, 2, Date.now() + 60_000, Date.now());
  await assert.rejects(member(h, k, big).joinWithKey(h.url, key), /refused the key \(invalid_request\)/);
  await member(h, k, { platform: "linux" }).joinWithKey(h.url, key);
  assert.deepEqual(JSON.parse(h.store.computer(k.id)!.info!), { platform: "linux" });
});

test("App Store purchases: Apple's transaction of this app's product is the reporting account's; another product is refused", async () => {
  const { h, apple } = await appleHarness({ env: { ACCOUNT_APPSTORE_BUNDLE_ID: AUD, ACCOUNT_APPSTORE_PRODUCTS: "pro.monthly,pro.yearly" } });
  const alice = await appleSignIn(h, apple);
  const later = Date.now() + 30 * 86_400_000;
  const jws = apple.transaction({ bundleId: AUD, productId: "pro.yearly", originalTransactionId: "1000", expiresDate: later, environment: "Sandbox" });
  const r = await json(await post(`${h.url}/v1/entitlements/appstore`, { jws }, bearer(alice.session)));
  assert.deepEqual(r.entitlements.appstore, { active: true, productId: "pro.yearly", expiresAt: later, sandbox: true });
  assert.deepEqual((await json(await get(`${h.url}/v1/me`, bearer(alice.session)))).entitlements.appstore.active, true);

  const bad = async (t: Parameters<TestApple["transaction"]>[0]) => (await post(`${h.url}/v1/entitlements/appstore`, { jws: apple.transaction(t) }, bearer(alice.session))).status;
  assert.equal(await bad({ bundleId: "com.other", productId: "pro.yearly", originalTransactionId: "2", environment: "Production" }), 400);
  assert.equal(await bad({ bundleId: AUD, productId: "other", originalTransactionId: "3", environment: "Production" }), 400);
  assert.equal((await post(`${h.url}/v1/entitlements/appstore`, { jws: "a.b.c" }, bearer(alice.session))).status, 400);

  // a family member's phone signed into another account reports the same purchase: it is that account's now
  const bob = await appleSignIn(h, apple, { sub: "apple-bob" });
  await post(`${h.url}/v1/entitlements/appstore`, { jws }, bearer(bob.session));
  assert.equal((await json(await get(`${h.url}/v1/me`, bearer(bob.session)))).entitlements.appstore.active, true);
  assert.equal((await json(await get(`${h.url}/v1/me`, bearer(alice.session)))).entitlements.appstore, undefined);
  // expired, or refunded: not active
  const gone = apple.transaction({ bundleId: AUD, productId: "pro.monthly", originalTransactionId: "1000", expiresDate: later, revocationDate: Date.now(), environment: "Production" });
  assert.equal((await json(await post(`${h.url}/v1/entitlements/appstore`, { jws: gone }, bearer(bob.session)))).entitlements.appstore.active, false);
});

test("deleting the account from the app: its computers leave, its devices are out, the Apple grant revoked; signing in again is a new account", async () => {
  const calls: string[] = [];
  const appleFetch = (async (url: string | URL | Request, init?: RequestInit) => {
    calls.push(`${String(url)} ${new URLSearchParams(String(init?.body)).get("grant_type") ?? "revoke"}`);
    const idToken = `x.${Buffer.from(JSON.stringify({ sub: "apple-alice" })).toString("base64url")}.y`;
    return new Response(JSON.stringify(String(url).endsWith("/token") ? { refresh_token: "r", id_token: idToken } : {}), { status: 200 });
  }) as typeof fetch;
  const { generateKeyPairSync } = await import("node:crypto");
  const pem = generateKeyPairSync("ec", { namedCurve: "P-256" }).privateKey.export({ format: "pem", type: "pkcs8" }).toString();
  const { h, apple } = await appleHarness({ appleFetch, env: { ACCOUNT_APPLE_TEAM_ID: "TEAM123456", ACCOUNT_APPLE_KEY_ID: "KEY1234567", ACCOUNT_APPLE_KEY: Buffer.from(pem).toString("base64") } });
  const phone = await appleSignIn(h, apple);
  const jk = await json(await post(`${h.url}/v1/join-keys`, {}, bearer(phone.session)));
  const m = member(h, linkKey());
  await m.joinWithKey(jk.server, jk.key);
  m.start();
  await until("the first list", () => m.current()?.synced === true);

  const r = await json(await fetch(`${h.url}/v1/me`, { method: "DELETE", headers: { ...bearer(phone.session), "content-type": "application/json" }, body: JSON.stringify({ authorizationCode: "c-123" }) }));
  assert.deepEqual(r, { ok: true, revoked: true });
  assert.deepEqual(calls, ["https://appleid.apple.com/auth/token authorization_code", "https://appleid.apple.com/auth/revoke revoke"]);
  await until("the computer left", () => m.current() === null);
  assert.equal((await get(`${h.url}/v1/me`, bearer(phone.session))).status, 401);
  const again = await appleSignIn(h, apple);
  assert.notEqual(again.account.id, phone.account.id);
});
