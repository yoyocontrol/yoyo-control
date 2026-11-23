// The OIDC client against the stand-in IdP: Google (both iss forms, access_type=offline and prompt=consent only with
// the re-check), client authentication (basic with RFC 6749 encoding, else post), discovery checks, and what a refresh
// answer means.
import assert from "node:assert/strict";
import { after, test } from "node:test";
import { configFromEnv } from "../src/config.js";
import { IdpError, OidcClient, cleanText } from "../src/oidc.js";
import { TestIdp } from "../src/testing/idp.js";

const idps: TestIdp[] = [];
after(async () => {
  for (const i of idps) await i.stop();
});
async function idp(f?: (i: TestIdp) => void) {
  const i = await new TestIdp().start();
  f?.(i);
  idps.push(i);
  return i;
}
const cfgOf = (i: TestIdp, extra: Record<string, string> = {}) =>
  configFromEnv({ ACCOUNT_OIDC_ISSUER: i.issuer, ACCOUNT_OIDC_CLIENT_ID: i.clientId, ACCOUNT_OIDC_CLIENT_SECRET: i.clientSecret, ACCOUNT_PUBLIC_URL: "https://account.example.com", ...extra });

/** A code from the stand-in IdP for this client's authorization URL. */
async function codeFor(c: OidcClient, nonce = "n1") {
  const url = await c.authorizationUrl({ state: "s", nonce, challenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM" });
  const r = await fetch(url.replace("https://accounts.google.com", (c as unknown as { gIdp: string }).gIdp ?? ""), { redirect: "manual" });
  return { url: new URL(url), code: new URL(r.headers.get("location")!).searchParams.get("code")! };
}
const VERIFIER = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";

/** Google, played by the stand-in: https://accounts.google.com/... goes to it. */
async function google(issClaim: string, recheck: boolean) {
  const i = await idp((x) => {
    x.issClaim = issClaim;
    x.discoveryIssuer = "https://accounts.google.com";
  });
  const f: typeof fetch = (input, init) => fetch(String(input instanceof Request ? input.url : input).replace("https://accounts.google.com", i.issuer), init);
  const cfg = configFromEnv({ ACCOUNT_OIDC_ISSUER: "https://accounts.google.com", ACCOUNT_OIDC_CLIENT_ID: i.clientId, ACCOUNT_OIDC_CLIENT_SECRET: i.clientSecret, ACCOUNT_PUBLIC_URL: "https://account.example.com", ACCOUNT_ALLOW: "@example.org", ...(recheck ? { ACCOUNT_IDP_RECHECK: "1" } : {}) });
  const c = new OidcClient(cfg, { fetch: f });
  (c as unknown as { gIdp: string }).gIdp = i.issuer;
  return { i, c };
}

test("Google: both iss forms verify and are stored as the URL; offline access only with the re-check", async () => {
  for (const form of ["https://accounts.google.com", "accounts.google.com"]) {
    const { c } = await google(form, true);
    const { url, code } = await codeFor(c);
    assert.equal(url.searchParams.get("access_type"), "offline");
    assert.equal(url.searchParams.get("prompt"), "consent");
    assert.equal(url.searchParams.get("scope"), "openid profile email", "no offline_access scope for Google");
    // (the stand-in's code was issued for the URL's redirect; the client exchanges it with the same)
    const r = await c.exchange(code, VERIFIER, "n1").catch((e: Error) => e);
    // the challenge above is RFC 7636's example for VERIFIER
    assert.ok(!(r instanceof Error), String(r));
    assert.equal((r as { identity: { iss: string } }).identity.iss, "https://accounts.google.com");
  }
  const { c } = await google("https://accounts.google.com", false);
  const { url } = await codeFor(c);
  assert.equal(url.searchParams.get("access_type"), null);
  assert.equal(url.searchParams.get("prompt"), null);
  // an iss that is neither Google form is refused
  const bad = await google("https://accounts.google.com.evil.example", false);
  const { code } = await codeFor(bad.c);
  await assert.rejects(bad.c.exchange(code, VERIFIER, "n1"), IdpError);
});

test("client authentication: basic with each part form-encoded, else post when that is all the IdP takes", async () => {
  for (const postOnly of [false, true]) {
    const i = await idp((x) => (x.postOnly = postOnly));
    const c = new OidcClient(cfgOf(i));
    const { code } = await codeFor(c);
    const r = await c.exchange(code, VERIFIER, "n1");
    assert.equal(r.identity.sub, "u-alice");
    assert.ok(r.refreshToken);
  }
});

test("discovery: the issuer must be the configured one", async () => {
  const i = await idp((x) => (x.discoveryIssuer = "https://other.example.com"));
  await assert.rejects(new OidcClient(cfgOf(i)).discovery(), /issuer/);
});

test("refresh: ok (rotated or not), invalid_grant, and everything else is 'retry'", async () => {
  const i = await idp();
  const c = new OidcClient(cfgOf(i));
  const { code } = await codeFor(c);
  const { refreshToken } = await c.exchange(code, VERIFIER, "n1");
  const ok = await c.refresh(refreshToken!, "u-alice");
  assert.equal(ok.kind, "ok");
  const rotated = ok.kind === "ok" ? ok.refreshToken! : "";
  // the old one again: the IdP's reuse detection says invalid_grant (and kills the family)
  assert.deepEqual(await c.refresh(refreshToken!, "u-alice"), { kind: "invalid_grant" });
  assert.deepEqual(await c.refresh(rotated, "u-alice"), { kind: "invalid_grant" });
  for (const mode of ["5xx", "429", "drop", "invalid_client", "html"] as const) {
    i.mode = mode;
    assert.equal((await c.refresh("whatever", "u-alice")).kind, "retry", mode);
  }
  i.mode = "ok";
  i.rotate = false;
  const { code: code2 } = await codeFor(c);
  const t = (await c.exchange(code2, VERIFIER, "n1")).refreshToken!;
  const same = await c.refresh(t, "u-alice");
  assert.deepEqual(same.kind === "ok" && same.refreshToken, null, "not rotated: keep the old");
  assert.equal((await c.refresh(t, "u-bob")).kind, "retry", "another sub in the refreshed id_token");
});

test("shown text loses control and bidi characters and is cut", () => {
  assert.equal(cleanText(" a‮b\u0000c​ ", 64), "abc");
  assert.equal(cleanText("x".repeat(100), 64).length, 64);
});
