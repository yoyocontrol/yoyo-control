// A browser's side (client.ts) against the real account server (@yoyocontrol/account-server, on a loopback port with
// its stand-in sign-in system): sign in, a key the page cannot read out, signed requests, the list, a ticket, the same
// key as the same device next time, sign-out; a sign-in this tab did not start, or one that ran out, is refused; a
// clock that is off is set by the server's.
import assert from "node:assert/strict";
import { after, test } from "node:test";
import { appSignIn, computerCall, confirm, enroll, get, harness, joinComputer, linkKey, post, stopAll, type Harness } from "@yoyocontrol/account-server/testing";
import { AccountError, beginSignIn, finishSignIn, isSignInReturn, joinCode, resumeSignIn, SignInError, type Keep, type SavedSignIn } from "../src/index.js";

after(stopAll);

const RETURN = "https://web.example.com/account/return";

function memoryKeep(): Keep & { saved: SavedSignIn | null } {
  let key: CryptoKeyPair | null = null;
  const k = {
    saved: null as SavedSignIn | null,
    get: async () => k.saved,
    set: async (v: SavedSignIn | null) => void (k.saved = v),
    getKey: async () => key,
    setKey: async (v: CryptoKeyPair | null) => void (key = v),
  };
  return k;
}

/** The browser's trip: the page → the account server → the sign-in system → back to the page (the URL it lands on). */
async function trip(_h: Harness, url: string): Promise<string> {
  const signin = await get(url);
  const atIdp = await get(signin.headers.get("location")!);
  const cb = await get(atIdp.headers.get("location")!);
  return cb.headers.get("location")!;
}

test("signs in with a key nothing can read out; signed requests: me, the list with what each computer says, a ticket, sign-out", async () => {
  const h = await harness({ env: { ACCOUNT_WEB_REDIRECTS: RETURN } });
  const app = await appSignIn(h);
  const pc = await joinComputer(h, app.session);
  await computerCall(h, pc.k, "POST", "/v1/computer/update", { signal: "https://signal.example.com", info: { id: "srv-1", platform: "linux" } });
  const keep = memoryKeep();
  const { url, pending } = await beginSignIn(h.url, RETURN);
  assert.match(url, /\/v1\/signin\?redirect_uri=https%3A%2F%2Fweb\.example\.com/);
  const landed = await trip(h, url);
  assert.ok(isSignInReturn(landed));
  assert.ok(!isSignInReturn(RETURN));
  const client = await finishSignIn(landed, pending, { keep, deviceName: "Safari on Mac" });
  assert.equal(client.account.id, app.account.id);
  assert.equal(keep.saved!.key.privateKey.extractable, false);
  await assert.rejects(crypto.subtle.exportKey("pkcs8", keep.saved!.key.privateKey));
  const me = await client.me();
  assert.equal(me.account.id, app.account.id);
  assert.equal(me.device?.id, client.device.id);
  const list = await client.computers();
  assert.deepEqual(list.map((c) => [c.linkId, c.signal, c.info?.platform]), [[pc.k.id, "https://signal.example.com", "linux"]]);
  assert.ok((await client.ticket(pc.k.id)).split(".").length === 3);
  // the token alone is nothing (the server wants the key's proof)
  assert.equal((await get(`${h.url}/v1/me`, { authorization: `Bearer ${keep.saved!.session}` })).status, 401);
  // a later visit: the kept sign-in
  const again = await resumeSignIn({ keep });
  assert.equal((await again!.computers()).length, 1);
  // the same key signs in again as the same device
  const second = await beginSignIn(h.url, RETURN);
  const c2 = await finishSignIn(await trip(h, second.url), second.pending, { keep, deviceName: "Safari on Mac" });
  assert.equal(c2.device.id, client.device.id);
  // signed out: forgotten here, refused there
  const token = keep.saved!.session;
  await c2.signOut();
  assert.equal(keep.saved, null);
  assert.equal(await resumeSignIn({ keep }), null);
  const stale = await resumeSignIn({ keep: { ...memoryKeep(), get: async () => ({ ...c2.saved, session: token }) } });
  await assert.rejects(stale!.computers(), (e: AccountError) => e.signedOut);
});

