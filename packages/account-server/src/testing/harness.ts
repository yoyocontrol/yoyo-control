// A running account server for tests (yours and this package's; `@yoyocontrol/account-server/testing`): a TestIdp, an in-memory (or file) store, a key ring, the service on
// a loopback port, and the client steps — an app's sign-in through the IdP, a computer's join.
import { createHash, generateKeyPairSync, randomBytes, sign, type KeyObject } from "node:crypto";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { configFromEnv, type AccountConfig } from "../config.js";
import { KeyRing } from "../keys.js";
import { OidcClient } from "../oidc.js";
import { Rechecker } from "../recheck.js";
import { DEFAULT_WIRE } from "@yoyocontrol/account";
import { AccountService, type Limits, type NoticeOut } from "../service.js";

/** The default namespace's signed texts and service names (a harness without ACCOUNT_NAMESPACE; `h.cfg.wire` has a
 *  harness's own). */
export const computerProofText = DEFAULT_WIRE.computerProofText.bind(DEFAULT_WIRE);
export const joinProofText = DEFAULT_WIRE.joinProofText.bind(DEFAULT_WIRE);
export const joinKeyProofText = DEFAULT_WIRE.joinKeyProofText.bind(DEFAULT_WIRE);
export const hostedProofText = DEFAULT_WIRE.hostedProofText.bind(DEFAULT_WIRE);
export const PUSH_SERVICE = DEFAULT_WIRE.service("push");
export const SPEECH_SERVICE = DEFAULT_WIRE.service("speech");
import { Store } from "../store.js";
import { TestIdp } from "./idp.js";
import type { TestApple } from "./apple.js";

export interface LinkKey {
  id: string;
  key: KeyObject;
  sign(text: string): string;
}
export function linkKey(): LinkKey {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const x = (publicKey.export({ format: "jwk" }) as { x: string }).x;
  return { id: Buffer.from(x, "base64url").toString("hex"), key: privateKey, sign: (t) => sign(null, Buffer.from(t, "utf8"), privateKey).toString("base64url") };
}

export interface Harness {
  idp: TestIdp;
  store: Store;
  ring: KeyRing;
  cfg: AccountConfig;
  svc: AccountService;
  oidc: OidcClient;
  recheck: Rechecker;
  url: string;
  logs: string[];
  notices: NoticeOut[];
  clock: { t: number | null };
  stop(): Promise<void>;
}

const running: Harness[] = [];

/** `apple`: a stand-in for Apple (identity tokens, StoreKit) — give ACCOUNT_APPLE_AUDIENCES in `env` too;
 *  `appleFetch`: Apple's token endpoints, for revoking. `oidc: false`: no IdP (Apple only). */
export async function harness(o: { env?: Record<string, string>; limits?: Partial<Limits>; dbFile?: string; idp?: (idp: TestIdp) => void; apple?: TestApple; appleFetch?: typeof fetch; oidc?: boolean } = {}): Promise<Harness> {
  const idp = await new TestIdp().start();
  o.idp?.(idp);
  const server: Server = createServer();
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const cfg = configFromEnv({
    ...(o.oidc === false ? {} : { ACCOUNT_OIDC_ISSUER: idp.issuer, ACCOUNT_OIDC_CLIENT_ID: idp.clientId, ACCOUNT_OIDC_CLIENT_SECRET: idp.clientSecret }),
    ACCOUNT_PUBLIC_URL: url,
    ACCOUNT_APP_REDIRECTS: "example://account",
    ...o.env,
  });
  const store = new Store(o.dbFile ?? ":memory:", cfg.wire);
  const ring = KeyRing.load(null, cfg.wire);
  const logs: string[] = [];
  const notices: NoticeOut[] = [];
  const clock = { t: null as number | null };
  const now = () => clock.t ?? Date.now();
  const oidc = new OidcClient(cfg);
  const svc = new AccountService({
    cfg, store, idp: o.oidc === false ? null : oidc, ring, limits: o.limits ?? {}, now, log: (l) => logs.push(l), deliver: (n) => void notices.push(n),
    ...(o.apple ? { appleKeys: o.apple.keys, storeKit: o.apple.storeKit } : {}),
    ...(o.appleFetch ? { appleFetch: o.appleFetch } : {}),
  });
  const recheck = new Rechecker(store, oidc, { now, log: (l) => logs.push(l), onEnded: (s) => svc.sessionEnded(s) });
  server.on("request", svc.handle);
  const h: Harness = {
    idp, store, ring, cfg, svc, oidc, recheck, url, logs, notices, clock,
    async stop() {
      server.closeAllConnections();
      await new Promise((r) => server.close(r));
      await idp.stop();
      store.close();
    },
  };
  running.push(h);
  return h;
}
export async function stopAll() {
  for (const h of running.splice(0)) await h.stop();
}

export const b64url = (b: Buffer) => b.toString("base64url");
export function pkce() {
  const verifier = b64url(randomBytes(32));
  return { verifier, challenge: b64url(createHash("sha256").update(verifier).digest()) };
}

/** GET without following redirects. */
export async function get(url: string, headers: Record<string, string> = {}) {
  return fetch(url, { redirect: "manual", headers });
}
export async function post(url: string, body: unknown, headers: Record<string, string> = {}) {
  return fetch(url, { method: "POST", redirect: "manual", headers: { "content-type": "application/json", ...headers }, body: typeof body === "string" ? body : JSON.stringify(body) });
}
export const bearer = (t: string) => ({ authorization: `Bearer ${t}` });

