// Email and password: sign up with a mailed code, sign in, a wrong password (one answer for a wrong email too) and its
// limit, a reset that ends the other sessions, a sign-up for an email that has a login (a mail that says so, no code),
// codes that run out after five wrong tries, the resend limits, a web page's key-bound session, the mail failing, the
// settings, and the SES request's signature.
import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { after, test } from "node:test";
import { ConfigError, configFromEnv } from "../src/config.js";
import { sesMailer, sigV4 } from "../src/mail.js";
import { hashPassword, normalizeEmail, verifyPassword } from "../src/password.js";
import { bearer, get, harness, post, stopAll, TestMailer } from "../src/testing/harness.js";

after(stopAll);

const device = { name: "Test iPhone", platform: "ios" };

async function signUp(h: { url: string }, mail: TestMailer, email: string, password = "correct horse") {
  const r = await post(`${h.url}/v1/auth/password/register`, { email, password, locale: "zh-Hans" });
  assert.equal(r.status, 200);
  const code = mail.codeFor(email.trim().toLowerCase())!;
  const v = await post(`${h.url}/v1/auth/password/verify`, { email, code, device });
  assert.equal(v.status, 200, await v.clone().text());
  return (await v.json()) as { session: string; account: { id: string; name: string }; idp: { name: string } };
}

test("sign up with a mailed code, then sign in; a wrong password and a wrong email get the same answer", async () => {
  const mail = new TestMailer();
  const h = await harness({ password: mail });
  assert.equal(((await (await get(`${h.url}/v1/config`)).json()) as { signin: { password: boolean } }).signin.password, true);
  const s = await signUp(h, mail, " Alice@Example.COM ");
  assert.equal(mail.sent[0]!.to, "alice@example.com");
  assert.match(mail.sent[0]!.subject, /验证码/);
  assert.equal(s.account.name, "alice@example.com");
  assert.equal(s.idp.name, "Email");
  assert.equal((await get(`${h.url}/v1/me`, bearer(s.session))).status, 200);
  // a computer this account approves is told it signs in by email (not the OpenID provider's name)
  const { enroll, linkKey } = await import("../src/testing/harness.js");
  const e = await enroll(h, linkKey());
  assert.equal((await post(`${h.url}/v1/computers/approve`, { user_code: e.body.user_code }, bearer(s.session))).status, 200);
  const polled = (await (await post(`${h.url}/v1/computers/poll`, { device_code: e.body.device_code })).json()) as { claimant: { idp: { name: string } } };
  assert.equal(polled.claimant.idp.name, "Email");
  // signing in: the same account
  const ok = await post(`${h.url}/v1/auth/password`, { email: "alice@example.com", password: "correct horse", device });
  assert.equal(ok.status, 200);
  assert.equal(((await ok.json()) as { account: { id: string } }).account.id, s.account.id);
  const wrong = await post(`${h.url}/v1/auth/password`, { email: "alice@example.com", password: "nope nope", device });
  const nobody = await post(`${h.url}/v1/auth/password`, { email: "bob@example.com", password: "nope nope", device });
  assert.deepEqual([wrong.status, nobody.status], [401, 401]);
  assert.deepEqual([((await wrong.json()) as { error: string }).error, ((await nobody.json()) as { error: string }).error], ["invalid_credentials", "invalid_credentials"]);
  // nothing in the logs is the email or the code
  assert.ok(!h.logs.some((l) => l.includes("alice@") || l.includes(mail.codeFor("alice@example.com") ?? "x")));
});

test("ten wrong passwords for one email: it waits (the right one too)", async () => {
  const mail = new TestMailer();
  const h = await harness({ password: mail, limits: { signinBurst: 100 } });
  await signUp(h, mail, "carol@example.com");
  for (let i = 0; i < 10; i++) assert.equal((await post(`${h.url}/v1/auth/password`, { email: "carol@example.com", password: `wrong-${i}-x`, device })).status, 401);
  assert.equal((await post(`${h.url}/v1/auth/password`, { email: "carol@example.com", password: "correct horse", device })).status, 429);
});