test("a join code typed or pasted is looked up and approved with the key's proof; the computer then says yes", async () => {
  const h = await harness({ env: { ACCOUNT_WEB_REDIRECTS: RETURN } });
  const keep = memoryKeep();
  const { url, pending } = await beginSignIn(h.url, RETURN);
  const client = await finishSignIn(await trip(h, url), pending, { keep, deviceName: "Firefox on Linux" });
  const k = linkKey();
  const e = await enroll(h, k);
  // the code as shown, in lower case, or the computer's QR text
  assert.equal(joinCode(e.body.user_code.toLowerCase()), e.body.user_code.replace("-", ""));
  assert.equal(joinCode(e.body.qr), e.body.user_code.replace("-", ""));
  assert.equal(joinCode("hello"), "");
  const found = await client.lookupJoin(` ${e.body.user_code} `);
  assert.equal(found.linkId, k.id);
  assert.equal(found.status, "pending");
  assert.equal(found.expectsAccount, false);
  await client.approveJoin(found.code);
  await assert.rejects(client.approveJoin(found.code), (x: AccountError) => x.code === "already_approved");
  const polled = (await (await post(`${h.url}/v1/computers/poll`, { device_code: e.body.device_code })).json()) as { claimant: { by: string } };
  assert.equal(polled.claimant.by, "Firefox on Linux");
  assert.equal((await confirm(h, k, e.body.device_code, client.account.id)).status, 200);
  assert.deepEqual((await client.computers()).map((c) => c.linkId), [k.id]);
  await assert.rejects(client.lookupJoin("BCDF-GHJK"), (x: AccountError) => x.status === 404);
});

test("a sign-in this tab did not start, one that ran out, an error from the server: not finished", async () => {
  const h = await harness({ env: { ACCOUNT_WEB_REDIRECTS: RETURN } });
  const keep = memoryKeep();
  const a = await beginSignIn(h.url, RETURN);
  const landed = await trip(h, a.url);
  const other = await beginSignIn(h.url, RETURN);
  await assert.rejects(finishSignIn(landed, other.pending, { keep, deviceName: "x" }), (e: SignInError) => e.code === "state");
  await assert.rejects(finishSignIn(landed, null, { keep, deviceName: "x" }), (e: SignInError) => e.code === "state");
  await assert.rejects(finishSignIn(landed, a.pending, { keep, deviceName: "x", now: Date.now() + 11 * 60_000 }), (e: SignInError) => e.code === "expired");
  await assert.rejects(finishSignIn(`${RETURN}?error=access_denied&state=${a.pending.state}`, a.pending, { keep, deviceName: "x" }), (e: SignInError) => e.code === "access_denied");
  assert.equal(keep.saved, null);
  // (and the code itself still works for the tab that started it)
  const ok = await finishSignIn(landed, a.pending, { keep, deviceName: "x" });
  assert.equal(ok.device.name, "x");
  // an http account server is not taken, but for loopback (tests)
  await assert.rejects(beginSignIn("http://account.example.com", RETURN));
});

test("another namespace: a server of another product's names takes this page only with the same namespace", async () => {
  const h = await harness({ env: { ACCOUNT_WEB_REDIRECTS: RETURN, ACCOUNT_NAMESPACE: "acme" } });
  const keep = memoryKeep();
  const a = await beginSignIn(h.url, RETURN);
  await assert.rejects(finishSignIn(await trip(h, a.url), a.pending, { keep, deviceName: "x" }), (e: SignInError) => e.code === "unbound");
  const b = await beginSignIn(h.url, RETURN);
  const client = await finishSignIn(await trip(h, b.url), b.pending, { keep, deviceName: "x", namespace: "acme" });
  assert.deepEqual(await client.computers(), []);
});

test("a clock ten minutes off is set by the server's, not taken for a sign-out; an old tab's 401 does not forget a newer sign-in", async () => {
  const h = await harness({ env: { ACCOUNT_WEB_REDIRECTS: RETURN } });
  const app = await appSignIn(h);
  await joinComputer(h, app.session);
  const keep = memoryKeep();
  const slow = () => Date.now() - 10 * 60_000;
  const { url, pending } = await beginSignIn(h.url, RETURN);
  const client = await finishSignIn(await trip(h, url), pending, { keep, deviceName: "Old laptop", clock: slow });
  assert.equal((await client.computers()).length, 1, "asked again by the server's time");
  assert.ok(keep.saved, "still signed in");
  const second = await beginSignIn(h.url, RETURN);
  const newer = await finishSignIn(await trip(h, second.url), second.pending, { keep, deviceName: "Old laptop" });
  assert.notEqual(newer.saved.session, client.saved.session);
  await assert.rejects(client.computers(), (e: AccountError) => e.signedOut);
  assert.equal(keep.saved?.session, newer.saved.session, "the newer sign-in is kept");
});

