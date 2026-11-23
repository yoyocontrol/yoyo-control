// The account server over HTTP, against a stand-in IdP: sign-in (redirects, PKCE, one-time codes and states, the
// allow-list, tombstones, disabled accounts, IdP errors), sessions (max age, sign-out, bad tokens), computers and
// tickets (only the account's own; a ticket for A refused on B), the join code (the whole way, brute force, expiry,
// approval races, the expected account, the computer's own confirmation), revocations (list, notices), a member
// computer's signed requests, the browser approval page, a computer page's ticket return, limits, and the logs.
import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { after, afterEach, test } from "node:test";
import { removeAccount, disableAccount, clearTombstone, runAdmin } from "../src/admin.js";
import { APP_CODE_TTL_MS, JOIN_TTL_MS, SESSION_MAX_AGE_MS, HOSTED_SESSION_MAX_AGE_MS, normCode, validCode, newCode, CODE_ALPHABET } from "../src/service.js";
import { ReplayCache, RevocationView, verifyRevocationList, verifyServiceToken, verifyTicket, TicketError, SERVICE_TTL_S, signTicket } from "../src/ticket.js";
import type { AccountConfig } from "../src/config.js";
import type { PublicJwk } from "../src/keys.js";
import { configFromEnv } from "../src/config.js";
import { hostedProofText, joinKeyProofText, PUSH_SERVICE, SPEECH_SERVICE } from "../src/testing/harness.js";
import { appSignIn, bearer, computerCall, confirm, enroll, get, harness, joinComputer, linkKey, pkce, post, stopAll, throughIdp } from "../src/testing/harness.js";

afterEach(stopAll);
after(stopAll);

const json = async (r: Response) => (await r.json()) as Record<string, any>;

// ----------------------------------------------------------------------------- sign-in

test("an app signs in: code + PKCE through the IdP, back to its redirect, then a 90-day device session", async () => {
  const h = await harness();
  const s = await appSignIn(h);
  assert.match(s.session, /^yoyo_as_/);
  assert.equal(s.account.name, "Alice");
  assert.ok(Math.abs(s.expiresAt - (Date.now() + SESSION_MAX_AGE_MS)) < 5_000);
  const me = await json(await get(`${h.url}/v1/me`, bearer(s.session)));
  assert.equal(me.account.sub, "u-alice");
  assert.equal(me.account.iss, h.idp.issuer);
  // the IdP was asked the standard way: code, S256, a nonce, openid profile — no offline_access while re-check is off
  const a = h.idp.authorizeRequests[0]!;
  assert.equal(a.get("response_type"), "code");
  assert.equal(a.get("code_challenge_method"), "S256");
  assert.ok(a.get("nonce"));
  assert.equal(a.get("scope"), "openid profile");
  assert.equal(a.get("redirect_uri"), `${h.url}/v1/callback`);
  // the same person again: the same account
  const s2 = await appSignIn(h, { device: { name: "iPad" } });
  assert.equal(s2.account.id, s.account.id);
  assert.notEqual(s2.device.id, s.device.id);
});

test("the app's state comes back; prompt=login is passed on; the https app-return redirect is always allowed", async () => {
  const h = await harness();
  const { challenge } = pkce();
  const r = await throughIdp(h, { redirect_uri: `${h.url}/v1/app-return`, state: "xyz", code_challenge: challenge, code_challenge_method: "S256", prompt: "login" });
  const back = new URL(r.location);
  assert.equal(back.origin + back.pathname, `${h.url}/v1/app-return`);
  assert.equal(back.searchParams.get("state"), "xyz");
  assert.ok(back.searchParams.get("code"));
  assert.equal(r.authorize!.get("prompt"), "login");
  // an unknown prompt is refused
  const bad = await get(`${h.url}/v1/signin?redirect_uri=example://account&code_challenge=${challenge}&code_challenge_method=S256&prompt=none`);
  assert.equal(bad.status, 400);
});

test("an unregistered redirect is refused without a redirect; PKCE is required", async () => {
  const h = await harness();
  const { challenge } = pkce();
  for (const redirect of ["https://evil.example.net/cb", "example://account/../x", "example://accountx", `${h.url}/v1/app-return/x`]) {
    const r = await get(`${h.url}/v1/signin?redirect_uri=${encodeURIComponent(redirect)}&code_challenge=${challenge}&code_challenge_method=S256`);
    assert.equal(r.status, 400, redirect);
    assert.equal(r.headers.get("location"), null);
  }
  assert.equal((await get(`${h.url}/v1/signin?redirect_uri=example://account&code_challenge=${challenge}&code_challenge_method=plain`)).status, 400);
  assert.equal((await get(`${h.url}/v1/signin?redirect_uri=example://account`)).status, 400);
  assert.equal(h.idp.authorizeRequests.length, 0);
});

test("a sign-in code: once, with its own verifier, within 60 s", async () => {
  const h = await harness();
  const { verifier, challenge } = pkce();
  const code = async () => new URL((await throughIdp(h, { redirect_uri: "example://account", code_challenge: challenge, code_challenge_method: "S256" })).location).searchParams.get("code")!;
  // a wrong verifier burns the code
  const c1 = await code();
  assert.equal((await post(`${h.url}/v1/token`, { grant_type: "authorization_code", code: c1, code_verifier: pkce().verifier })).status, 400);
  assert.equal((await post(`${h.url}/v1/token`, { grant_type: "authorization_code", code: c1, code_verifier: verifier })).status, 400);
  // replayed
  const c2 = await code();
  assert.equal((await post(`${h.url}/v1/token`, { grant_type: "authorization_code", code: c2, code_verifier: verifier })).status, 200);
  const again = await post(`${h.url}/v1/token`, { grant_type: "authorization_code", code: c2, code_verifier: verifier });
  assert.equal(again.status, 400);
  assert.equal((await json(again)).error, "invalid_grant");
  // expired
  const c3 = await code();
  h.clock.t = Date.now() + APP_CODE_TTL_MS + 1000;
  assert.equal((await post(`${h.url}/v1/token`, { grant_type: "authorization_code", code: c3, code_verifier: verifier })).status, 400);
  // a different redirect_uri than it was issued for (the clock stays ahead: the limits' buckets only go forward)
  const c4 = await code();
  assert.equal((await post(`${h.url}/v1/token`, { grant_type: "authorization_code", code: c4, code_verifier: verifier, redirect_uri: "https://x.example.com/" })).status, 400);
});

test("a callback's state works once and only for 10 minutes", async () => {
  const h = await harness();
  const { challenge } = pkce();
  const signin = await get(`${h.url}/v1/signin?redirect_uri=example://account&code_challenge=${challenge}&code_challenge_method=S256`);
  const atIdp = await get(signin.headers.get("location")!);
  const cb = atIdp.headers.get("location")!;
  assert.equal((await get(cb)).status, 302);
  const replay = await get(cb);
  assert.equal(replay.status, 400);
  assert.equal(replay.headers.get("location"), null);
  assert.equal((await get(`${h.url}/v1/callback?state=made-up&code=x`)).status, 400);
  // expired
  const s2 = await get(`${h.url}/v1/signin?redirect_uri=example://account&code_challenge=${challenge}&code_challenge_method=S256`);
  const cb2 = (await get(s2.headers.get("location")!)).headers.get("location")!;
  h.clock.t = Date.now() + 11 * 60_000;
  assert.equal((await get(cb2)).status, 400);
});

test("the id_token is checked: nonce, audience, azp; an IdP error comes back as an error", async () => {
  const h = await harness();
  const { challenge } = pkce();
  const q = { redirect_uri: "example://account", code_challenge: challenge, code_challenge_method: "S256" };
  h.idp.nonceOverride = "other";
  assert.equal(new URL((await throughIdp(h, q)).location).searchParams.get("error"), "server_error");
  h.idp.nonceOverride = null;
  h.idp.audOverride = "another-client";
  assert.equal(new URL((await throughIdp(h, q)).location).searchParams.get("error"), "server_error");
  h.idp.audOverride = [h.idp.clientId, "another"];
  h.idp.azp = "another";
  assert.equal(new URL((await throughIdp(h, q)).location).searchParams.get("error"), "server_error");
  h.idp.audOverride = null;
  h.idp.azp = null;
  h.idp.authorizeError = "access_denied";
  assert.equal(new URL((await throughIdp(h, q)).location).searchParams.get("error"), "access_denied");
  h.idp.authorizeError = "weird<script>";
  assert.equal(new URL((await throughIdp(h, q)).location).searchParams.get("error"), "server_error");
  h.idp.authorizeError = null;
  h.idp.idTokenExpiresIn = -3600;
  assert.equal(new URL((await throughIdp(h, q)).location).searchParams.get("error"), "server_error");
  assert.equal(h.store.all("SELECT * FROM accounts").length, 0);
});