test("a sign-up for an email with a login: a mail that says so, no code; the answer is the same", async () => {
  const mail = new TestMailer();
  const h = await harness({ password: mail });
  await signUp(h, mail, "dan@example.com");
  h.clock.t = Date.now() + 120_000;
  const again = await post(`${h.url}/v1/auth/password/register`, { email: "dan@example.com", password: "another one" });
  assert.equal(again.status, 200);
  assert.deepEqual(await again.json(), { sent: true, expiresIn: 600 });
  assert.equal(mail.codeFor("dan@example.com"), null);
  assert.match(mail.sent.at(-1)!.subject, /already has an account/);
  // and no code it could be verified with
  assert.equal((await post(`${h.url}/v1/auth/password/verify`, { email: "dan@example.com", code: "000000", device })).status, 400);
});

test("a code: five wrong tries end it; one a minute, five an hour; a weak password and a bad email are refused", async () => {
  const mail = new TestMailer();
  const h = await harness({ password: mail, limits: { signinBurst: 100 } });
  assert.equal((await post(`${h.url}/v1/auth/password/register`, { email: "not an email", password: "long enough" })).status, 400);
  const weak = await post(`${h.url}/v1/auth/password/register`, { email: "erin@example.com", password: "short" });
  assert.equal(((await weak.json()) as { error: string }).error, "weak_password");
  assert.equal((await post(`${h.url}/v1/auth/password/register`, { email: "erin@example.com", password: "long enough" })).status, 200);
  const code = mail.codeFor("erin@example.com")!;
  const wrong = code === "000000" ? "111111" : "000000";
  const errors: string[] = [];
  for (let i = 0; i < 5; i++) errors.push(((await (await post(`${h.url}/v1/auth/password/verify`, { email: "erin@example.com", code: wrong, device })).json()) as { error: string }).error);
  assert.deepEqual(errors, ["invalid_code", "invalid_code", "invalid_code", "invalid_code", "code_expired"]);
  assert.equal((await post(`${h.url}/v1/auth/password/verify`, { email: "erin@example.com", code, device })).status, 400, "the right code no longer works");
  // a new code: not within the minute
  assert.equal((await post(`${h.url}/v1/auth/password/register`, { email: "erin@example.com", password: "long enough" })).status, 429);
  let t = Date.now();
  for (let i = 0; i < 4; i++) {
    t += 61_000;
    h.clock.t = t;
    assert.equal((await post(`${h.url}/v1/auth/password/register`, { email: "erin@example.com", password: "long enough" })).status, 200);
  }
  t += 61_000;
  h.clock.t = t;
  assert.equal((await post(`${h.url}/v1/auth/password/register`, { email: "erin@example.com", password: "long enough" })).status, 429, "the sixth in an hour");
  // a code ten minutes old: gone
  h.clock.t = t + 3_600_000;
  assert.equal((await post(`${h.url}/v1/auth/password/register`, { email: "erin@example.com", password: "long enough" })).status, 200);
  const late = mail.codeFor("erin@example.com")!;
  h.clock.t = t + 3_600_000 + 11 * 60_000;
  assert.equal(((await (await post(`${h.url}/v1/auth/password/verify`, { email: "erin@example.com", code: late, device })).json()) as { error: string }).error, "code_expired");
});