test("email and password from a web page: sign up with the mailed code, sign in, reset; every session key-bound", async () => {
  const { TestMailer } = await import("@yoyocontrol/account-server/testing");
  const { emailSignIn } = await import("../src/index.js");
  const mail = new TestMailer();
  const h = await harness({ password: mail, env: { ACCOUNT_WEB_REDIRECTS: RETURN } });
  // (a browser sends its page's origin with every cross-origin request)
  const page: typeof fetch = (u, i) => fetch(u, { ...i, headers: { ...(i?.headers as Record<string, string>), origin: "https://web.example.com" } });
  const keep = memoryKeep();
  await emailSignIn.register(h.url, "Web@Example.com", "long enough", { locale: "en", fetch: page });
  const client = await emailSignIn.verify(h.url, "web@example.com", mail.codeFor("web@example.com")!, { keep, deviceName: "Safari on Mac", fetch: page });
  assert.equal(client.account.name, "web@example.com");
  assert.equal(keep.saved!.key.privateKey.extractable, false);
  assert.deepEqual(await client.computers(), []);
  const again = await emailSignIn.signIn(h.url, "web@example.com", "long enough", { keep, deviceName: "Safari on Mac", fetch: page });
  assert.equal(again.device.id, client.device.id, "the same key: the same device");
  await assert.rejects(emailSignIn.signIn(h.url, "web@example.com", "wrong one!", { keep, deviceName: "x", fetch: page }), (e: AccountError) => e.code === "invalid_credentials");
  await assert.rejects(emailSignIn.register(h.url, "web@example.com", "short", { fetch: page }), (e: AccountError) => e.code === "weak_password");
  await emailSignIn.reset(h.url, "web@example.com", { fetch: page });
  const reset = await emailSignIn.confirmReset(h.url, "web@example.com", mail.codeFor("web@example.com")!, "the new one", { keep, deviceName: "Safari on Mac", fetch: page });
  await assert.rejects(again.computers(), (e: AccountError) => e.signedOut, "the other sessions ended");
  assert.deepEqual(await reset.computers(), []);
});

test("sign-in by QR code: this browser shows a code, the app approves, the wait ends signed in with a key nothing can read out; a signed-in page approves another's code", async () => {
  const { beginQrSignIn, qrSignInLink, signInCode } = await import("../src/index.js");
  const h = await harness({ env: { ACCOUNT_WEB_REDIRECTS: RETURN } });
  const app = await appSignIn(h);
  const keep = memoryKeep();
  const qr = await beginQrSignIn(h.url, { keep, deviceName: "Chrome on Windows" });
  assert.match(qr.code, /^[A-Z]{8}$/);
  assert.equal(qr.userCode, `${qr.code.slice(0, 4)}-${qr.code.slice(4)}`);
  const link = qrSignInLink("https://web.example.com/app/login", qr.code);
  assert.equal(link, `https://web.example.com/app/login#${qr.code}`);
  // what a scanner or a person gives back
  assert.equal(signInCode(link), qr.code);
  assert.equal(signInCode(` ${qr.userCode.toLowerCase()} `), qr.code);
  assert.equal(signInCode("https://web.example.com/app/login#nope"), "");
  const waiting = qr.wait();
  const look = (await (await get(`${h.url}/v1/auth/qr/lookup?code=${qr.code}`, { authorization: `Bearer ${app.session}` })).json()) as { device: { name: string } };
  assert.equal(look.device.name, "Chrome on Windows");
  assert.equal((await post(`${h.url}/v1/auth/qr/approve`, { code: qr.code }, { authorization: `Bearer ${app.session}` })).status, 200);
  const client = await waiting;
  assert.equal(client.account.id, app.account.id);
  assert.equal(keep.saved!.key.privateKey.extractable, false);
  assert.deepEqual(await client.computers(), []);
  // this browser approves a second one's code (looked up first), and declines a third's
  const keep2 = memoryKeep();
  const qr2 = await beginQrSignIn(h.url, { keep: keep2, deviceName: "Desktop", platform: "windows" });
  const found = await client.lookupSignIn(qrSignInLink("https://web.example.com/app/login", qr2.code));
  assert.deepEqual(found.device, { name: "Desktop", platform: "windows" });
  assert.equal(found.from, "127.0.0.1");
  assert.ok(found.expiresIn > 100);
  const second = qr2.wait();
  await client.approveSignIn(found.code);
  assert.equal((await second).account.id, app.account.id);
  const qr3 = await beginQrSignIn(h.url, { keep: memoryKeep(), deviceName: "Someone else" });
  const third = qr3.wait();
  await client.declineSignIn(qr3.userCode);
  await assert.rejects(third, (e: SignInError) => e.code === "access_denied");
  await assert.rejects(client.lookupSignIn(qr3.code), (e: AccountError) => e.status === 404);
  // stopped: the wait ends at once
  const qr4 = await beginQrSignIn(h.url, { keep: memoryKeep(), deviceName: "x" });
  const ac = new AbortController();
  const fourth = qr4.wait({ signal: ac.signal });
  ac.abort();
  await assert.rejects(fourth, (e: SignInError) => e.code === "aborted");
});
