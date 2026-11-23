// Settings: the three IdP lines, the refusal to start against an IdP anyone can sign up at, the allow-list, issuers.
import assert from "node:assert/strict";
import { test } from "node:test";
import { allowed, ConfigError, configFromEnv, normalizeIssuer, opennessProblem, parseAllow } from "../src/config.js";

const base = { ACCOUNT_OIDC_ISSUER: "https://id.example.com", ACCOUNT_OIDC_CLIENT_ID: "example-account", ACCOUNT_OIDC_CLIENT_SECRET: "s", ACCOUNT_PUBLIC_URL: "https://account.example.com" };

test("three lines say which IdP; the rest has defaults", () => {
  const c = configFromEnv(base);
  assert.equal(c.issuer, "https://id.example.com");
  assert.equal(c.recheck, false, "the re-check is off by default");
  assert.deepEqual(c.appRedirects, []);
  assert.equal(c.port, 4490);
  assert.equal(c.idpName, "id.example.com");
  // the secret from its file
  assert.equal(configFromEnv({ ...base, ACCOUNT_OIDC_CLIENT_SECRET: "" }, "from-file\n").clientSecret, "from-file");
  assert.throws(() => configFromEnv({ ...base, ACCOUNT_OIDC_CLIENT_SECRET: "" }), ConfigError);
  assert.throws(() => configFromEnv({ ...base, ACCOUNT_OIDC_ISSUER: "http://id.example.com" }), /https/);
  assert.throws(() => configFromEnv({ ...base, ACCOUNT_PUBLIC_URL: "https://account.example.com/sub" }), /origin/);
  assert.throws(() => configFromEnv({ ...base, ACCOUNT_IDP_RECHECK: "yes" }), /1 or 0/);
  assert.throws(() => configFromEnv({ ...base, ACCOUNT_APP_REDIRECTS: "javascript:alert(1)" }), ConfigError);
  assert.throws(() => configFromEnv({ ...base, ACCOUNT_WEB_REDIRECTS: "http://app.example.com/cb" }), /https/);
  // a web page's address is never an app's too (a code back to it makes a key-bound web session)
  assert.throws(() => configFromEnv({ ...base, ACCOUNT_APP_REDIRECTS: "https://app.example.com/cb", ACCOUNT_WEB_REDIRECTS: "https://app.example.com/cb" }), /app's redirect too/);
  assert.throws(() => configFromEnv({ ...base, ACCOUNT_WEB_REDIRECTS: "https://account.example.com/v1/app-return" }), /app's redirect too/);
  assert.equal(configFromEnv({ ...base, ACCOUNT_IDP_RECHECK: "1" }).recheck, true);
  // a Keycloak realm's issuer has a path
  assert.equal(configFromEnv({ ...base, ACCOUNT_OIDC_ISSUER: "https://kc.example.com/realms/example/" }).issuer, "https://kc.example.com/realms/example");
});

test("an IdP anyone can sign up at does not start without an allow-list or ACCOUNT_OPEN=1", () => {
  for (const iss of ["https://accounts.google.com", "accounts.google.com", "https://login.microsoftonline.com/common/v2.0", "https://appleid.apple.com", "https://gitlab.com"]) {
    const env = { ...base, ACCOUNT_OIDC_ISSUER: iss.startsWith("http") ? iss : `https://${iss}` };
    assert.throws(() => configFromEnv(env), /lets anyone sign in/, iss);
    assert.ok(configFromEnv({ ...env, ACCOUNT_ALLOW: "1234567890" }));
    assert.ok(configFromEnv({ ...env, ACCOUNT_OPEN: "1" }));
  }
  // a tenant's own Microsoft endpoint, a self-hosted IdP: the IdP decides who has an account
  assert.equal(opennessProblem({ issuer: "https://login.microsoftonline.com/11111111-2222-3333-4444-555555555555/v2.0", allow: null, open: false }), null);
  assert.equal(opennessProblem({ issuer: "https://id.example.com", allow: null, open: false }), null);
});

test("Google's two iss forms are one issuer", () => {
  assert.equal(normalizeIssuer("accounts.google.com"), "https://accounts.google.com");
  assert.equal(normalizeIssuer("https://accounts.google.com/"), "https://accounts.google.com");
});

test("the allow-list: subs exactly; @domain = a verified email there, or Google's hd", () => {
  const a = parseAllow("u-1, @Example.org");
  assert.ok(allowed(a, "https://id.example.com", { sub: "u-1" }));
  assert.ok(!allowed(a, "https://id.example.com", { sub: "u-11" }));
  assert.ok(allowed(a, "https://id.example.com", { sub: "x", email: "x@example.org", email_verified: true }));
  assert.ok(!allowed(a, "https://id.example.com", { sub: "x", email: "x@example.org", email_verified: false }));
  assert.ok(!allowed(a, "https://id.example.com", { sub: "x", email: "x@notexample.org", email_verified: true }));
  assert.ok(!allowed(a, "https://id.example.com", { sub: "x", email: "x@example.org.evil.example", email_verified: true }));
  // Google: hd, not the address (a gmail account can have a verified address anywhere)
  assert.ok(allowed(a, "https://accounts.google.com", { sub: "x", hd: "example.org" }));
  assert.ok(!allowed(a, "https://accounts.google.com", { sub: "x", email: "x@example.org", email_verified: true }));
  assert.ok(allowed(null, "https://id.example.com", { sub: "anyone" }));
  assert.throws(() => parseAllow("@nodot"), ConfigError);
});