test("a reset: a code to the login's email (none for an unknown one, the same answer), the new password, the other sessions end", async () => {
  const mail = new TestMailer();
  const h = await harness({ password: mail });
  const first = await signUp(h, mail, "fay@example.com");
  h.clock.t = Date.now() + 120_000;
  const before = mail.sent.length;
  assert.deepEqual(await (await post(`${h.url}/v1/auth/password/reset`, { email: "nobody@example.com" })).json(), { sent: true, expiresIn: 600 });
  assert.equal(mail.sent.length, before, "nothing mailed for an email without a login");
  assert.equal((await post(`${h.url}/v1/auth/password/reset`, { email: "fay@example.com", locale: "en" })).status, 200);
  assert.match(mail.sent.at(-1)!.subject, /password reset code/);
  const code = mail.codeFor("fay@example.com")!;
  const weak = await post(`${h.url}/v1/auth/password/reset/confirm`, { email: "fay@example.com", code, password: "short", device });
  assert.equal(weak.status, 400);
  const done = await post(`${h.url}/v1/auth/password/reset/confirm`, { email: "fay@example.com", code, password: "a brand new one", device });
  assert.equal(done.status, 200);
  assert.equal(((await done.json()) as { account: { id: string } }).account.id, first.account.id);
  assert.equal((await get(`${h.url}/v1/me`, bearer(first.session))).status, 401, "the old session ended");
  assert.equal((await post(`${h.url}/v1/auth/password`, { email: "fay@example.com", password: "correct horse", device })).status, 401);
  assert.equal((await post(`${h.url}/v1/auth/password`, { email: "fay@example.com", password: "a brand new one", device })).status, 200);
  // the code is used
  assert.equal((await post(`${h.url}/v1/auth/password/reset/confirm`, { email: "fay@example.com", code, password: "yet another one", device })).status, 400);
});

test("from a web page's origin: the session is bound to its device key", async () => {
  const mail = new TestMailer();
  const web = "https://web.example.com/account/return";
  const h = await harness({ password: mail, env: { ACCOUNT_WEB_REDIRECTS: web } });
  const origin = { origin: "https://web.example.com" };
  assert.equal((await post(`${h.url}/v1/auth/password/register`, { email: "gil@example.com", password: "long enough" }, origin)).status, 200);
  const code = mail.codeFor("gil@example.com")!;
  const noKey = await post(`${h.url}/v1/auth/password/verify`, { email: "gil@example.com", code, device: { name: "Safari" } }, origin);
  assert.equal(noKey.status, 400, "a web page's session needs its key");
  const key = Buffer.from(generateKeyPairSync("ed25519").publicKey.export({ format: "der", type: "spki" })).subarray(-32).toString("base64url");
  const r = await post(`${h.url}/v1/auth/password/verify`, { email: "gil@example.com", code, device: { name: "Safari", key } }, origin);
  assert.equal(r.status, 200);
  const b = (await r.json()) as { session: string; proof?: string };
  assert.equal(b.proof, "yoyo-hosted-v1");
  assert.equal((await get(`${h.url}/v1/me`, bearer(b.session))).status, 401, "the token alone is nothing");
  assert.equal(r.headers.get("access-control-allow-origin"), "https://web.example.com");
});

test("the mail failing: 502, and a code may be asked for again at once", async () => {
  const mail = new TestMailer();
  const h = await harness({ password: mail });
  mail.failing = true;
  const r = await post(`${h.url}/v1/auth/password/register`, { email: "hal@example.com", password: "long enough" });
  assert.equal(r.status, 502);
  mail.failing = false;
  assert.equal((await post(`${h.url}/v1/auth/password/register`, { email: "hal@example.com", password: "long enough" })).status, 200);
});

test("off unless asked for; the settings it needs; an open sign-up only on purpose", async () => {
  const h = await harness();
  assert.notEqual((await post(`${h.url}/v1/auth/password`, { email: "a@example.com", password: "long enough" })).status, 200);
  const base = { ACCOUNT_OIDC_ISSUER: "https://id.example.com", ACCOUNT_OIDC_CLIENT_ID: "c", ACCOUNT_OIDC_CLIENT_SECRET: "s", ACCOUNT_PUBLIC_URL: "https://account.example.com" };
  const ses = { ACCOUNT_PASSWORD: "1", ACCOUNT_MAIL_FROM: "Example <no-reply@example.com>", ACCOUNT_SES_REGION: "us-east-1", ACCOUNT_SES_ACCESS_KEY_ID: "AKID", ACCOUNT_SES_SECRET_ACCESS_KEY: "secret" };
  assert.ok(configFromEnv({ ...base, ...ses, ACCOUNT_OPEN: "1" }).password);
  assert.ok(configFromEnv({ ...base, ...ses, ACCOUNT_ALLOW: "@example.com" }).password);
  assert.throws(() => configFromEnv({ ...base, ...ses }), (e: unknown) => e instanceof ConfigError && /anyone with an email/.test(e.message));
  assert.throws(() => configFromEnv({ ...base, ...ses, ACCOUNT_OPEN: "1", ACCOUNT_MAIL_FROM: "" }), /ACCOUNT_MAIL_FROM/);
  assert.throws(() => configFromEnv({ ...base, ...ses, ACCOUNT_OPEN: "1", ACCOUNT_SES_REGION: "" }), /SES/);
  assert.equal(configFromEnv(base).password, null);
});