test("the RFC 9207 iss on the callback is checked when the IdP sends it", async () => {
  const h = await harness({ idp: (i) => (i.issParam = true) });
  const { challenge } = pkce();
  const signin = await get(`${h.url}/v1/signin?redirect_uri=example://account&code_challenge=${challenge}&code_challenge_method=S256`);
  const cb = new URL((await get(signin.headers.get("location")!)).headers.get("location")!);
  cb.searchParams.set("iss", "https://mixup.example.com");
  assert.equal(new URL((await get(cb.toString())).headers.get("location")!).searchParams.get("error"), "server_error");
  // and the right one passes
  await appSignIn(h);
});

test("the allow-list: a sub, or a verified email's @domain", async () => {
  const h = await harness({ env: { ACCOUNT_ALLOW: "u-bob,@example.org" } });
  const { challenge } = pkce();
  const q = { redirect_uri: "example://account", code_challenge: challenge, code_challenge_method: "S256" };
  h.idp.user = { sub: "u-alice", name: "Alice" };
  assert.equal(new URL((await throughIdp(h, q)).location).searchParams.get("error"), "access_denied");
  assert.ok(h.logs.some((l) => /not on the allow-list \(sub #[A-Za-z0-9_-]{8}\)/.test(l)));
  assert.ok(!h.logs.some((l) => l.includes("u-alice")), "no sub in the logs");
  h.idp.user = { sub: "u-carol", email: "carol@example.org", email_verified: false };
  assert.equal(new URL((await throughIdp(h, q)).location).searchParams.get("error"), "access_denied");
  h.idp.user = { sub: "u-carol", email: "carol@sub.example.org.evil.example", email_verified: true };
  assert.equal(new URL((await throughIdp(h, q)).location).searchParams.get("error"), "access_denied");
  h.idp.user = { sub: "u-carol", email: "carol@example.org", email_verified: true };
  assert.ok(new URL((await throughIdp(h, q)).location).searchParams.get("code"));
  h.idp.user = { sub: "u-bob" };
  assert.ok(new URL((await throughIdp(h, q)).location).searchParams.get("code"));
  // the email scope is asked for (an @domain is on the list)
  assert.equal(h.idp.authorizeRequests[0]!.get("scope"), "openid profile email");
});

test("a removed account leaves a tombstone: the same iss + sub is refused until it is cleared, then is a new account", async () => {
  const h = await harness();
  const s = await appSignIn(h);
  removeAccount(h.store, s.account.id);
  assert.equal((await get(`${h.url}/v1/me`, bearer(s.session))).status, 401);
  const { challenge } = pkce();
  const q = { redirect_uri: "example://account", code_challenge: challenge, code_challenge_method: "S256" };
  assert.equal(new URL((await throughIdp(h, q)).location).searchParams.get("error"), "account_removed");
  assert.equal(h.store.all("SELECT * FROM accounts").length, 0);
  // another user of the same IdP is not affected
  h.idp.user = { sub: "u-bob", name: "Bob" };
  await appSignIn(h);
  h.idp.user = { sub: "u-alice", name: "Alice" };
  assert.ok(clearTombstone(h.store, h.idp.issuer, "u-alice"));
  const again = await appSignIn(h);
  assert.notEqual(again.account.id, s.account.id);
});

test("a disabled account: its sessions stop, it cannot sign in, its computers are told", async () => {
  const h = await harness();
  const s = await appSignIn(h);
  const c = await joinComputer(h, s.session);
  disableAccount(h.store, s.account.id);
  assert.equal((await get(`${h.url}/v1/computers`, bearer(s.session))).status, 401);
  const { challenge } = pkce();
  assert.equal(new URL((await throughIdp(h, { redirect_uri: "example://account", code_challenge: challenge, code_challenge_method: "S256" })).location).searchParams.get("error"), "account_disabled");
  await h.svc.deliverNotices();
  const n = h.notices.at(-1)!;
  assert.deepEqual(n.linkIds, [c.k.id]);
  const list = await json(await computerCall(h, c.k, "GET", `/v1/computer/revocations?account=${s.account.id}`));
  assert.ok((await verifyRevocationList(list.list, { issuer: h.url, keys: h.ring.jwks(), owner: s.account.id, minVersion: n.seq })).disabled);
});

test("the IdP down at sign-in: a 503 page, nothing stored", async () => {
  const h = await harness();
  await h.idp.stop();
  const { challenge } = pkce();
  const r = await get(`${h.url}/v1/signin?redirect_uri=example://account&code_challenge=${challenge}&code_challenge_method=S256`);
  assert.equal(r.status, 503);
  assert.equal(h.store.countSignins(Date.now()), 0);
  h.idp.start = async () => h.idp; // (stopped already: the harness's stop must not fail)
  h.idp.stop = async () => {};
});

// ----------------------------------------------------------------------------- sessions

test("a device session ends after 90 days, at sign-out, or when the device is removed", async () => {
  const h = await harness();
  const s = await appSignIn(h);
  h.clock.t = Date.now() + SESSION_MAX_AGE_MS + 1000;
  assert.equal((await get(`${h.url}/v1/me`, bearer(s.session))).status, 401);
  h.clock.t = null;
  const s2 = await appSignIn(h);
  assert.equal((await post(`${h.url}/v1/signout`, {}, bearer(s2.session))).status, 200);
  assert.equal((await get(`${h.url}/v1/me`, bearer(s2.session))).status, 401);
  // a second device removes the first
  const a = await appSignIn(h, { device: { name: "Phone" } });
  const b = await appSignIn(h, { device: { name: "iPad" } });
  const devs = (await json(await get(`${h.url}/v1/devices`, bearer(b.session)))).devices as { id: string; current: boolean }[];
  assert.ok(devs.find((d) => d.id === b.device.id)!.current);
  assert.equal((await fetch(`${h.url}/v1/devices/${a.device.id}`, { method: "DELETE", headers: bearer(b.session) })).status, 200);
  assert.equal((await get(`${h.url}/v1/me`, bearer(a.session))).status, 401);
  assert.equal((await get(`${h.url}/v1/me`, bearer(b.session))).status, 200);
  // the revocation list has both devices that went
  const st = h.store.revocationState(a.account.id);
  assert.ok(st.devices.some((d) => d.id === a.device.id));
  assert.ok(st.devices.some((d) => d.id === s2.device.id));
});

test("the same device key signs in again as the same device (and ends its old session)", async () => {
  const h = await harness();
  const key = Buffer.alloc(32, 7).toString("base64url");
  const s1 = await appSignIn(h, { device: { name: "Phone", key } });
  const s2 = await appSignIn(h, { device: { name: "Phone (renamed)", key } });
  assert.equal(s2.device.id, s1.device.id);
  assert.equal((await get(`${h.url}/v1/me`, bearer(s1.session))).status, 401);
  assert.equal(h.store.devicesOf(s1.account.id).length, 1);
  // a key that is not 32 bytes is refused
  await assert.rejects(appSignIn(h, { device: { name: "x", key: "abc" } }));
});

test("bad bearer tokens: 401, then 429 for that address", async () => {
  const h = await harness({ limits: { badTokensPerMinute: 3 } });
  for (let i = 0; i < 3; i++) assert.equal((await get(`${h.url}/v1/me`, bearer("yoyo_as_" + "A".repeat(43)))).status, 401);
  const r = await get(`${h.url}/v1/me`, bearer("yoyo_as_" + "A".repeat(43)));
  assert.equal(r.status, 429);
  assert.ok(r.headers.get("retry-after"));
});

// ----------------------------------------------------------------------------- computers and tickets

test("the computer list, with its relay; a ticket only for one's own computer; a ticket for A refused on B", async () => {
  const h = await harness();
  const s = await appSignIn(h);
  const a = await joinComputer(h, s.session);
  const b = await joinComputer(h, s.session);
  const list = (await json(await get(`${h.url}/v1/computers`, bearer(s.session)))).computers as { linkId: string; relays: string[]; fingerprint: string }[];
  assert.deepEqual(list.map((c) => c.linkId).sort(), [a.k.id, b.k.id].sort());
  assert.deepEqual(list[0]!.relays, ["https://relay.example.com/?token=t0k"]);
  // another account's computer: 404
  h.idp.user = { sub: "u-bob", name: "Bob" };
  const bob = await appSignIn(h);
  assert.equal((await post(`${h.url}/v1/tickets`, { computer: a.k.id }, bearer(bob.session))).status, 404);
  assert.equal((await json(await get(`${h.url}/v1/computers`, bearer(bob.session)))).computers.length, 0);
  // alice's ticket for A
  const t = await json(await post(`${h.url}/v1/tickets`, { computer: a.k.id }, bearer(s.session)));
  assert.equal(t.expiresIn, 120);
  const keys = a.body.server.keys as PublicJwk[];
  const replay = new ReplayCache();
  const claims = await verifyTicket(t.ticket, { issuer: h.url, keys, owner: s.account.id, linkId: a.k.id, replay });
  assert.equal(claims.dev.id, s.device.id);
  assert.equal(claims.sub, s.account.id);
  // on B: refused
  await assert.rejects(verifyTicket(t.ticket, { issuer: h.url, keys, owner: s.account.id, linkId: b.k.id, replay: new ReplayCache() }), (e: TicketError) => e.code === "wrong_computer");
  // again on A: replayed
  await assert.rejects(verifyTicket(t.ticket, { issuer: h.url, keys, owner: s.account.id, linkId: a.k.id, replay }), (e: TicketError) => e.code === "replayed");
  // after two minutes: expired
  const t2 = await json(await post(`${h.url}/v1/tickets`, { computer: a.k.id }, bearer(s.session)));
  await assert.rejects(verifyTicket(t2.ticket, { issuer: h.url, keys, owner: s.account.id, linkId: a.k.id, replay, now: Date.now() + 200_000 }), (e: TicketError) => e.code === "expired");
  // bob's account as the owner (a computer that pinned bob): not_owner
  await assert.rejects(verifyTicket(t2.ticket, { issuer: h.url, keys, owner: bob.account.id, linkId: a.k.id, replay: new ReplayCache() }), (e: TicketError) => e.code === "not_owner");
});

test("tickets are limited per device; rename and remove a computer", async () => {
  const h = await harness({ limits: { ticketBurst: 3, ticketEveryMs: 60_000 } });
  const s = await appSignIn(h);
  const a = await joinComputer(h, s.session);
  for (let i = 0; i < 3; i++) assert.equal((await post(`${h.url}/v1/tickets`, { computer: a.k.id }, bearer(s.session))).status, 200);
  const over = await post(`${h.url}/v1/tickets`, { computer: a.k.id }, bearer(s.session));
  assert.equal(over.status, 429);
  assert.ok(Number(over.headers.get("retry-after")) > 0);
  // another device of the same account has its own budget
  const s2 = await appSignIn(h, { device: { name: "iPad" } });
  assert.equal((await post(`${h.url}/v1/tickets`, { computer: a.k.id }, bearer(s2.session))).status, 200);
  const r = await fetch(`${h.url}/v1/computers/${a.k.id}`, { method: "PATCH", headers: { ...bearer(s.session), "content-type": "application/json" }, body: JSON.stringify({ name: " Den‮ PC " }) });
  assert.equal((await json(r)).computer.name, "Den PC");
  assert.equal((await fetch(`${h.url}/v1/computers/${a.k.id}`, { method: "DELETE", headers: bearer(s.session) })).status, 200);
  assert.equal((await json(await get(`${h.url}/v1/computers`, bearer(s.session)))).computers.length, 0);
  assert.ok(h.store.revocationState(s.account.id).computers.some((c) => c.id === a.k.id));
  assert.ok(h.notices.some((n) => n.linkIds.includes(a.k.id)));
});

// ----------------------------------------------------------------------------- the join code

test("join codes: 8 of 20 consonants, shown XXXX-XXXX, an upper-case QR URL", async () => {
  for (let i = 0; i < 200; i++) {
    const c = newCode();
    assert.ok(validCode(c), c);
  }
  assert.equal(CODE_ALPHABET.length, 20);
  assert.equal(normCode("bcdf-ghjk"), "BCDFGHJK");
  const h = await harness();
  const e = await enroll(h, linkKey());
  assert.match(e.body.user_code, /^[BCDFGHJKLMNPQRSTVWXZ]{4}-[BCDFGHJKLMNPQRSTVWXZ]{4}$/);
  assert.equal(e.body.qr, `${h.url.toUpperCase()}/C/${e.body.user_code.replace("-", "")}`);
  assert.match(e.body.qr, /^[0-9A-Z $%*+\-./:]+$/, "QR alphanumeric mode");
  assert.equal(e.body.interval, 2);
  // the device code is never in what is shown
  assert.ok(!e.body.qr.includes(e.body.device_code));
  // (no page to send a browser to: the code is approved in a client)
  assert.equal((e.body as Record<string, unknown>).verification_uri_complete, undefined);
});

test("a join, the whole way: enroll, lookup, approve, poll shows who, confirmed only with the Link key", async () => {
  const h = await harness();
  const s = await appSignIn(h);
  const k = linkKey();
  const e = await enroll(h, k);
  // the computer polls before anyone approved
  assert.equal((await json(await post(`${h.url}/v1/computers/poll`, { device_code: e.body.device_code }))).error, "authorization_pending");
  const look = await json(await get(`${h.url}/v1/computers/lookup?code=${encodeURIComponent(e.body.user_code.toLowerCase())}`, bearer(s.session)));
  assert.equal(look.computer.name, "Study PC");
  assert.equal(look.computer.linkId, k.id);
  assert.equal(look.from, "127.0.0.1");
  assert.equal(look.status, "pending");
  const ap = await post(`${h.url}/v1/computers/approve`, { user_code: e.body.user_code }, bearer(s.session));
  assert.equal(ap.status, 200);
  // approved, but not in the account until the computer confirms
  assert.equal((await json(await get(`${h.url}/v1/computers`, bearer(s.session)))).computers.length, 0);
  await new Promise((r) => setTimeout(r, 2_000));
  const p = await post(`${h.url}/v1/computers/poll`, { device_code: e.body.device_code });
  assert.equal(p.status, 200);
  const pb = await json(p);
  assert.equal(pb.claimant.account.id, s.account.id);
  assert.equal(pb.claimant.account.name, "Alice");
  assert.equal(pb.claimant.by, "Alex's iPhone");
  assert.equal(pb.server.url, h.url);
  // a confirmation signed by another key: refused
  assert.equal((await confirm(h, k, e.body.device_code, s.account.id, linkKey())).status, 403);
  // signed for another account: refused
  assert.equal((await confirm(h, k, e.body.device_code, "a_someoneelse000000000")).status, 403);
  const c = await confirm(h, k, e.body.device_code, s.account.id);
  assert.equal(c.status, 200);
  const cb = await json(c);
  assert.equal(cb.account.id, s.account.id);
  assert.deepEqual(cb.server.keys, h.ring.jwks());
  assert.equal((await json(await get(`${h.url}/v1/computers`, bearer(s.session)))).computers[0].linkId, k.id);
  // the device code is spent
  assert.equal((await confirm(h, k, e.body.device_code, s.account.id)).status, 400);
});

test("join: polling faster than the interval gets slow_down", async () => {
  const h = await harness();
  const e = await enroll(h, linkKey());
  await post(`${h.url}/v1/computers/poll`, { device_code: e.body.device_code });
  assert.equal((await json(await post(`${h.url}/v1/computers/poll`, { device_code: e.body.device_code }))).error, "slow_down");
  assert.equal((await post(`${h.url}/v1/computers/poll`, { device_code: "x".repeat(43) })).status, 400);
});

test("join: a code expires after 10 minutes (lookup, approve, poll)", async () => {
  const h = await harness();
  const s = await appSignIn(h);
  const e = await enroll(h, linkKey());
  h.clock.t = Date.now() + JOIN_TTL_MS + 1000;
  assert.equal((await get(`${h.url}/v1/computers/lookup?code=${e.body.user_code}`, bearer(s.session))).status, 404);
  assert.equal((await post(`${h.url}/v1/computers/approve`, { user_code: e.body.user_code }, bearer(s.session))).status, 404);
  assert.equal((await json(await post(`${h.url}/v1/computers/poll`, { device_code: e.body.device_code }))).error, "expired_token");
});

test("join: brute force — wrong codes are counted per session, address and account, then 429", async () => {
  const h = await harness({ limits: { codeFailuresPerSession: 5, codeFailuresPerAddress: 100 } });
  const s = await appSignIn(h);
  const e = await enroll(h, linkKey());
  let codes404 = 0;
  for (let i = 0; i < 5; i++) if ((await post(`${h.url}/v1/computers/approve`, { user_code: "BBBB-BBBB" }, bearer(s.session))).status === 404) codes404++;
  assert.equal(codes404, 5);
  // now even the right code waits
  const r = await post(`${h.url}/v1/computers/approve`, { user_code: e.body.user_code }, bearer(s.session));
  assert.equal(r.status, 429);
  assert.equal((await get(`${h.url}/v1/computers/lookup?code=${e.body.user_code}`, bearer(s.session))).status, 429);
  // per address too: a second session from the same address
  const h2 = await harness({ limits: { codeFailuresPerSession: 100, codeFailuresPerAddress: 3 } });
  const a = await appSignIn(h2);
  const b = await appSignIn(h2, { device: { name: "other" } });
  for (let i = 0; i < 3; i++) await post(`${h2.url}/v1/computers/approve`, { user_code: "CCCCCCCC" }, bearer(a.session));
  assert.equal((await post(`${h2.url}/v1/computers/approve`, { user_code: "CCCCCCCC" }, bearer(b.session))).status, 429);
  // the logs never name a code
  assert.ok(!h.logs.some((l) => l.includes(e.body.user_code.replace("-", "")) || l.includes("BBBB")));
});

test("join: two approvals at once — exactly one wins, the other gets 409", async () => {
  const h = await harness();
  const alice = await appSignIn(h);
  h.idp.user = { sub: "u-bob", name: "Bob" };
  const bob = await appSignIn(h);
  const k = linkKey();
  const e = await enroll(h, k);
  const [r1, r2] = await Promise.all([
    post(`${h.url}/v1/computers/approve`, { user_code: e.body.user_code }, bearer(alice.session)),
    post(`${h.url}/v1/computers/approve`, { user_code: e.body.user_code }, bearer(bob.session)),
  ]);
  const statuses = [r1.status, r2.status].sort();
  assert.ok(statuses[0] === 200 && (statuses[1] === 409 || statuses[1] === 404), String(statuses));
  const winner = r1.status === 200 ? alice : bob;
  const loser = r1.status === 200 ? bob : alice;
  // the loser cannot see it any more, nor confirm into its account
  assert.equal((await get(`${h.url}/v1/computers/lookup?code=${e.body.user_code}`, bearer(loser.session))).status, 404);
  assert.equal((await confirm(h, k, e.body.device_code, loser.account.id)).status, 403);
  // and the computer shows the winner, and only joins once it confirms
  const p = await json(await post(`${h.url}/v1/computers/poll`, { device_code: e.body.device_code }));
  assert.equal(p.claimant.account.id, winner.account.id);
});

test("join: a headless computer's expected account — another approver is refused; the code stays for the right one", async () => {
  const h = await harness();
  h.idp.user = { sub: "u-bob", name: "Bob" };
  const bob = await appSignIn(h);
  h.idp.user = { sub: "u-alice", name: "Alice" };
  const alice = await appSignIn(h);
  const k = linkKey();
  const e = await enroll(h, k, { expect: { sub: "u-alice" } });
  const look = await json(await get(`${h.url}/v1/computers/lookup?code=${e.body.user_code}`, bearer(bob.session)));
  assert.equal(look.expectsAccount, true);
  assert.equal(look.matchesExpected, false);
  const r = await post(`${h.url}/v1/computers/approve`, { user_code: e.body.user_code }, bearer(bob.session));
  assert.equal(r.status, 403);
  assert.equal((await json(r)).error, "wrong_account");
  assert.equal((await post(`${h.url}/v1/computers/approve`, { user_code: e.body.user_code }, bearer(alice.session))).status, 200);
  // by account id too
  const e2 = await enroll(h, linkKey(), { expect: { account: alice.account.id } });
  assert.equal((await post(`${h.url}/v1/computers/approve`, { user_code: e2.body.user_code }, bearer(bob.session))).status, 403);
  assert.equal((await enroll(h, linkKey(), { expect: { account: "no" } })).status, 400);
});

test("join: the person at the computer declines — the approval goes nowhere", async () => {
  const h = await harness();
  const s = await appSignIn(h);
  const k = linkKey();
  const e = await enroll(h, k);
  await post(`${h.url}/v1/computers/approve`, { user_code: e.body.user_code }, bearer(s.session));
  assert.equal((await post(`${h.url}/v1/computers/decline`, { device_code: e.body.device_code })).status, 200);
  assert.equal((await confirm(h, k, e.body.device_code, s.account.id)).status, 400);
  assert.equal((await json(await get(`${h.url}/v1/computers`, bearer(s.session)))).computers.length, 0);
});

test("join: a computer that joins another account (confirmed on it) leaves the old one, whose devices are told", async () => {
  const h = await harness();
  const alice = await appSignIn(h);
  const a = await joinComputer(h, alice.session);
  h.idp.user = { sub: "u-bob", name: "Bob" };
  const bob = await appSignIn(h);
  await joinComputer(h, bob.session, a.k);
  assert.equal((await json(await get(`${h.url}/v1/computers`, bearer(alice.session)))).computers.length, 0);
  assert.equal((await json(await get(`${h.url}/v1/computers`, bearer(bob.session)))).computers.length, 1);
  assert.ok(h.store.revocationState(alice.account.id).computers.some((c) => c.id === a.k.id));
});

test("join limits: per address, the body, the fields", async () => {
  const h = await harness({ limits: { enrollBurst: 3, enrollEveryMs: 60_000 } });
  for (let i = 0; i < 3; i++) assert.equal((await enroll(h, linkKey())).status, 200);
  assert.equal((await enroll(h, linkKey())).status, 429);
  const h2 = await harness({ limits: { enrollOpenPerAddress: 2 } });
  await enroll(h2, linkKey());
  await enroll(h2, linkKey());
  assert.equal((await enroll(h2, linkKey())).status, 429);
  const h3 = await harness();
  assert.equal((await post(`${h3.url}/v1/computers/enroll`, { linkId: "nothex", name: "x" })).status, 400);
  assert.equal((await post(`${h3.url}/v1/computers/enroll`, { linkId: linkKey().id, name: "" })).status, 400);
  assert.equal((await enroll(h3, linkKey(), { relays: ["http://relay.example.com/"] })).status, 400);
  // an address of its own page this server does not take as a way back (more than an origin, plain http to a public
  // address, a bare host name) is left out — the join itself is not refused over it
  const lenient = linkKey();
  assert.equal((await enroll(h3, lenient, { origins: ["https://pc.example.com/path", "http://203.0.113.20:8700", "http://DESKTOP-1:8700", "https://pc.example.com", "http://10.0.0.5:8700"] })).status, 200);
  assert.deepEqual(JSON.parse(h3.store.get<{ origins: string }>("SELECT origins FROM enrollments WHERE link_id = ?", lenient.id)!.origins), ["https://pc.example.com", "http://10.0.0.5:8700"]);
  assert.equal((await post(`${h3.url}/v1/computers/enroll`, "x".repeat(17 * 1024))).status, 413);
  assert.equal((await post(`${h3.url}/v1/computers/enroll`, "{not json")).status, 400);
});

// ----------------------------------------------------------------------------- a member computer's own requests

test("a member computer pulls its signed revocation list, updates itself, leaves; unsigned or stale requests are refused", async () => {
  const h = await harness();
  const s = await appSignIn(h);
  const a = await joinComputer(h, s.session);
  // a device removed → on the list
  const other = await appSignIn(h, { device: { name: "Old phone" } });
  await fetch(`${h.url}/v1/devices/${other.device.id}`, { method: "DELETE", headers: bearer(s.session) });
  const r = await computerCall(h, a.k, "GET", `/v1/computer/revocations?account=${s.account.id}`);
  assert.equal(r.status, 200);
  const body = await json(r);
  const list = await verifyRevocationList(body.list, { issuer: h.url, keys: h.ring.jwks(), owner: s.account.id, minVersion: 0 });
  assert.ok(list.devices.some((d) => d.id === other.device.id));
  const view = new RevocationView(list);
  assert.ok(view.isRevoked(other.device.id, Math.floor(Date.now() / 1000) - 5));
  assert.ok(!view.isRevoked(s.device.id, Math.floor(Date.now() / 1000)));
  // an older list is refused once a newer one is held
  await assert.rejects(verifyRevocationList(body.list, { issuer: h.url, keys: h.ring.jwks(), owner: s.account.id, minVersion: list.version + 1 }));
  // a computer waiting on its list (`after` + `wait`) is answered the moment a revocation takes effect, not at the
  // wait's end; one with nothing new gets the list as it is when the wait is over
  const third = await appSignIn(h, { device: { name: "Tablet" } });
  const t0 = Date.now();
  const waitingFor = computerCall(h, a.k, "GET", `/v1/computer/revocations?account=${s.account.id}&after=${list.version}&wait=20`);
  await new Promise((r) => setTimeout(r, 150));
  await fetch(`${h.url}/v1/devices/${third.device.id}`, { method: "DELETE", headers: bearer(s.session) });
  const woken = await json(await waitingFor);
  assert.ok(Date.now() - t0 < 5_000, "answered by the revocation, not the timeout");
  const list2 = await verifyRevocationList(woken.list, { issuer: h.url, keys: h.ring.jwks(), owner: s.account.id, minVersion: list.version + 1 });
  assert.ok(list2.devices.some((d) => d.id === third.device.id));
  const idle = await json(await computerCall(h, a.k, "GET", `/v1/computer/revocations?account=${s.account.id}&after=${list2.version}&wait=1`));
  assert.equal(idle.version, list2.version);
  // signed by another key, a stale time, a tampered body: 401
  assert.equal((await computerCall(h, a.k, "GET", "/v1/computer/revocations", undefined, { signer: linkKey() })).status, 401);
  assert.equal((await computerCall(h, a.k, "GET", "/v1/computer/revocations", undefined, { ts: Math.floor(Date.now() / 1000) - 600 })).status, 401);
  assert.equal((await fetch(`${h.url}/v1/computer/revocations`)).status, 401);
  // update
  const u = await computerCall(h, a.k, "POST", "/v1/computer/update", { name: "Den PC", relays: ["https://relay2.example.com/?token=new"], origins: ["https://pc.example.com"] });
  assert.equal(u.status, 200);
  assert.equal((await json(await get(`${h.url}/v1/computers`, bearer(s.session)))).computers[0].relays[0], "https://relay2.example.com/?token=new");
  // a computer not in the account: 404
  assert.equal((await computerCall(h, linkKey(), "POST", "/v1/computer/update", { name: "x" })).status, 404);
  // leave: gone from the list; it can still read the list that says so
  assert.equal((await computerCall(h, a.k, "POST", "/v1/computer/leave", {})).status, 200);
  assert.equal((await json(await get(`${h.url}/v1/computers`, bearer(s.session)))).computers.length, 0);
  const after = await json(await computerCall(h, a.k, "GET", `/v1/computer/revocations?account=${s.account.id}`));
  const l2 = await verifyRevocationList(after.list, { issuer: h.url, keys: h.ring.jwks(), owner: s.account.id, minVersion: list.version });
  assert.ok(l2.computers.some((c) => c.id === a.k.id));
  // a stranger computer cannot read another account's list
  assert.equal((await computerCall(h, linkKey(), "GET", `/v1/computer/revocations?account=${s.account.id}`)).status, 404);
});

test("what an account brings its computers: the relay, and a push token of the computer's own that only the push relay's check takes", async () => {
  const h = await harness({ env: { ACCOUNT_RELAY_URL: "https://relay.example.com", ACCOUNT_RELAY_TOKEN: "relay-token-0123456789", ACCOUNT_PUSH_URL: "https://push.example.com", ACCOUNT_SPEECH_URL: "https://speech.example.com", ACCOUNT_SIGNAL_URL: "https://signal.example.com", ACCOUNT_SIGNAL_KEY: "signal-key-0123456789" } });
  const s = await appSignIn(h);
  const { k, account } = await joinComputer(h, s.session);
  const r = await computerCall(h, k, "GET", "/v1/computer/services");
  assert.equal(r.status, 200);
  const b = (await r.json()) as { relay: { url: string; token: string }; push: { url: string; token: string; expiresAt: number }; speech: { url: string; token: string; expiresAt: number }; signal: { url: string; key: string } };
  assert.deepEqual(b.relay, { url: "https://relay.example.com", token: "relay-token-0123456789" });
  // the signaling service with its computer key (the same for every computer here, as the relay token is)
  assert.deepEqual(b.signal, { url: "https://signal.example.com", key: "signal-key-0123456789" });
  // the hosted web client, where connectors' sign-ins come back to (the first web redirect's origin)
  assert.deepEqual((b as unknown as { web: unknown }).web, h.cfg.webRedirects[0] ? { url: new URL(h.cfg.webRedirects[0]).origin } : undefined);
  assert.equal(b.push.url, "https://push.example.com");
  assert.ok(Math.abs(b.push.expiresAt - (Date.now() + SERVICE_TTL_S * 1000)) < 10_000);
  // the push relay's check: this server's key, this server, the push service
  const keys = h.ring.jwks();
  assert.deepEqual(await verifyServiceToken(b.push.token, { issuer: h.url, keys, service: PUSH_SERVICE }), { account, computer: k.id, exp: Math.floor(b.push.expiresAt / 1000) });
  // not for another service, not another server's, not after its day; and it is no ticket (nor a ticket a service token)
  await assert.rejects(verifyServiceToken(b.push.token, { issuer: h.url, keys, service: "yoyo-speech" }), TicketError);
  await assert.rejects(verifyServiceToken(b.push.token, { issuer: "https://other.example.com", keys, service: PUSH_SERVICE }), TicketError);
  await assert.rejects(verifyServiceToken(b.push.token, { issuer: h.url, keys, service: PUSH_SERVICE, now: b.push.expiresAt + 60_000 }), (e: TicketError) => e.code === "expired");
  await assert.rejects(verifyTicket(b.push.token, { issuer: h.url, keys, owner: account, linkId: k.id, replay: new ReplayCache() }), TicketError);
  const ticket = await signTicket(h.ring, { issuer: h.url, account, linkId: PUSH_SERVICE, device: { id: "d_x", name: "x" } });
  await assert.rejects(verifyServiceToken(ticket, { issuer: h.url, keys, service: PUSH_SERVICE }), TicketError);
  // the speech services' token: its own audience — the push relay does not take it, nor the speech front the push relay's
  assert.equal(b.speech.url, "https://speech.example.com");
  assert.deepEqual(await verifyServiceToken(b.speech.token, { issuer: h.url, keys, service: SPEECH_SERVICE }), { account, computer: k.id, exp: Math.floor(b.speech.expiresAt / 1000) });
  await assert.rejects(verifyServiceToken(b.speech.token, { issuer: h.url, keys, service: PUSH_SERVICE }), TicketError);
  await assert.rejects(verifyServiceToken(b.push.token, { issuer: h.url, keys, service: SPEECH_SERVICE }), TicketError);
  // only a member computer, with its own signature
  const stranger = linkKey();
  assert.equal((await computerCall(h, stranger, "GET", "/v1/computer/services")).status, 404);
  assert.equal((await computerCall(h, k, "GET", "/v1/computer/services", undefined, { signer: stranger })).status, 401);
  assert.equal((await fetch(`${h.url}/v1/computer/services`)).status, 401);
  // a disabled account's computers get no more; a computer that left gets none
  await disableAccount(h.store, account, Date.now());
  assert.equal((await computerCall(h, k, "GET", "/v1/computer/services")).status, 403);
  // the relay token and the signaling key are in no log
  assert.ok(!h.logs.join("\n").includes("relay-token-0123456789"));
  assert.ok(!h.logs.join("\n").includes("signal-key-0123456789"));

  // the relay token from a file is read as it is now: a new token is handed out without a restart, a file with
  // nothing whole in it hands out no relay
  let inFile = "file-token-0123456789";
  const cfg = configFromEnv({ ACCOUNT_OIDC_ISSUER: "https://id.example.com", ACCOUNT_OIDC_CLIENT_ID: "c", ACCOUNT_OIDC_CLIENT_SECRET: "s", ACCOUNT_PUBLIC_URL: "https://account.example.com", ACCOUNT_RELAY_URL: "https://relay.example.com" }, undefined, () => inFile);
  assert.equal(relayToken(cfg), "file-token-0123456789");
  inFile = "next-token-0123456789\n";
  assert.equal(relayToken(cfg), "next-token-0123456789");
  inFile = "";
  assert.equal(relayToken(cfg), null);
  assert.throws(() => configFromEnv({ ACCOUNT_OIDC_ISSUER: "https://id.example.com", ACCOUNT_OIDC_CLIENT_ID: "c", ACCOUNT_OIDC_CLIENT_SECRET: "s", ACCOUNT_PUBLIC_URL: "https://account.example.com", ACCOUNT_RELAY_URL: "https://relay.example.com" }), /ACCOUNT_RELAY_TOKEN/);

  // the signaling key the same way; never without the relay (browsers post with its token), never the relay token
  const idp = { ACCOUNT_OIDC_ISSUER: "https://id.example.com", ACCOUNT_OIDC_CLIENT_ID: "c", ACCOUNT_OIDC_CLIENT_SECRET: "s", ACCOUNT_PUBLIC_URL: "https://account.example.com" };
  const withRelay = { ...idp, ACCOUNT_RELAY_URL: "https://relay.example.com", ACCOUNT_RELAY_TOKEN: "relay-token-0123456789", ACCOUNT_SIGNAL_URL: "https://signal.example.com" };
  let keyInFile = "file-key-0123456789\n";
  const sc = configFromEnv(withRelay, undefined, undefined, () => keyInFile);
  const signal = () => {
    const s = sc.services.find((x) => x.name === "signal");
    return s?.kind === "fixed" ? s.value() : undefined;
  };
  assert.deepEqual(signal(), { url: "https://signal.example.com", key: "file-key-0123456789" });
  keyInFile = "relay-token-0123456789";
  assert.equal(signal(), null);
  assert.throws(() => configFromEnv(withRelay), /ACCOUNT_SIGNAL_KEY/);
  assert.throws(() => configFromEnv({ ...withRelay, ACCOUNT_SIGNAL_KEY: "relay-token-0123456789" }), /not the relay token/);
  assert.throws(() => configFromEnv({ ...idp, ACCOUNT_SIGNAL_URL: "https://signal.example.com", ACCOUNT_SIGNAL_KEY: "signal-key-0123456789" }), /ACCOUNT_RELAY_URL/);
  assert.throws(() => configFromEnv({ ...idp, ACCOUNT_RELAY_URL: "https://relay.example.com", ACCOUNT_RELAY_TOKEN: "relay-token-0123456789", ACCOUNT_SIGNAL_KEY: "signal-key-0123456789" }), /without ACCOUNT_SIGNAL_URL/);

  // a server that lends nothing says so (a service it has but cannot lend now is null; one it never had is absent)
  const bare = await harness();
  const s2 = await appSignIn(bare);
  const j2 = await joinComputer(bare, s2.session);
  assert.deepEqual(await (await computerCall(bare, j2.k, "GET", "/v1/computer/services")).json(), {});
  assert.equal((await computerCall(bare, j2.k, "POST", "/v1/computer/leave", {})).status, 200);
  assert.equal((await computerCall(bare, j2.k, "GET", "/v1/computer/services")).status, 404);
});

test("no pages: the old /c approval pages and a sign-in back to a computer's own page are gone", async () => {
  const h = await harness();
  const e = await enroll(h, linkKey());
  const code = e.body.user_code.replace("-", "");
  for (const path of ["/c", `/c/${code}`, `/C/${code}`]) assert.equal((await get(`${h.url}${path}`)).status, 404, path);
  assert.equal((await post(`${h.url}/c/${code}/approve`, {})).status, 404);
  // next= and computer= are no sign-in of their own: without a registered redirect, refused
  assert.equal((await get(`${h.url}/v1/signin?next=${encodeURIComponent(`/c/${code}`)}`)).status, 400);
  assert.equal((await get(`${h.url}/v1/signin?computer=${"ab".repeat(32)}&return=${encodeURIComponent("https://evil.example.net/x")}`)).status, 400);
  // a member computer's old browser routes answer nothing
  const pc = await joinComputer(h, (await appSignIn(h)).session);
  assert.equal((await computerCall(h, pc.k, "POST", "/v1/computer/browser/token", {})).status, 404);
});

// ----------------------------------------------------------------------------- what the review found

test("a ticket says when its device's session ends; revocation versions never go below the clock; a disabled account's join key is not used up", async () => {
  const h = await harness();
  const s = await appSignIn(h);
  const c = await joinComputer(h, s.session);
  const t = await json(await post(`${h.url}/v1/tickets`, { computer: c.k.id }, bearer(s.session)));
  const claims = await verifyTicket(t.ticket, { issuer: h.url, keys: h.ring.jwks(), owner: s.account.id, linkId: c.k.id, replay: new ReplayCache() });
  assert.equal(claims.sx, Math.floor(s.expiresAt / 1000));
  // a ticket of a session already over (the clock moved on): refused as expired, whatever its own 120 s say
  const t2 = await json(await post(`${h.url}/v1/tickets`, { computer: c.k.id }, bearer(s.session)));
  await assert.rejects(verifyTicket(t2.ticket, { issuer: h.url, keys: h.ring.jwks(), owner: s.account.id, linkId: c.k.id, replay: new ReplayCache(), now: s.expiresAt + 1000 }), (e: TicketError) => e.code === "expired");
  // versions: a database that lost its counter (a restore, a new one) still hands out a version past what computers hold
  const other = await appSignIn(h, { device: { name: "Old" } });
  await fetch(`${h.url}/v1/devices/${other.device.id}`, { method: "DELETE", headers: bearer(s.session) });
  const v1 = h.store.revocationState(s.account.id).version;
  assert.ok(v1 >= Date.now() - 5_000);
  h.store.run("DELETE FROM revocation_versions WHERE account_id = ?", s.account.id);
  const third = await appSignIn(h, { device: { name: "Third" } });
  await fetch(`${h.url}/v1/devices/${third.device.id}`, { method: "DELETE", headers: bearer(s.session) });
  assert.ok(h.store.revocationState(s.account.id).version > v1);
  // a join key of a disabled account: refused, and still good once the account is enabled again
  const key = (await runAdmin(["join-key", s.account.id], { store: h.store, ring: h.ring })).split("\n")[0]!;
  const k = linkKey();
  const body = { key, linkId: k.id, name: "Server", proof: k.sign(joinKeyProofText(h.url, k.id, key)) };
  h.store.run("UPDATE accounts SET disabled_at = ? WHERE id = ?", Date.now(), s.account.id);
  assert.equal((await post(`${h.url}/v1/computers/join`, body)).status, 403);
  h.store.run("UPDATE accounts SET disabled_at = NULL WHERE id = ?", s.account.id);
  assert.equal((await post(`${h.url}/v1/computers/join`, body)).status, 200);
});

test("a valid session is not shut out by bad tokens from its address; an error's answer carries the CORS headers of a registered web client", async () => {
  const h = await harness({ env: { ACCOUNT_WEB_REDIRECTS: "https://app.example.com/account/callback" }, limits: { badTokensPerMinute: 3 } });
  const s = await appSignIn(h);
  for (let i = 0; i < 5; i++) await get(`${h.url}/v1/me`, bearer(`yoyo_as_${"x".repeat(43)}`));
  assert.equal((await get(`${h.url}/v1/me`, bearer(`yoyo_as_${"x".repeat(43)}`))).status, 429);
  assert.equal((await get(`${h.url}/v1/me`, bearer(s.session))).status, 200);
  const bad = await get(`${h.url}/v1/computers`, { origin: "https://app.example.com", authorization: "Bearer nope" });
  assert.equal(bad.headers.get("access-control-allow-origin"), "https://app.example.com");
});

// ----------------------------------------------------------------------------- the hosted web client

const WEB = "https://web.example.com/account/return";

/** A hosted web client: its device key (as WebCrypto keeps it, non-extractable there), its signed requests. */
function webKey() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const raw = (publicKey.export({ format: "jwk" }) as { x: string }).x;
  return {
    raw,
    proof: (server: string, method: string, pathQ: string, ts = Math.floor(Date.now() / 1000), body = "") => {
      const hash = createHash("sha256").update(body).digest("base64url");
      return `${ts}.${hash}.${sign(null, Buffer.from(hostedProofText(server, method, pathQ, ts, hash)), privateKey).toString("base64url")}`;
    },
  };
}

async function webSignIn(h: Awaited<ReturnType<typeof harness>>, device: Record<string, unknown>) {
  const { verifier, challenge } = pkce();
  const r = await throughIdp(h, { redirect_uri: WEB, state: "page-state", code_challenge: challenge, code_challenge_method: "S256" });
  const back = new URL(r.location);
  assert.equal(back.origin + back.pathname, WEB);
  assert.equal(back.searchParams.get("state"), "page-state");
  return post(`${h.url}/v1/token`, { grant_type: "authorization_code", code: back.searchParams.get("code"), code_verifier: verifier, redirect_uri: WEB, device }, { origin: "https://web.example.com" });
}

test("a hosted web client signs in to its registered address: a 30-day session bound to its key; each request signed, just now, by that key", async () => {
  const h = await harness({ env: { ACCOUNT_WEB_REDIRECTS: WEB } });
  // no key: no session (its token alone would be worth as much as an app's)
  assert.equal((await webSignIn(h, { name: "Safari on Mac" })).status, 400);
  const k = webKey();
  const t = await webSignIn(h, { name: "Safari on Mac", platform: "ios", key: k.raw });
  assert.equal(t.status, 200);
  assert.equal(t.headers.get("access-control-allow-origin"), "https://web.example.com");
  // (its clock may be off: the server's Date is readable to it)
  assert.equal(t.headers.get("access-control-expose-headers"), "date");
  const s = await json(t);
  assert.equal(s.proof, "yoyo-hosted-v1");
  assert.ok(Math.abs(s.expiresAt - (Date.now() + HOSTED_SESSION_MAX_AGE_MS)) < 5_000);
  const as = (pathQ: string, method = "GET", proof?: string) => ({ ...bearer(s.session), origin: "https://web.example.com", "yoyo-proof": proof ?? k.proof(h.url, method, pathQ) });
  // the token alone, a proof of another key, of another path, an old one: no session
  assert.equal((await get(`${h.url}/v1/me`, bearer(s.session))).status, 401);
  assert.equal((await get(`${h.url}/v1/me`, as("/v1/me", "GET", webKey().proof(h.url, "GET", "/v1/me")))).status, 401);
  assert.equal((await get(`${h.url}/v1/me`, as("/v1/me", "GET", k.proof(h.url, "GET", "/v1/devices")))).status, 401);
  assert.equal((await get(`${h.url}/v1/me`, as("/v1/me", "GET", k.proof(h.url, "GET", "/v1/me", Math.floor(Date.now() / 1000) - 600)))).status, 401);
  assert.equal((await get(`${h.url}/v1/me`, as("/v1/me", "GET", k.proof("https://other.example.com", "GET", "/v1/me")))).status, 401);
  const me = await get(`${h.url}/v1/me`, as("/v1/me"));
  assert.equal(me.status, 200);
  assert.equal((await json(me)).device.id, s.device.id);
  // a device of the account, a web one whatever it said
  const devices = (await json(await get(`${h.url}/v1/devices`, as("/v1/devices")))).devices as { id: string; platform: string; current: boolean }[];
  assert.deepEqual(devices.map((d) => [d.platform, d.current]), [["web", true]]);
  // the preflight lets it send the proof
  const pre = await fetch(`${h.url}/v1/tickets`, { method: "OPTIONS", headers: { origin: "https://web.example.com", "access-control-request-method": "POST", "access-control-request-headers": "authorization, content-type, yoyo-proof" } });
  assert.match(pre.headers.get("access-control-allow-headers") ?? "", /yoyo-proof/);
  // an app's session is not asked for a proof
  const app = await appSignIn(h);
  assert.equal((await get(`${h.url}/v1/me`, bearer(app.session))).status, 200);
  assert.ok(h.logs.some((l) => /web client session for/.test(l)));
});

test("the hosted web client: the list with each computer's signaling service, tickets like an app's, approving joins, sign-out ends it", async () => {
  const h = await harness({ env: { ACCOUNT_WEB_REDIRECTS: WEB } });
  const app = await appSignIn(h);
  const pc = await joinComputer(h, app.session);
  // the computer says where it waits for browsers' offers; a bad origin is refused, null clears it
  // (one the server does not take is left out, the rest of what it says stands)
  for (const bad of ["http://signal.example.com", "https://signal.example.com/v1", "nope", 7]) {
    assert.equal((await computerCall(h, pc.k, "POST", "/v1/computer/update", { signal: bad, name: `PC ${String(bad).length}` })).status, 200, String(bad));
    assert.equal(h.store.computer(pc.k.id)?.signal, null);
    assert.equal(h.store.computer(pc.k.id)?.name, `PC ${String(bad).length}`);
  }
  assert.equal((await computerCall(h, pc.k, "POST", "/v1/computer/update", { signal: "https://signal.example.com" })).status, 200);
  // (one that says it as it joins has it from the start)
  const other = linkKey();
  const e0 = await enroll(h, other, { signal: "https://signal2.example.com" });
  assert.equal((await post(`${h.url}/v1/computers/approve`, { user_code: e0.body.user_code }, bearer(app.session))).status, 200);
  assert.equal((await confirm(h, other, e0.body.device_code, app.account.id)).status, 200);
  assert.equal(h.store.computer(other.id)?.signal, "https://signal2.example.com");
  await computerCall(h, other, "POST", "/v1/computer/leave");
  const k = webKey();
  const s = await json(await webSignIn(h, { name: "Firefox on Linux", key: k.raw }));
  const as = (pathQ: string, method = "GET", body?: unknown) => ({ ...bearer(s.session), "yoyo-proof": k.proof(h.url, method, pathQ, undefined, body === undefined ? "" : JSON.stringify(body)) });
  const list = (await json(await get(`${h.url}/v1/computers`, as("/v1/computers")))).computers as { linkId: string; fingerprint: string; relays: string[]; signal: string | null }[];
  assert.equal(list.length, 1);
  assert.equal(list[0]!.linkId, pc.k.id);
  assert.equal(list[0]!.fingerprint, "sha-256 AB:CD:EF:01:23");
  assert.equal(list[0]!.signal, "https://signal.example.com");
  // a ticket into it, naming this browser
  const t = await json(await post(`${h.url}/v1/tickets`, { computer: pc.k.id }, as("/v1/tickets", "POST", { computer: pc.k.id })));
  // the proof covers the body: the same headers with another body (another computer) are refused
  const signedFor = as("/v1/tickets", "POST", { computer: pc.k.id });
  assert.equal((await post(`${h.url}/v1/tickets`, { computer: "ab".repeat(32) }, signedFor)).status, 401);
  const claims = await verifyTicket(t.ticket, { issuer: h.url, keys: pc.body.server.keys as PublicJwk[], owner: app.account.id, linkId: pc.k.id, replay: new ReplayCache() });
  assert.equal(claims.dev.id, s.device.id);
  // it approves a computer's join as the app does, with its key's proof only
  const e = await enroll(h, linkKey());
  const look = `/v1/computers/lookup?code=${e.body.user_code}`;
  assert.equal((await get(`${h.url}${look}`, bearer(s.session))).status, 401, "the token alone is no session");
  const seen = await json(await get(`${h.url}${look}`, as(look)));
  assert.equal(seen.computer.name, "Study PC");
  assert.equal(seen.status, "pending");
  assert.equal((await post(`${h.url}/v1/computers/approve`, { user_code: e.body.user_code }, bearer(s.session))).status, 401);
  assert.equal((await post(`${h.url}/v1/computers/approve`, { user_code: e.body.user_code }, as("/v1/computers/approve", "POST", { user_code: e.body.user_code }))).status, 200);
  const polled = await json(await post(`${h.url}/v1/computers/poll`, { device_code: e.body.device_code }));
  assert.equal(polled.claimant.by, "Firefox on Linux");
  // null clears the computer's signaling service
  assert.equal((await computerCall(h, pc.k, "POST", "/v1/computer/update", { signal: null })).status, 200);
  assert.equal(((await json(await get(`${h.url}/v1/computers`, as("/v1/computers")))).computers[0] as { signal: unknown }).signal, null);
  // signing out ends the session and puts the device on the computers' list
  assert.equal((await post(`${h.url}/v1/signout`, {}, as("/v1/signout", "POST", {}))).status, 200);
  assert.equal((await get(`${h.url}/v1/me`, as("/v1/me"))).status, 401);
  const r = await json(await computerCall(h, pc.k, "GET", `/v1/computer/revocations?account=${app.account.id}`));
  const revoked = await verifyRevocationList(r.list, { issuer: h.url, keys: h.ring.jwks(), owner: app.account.id, minVersion: 0 });
  assert.ok(revoked.devices.some((d) => d.id === s.device.id));
});

// ----------------------------------------------------------------------------- the rest

test("config, JWKS, CORS for a registered web client only, 404 for anything else", async () => {
  const h = await harness({ env: { ACCOUNT_WEB_REDIRECTS: "https://app.example.com/account/callback", ACCOUNT_APPLE_APP_IDS: "ABCDE12345.com.example.app" } });
  const c = await json(await get(`${h.url}/v1/config`));
  assert.equal(c.idp.issuer, h.idp.issuer);
  assert.equal(c.signin.appReturn, `${h.url}/v1/app-return`);
  const j = await json(await get(`${h.url}/.well-known/jwks.json`));
  assert.equal(j.keys[0].kty, "OKP");
  assert.equal(j.keys[0].d, undefined);
  const aasa = await json(await get(`${h.url}/.well-known/apple-app-site-association`));
  assert.deepEqual(aasa.webcredentials.apps, ["ABCDE12345.com.example.app"]);
  const pre = await fetch(`${h.url}/v1/token`, { method: "OPTIONS", headers: { origin: "https://app.example.com", "access-control-request-method": "POST" } });
  assert.equal(pre.status, 204);
  assert.equal(pre.headers.get("access-control-allow-origin"), "https://app.example.com");
  const bad = await fetch(`${h.url}/v1/token`, { method: "OPTIONS", headers: { origin: "https://evil.example.net" } });
  assert.equal(bad.status, 404);
  assert.equal((await get(`${h.url}/v1/config`, { origin: "https://evil.example.net" })).headers.get("access-control-allow-origin"), null);
  // a web client's https redirect is allowed (its session needs its key: see the hosted web client's tests)
  await assert.rejects(appSignIn(h, { redirect: "https://app.example.com/account/callback" }), /token 400/);
  await appSignIn(h, { redirect: "https://app.example.com/account/callback", device: { name: "Chrome", key: Buffer.alloc(32, 7).toString("base64url") } });
  assert.equal((await get(`${h.url}/v1/nothing`)).status, 401);
  assert.equal((await get(`${h.url}/nothing`)).status, 404);
});

test("sign-ins per address are limited", async () => {
  const h = await harness({ limits: { signinBurst: 2, signinEveryMs: 60_000 } });
  const { challenge } = pkce();
  const q = `${h.url}/v1/signin?redirect_uri=example://account&code_challenge=${challenge}&code_challenge_method=S256`;
  assert.equal((await get(q)).status, 302);
  assert.equal((await get(q)).status, 302);
  assert.equal((await get(q)).status, 429);
});

test("the logs never carry a token, a code, a state, a refresh token or a relay token", async () => {
  const h = await harness({ env: { ACCOUNT_IDP_RECHECK: "1" } });
  const s = await appSignIn(h);
  const a = await joinComputer(h, s.session);
  await post(`${h.url}/v1/tickets`, { computer: a.k.id }, bearer(s.session));
  await h.recheck.runDue();
  const secrets = [s.session, ...h.idp.liveRefreshTokens(), "t0k", h.idp.clientSecret, "u-alice"];
  for (const l of h.logs) for (const sec of secrets) assert.ok(!l.includes(sec), `log line has a secret: ${l}`);
  // and nothing stored has a password field, the session only as a hash
  assert.equal(h.store.all("SELECT * FROM sessions WHERE token_hash = ?", s.session).length, 0);
});

test("a join key: the admin's word puts a computer into an account before its person ever signed in; once, signed, in time", async () => {
  const h = await harness();
  const out = await runAdmin(["add-account", "u-alice", "Alice"], { store: h.store, ring: h.ring, issuer: h.cfg.issuer });
  const account = out.split(" ")[0]!;
  const key = (await runAdmin(["join-key", account], { store: h.store, ring: h.ring })).split("\n")[0]!;
  const k = linkKey();
  const body = (key_: string, signer = k) => ({ key: key_, linkId: k.id, name: "Server", relays: ["https://relay.example.com/?token=secret-relay-token"], proof: signer.sign(joinKeyProofText(h.url, k.id, key_)) });
  // signed by another key, a made-up key: refused, and the real key is not used up by them
  assert.equal((await post(`${h.url}/v1/computers/join`, body(key, linkKey()))).status, 403);
  assert.equal((await post(`${h.url}/v1/computers/join`, body(`yoyo_jk_${"A".repeat(43)}`))).status, 403);
  const r = await post(`${h.url}/v1/computers/join`, body(key));
  assert.equal(r.status, 200);
  const joined = await json(r);
  assert.equal(joined.account.id, account);
  assert.equal(joined.server.keys.length, 1);
  // one use
  assert.equal((await post(`${h.url}/v1/computers/join`, body(key))).status, 403);
  // the person signs in later (the same sub): the computer is already theirs, and a ticket into it verifies
  const s = await appSignIn(h);
  assert.equal(s.account.id, account);
  const list = await json(await get(`${h.url}/v1/computers`, bearer(s.session)));
  assert.deepEqual(list.computers.map((c: { linkId: string }) => c.linkId), [k.id]);
  const t = await json(await post(`${h.url}/v1/tickets`, { computer: k.id }, bearer(s.session)));
  assert.ok(await verifyTicket(t.ticket, { issuer: h.url, keys: joined.server.keys, owner: account, linkId: k.id, replay: new ReplayCache() }));
  // an expired key, a disabled account's key
  const old = (await runAdmin(["join-key", account, "1", "1"], { store: h.store, ring: h.ring, now: () => Date.now() - 2 * 3_600_000 })).split("\n")[0]!;
  assert.equal((await post(`${h.url}/v1/computers/join`, body(old))).status, 403);
  assert.ok(!h.logs.some((l) => l.includes(key) || l.includes("secret-relay-token")));
});

test("My devices lists the devices signed in now: one that signed out is gone from it, and comes back as itself with the same key", async () => {
  const h = await harness();
  const key = Buffer.alloc(32, 7).toString("base64url");
  const phone = await appSignIn(h, { device: { name: "Phone", platform: "ios", key } });
  const tablet = await appSignIn(h, { device: { name: "Tablet", platform: "ios" } });
  const names = async (session: string) => ((await json(await get(`${h.url}/v1/devices`, bearer(session)))).devices as { id: string; name: string }[]).map((d) => d.name);
  assert.deepEqual(await names(tablet.session), ["Phone", "Tablet"]);
  await post(`${h.url}/v1/signout`, {}, bearer(phone.session));
  assert.deepEqual(await names(tablet.session), ["Tablet"]);
  const again = await appSignIn(h, { device: { name: "Phone", platform: "ios", key } });
  assert.equal(again.device.id, phone.device.id);
  assert.deepEqual(await names(tablet.session), ["Phone", "Tablet"]);
});

test("devices that count are those signed in: browsers whose sign-in ran out do not fill the account", async () => {
  const h = await harness({ limits: { devicesPerAccount: 4 } });
  const s = await appSignIn(h, { device: { name: "Phone", platform: "ios", key: Buffer.alloc(32, 1).toString("base64url") } });
  const c = await joinComputer(h, s.session);
  // browsers of that computer, as its page signs them in (the store's own steps: the sign-in itself is the server's test)
  const browser = (name: string, at: number) => {
    const d = h.store.deviceFor(s.account.id, { name, platform: "web", key: null, keyDigest: null, computer: c.k.id }, at);
    h.store.createSession({ account: s.account.id, device: d.id, kind: "browser", now: at, maxAgeMs: 1000, idpRefresh: null });
    return d.id;
  };
  const long = Date.now() - 40 * 86_400_000;
  for (let i = 0; i < 10; i++) browser(`Old ${i}`, long);
  // ten browsers signed in 40 days ago, their sign-ins long over: none of them counts, and the sweep lets them go
  assert.equal(h.store.countDevices(s.account.id, Date.now()), 1);
  const tablet = await appSignIn(h, { device: { name: "Tablet", platform: "ios", key: Buffer.alloc(32, 2).toString("base64url") } });
  assert.ok(tablet.session, "a new device still signs in");
  h.store.sweep(Date.now());
  assert.equal(h.store.all<{ id: string }>("SELECT id FROM devices WHERE account_id = ? AND removed_at IS NULL", s.account.id).length, 2, "the phone and the tablet");
});

function relayToken(cfg: AccountConfig): string | null {
  const s = cfg.services.find((x) => x.name === "relay");
  return s?.kind === "fixed" ? (s.value()?.token ?? null) : null;
}
