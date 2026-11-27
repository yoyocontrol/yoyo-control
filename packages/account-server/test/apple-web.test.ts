// Sign in with Apple on the web: Apple as the OpenID provider of a web page's sign-in, next to the app's native one.
// The settings (the Services ID as the client, the client secret signed here with the Sign in with Apple key), the
// scope (only `openid`: Apple takes no `profile`), and the secret the token endpoint gets.
import assert from "node:assert/strict";
import { generateKeyPairSync, verify } from "node:crypto";
import { test } from "node:test";
import { ConfigError, configFromEnv } from "../src/config.js";
import { OidcClient } from "../src/oidc.js";

const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
const pem = privateKey.export({ format: "pem", type: "pkcs8" }).toString();
const env = {
  ACCOUNT_PUBLIC_URL: "https://account.example.com",
  ACCOUNT_OPEN: "1",
  ACCOUNT_APPLE_AUDIENCES: "com.example.app",
  ACCOUNT_APPLE_TEAM_ID: "TEAM123456",
  ACCOUNT_APPLE_KEY_ID: "KEY1234567",
  ACCOUNT_APPLE_KEY: pem,
  ACCOUNT_OIDC_ISSUER: "https://appleid.apple.com",
  ACCOUNT_OIDC_CLIENT_ID: "com.example.web",
  ACCOUNT_WEB_REDIRECTS: "https://app.example.com/account/return",
};

test("Apple as the web's provider: the Services ID is the client, the secret is signed here, the app's sign-in stays", () => {
  const c = configFromEnv(env);
  assert.equal(c.oidc, true);
  assert.equal(c.issuer, "https://appleid.apple.com");
  assert.equal(c.clientId, "com.example.web");
  assert.equal(c.clientSecret, "");
  assert.deepEqual(c.appleSecret, { teamId: "TEAM123456", keyId: "KEY1234567", clientId: "com.example.web", privateKey: pem.trim() });
  assert.deepEqual(c.apple?.audiences, ["com.example.app"], "the app's native sign-in is still there");
  assert.equal(c.idpName, "Apple");
  // a secret given is used as it is
  assert.equal(configFromEnv({ ...env, ACCOUNT_OIDC_CLIENT_SECRET: "given" }).appleSecret, null);
  // no Sign in with Apple key and no secret: nothing to sign with
  const { ACCOUNT_APPLE_TEAM_ID: _t, ACCOUNT_APPLE_KEY_ID: _k, ACCOUNT_APPLE_KEY: _p, ...noKey } = env;
  assert.throws(() => configFromEnv(noKey), (e: unknown) => e instanceof ConfigError && /Sign in with Apple key/.test(e.message));
  // another provider is no Apple one
  assert.equal(configFromEnv({ ...env, ACCOUNT_OIDC_ISSUER: "https://id.example.com", ACCOUNT_OIDC_CLIENT_SECRET: "s" }).appleSecret, null);
});

test("Apple's token endpoint gets a client secret signed with the key, for the Services ID; the scope is openid", async () => {
  const sent: URLSearchParams[] = [];
  const fake: typeof fetch = async (input, init) => {
    const url = String(input instanceof Request ? input.url : input);
    if (url === "https://appleid.apple.com/.well-known/openid-configuration") {
      return Response.json({
        issuer: "https://appleid.apple.com",
        authorization_endpoint: "https://appleid.apple.com/auth/authorize",
        token_endpoint: "https://appleid.apple.com/auth/token",
        jwks_uri: "https://appleid.apple.com/auth/keys",
        scopes_supported: ["openid", "email", "name"],
        token_endpoint_auth_methods_supported: ["client_secret_post"],
        id_token_signing_alg_values_supported: ["RS256"],
      });
    }
    if (url === "https://appleid.apple.com/auth/token") {
      sent.push(new URLSearchParams(String(init?.body)));
      return Response.json({ error: "invalid_grant" }, { status: 400 });
    }
    return new Response("no", { status: 404 });
  };
  const c = new OidcClient(configFromEnv(env), { fetch: fake });
  const auth = new URL(await c.authorizationUrl({ state: "s", nonce: "n", challenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM" }));
  assert.equal(auth.origin + auth.pathname, "https://appleid.apple.com/auth/authorize");
  assert.equal(auth.searchParams.get("scope"), "openid");
  assert.equal(auth.searchParams.get("client_id"), "com.example.web");
  assert.equal(auth.searchParams.get("redirect_uri"), "https://account.example.com/v1/callback");
  await assert.rejects(c.exchange("code", "verifier", "n"), /idp_token|HTTP 400/);
  const body = sent[0]!;
  assert.equal(body.get("client_id"), "com.example.web");
  const [h, p, s] = body.get("client_secret")!.split(".");
  const header = JSON.parse(Buffer.from(h!, "base64url").toString());
  const payload = JSON.parse(Buffer.from(p!, "base64url").toString());
  assert.deepEqual(header, { alg: "ES256", kid: "KEY1234567" });
  assert.equal(payload.iss, "TEAM123456");
  assert.equal(payload.sub, "com.example.web");
  assert.equal(payload.aud, "https://appleid.apple.com");
  assert.ok(payload.exp > payload.iat);
  assert.ok(verify("SHA256", Buffer.from(`${h}.${p}`), { key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(s!, "base64url")));
});