/** /v1/signin → the IdP → /v1/callback; the final Location (the app's redirect with code or error). */
export async function throughIdp(h: Harness, query: Record<string, string>): Promise<{ location: string; signin: Response; callback: Response | null; authorize: URLSearchParams | null }> {
  const signin = await get(`${h.url}/v1/signin?${new URLSearchParams(query)}`);
  const toIdp = signin.headers.get("location");
  if (signin.status !== 302 || !toIdp) return { location: "", signin, callback: null, authorize: null };
  const authorize = new URL(toIdp).searchParams;
  const atIdp = await get(toIdp);
  const cb = atIdp.headers.get("location")!;
  // (the same browser: what the sign-in set comes back with the callback)
  const cookie = signin.headers.getSetCookie().map((c) => c.split(";")[0]).join("; ");
  const callback = await get(cb, cookie ? { cookie } : {});
  return { location: callback.headers.get("location") ?? "", signin, callback, authorize };
}

/** An app's whole sign-in: code + PKCE through the IdP, then /v1/token. */
export async function appSignIn(h: Harness, o: { device?: Record<string, unknown>; prompt?: string; redirect?: string } = {}) {
  const { verifier, challenge } = pkce();
  const redirect = o.redirect ?? "example://account";
  const r = await throughIdp(h, { redirect_uri: redirect, state: "app-state", code_challenge: challenge, code_challenge_method: "S256", ...(o.prompt ? { prompt: o.prompt } : {}) });
  const back = new URL(r.location);
  const code = back.searchParams.get("code");
  if (!code) throw new Error(`no code: ${r.location} (${r.signin.status}, ${r.callback?.status})`);
  const t = await post(`${h.url}/v1/token`, { grant_type: "authorization_code", code, code_verifier: verifier, redirect_uri: redirect, device: o.device ?? { name: "Alex's iPhone", platform: "ios" } });
  const body = (await t.json()) as { session: string; account: { id: string; name: string }; device: { id: string; name: string }; expiresAt: number };
  if (t.status !== 200) throw new Error(`token ${t.status} ${JSON.stringify(body)}`);
  return body;
}

/** A computer starts a join. */
/** An app's native Sign in with Apple through the stand-in (`h` made with `apple`): its device session. */
export async function appleSignIn(h: Harness, apple: TestApple, o: { sub?: string; name?: string; email?: string; device?: Record<string, unknown>; aud?: string } = {}) {
  const nonce = randomBytes(16).toString("base64url");
  const aud = o.aud ?? h.cfg.apple?.audiences[0] ?? "com.example.app";
  const r = await post(`${h.url}/v1/auth/apple`, { identityToken: apple.token({ sub: o.sub ?? "apple-alice", nonce, aud, ...(o.email ? { email: o.email } : {}) }), nonce, ...(o.name ? { name: o.name } : {}), device: o.device ?? { name: "iPhone", platform: "ios" } });
  if (r.status !== 200) throw new Error(`Apple sign-in: ${r.status} ${await r.text()}`);
  return (await r.json()) as { session: string; account: { id: string; name: string | null }; device: { id: string } };
}

export async function enroll(h: Harness, k: LinkKey, extra: Record<string, unknown> = {}) {
  const r = await post(`${h.url}/v1/computers/enroll`, { linkId: k.id, name: "Study PC", fingerprint: "sha-256 AB:CD:EF:01:23", relays: ["https://relay.example.com/?token=t0k"], ...extra });
  return { status: r.status, body: (await r.json()) as { device_code: string; user_code: string; qr: string; interval: number; error?: string } };
}

/** The computer's confirmation, signed with its Link key. */
export async function confirm(h: Harness, k: LinkKey, deviceCode: string, account: string, signer: LinkKey = k) {
  return post(`${h.url}/v1/computers/confirm`, { device_code: deviceCode, proof: signer.sign(h.cfg.wire.joinProofText(h.url, k.id, account, deviceCode)) });
}

/** A computer joined to the account of `session`, the whole way. */
export async function joinComputer(h: Harness, session: string, k: LinkKey = linkKey()) {
  const e = await enroll(h, k);
  const ap = await post(`${h.url}/v1/computers/approve`, { user_code: e.body.user_code }, bearer(session));
  if (ap.status !== 200) throw new Error(`approve ${ap.status}`);
  const me = (await (await get(`${h.url}/v1/me`, bearer(session))).json()) as { account: { id: string } };
  const c = await confirm(h, k, e.body.device_code, me.account.id);
  if (c.status !== 200) throw new Error(`confirm ${c.status} ${await c.text()}`);
  return { k, account: me.account.id, body: (await c.json()) as { server: { keys: unknown[] } } };
}

/** A member computer's signed request. */
export async function computerCall(h: Harness, k: LinkKey, method: "GET" | "POST", pathQ: string, body?: unknown, o: { ts?: number; signer?: LinkKey } = {}) {
  const raw = body === undefined ? "" : JSON.stringify(body);
  const ts = o.ts ?? Math.floor(Date.now() / 1000);
  const sig = (o.signer ?? k).sign(h.cfg.wire.computerProofText(h.url, method, pathQ, ts, createHash("sha256").update(raw).digest("base64url")));
  return fetch(`${h.url}${pathQ}`, { method, headers: { authorization: `${h.cfg.wire.linkScheme} ${k.id}.${ts}.${sig}`, ...(raw ? { "content-type": "application/json" } : {}) }, ...(raw ? { body: raw } : {}) });
}