test("an allow-list of domains: other emails may not sign up", async () => {
  const mail = new TestMailer();
  const h = await harness({ password: mail, env: { ACCOUNT_ALLOW: "@example.org" } });
  assert.equal((await post(`${h.url}/v1/auth/password/register`, { email: "ida@example.com", password: "long enough" })).status, 403);
  assert.equal((await post(`${h.url}/v1/auth/password/register`, { email: "ida@example.org", password: "long enough" })).status, 200);
});

test("passwords: scrypt, salted, checked; emails as kept", async () => {
  const a = await hashPassword("pässword 1");
  const b = await hashPassword("pässword 1");
  assert.notEqual(a, b, "salted");
  assert.match(a, /^scrypt\$32768\$8\$1\$/);
  assert.equal(await verifyPassword("pässword 1", a), true);
  assert.equal(await verifyPassword("pässword 2", a), false);
  assert.equal(await verifyPassword("x", "garbage"), false);
  assert.equal(normalizeEmail("  Bob@Example.Com "), "bob@example.com");
  for (const bad of ["bob", "bob@", "@example.com", "bob@example", "a b@example.com", 7]) assert.equal(normalizeEmail(bad), null, String(bad));
});

test("SES: the v2 SendEmail request, signed (SigV4) for the region and service", async () => {
  const sent: { url: string; init: RequestInit }[] = [];
  const m = sesMailer({ region: "us-east-1", accessKeyId: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", from: "Example <no-reply@example.com>", now: () => Date.UTC(2026, 10, 26, 12, 0, 0), fetch: async (url, init) => (sent.push({ url: String(url), init: init! }), new Response("{}")) });
  await m.send({ to: "a@example.com", subject: "s", text: "t" });
  assert.equal(sent[0]!.url, "https://email.us-east-1.amazonaws.com/v2/email/outbound-emails");
  const h = sent[0]!.init.headers as Record<string, string>;
  assert.equal(h["x-amz-date"], "20261126T120000Z");
  assert.match(h.authorization!, /^AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE\/20261126\/us-east-1\/ses\/aws4_request, SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, Signature=[0-9a-f]{64}$/);
  const body = JSON.parse(String(sent[0]!.init.body));
  assert.deepEqual(body.Destination, { ToAddresses: ["a@example.com"] });
  assert.equal(body.Content.Simple.Body.Text.Charset, "UTF-8");
  // the same request signs the same; another body does not
  const again = sigV4({ method: "POST", url: sent[0]!.url, body: String(sent[0]!.init.body), region: "us-east-1", service: "ses", accessKeyId: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", contentType: "application/json", now: Date.UTC(2026, 10, 26, 12, 0, 0) });
  assert.equal(again.authorization, h.authorization);
  assert.notEqual(sigV4({ method: "POST", url: sent[0]!.url, body: "{}", region: "us-east-1", service: "ses", accessKeyId: "AKIDEXAMPLE", secretAccessKey: "x", contentType: "application/json", now: 0 }).authorization, h.authorization);
  // refused: thrown
  const no = sesMailer({ region: "us-east-1", accessKeyId: "a", secretAccessKey: "b", from: "x@example.com", fetch: async () => new Response("denied", { status: 403 }) });
  await assert.rejects(no.send({ to: "a@example.com", subject: "s", text: "t" }), /HTTP 403/);
});
