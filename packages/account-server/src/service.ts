// The account server (docs/ACCOUNT-LIB.md): the one component that talks to the IdP. It
// keeps accounts (`iss` + `sub`), their computers and devices; gives a signed-in device the list of its account's
// computers and short-lived tickets into each; lets a signed-in phone approve a computer's join code; and publishes
// signed revocations. It is not on any data path: chat, screens and voice go between devices and computers directly.
//
// HTTP routes (all JSON unless said; errors are `{ error, error_description? }`):
//   GET  /healthz, /v1/config, /.well-known/jwks.json, /.well-known/apple-app-site-association
//   GET  /v1/signin            → the IdP (app / hosted web: code + PKCE back to a registered redirect)
//   GET  /v1/callback          ← the IdP
//   GET  /v1/app-return        (the https callback iOS intercepts; a page saying "back to the app" otherwise)
//   POST /v1/token             sign-in code + PKCE verifier + device → a device session (90 days; the hosted web
//                                client's: 30, bound to its device key — each request it makes is signed, `<ns>-proof`)
//   POST /v1/auth/apple        an app's native Sign in with Apple: its identity token + the nonce → a device session
//   POST /v1/auth/password/register|verify, /v1/auth/password, /v1/auth/password/reset|reset/confirm
//                              email and password (ACCOUNT_PASSWORD): a code mailed to sign up and to reset, then a
//                              device session (from a web page's origin: its key-bound one)
//   POST /v1/auth/qr, /v1/auth/qr/poll   a new device's sign-in by QR code: it asks with its key (a code to show, a
//                              secret to poll with), a signed-in device approves, the new one polls for its session
//                              (key-bound, 30 days, like a web page's)
//   GET  /v1/auth/qr/lookup, POST /v1/auth/qr/approve|decline   (a signed-in app or hosted web client: the code shown)
//   GET  /v1/me, POST /v1/signout, DELETE /v1/me (the account itself, from the app; its Apple grant revoked)
//   POST /v1/join-keys         a signed-in app's one-use join key for its own account (a computer it is paired with
//                                joins with it: docs/ACCOUNT-LIB.md「经已配对的设备」)
//   POST /v1/entitlements/appstore   a StoreKit 2 transaction of the account's (its subscription)
//   GET  /v1/computers, PATCH|DELETE /v1/computers/<linkId>, POST /v1/tickets
//   GET  /v1/devices, DELETE /v1/devices/<id>
//   POST /v1/computers/enroll|poll|confirm|decline    (the computer; poll / confirm / decline by its device code)
//   POST /v1/computers/join    (the computer, with a join key the admin made: no approval)
//   GET  /v1/computers/lookup, POST /v1/computers/approve   (a signed-in app or hosted web client)
//   GET  /v1/computer/revocations, POST /v1/computer/update|leave   (a member computer, signed with its Link key)
//   GET  /v1/computer/services      (the same: the relay, push relay, speech and signaling its account brings it)
//
// No pages of its own (2026-11-20): a computer's join is approved in a client (the app, the hosted web client), the
// sign-in's few words of error are all the HTML it answers.
//
// Logs: events, statuses, account / device ids (random, shortened), Link ids' first 8 characters, a short hash of a
// `sub` when a sign-in is refused. Never a token, a code, a state, a refresh token, an id_token or a query string.
import { createHash, createPublicKey, randomBytes, timingSafeEqual, verify } from "node:crypto";
import type { IncomingMessage, ServerResponse } from "node:http";
import { addressKind, normalizeIp } from "./address.js";
import { FailureLimiter, ipBucket, TokenBuckets } from "./rate-limit.js";
import type { AccountConfig } from "./config.js";
import { allowed } from "./config.js";
import type { KeyRing } from "./keys.js";
import { cleanText, IdpError, type Idp } from "./oidc.js";
import { APPLE_ISSUER, cachedAppleKeys, revokeAppleGrant, verifyIdentityToken, verifyStoreKit, type AppleKeys, type StoreTransaction } from "./apple.js";
import { randomId, sha256, type Account, type Computer, type EmailCode, type Enrollment, type Session, type Store } from "./store.js";
import { codeHash, codeMail, decoyHash, hashPassword, newCode as newEmailCode, normalizeEmail, passwordProblem, verifyPassword, type CodePurpose } from "./password.js";
import { signRevocationList, signServiceToken, signTicket, TICKET_TTL_S } from "./ticket.js";

export const SESSION_MAX_AGE_MS = 90 * 86_400_000;
/** The hosted web client's device session (a page whose token a script could read: shorter than an app's). */
export const HOSTED_SESSION_MAX_AGE_MS = 30 * 86_400_000;
/** How far a hosted web client's request proof may be from the server's clock (s). */
export const HOSTED_PROOF_MAX_AGE_S = 120;
/**
 * What the hosted web client signs for each request with its device key (Ed25519, kept non-extractable in the
 * browser): the token alone is worth nothing without the key — one copied out of the page, a log or a proxy is no
 * session anywhere else. `bodyHash`: SHA-256 of the body as sent (base64url; of nothing for a request without one).
 * Header `<ns>-proof: <unix seconds>.<bodyHash>.<signature, base64url>` over `Wire.hostedProofText`.
 */
export const SIGNIN_TTL_MS = 10 * 60_000;
export const APP_CODE_TTL_MS = 60_000;
export const JOIN_TTL_MS = 10 * 60_000;
/** A join key an app made for a computer it is paired with: one use, this long. */
export const APP_JOIN_KEY_TTL_MS = 10 * 60_000;
/** What a computer says of itself for its product's clients (`info`, a JSON object): this many bytes at most. */
export const INFO_MAX = 2048;
/** After an approval the computer has this long to confirm it on its own screen. */
export const JOIN_CONFIRM_MS = 10 * 60_000;
export const POLL_INTERVAL_S = 2;
/** A sign-in by QR code: the code is good this long, once. */
export const QR_SIGNIN_TTL_MS = 150_000;
export const BODY_MAX = 16 * 1024;
/** RFC 8628's alphabet: 20 consonants (no vowels: no words; no 0/O, 1/I). 8 of them = 34.6 bits. */
export const CODE_ALPHABET = "BCDFGHJKLMNPQRSTVWXZ";
export const CODE_LEN = 8;

export const LIMITS = {
  /** Sign-ins started, callbacks, and code exchanges (each its own budget) per address: 20 at once, then 20 a minute
   *  (a home or a phone network behind one IPv4 address signs in several people). */
  signinBurst: 20,
  signinEveryMs: 3_000,
  /** Requests with a bad bearer token or cookie per address and minute, before 429 for the rest of it. */
  badTokensPerMinute: 20,
  /** Join codes started per address: 6 at once, then 6 a minute; at most 5 open per address, 2000 in all. */
  enrollBurst: 6,
  enrollEveryMs: 10_000,
  enrollOpenPerAddress: 5,
  enrollOpenMax: 2_000,
  /** Wrong join codes (lookups and approvals): per session and minute, per address and minute, per account and hour. */
  codeFailuresPerSession: 5,
  codeFailuresPerAddress: 10,
  codeFailuresPerAccountHour: 30,
  /** Sign-ins by QR code started per address: 6 at once, then 6 a minute; at most 5 open per address, 2000 in all. */
  qrBurst: 6,
  qrEveryMs: 10_000,
  qrOpenPerAddress: 5,
  qrOpenMax: 2_000,
  /** Their polls per address: 30 at once, then one a second (several waiting behind one address). */
  qrPollBurst: 30,
  qrPollEveryMs: 1_000,
  /** Tickets per device: 30 at once, then 30 a minute. */
  ticketBurst: 30,
  ticketEveryMs: 2_000,
  /** A member computer's own requests (revocation list, update): 10 at once, then 30 a minute. */
  computerBurst: 10,
  computerEveryMs: 2_000,
  /** A computer's wait on its revocation list at most (seconds), and how many may wait at once (past it: no wait). */
  revocationWaitS: 25,
  revocationWaitersMax: 5_000,
  /** Sign-ins on their way through the IdP, in all. */
  signinsOpenMax: 5_000,
  computersPerAccount: 64,
  /** Join keys an app may have made for its account and not yet used. */
  appJoinKeysOpen: 16,
  /** Devices signed in at once (a device that is signed out does not count). */
  devicesPerAccount: 64,
  /** A request's body must have arrived within this. */
  bodyTimeoutMs: 5_000,
};
export type Limits = typeof LIMITS;

const LINK_ID_RE = /^[0-9a-f]{64}$/;
const B64URL_RE = /^[A-Za-z0-9_-]+$/;
const ED25519_SPKI = Buffer.from("302a300506032b6570032100", "hex");
const PROMPTS = new Set(["login", "select_account"]);
/** IdP errors passed back to the client as they are; anything else is `server_error`. */
const IDP_ERRORS = new Set(["access_denied", "login_required", "consent_required", "interaction_required", "account_selection_required", "temporarily_unavailable"]);

export const normCode = (s: string) => s.toUpperCase().replace(/[^A-Z]/g, "");
export const validCode = (c: string) => c.length === CODE_LEN && [...c].every((ch) => CODE_ALPHABET.includes(ch));
export const showCode = (c: string) => `${c.slice(0, 4)}-${c.slice(4)}`;
export function newCode(): string {
  const out: string[] = [];
  while (out.length < CODE_LEN) {
    for (const b of randomBytes(16)) if (b < 240 && out.length < CODE_LEN) out.push(CODE_ALPHABET[b % 20]!);
  }
  return out.join("");
}
const s256 = (verifier: string) => createHash("sha256").update(verifier, "ascii").digest("base64url");
const eq = (a: string, b: string) => {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
};
const short = (id: string) => `${id.slice(0, 10)}…`;
const subTag = (iss: string, sub: string) => sha256(`${iss}|${sub}`).slice(0, 8);
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);

/** True when `sig` (base64url) is Link id `id`'s (hex of an Ed25519 public key) signature over `text`. */
export function verifyLinkSignature(id: string, text: string, sig: string): boolean {
  if (!LINK_ID_RE.test(id) || !B64URL_RE.test(sig)) return false;
  const s = Buffer.from(sig, "base64url");
  if (s.length !== 64) return false;
  try {
    const key = createPublicKey({ key: Buffer.concat([ED25519_SPKI, Buffer.from(id, "hex")]), format: "der", type: "spki" });
    return verify(null, Buffer.from(text, "utf8"), key, s);
  } catch {
    return false;
  }
}

/** An email code: good for 10 minutes, 5 tries; one mailed a minute at most, 5 an hour per email. */
const CODE_TTL_MS = 10 * 60_000;
const CODE_ATTEMPTS = 5;
const CODE_RESEND_MS = 60_000;
const CODE_SENDS_PER_HOUR = 5;

class HttpError extends Error {
  constructor(readonly status: number, readonly error: string, readonly description?: string, readonly headers: Record<string, string> = {}) {
    super(error);
  }
}

/** A revocation that took effect: the account's list is at `seq` now, and the computers waiting on it are answered. */
export interface NoticeOut {
  account: string;
  seq: number;
  /** The computers it concerns: the account's, and those just taken out of it. */
  linkIds: string[];
}

export interface ServiceDeps {
  cfg: AccountConfig;
  store: Store;
  /** The OpenID Connect provider (null: none set up — only the native sign-ins). */
  idp: Idp | null;
  ring: KeyRing;
  /** Apple's keys by kid (tests: their own; default: fetched from Apple, cached). */
  appleKeys?: AppleKeys;
  /** Apple's token endpoints, to revoke a grant (tests: their own). */
  appleFetch?: typeof fetch;
  /** A StoreKit transaction's check (tests: their own; default: verifyStoreKit, the chain to Apple's root). */
  storeKit?: (jws: string, now: number) => StoreTransaction | null;
  limits?: Partial<Limits>;
  now?: () => number;
  log?: (line: string) => void;
  /** Told of each revocation as it takes effect (tests). A throw keeps it queued for the next try. */
  deliver?: (n: NoticeOut) => Promise<void> | void;
}

interface Authed {
  session: Session;
  account: Account;
}

const SECURITY_HEADERS = {
  "cache-control": "no-store",
  "x-content-type-options": "nosniff",
  "referrer-policy": "no-referrer",
  "x-frame-options": "DENY",
};

export class AccountService {
  private readonly cfg: AccountConfig;
  private readonly sessionRe: RegExp;
  private readonly linkRe: RegExp;
  private readonly store: Store;
  private readonly l: Limits;
  private readonly now: () => number;
  private readonly log: (line: string) => void;
  private readonly signins: TokenBuckets;
  private readonly callbacks: TokenBuckets;
  private readonly exchanges: TokenBuckets;
  private readonly enrolls: TokenBuckets;
  private readonly qrStarts: TokenBuckets;
  private readonly qrPolls: TokenBuckets;
  private readonly tickets: TokenBuckets;
  private readonly computerReqs: TokenBuckets;
  private readonly badTokens: FailureLimiter;
  /** Wrong passwords per email: 10 in 15 minutes, then that email waits. */
  private readonly passwordFails = new FailureLimiter(10, 15 * 60_000);
  private readonly codeFailSession: FailureLimiter;
  private readonly codeFailAddress: FailureLimiter;
  private readonly codeFailAccount: FailureLimiter;
  private readonly webOrigins: Set<string>;
  private readonly appleKeys: AppleKeys;
  private refused = new Map<string, number>();
  private refusedLogged = -Infinity;
  private delivering: Promise<void> | null = null;
  /** Computers waiting on their account's revocation list (GET /v1/computer/revocations?wait=), by account. */
  private waiters = new Map<string, Set<() => void>>();
  private waitingBy = new Map<string, () => void>();
  private waiting = 0;
  /** A hosted web client's request: the body hash its proof covers (readBody checks the body against it). */
  private readonly signedBodies = new WeakMap<IncomingMessage, string>();

  constructor(private readonly deps: ServiceDeps) {
    this.cfg = deps.cfg;
    if (deps.ring.wire.ns !== deps.cfg.wire.ns) throw new Error(`the key ring signs as ${deps.ring.wire.ns}, the server is ${deps.cfg.wire.ns}`);
    this.sessionRe = new RegExp(`^Bearer (${deps.cfg.wire.sessionPrefix}[A-Za-z0-9_-]{43})$`);
    this.linkRe = new RegExp(`^${deps.cfg.wire.linkScheme} ([0-9a-f]{64})\\.(\\d{9,11})\\.([A-Za-z0-9_-]{86})$`);
    this.store = deps.store;
    this.l = { ...LIMITS, ...deps.limits };
    this.now = deps.now ?? Date.now;
    this.log = deps.log ?? ((l) => console.log(l));
    this.signins = new TokenBuckets(this.l.signinBurst, this.l.signinEveryMs, this.now);
    this.callbacks = new TokenBuckets(this.l.signinBurst, this.l.signinEveryMs, this.now);
    this.exchanges = new TokenBuckets(this.l.signinBurst, this.l.signinEveryMs, this.now);
    this.enrolls = new TokenBuckets(this.l.enrollBurst, this.l.enrollEveryMs, this.now);
    this.qrStarts = new TokenBuckets(this.l.qrBurst, this.l.qrEveryMs, this.now);
    this.qrPolls = new TokenBuckets(this.l.qrPollBurst, this.l.qrPollEveryMs, this.now);
    this.tickets = new TokenBuckets(this.l.ticketBurst, this.l.ticketEveryMs, this.now);
    this.computerReqs = new TokenBuckets(this.l.computerBurst, this.l.computerEveryMs, this.now);
    this.badTokens = new FailureLimiter(this.l.badTokensPerMinute, 60_000);
    this.codeFailSession = new FailureLimiter(this.l.codeFailuresPerSession, 60_000);
    this.codeFailAddress = new FailureLimiter(this.l.codeFailuresPerAddress, 60_000);
    this.codeFailAccount = new FailureLimiter(this.l.codeFailuresPerAccountHour, 3_600_000);
    this.webOrigins = new Set(this.cfg.webRedirects.map((r) => new URL(r).origin));
    this.appleKeys = deps.appleKeys ?? cachedAppleKeys(undefined, this.now);
  }

  // --------------------------------------------------------------------------- plumbing

  /** Where a request comes from: the socket, or behind the trusted TLS front on loopback its last X-Forwarded-For. */
  addressOf(req: IncomingMessage): string {
    const peer = req.socket.remoteAddress ? normalizeIp(req.socket.remoteAddress) : null;
    if (this.cfg.trustProxy && peer && addressKind(peer) === "loopback") {
      const xff = req.headers["x-forwarded-for"];
      const last = (Array.isArray(xff) ? xff.join(",") : (xff ?? "")).split(",").map((s) => s.trim()).filter(Boolean).at(-1);
      return (last && normalizeIp(last)) || "unknown";
    }
    return peer ?? "unknown";
  }

  private refuse(why: string) {
    this.refused.set(why, (this.refused.get(why) ?? 0) + 1);
    if (this.now() - this.refusedLogged >= 60_000) {
      const parts = [...this.refused].map(([w, n]) => `${n} ${w}`);
      this.log(`[account] refused: ${parts.join(", ")}`);
      this.refused.clear();
      this.refusedLogged = this.now();
    }
  }

  private send(res: ServerResponse, status: number, body: unknown, headers: Record<string, string> = {}) {
    res.writeHead(status, { "content-type": "application/json", ...SECURITY_HEADERS, ...headers });
    res.end(JSON.stringify(body));
  }

  private page(res: ServerResponse, status: number, title: string, body: string, headers: Record<string, string> = {}) {
    res.writeHead(status, {
      "content-type": "text/html; charset=utf-8",
      ...SECURITY_HEADERS,
      "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
      ...headers,
    });
    res.end(
      `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>${esc(title)}</title>` +
        `<style>body{font:16px/1.5 system-ui,sans-serif;max-width:32rem;margin:3rem auto;padding:0 1rem}code{font-size:1.1em}button{font:inherit;padding:.5rem 1rem}dt{color:#666}</style></head>` +
        `<body><h1>${esc(title)}</h1>${body}</body></html>`,
    );
  }

  private redirect(res: ServerResponse, location: string, headers: Record<string, string> = {}) {
    res.writeHead(302, { location, ...SECURITY_HEADERS, ...headers });
    res.end();
  }

  private readBody(req: IncomingMessage): Promise<Record<string, unknown>> {
    return new Promise((resolve, reject) => {
      const chunks: Buffer[] = [];
      let size = 0;
      let done = false;
      const fail = (e: HttpError) => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        req.resume();
        reject(e);
      };
      const timer = setTimeout(() => fail(new HttpError(408, "invalid_request", "the body was too slow")), this.l.bodyTimeoutMs);
      req.on("data", (c: Buffer) => {
        size += c.length;
        if (size > BODY_MAX) fail(new HttpError(413, "invalid_request", `the body is at most ${BODY_MAX} bytes`));
        else chunks.push(c);
      });
      req.on("error", () => fail(new HttpError(400, "invalid_request")));
      req.on("end", () => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        const raw = Buffer.concat(chunks);
        const signed = this.signedBodies.get(req);
        if (signed !== undefined && !eq(createHash("sha256").update(raw).digest("base64url"), signed)) {
          this.refuse("web client requests whose body is not the one they signed");
          return reject(new HttpError(401, "invalid_token", "the body is not the one the proof is for"));
        }
        const text = raw.toString("utf8");
        const type = req.headers["content-type"] ?? "";
        try {
          if (!text) return resolve({});
          if (type.startsWith("application/x-www-form-urlencoded")) return resolve(Object.fromEntries(new URLSearchParams(text)));
          const j = JSON.parse(text) as unknown;
          if (!j || typeof j !== "object" || Array.isArray(j)) throw new Error();
          resolve(j as Record<string, unknown>);
        } catch {
          reject(new HttpError(400, "invalid_request", "the body is a JSON object"));
        }
      });
    });
  }

  /** The raw body too (a computer's signature covers it). */
  private readRaw(req: IncomingMessage): Promise<string> {
    return new Promise((resolve, reject) => {
      const chunks: Buffer[] = [];
      let size = 0;
      const timer = setTimeout(() => reject(new HttpError(408, "invalid_request", "the body was too slow")), this.l.bodyTimeoutMs);
      req.on("data", (c: Buffer) => {
        size += c.length;
        if (size <= BODY_MAX) chunks.push(c);
      });
      req.on("end", () => {
        clearTimeout(timer);
        if (size > BODY_MAX) reject(new HttpError(413, "invalid_request", `the body is at most ${BODY_MAX} bytes`));
        else resolve(Buffer.concat(chunks).toString("utf8"));
      });
      req.on("error", () => reject(new HttpError(400, "invalid_request")));
    });
  }

  private limited(buckets: TokenBuckets, key: string, what: string) {
    const wait = buckets.take(key);
    if (wait) {
      this.refuse(`${what} over the limit`);
      throw new HttpError(429, "slow_down", `too many ${what}`, { "retry-after": String(wait) });
    }
  }

  // --------------------------------------------------------------------------- the handler

  handle = (req: IncomingMessage, res: ServerResponse): void => {
    const t0 = this.now();
    this.route(req, res)
      .catch((e: unknown) => {
        if (e instanceof HttpError) {
          if (!res.headersSent) this.send(res, e.status, { error: e.error, ...(e.description ? { error_description: e.description } : {}) }, e.headers);
          return;
        }
        this.log(`[account] ${req.method} ${logPath(req.url)}: internal error ${(e as Error)?.name ?? ""}: ${String((e as Error)?.message ?? e).slice(0, 200)}`);
        if (!res.headersSent) this.send(res, 500, { error: "server_error" });
        else res.destroy();
      })
      .finally(() => {
        const ms = this.now() - t0;
        // (a computer's wait on its revocation list is long by design)
        if (ms > 2_000 && !(req.url ?? "").startsWith("/v1/computer/revocations")) this.log(`[account] slow: ${req.method} ${logPath(req.url)} ${res.statusCode} in ${ms} ms`);
      });
  };

  private async route(req: IncomingMessage, res: ServerResponse): Promise<void> {
    const url = new URL(req.url ?? "/", "http://localhost");
    const path = url.pathname;
    const method = req.method ?? "GET";
    const ip = this.addressOf(req);
    const ipKey = ipBucket(ip);
    const cors = this.corsHeaders(req, path);
    // (set on the response itself: an error's answer carries them too, so a web client can read a 401 or a 429)
    if (cors) for (const [k, v] of Object.entries(cors)) res.setHeader(k, v);
    if (this.cfg.publicUrl.startsWith("https:")) res.setHeader("strict-transport-security", "max-age=31536000");
    if (method === "OPTIONS") {
      if (!cors) throw new HttpError(404, "not_found");
      res.writeHead(204, { ...cors, "access-control-allow-methods": "GET, POST, PATCH, DELETE", "access-control-allow-headers": `authorization, content-type, ${this.cfg.wire.proofHeader}`, "access-control-max-age": "600" });
      return void res.end();
    }
    const send = (status: number, body: unknown, h: Record<string, string> = {}) => this.send(res, status, body, { ...cors, ...h });

    if (method === "GET" && path === "/healthz") return send(200, { ok: true });
    if (method === "GET" && path === "/v1/config") return send(200, this.configBody());
    if (method === "GET" && path === "/.well-known/jwks.json") return send(200, { keys: this.deps.ring.jwks() }, { "cache-control": "public, max-age=300" });
    if (method === "GET" && path === "/.well-known/apple-app-site-association" && this.cfg.appleAppIds.length) {
      return send(200, { webcredentials: { apps: this.cfg.appleAppIds } }, { "cache-control": "public, max-age=3600" });
    }

    // sign-in
    if ((path === "/v1/signin" || path === "/v1/callback") && !this.deps.idp) {
      req.resume();
      return this.page(res, 404, "No sign-in here", "<p>This account server signs in from its apps only.</p>");
    }
    if (method === "GET" && path === "/v1/signin") return this.signin(url, res, ipKey);
    if (method === "GET" && path === "/v1/callback") return this.callback(url, res, ipKey);
    if (method === "POST" && path === "/v1/auth/apple" && this.cfg.apple) return send(200, await this.appleSignIn(req, ipKey));
    if (method === "POST" && path.startsWith("/v1/auth/password") && this.cfg.password) {
      if (path === "/v1/auth/password") return send(200, await this.passwordSignIn(req, ipKey));
      if (path === "/v1/auth/password/register") return send(200, await this.passwordRegister(req, ipKey));
      if (path === "/v1/auth/password/verify") return send(200, await this.passwordVerify(req, ipKey));
      if (path === "/v1/auth/password/reset") return send(200, await this.passwordReset(req, ipKey));
      if (path === "/v1/auth/password/reset/confirm") return send(200, await this.passwordResetConfirm(req, ipKey));
    }
    if (method === "POST" && path === "/v1/auth/qr") return send(200, await this.qrStart(req, ip, ipKey));
    if (method === "POST" && path === "/v1/auth/qr/poll") {
      const r = await this.qrPoll(req, ipKey);
      return send(r.status, r.body);
    }
    if (method === "GET" && path === "/v1/app-return") return this.page(res, 200, "Signed in", "<p>Go back to the app.</p>");
    if (method === "POST" && path === "/v1/token") return send(200, await this.token(req, ipKey));

    // the join code: the computer's side
    if (method === "POST" && path === "/v1/computers/enroll") return send(200, await this.enroll(req, ip, ipKey));
    if (method === "POST" && path === "/v1/computers/poll") {
      const r = await this.poll(req);
      return send(r.status, r.body);
    }
    if (method === "POST" && path === "/v1/computers/confirm") return send(200, await this.confirm(req));
    if (method === "POST" && path === "/v1/computers/decline") return send(200, await this.decline(req));
    if (method === "POST" && path === "/v1/computers/join") return send(200, await this.joinWithKey(req, ipKey));

    // a member computer, signed with its Link key
    if (path.startsWith("/v1/computer/")) return send(200, await this.computerRequest(req, url, method));

    // a signed-in device
    if (path.startsWith("/v1/")) {
      const a = this.bearer(req, ipKey);
      if (method === "GET" && path === "/v1/me") return send(200, this.me(a));
      if (method === "DELETE" && path === "/v1/me") return send(200, await this.deleteAccount(a, await this.readBody(req)));
      if (method === "POST" && path === "/v1/join-keys") {
        req.resume();
        return send(200, this.appJoinKey(a));
      }
      if (method === "POST" && path === "/v1/entitlements/appstore" && this.cfg.appstore) return send(200, this.appStoreEntitlement(a, await this.readBody(req)));
      if (method === "POST" && path === "/v1/signout") {
        req.resume();
        await this.endDeviceSession(a, "signed_out");
        return send(200, { ok: true });
      }
      if (method === "GET" && path === "/v1/computers") return send(200, { computers: this.store.computersOf(a.account.id).map(computerBody) });
      // (a computer is put into the account from a client: the app, or the hosted web client — whose requests are
      // signed with its device key, so its token alone approves nothing)
      if (method === "GET" && path === "/v1/computers/lookup") return send(200, this.lookup(a, url.searchParams.get("code") ?? "", ipKey));
      if (method === "POST" && path === "/v1/computers/approve") {
        const b = await this.readBody(req);
        return send(200, this.approve(a, String(b.user_code ?? ""), ipKey));
      }
      // (a sign-in by QR code is approved the same way: from the app, or a web page with its key's proof)
      if (method === "GET" && path === "/v1/auth/qr/lookup") return send(200, this.qrLookup(a, url.searchParams.get("code") ?? "", ipKey));
      if (method === "POST" && (path === "/v1/auth/qr/approve" || path === "/v1/auth/qr/decline")) {
        const b = await this.readBody(req);
        return send(200, path.endsWith("approve") ? this.qrApprove(a, String(b.code ?? ""), ipKey) : this.qrDecline(a, String(b.code ?? ""), ipKey));
      }
      const cm = /^\/v1\/computers\/([0-9a-f]{64})$/.exec(path);
      if (cm && method === "PATCH") return send(200, await this.renameComputer(a, cm[1]!, await this.readBody(req)));
      if (cm && method === "DELETE") {
        req.resume();
        return send(200, await this.removeComputer(a, cm[1]!));
      }
      if (method === "POST" && path === "/v1/tickets") return send(200, await this.ticket(a, await this.readBody(req)));
      if (method === "GET" && path === "/v1/devices") return send(200, { devices: this.store.signedInDevicesOf(a.account.id, this.now()).map((d) => ({ id: d.id, name: d.name, platform: d.platform, createdAt: d.created_at, lastUsedAt: d.last_used_at, current: d.id === a.session.device_id })) });
      const dm = /^\/v1\/devices\/(d_[A-Za-z0-9_-]{10,40})$/.exec(path);
      if (dm && method === "DELETE") {
        req.resume();
        return send(200, await this.removeDevice(a, dm[1]!));
      }
    }
    req.resume();
    throw new HttpError(404, "not_found");
  }

  private corsHeaders(req: IncomingMessage, path: string): Record<string, string> | null {
    const origin = req.headers.origin;
    if (!origin || !this.webOrigins.has(origin)) return null;
    if (!path.startsWith("/v1/") || path === "/v1/signin" || path === "/v1/callback" || path.startsWith("/v1/computer/")) return null;
    // (`Date` readable: a web page whose clock is off by more than its proof's window sets itself by this server's)
    return { "access-control-allow-origin": origin, vary: "origin", "access-control-expose-headers": "date" };
  }

  configBody() {
    return {
      server: { url: this.cfg.publicUrl, name: this.cfg.serverName },
      idp: { issuer: this.cfg.issuer, name: this.cfg.idpName },
      signin: { appReturn: `${this.cfg.publicUrl}/v1/app-return`, redirects: this.cfg.appRedirects, oidc: this.cfg.oidc, apple: !!this.cfg.apple, password: !!this.cfg.password, qr: true },
      ticketTtl: TICKET_TTL_S,
      sessionMaxAgeDays: SESSION_MAX_AGE_MS / 86_400_000,
    };
  }

  // --------------------------------------------------------------------------- sign-in

  private redirectAllowed(r: string) {
    return r === `${this.cfg.publicUrl}/v1/app-return` || this.cfg.appRedirects.includes(r) || this.cfg.webRedirects.includes(r);
  }

  private async signin(url: URL, res: ServerResponse, ipKey: string) {
    const p = url.searchParams;
    const wait = this.signins.take(ipKey);
    if (wait) {
      this.refuse("sign-ins over the limit");
      return this.page(res, 429, "Too many sign-ins", "<p>Wait a minute and try again.</p>", { "retry-after": String(wait) });
    }
    const now = this.now();
    if (this.store.countSignins(now) >= this.l.signinsOpenMax) return this.page(res, 503, "Busy", "<p>Too many sign-ins at once. Try again in a few minutes.</p>");
    const prompt = p.get("prompt") ?? undefined;
    if (prompt !== undefined && !PROMPTS.has(prompt)) return this.page(res, 400, "Cannot sign in", "<p>Unknown prompt.</p>");
    const clientState = p.get("state") ?? "";
    if (clientState.length > 512) return this.page(res, 400, "Cannot sign in", "<p>The state is too long.</p>");
    const redirect = p.get("redirect_uri") ?? "";
    if (!this.redirectAllowed(redirect)) {
      this.refuse("sign-ins to an unregistered redirect");
      return this.page(res, 400, "Cannot sign in", "<p>This app is not registered with this account server.</p>");
    }
    const challenge = p.get("code_challenge") ?? "";
    if (p.get("code_challenge_method") !== "S256" || !/^[A-Za-z0-9_-]{43,128}$/.test(challenge)) {
      return this.page(res, 400, "Cannot sign in", "<p>PKCE (S256) is required.</p>");
    }
    const state = randomBytes(32).toString("base64url");
    const verifier = randomBytes(32).toString("base64url");
    const nonce = randomBytes(16).toString("base64url");
    let to: string;
    try {
      to = await this.deps.idp!.authorizationUrl({ state, nonce, challenge: s256(verifier), prompt });
    } catch (e) {
      this.log(`[account] sign-in: the IdP is not reachable (${(e as Error).message.slice(0, 120)})`);
      return this.page(res, 503, "Cannot sign in right now", "<p>The sign-in service is not reachable. Try again in a minute.</p>");
    }
    this.store.putSignin({ state, verifier, nonce, client_state: clientState, created_at: now, expires_at: now + SIGNIN_TTL_MS, bind: "", kind: "app", redirect_uri: redirect, challenge, computer: null });
    return this.redirect(res, to);
  }

  private async callback(url: URL, res: ServerResponse, ipKey: string) {
    const p = url.searchParams;
    const wait = this.callbacks.take(ipKey);
    if (wait) {
      this.refuse("callbacks over the limit");
      return this.page(res, 429, "Too many sign-ins", "<p>Wait a minute and try again.</p>", { "retry-after": String(wait) });
    }
    const now = this.now();
    const s = this.store.takeSignin(p.get("state") ?? "", now);
    // (only an app's or a hosted web client's: a sign-in of the pages this server no longer has is no sign-in)
    if (!s || s.kind !== "app") {
      this.refuse("callbacks with an unknown or expired state");
      return this.page(res, 400, "This sign-in has expired", "<p>Start again from the app or the page you came from.</p>");
    }
    const back = (params: Record<string, string>) => {
      const r = new URL(s.redirect_uri);
      for (const [k, v] of Object.entries(params)) r.searchParams.set(k, v);
      if (s.client_state) r.searchParams.set("state", s.client_state);
      return this.redirect(res, r.toString());
    };
    const idpError = p.get("error");
    if (idpError) {
      this.log(`[account] sign-in: the IdP said ${IDP_ERRORS.has(idpError) ? idpError : "an error"}`);
      return back({ error: IDP_ERRORS.has(idpError) ? idpError : "server_error" });
    }
    const idp = this.deps.idp!;
    if (!(await idp.callbackIssOk(p.get("iss")))) {
      this.log("[account] sign-in: the callback's iss is not the IdP's (a mix-up?)");
      return back({ error: "server_error" });
    }
    let identity;
    let refresh: string | null;
    try {
      ({ identity, refreshToken: refresh } = await idp.exchange(p.get("code") ?? "", s.verifier, s.nonce));
    } catch (e) {
      this.log(`[account] sign-in: ${e instanceof IdpError ? e.message : `failed (${(e as Error).name})`}`);
      return back({ error: e instanceof IdpError && e.code === "idp_unreachable" ? "temporarily_unavailable" : "server_error" });
    }
    if (identity.iss !== this.cfg.issuer) {
      this.log("[account] sign-in: the id_token's issuer is not the configured one");
      return back({ error: "server_error" });
    }
    if (!allowed(this.cfg.allow, this.cfg.issuer, identity)) {
      this.log(`[account] sign-in refused: not on the allow-list (sub #${subTag(identity.iss, identity.sub)})`);
      return back({ error: "access_denied" });
    }
    const got = this.store.signInAccount(identity.iss, identity.sub, identity.name, now);
    if ("refused" in got) {
      this.log(`[account] sign-in refused: the account is ${got.refused} (sub #${subTag(identity.iss, identity.sub)})`);
      return back({ error: got.refused === "removed" ? "account_removed" : "account_disabled" });
    }
    const a = got.account;
    const code = randomBytes(32).toString("base64url");
    this.store.putAppCode({ code_hash: sha256(code), account_id: a.id, challenge: s.challenge, redirect_uri: s.redirect_uri, idp_refresh: refresh, computer: null, expires_at: now + APP_CODE_TTL_MS });
    this.log(`[account] sign-in ${short(a.id)}: back to the ${s.redirect_uri.startsWith("https:") ? "https" : "app"} redirect${refresh ? " (with a refresh token)" : ""}`);
    return back({ code });
  }

  private async token(req: IncomingMessage, ipKey: string) {
    const b = await this.readBody(req);
    this.limited(this.exchanges, ipKey, "code exchanges");
    if (b.grant_type !== "authorization_code") throw new HttpError(400, "unsupported_grant_type");
    const now = this.now();
    const code = this.store.takeAppCode(String(b.code ?? ""), now);
    // (one use: a wrong verifier burns the code too)
    if (!code || code.computer !== null) {
      this.refuse("code exchanges with an unknown or used code");
      throw new HttpError(400, "invalid_grant", "unknown, used or expired code");
    }
    const verifier = String(b.code_verifier ?? "");
    if (!/^[A-Za-z0-9._~-]{43,128}$/.test(verifier) || !eq(s256(verifier), code.challenge)) {
      this.log(`[account] code exchange refused: the PKCE verifier does not match (account ${short(code.account_id)})`);
      throw new HttpError(400, "invalid_grant", "PKCE verifier");
    }
    if (b.redirect_uri !== undefined && b.redirect_uri !== code.redirect_uri) throw new HttpError(400, "invalid_grant", "redirect_uri");
    const a = this.store.account(code.account_id);
    if (!a || a.disabled_at !== null) throw new HttpError(400, "invalid_grant", "the account is disabled");
    // a code that went back to a hosted web client's address: that page's session, bound to its key
    return this.deviceSession(a, b.device, this.cfg.webRedirects.includes(code.redirect_uri), code.idp_refresh);
  }

  /** A new session for the device a sign-in named (`device`: `{ name, platform, key }`, each optional): the account's
   *  device with that key, else a new one. What /v1/token and /v1/auth/apple answer. */
  private deviceSession(a: Account, device: unknown, hosted: boolean, idpRefresh: string | null, hostedPlatform = "web") {
    const now = this.now();
    const d = (device && typeof device === "object" ? device : {}) as Record<string, unknown>;
    const name = typeof d.name === "string" && cleanText(d.name, 64) ? cleanText(d.name, 64) : hosted ? "Browser" : "Device";
    const platform = hosted ? hostedPlatform : typeof d.platform === "string" && /^[a-z]{1,16}$/.test(d.platform) ? d.platform : null;
    let key: string | null = null;
    if (d.key !== undefined) {
      if (typeof d.key !== "string" || !B64URL_RE.test(d.key) || Buffer.from(d.key, "base64url").length !== 32) throw new HttpError(400, "invalid_request", "device.key is a raw Ed25519 public key, base64url");
      key = d.key;
    }
    if (hosted && !key) throw new HttpError(400, "invalid_request", "a web page's session is bound to its device key: give device.key");
    const keyDigest = key ? createHash("sha256").update(Buffer.from(key, "base64url")).digest("base64url") : null;
    const out = this.store.tx(() => {
      const known = keyDigest ? this.store.get<{ id: string }>("SELECT id FROM devices WHERE account_id = ? AND key_digest = ? AND removed_at IS NULL", a.id, keyDigest) : undefined;
      if (!known && this.store.countDevices(a.id, now) >= this.l.devicesPerAccount) throw new HttpError(403, "too_many_devices", `an account has ${this.l.devicesPerAccount} devices at most: remove one`);
      const dev = this.store.deviceFor(a.id, { name, platform, key, keyDigest }, now);
      const sess = this.store.createSession({ account: a.id, device: dev.id, kind: hosted ? "hosted" : "app", now, maxAgeMs: hosted ? HOSTED_SESSION_MAX_AGE_MS : SESSION_MAX_AGE_MS, idpRefresh });
      return { dev, sess };
    });
    this.log(`[account] ${hosted ? "web client " : ""}session for ${short(a.id)} on device ${short(out.dev.id)} (${platform ?? "?"})`);
    return {
      session: out.sess.token,
      token_type: "Bearer",
      // (each request of this session is signed with the device key: see hostedProofText)
      ...(hosted ? { proof: this.cfg.wire.hostedProof } : {}),
      expiresAt: out.sess.expiresAt,
      account: { id: a.id, name: a.name },
      device: { id: out.dev.id, name: out.dev.name },
      idp: { issuer: a.iss, name: this.idpNameOf(a) },
    };
  }

  /** How an account signs in, as shown: "Email", the OpenID provider's name, "Apple", or the issuer's host. */
  private idpNameOf(a: Account): string {
    return a.iss === this.passwordIss ? "Email" : a.iss === this.cfg.issuer ? this.cfg.idpName : a.iss === APPLE_ISSUER ? "Apple" : new URL(a.iss).host;
  }

  /**
   * POST /v1/auth/apple `{ identityToken, nonce, name?, device }`: an app's native Sign in with Apple. The token is
   * checked here (Apple's key, one of the apps' bundle ids, not expired, SHA-256 of `nonce`); the account is Apple's
   * `iss` + `sub` — the same one a web sign-in through Apple as an OpenID provider would be. `name`: what the app got
   * from Apple at the first sign-in (Apple says it only then), the shown name; else the email, if any.
   */
  private async appleSignIn(req: IncomingMessage, ipKey: string) {
    const b = await this.readBody(req);
    this.limited(this.exchanges, ipKey, "sign-ins");
    const apple = this.cfg.apple!;
    const token = typeof b.identityToken === "string" && b.identityToken.length <= 8192 ? b.identityToken : "";
    const nonce = typeof b.nonce === "string" && b.nonce.length <= 256 ? b.nonce : "";
    if (!token || !nonce) throw new HttpError(400, "invalid_request", "identityToken and nonce");
    const who = await verifyIdentityToken(token, nonce, apple.audiences, this.appleKeys, this.now());
    if (!who) {
      this.badTokens.fail(ipKey);
      this.refuse("Apple sign-ins with a token that does not check out");
      throw new HttpError(401, "invalid_grant", "the identity token is not Apple's for this app, or it expired");
    }
    if (!allowed(this.cfg.allow, APPLE_ISSUER, { sub: who.sub, email: who.email, email_verified: who.email_verified })) {
      this.log(`[account] Apple sign-in refused: not on the allow-list (sub #${subTag(APPLE_ISSUER, who.sub)})`);
      throw new HttpError(403, "access_denied", "this Apple ID may not sign in here");
    }
    const given = typeof b.name === "string" ? cleanText(b.name, 64) : "";
    const got = this.store.signInAccount(APPLE_ISSUER, who.sub, given || (this.store.accountOf(APPLE_ISSUER, who.sub) ? null : (who.email ?? null)), this.now());
    if ("refused" in got) {
      this.log(`[account] Apple sign-in refused: the account is ${got.refused} (sub #${subTag(APPLE_ISSUER, who.sub)})`);
      throw new HttpError(403, got.refused === "removed" ? "account_removed" : "account_disabled", `the account is ${got.refused}`);
    }
    this.log(`[account] Apple sign-in ${short(got.account.id)}`);
    return this.deviceSession(got.account, b.device, false, null);
  }

  // --------------------------------------------------------------------------- email and password

  /** The accounts of email and password: their `iss` (the `sub` is random, the email is in `password_logins`). */
  private get passwordIss() {
    return `${this.cfg.publicUrl}/password`;
  }

  /** A request from a hosted web client's page (its origin is one of ACCOUNT_WEB_REDIRECTS'): its session is the
   *  key-bound one. */
  private fromWebPage(req: IncomingMessage): boolean {
    const o = req.headers.origin;
    return typeof o === "string" && this.webOrigins.has(o);
  }

  private emailOf(b: Record<string, unknown>): string {
    const email = normalizeEmail(b.email);
    if (!email) throw new HttpError(400, "invalid_email", "an email address");
    return email;
  }

  /** A web page's request must name its device key (checked before anything is made or used up). */
  private needKey(req: IncomingMessage, device: unknown) {
    if (!this.fromWebPage(req)) return;
    const key = device && typeof device === "object" ? (device as Record<string, unknown>).key : undefined;
    if (typeof key !== "string" || !B64URL_RE.test(key) || Buffer.from(key, "base64url").length !== 32) {
      throw new HttpError(400, "invalid_request", "a web page's session is bound to its device key: give device.key");
    }
  }

  private passwordOf(b: Record<string, unknown>): string {
    const problem = passwordProblem(b.password);
    if (problem) throw new HttpError(400, "weak_password", `the password: ${problem}`);
    return b.password as string;
  }

  /**
   * Mails a code for `purpose` (a new one each time; at most one a minute and `CODE_SENDS_PER_HOUR` an hour per
   * email). `pending`: what the code finishes (a sign-up's password hash). `existing`: a sign-up for an email that
   * has its login already — the mail says so instead (the answer is the same: nobody learns whose email has an account).
   */
  private async mailCode(email: string, purpose: CodePurpose, locale: unknown, pending: string | null, existing = false) {
    const now = this.now();
    const prev = this.store.emailCode(email, purpose);
    if (prev && now - prev.sent_at < CODE_RESEND_MS) {
      throw new HttpError(429, "slow_down", "a code was sent a moment ago: wait a minute", { "retry-after": String(Math.ceil((prev.sent_at + CODE_RESEND_MS - now) / 1000)) });
    }
    const windowAt = prev && now - prev.window_at < 3_600_000 ? prev.window_at : now;
    const sends = prev && windowAt === prev.window_at ? prev.sends + 1 : 1;
    if (sends > CODE_SENDS_PER_HOUR) {
      this.refuse("codes over the hourly limit for one email");
      throw new HttpError(429, "slow_down", "too many codes for this email: try again later", { "retry-after": String(Math.ceil((windowAt + 3_600_000 - now) / 1000)) });
    }
    const code = existing ? null : newEmailCode();
    this.store.run(
      `INSERT INTO email_codes (email, purpose, code_hash, pending, expires_at, attempts, sent_at, window_at, sends) VALUES (?,?,?,?,?,0,?,?,?)
       ON CONFLICT (email, purpose) DO UPDATE SET code_hash = excluded.code_hash, pending = excluded.pending, expires_at = excluded.expires_at,
         attempts = 0, sent_at = excluded.sent_at, window_at = excluded.window_at, sends = excluded.sends`,
      email, purpose, code ? codeHash(email, purpose, code) : "-", pending, now + CODE_TTL_MS, now, windowAt, sends,
    );
    const mail = codeMail({ purpose, code, serverName: this.cfg.serverName, locale: typeof locale === "string" ? locale : undefined, minutes: CODE_TTL_MS / 60_000 });
    try {
      await this.cfg.password!.mailer.send({ to: email, ...mail });
    } catch (e) {
      this.log(`[account] a ${purpose} code was not mailed: ${String((e as Error)?.message ?? e).slice(0, 160)}`);
      // (sent nothing: may be asked again at once)
      this.store.run("UPDATE email_codes SET sent_at = 0 WHERE email = ? AND purpose = ?", email, purpose);
      throw new HttpError(502, "mail_failed", "the email could not be sent: try again");
    }
  }

  /** The code given for `email`'s `purpose`: right (the row, still there), or 400 (`invalid_code`, `code_expired`). A
   *  wrong one counts; the fifth wrong one ends it. */
  private checkCode(email: string, purpose: CodePurpose, given: unknown): EmailCode {
    const now = this.now();
    const row = this.store.emailCode(email, purpose);
    if (!row || row.code_hash === "-" || row.expires_at <= now || row.attempts >= CODE_ATTEMPTS) throw new HttpError(400, "code_expired", "this code ran out: ask for a new one");
    const code = typeof given === "string" ? given.replace(/\s+/g, "") : "";
    if (!/^\d{6}$/.test(code) || !eq(codeHash(email, purpose, code), row.code_hash)) {
      this.store.run("UPDATE email_codes SET attempts = attempts + 1 WHERE email = ? AND purpose = ?", email, purpose);
      this.refuse("wrong email codes");
      throw new HttpError(400, row.attempts + 1 >= CODE_ATTEMPTS ? "code_expired" : "invalid_code", "the code is not right");
    }
    return row;
  }

  /** POST /v1/auth/password/register `{ email, password, locale? }`: a code mailed (always `{ sent: true }`). */
  private async passwordRegister(req: IncomingMessage, ipKey: string) {
    const b = await this.readBody(req);
    this.limited(this.signins, ipKey, "sign-ups");
    const email = this.emailOf(b);
    const password = this.passwordOf(b);
    if (!allowed(this.cfg.allow, this.passwordIss, { sub: "", email, email_verified: true })) throw new HttpError(403, "access_denied", "this email may not sign up here");
    const existing = !!this.store.passwordLogin(email);
    await this.mailCode(email, "register", b.locale, existing ? null : await hashPassword(password), existing);
    this.log(`[account] a sign-up code mailed`);
    return { sent: true, expiresIn: CODE_TTL_MS / 1000 };
  }

  /** POST /v1/auth/password/verify `{ email, code, name?, device }`: the account made, and this device's session. */
  private async passwordVerify(req: IncomingMessage, ipKey: string) {
    const b = await this.readBody(req);
    this.limited(this.exchanges, ipKey, "sign-ins");
    const email = this.emailOf(b);
    this.needKey(req, b.device);
    const row = this.checkCode(email, "register", b.code);
    if (!row.pending) throw new HttpError(400, "code_expired", "this code ran out: ask for a new one");
    const given = typeof b.name === "string" ? cleanText(b.name, 64) : "";
    const now = this.now();
    const made = this.store.tx(() => {
      if (this.store.passwordLogin(email)) return null;
      const got = this.store.signInAccount(this.passwordIss, randomId("pw_"), given || email, now);
      if ("refused" in got) return null;
      this.store.run("INSERT INTO password_logins (email, account_id, hash, created_at, updated_at) VALUES (?,?,?,?,?)", email, got.account.id, row.pending, now, now);
      this.store.run("DELETE FROM email_codes WHERE email = ? AND purpose = 'register'", email);
      return got.account;
    });
    if (!made) throw new HttpError(409, "already_registered", "this email has an account: sign in");
    this.log(`[account] email sign-up ${short(made.id)}`);
    return this.deviceSession(made, b.device, this.fromWebPage(req), null);
  }

  /** POST /v1/auth/password `{ email, password, device }`: this device's session. Wrong: 401 `invalid_credentials`
   *  (one answer for no such email and a wrong password); ten wrong for one email in 15 minutes: 429. */
  private async passwordSignIn(req: IncomingMessage, ipKey: string) {
    const b = await this.readBody(req);
    this.limited(this.exchanges, ipKey, "sign-ins");
    const email = this.emailOf(b);
    this.needKey(req, b.device);
    const password = typeof b.password === "string" && b.password.length <= 1024 ? b.password : "";
    const blocked = this.passwordFails.blockedFor(email);
    if (blocked) {
      this.refuse("password sign-ins for an email with too many wrong ones");
      throw new HttpError(429, "slow_down", "too many wrong passwords: wait a while", { "retry-after": String(blocked) });
    }
    const login = this.store.passwordLogin(email);
    const ok = (await verifyPassword(password, login?.hash ?? (await decoyHash()))) && !!login;
    if (!ok || !login) {
      this.passwordFails.fail(email);
      this.refuse("password sign-ins with a wrong email or password");
      throw new HttpError(401, "invalid_credentials", "the email or the password is not right");
    }
    const a = this.store.account(login.account_id);
    if (!a || a.disabled_at !== null) throw new HttpError(403, "account_disabled", "the account is disabled");
    this.log(`[account] email sign-in ${short(a.id)}`);
    return this.deviceSession(a, b.device, this.fromWebPage(req), null);
  }

  /** POST /v1/auth/password/reset `{ email, locale? }`: a code mailed when the email has a login (always `{ sent: true }`). */
  private async passwordReset(req: IncomingMessage, ipKey: string) {
    const b = await this.readBody(req);
    this.limited(this.signins, ipKey, "password resets");
    const email = this.emailOf(b);
    if (this.store.passwordLogin(email)) {
      await this.mailCode(email, "reset", b.locale, null);
      this.log(`[account] a reset code mailed`);
    }
    return { sent: true, expiresIn: CODE_TTL_MS / 1000 };
  }

  /** POST /v1/auth/password/reset/confirm `{ email, code, password, device }`: the new password; the account's other
   *  sessions end; this device's session. */
  private async passwordResetConfirm(req: IncomingMessage, ipKey: string) {
    const b = await this.readBody(req);
    this.limited(this.exchanges, ipKey, "password resets");
    const email = this.emailOf(b);
    const password = this.passwordOf(b);
    this.needKey(req, b.device);
    this.checkCode(email, "reset", b.code);
    const login = this.store.passwordLogin(email);
    if (!login) throw new HttpError(400, "code_expired", "this code ran out: ask for a new one");
    const hash = await hashPassword(password);
    const now = this.now();
    this.store.tx(() => {
      this.store.run("UPDATE password_logins SET hash = ?, updated_at = ? WHERE email = ?", hash, now, email);
      this.store.run("DELETE FROM email_codes WHERE email = ? AND purpose = 'reset'", email);
      this.store.endSessions("account_id", login.account_id, "password_reset", now);
    });
    const a = this.store.account(login.account_id);
    if (!a || a.disabled_at !== null) throw new HttpError(403, "account_disabled", "the account is disabled");
    this.log(`[account] password reset ${short(a.id)}`);
    return this.deviceSession(a, b.device, this.fromWebPage(req), null);
  }

  /** The device session of a request's bearer token (an app's), or 401 / 429. */
  private bearer(req: IncomingMessage, ipKey: string): Authed {
    // (a valid session first: a home or an office behind one address is not locked out by somebody else's bad tokens;
    // the tokens are 256 random bits, so the limit is against load, not guessing)
    const m = this.sessionRe.exec(req.headers.authorization ?? "");
    // (a hosted web client's token counts only with its device key's proof: without it, it is no token at all)
    const a = m ? this.sessionAuth(m[1]!, ["app", "hosted"], (s) => s.kind !== "hosted" || this.hostedProofOk(req, s)) : null;
    if (!a) {
      req.resume();
      const blocked = this.badTokens.blockedFor(ipKey);
      if (blocked) {
        this.refuse("requests from an address with too many bad tokens");
        throw new HttpError(429, "slow_down", "too many requests without a valid session", { "retry-after": String(blocked) });
      }
      this.badTokens.fail(ipKey);
      this.refuse("requests without a valid session");
      throw new HttpError(401, "invalid_token", "sign in again", { "www-authenticate": 'Bearer error="invalid_token"' });
    }
    return a;
  }

  /** A hosted web client's request: signed, just now, with the key its session was made for. */
  private hostedProofOk(req: IncomingMessage, s: Session): boolean {
    const m = /^(\d{9,11})\.([A-Za-z0-9_-]{43})\.([A-Za-z0-9_-]{86})$/.exec(String(req.headers[this.cfg.wire.proofHeader] ?? ""));
    const key = s.device_id ? this.store.device(s.device_id)?.key : null;
    if (!m || !key) {
      this.refuse("web client requests without their device key's proof");
      return false;
    }
    const ts = Number(m[1]);
    if (Math.abs(ts - this.now() / 1000) > HOSTED_PROOF_MAX_AGE_S) return false;
    // (the device key is a raw Ed25519 public key, as a Link id is: the same check; the path as it reached this server)
    if (!verifyLinkSignature(Buffer.from(key, "base64url").toString("hex"), this.cfg.wire.hostedProofText(this.cfg.publicUrl, req.method ?? "GET", req.url ?? "/", ts, m[2]!), m[3]!)) return false;
    // the body it signed is the body this request carries: checked as it is read (readBody)
    this.signedBodies.set(req, m[2]!);
    return true;
  }

  /** The session of `token` if it is one of `kinds`, current, and passes `check` (before it counts as used). */
  private sessionAuth(token: string, kinds: Session["kind"] | Session["kind"][], check?: (s: Session) => boolean): Authed | null {
    const s = this.store.sessionOfToken(token);
    const now = this.now();
    if (!s || !(Array.isArray(kinds) ? kinds : [kinds]).includes(s.kind) || s.ended_at !== null || s.expires_at <= now) return null;
    const account = this.store.account(s.account_id);
    if (!account || account.disabled_at !== null) return null;
    if (s.device_id) {
      const d = this.store.device(s.device_id);
      if (!d || d.removed_at !== null) return null;
    }
    if (check && !check(s)) return null;
    this.store.touchSession(s, now);
    return { session: s, account };
  }

  private me(a: Authed) {
    const d = a.session.device_id ? this.store.device(a.session.device_id) : undefined;
    return {
      entitlements: this.entitlements(a.account.id),
      account: { id: a.account.id, name: a.account.name, iss: a.account.iss, sub: a.account.sub },
      device: d ? { id: d.id, name: d.name } : null,
      session: { expiresAt: a.session.expires_at, idpCheckedAt: a.session.idp_checked_at, idpCheck: a.session.idp_refresh ? (a.session.idp_check_result ?? "pending") : "unchecked" },
      server: this.configBody().server,
    };
  }

  /** What the account has bought, by source: `appstore` → `{ active, productId, expiresAt, sandbox }` from its newest
   *  purchase that is not revoked (absent: none ever reported). */
  private entitlements(account: string): Record<string, { active: boolean; productId: string; expiresAt: number | null; sandbox: boolean }> {
    const now = this.now();
    const out: Record<string, { active: boolean; productId: string; expiresAt: number | null; sandbox: boolean }> = {};
    const bySource = new Map<string, ReturnType<Store["entitlementsOf"]>>();
    for (const e of this.store.entitlementsOf(account)) bySource.set(e.source, [...(bySource.get(e.source) ?? []), e]);
    for (const [source, list] of bySource) {
      const live = list.filter((e) => e.revoked_at === null);
      // (the one that lasts longest; one without an end — a lifetime purchase — beats them all)
      const best = live.sort((x, y) => (x.expires_at ?? Infinity) - (y.expires_at ?? Infinity)).at(-1) ?? list.at(-1)!;
      const active = best.revoked_at === null && (best.expires_at === null || best.expires_at > now);
      out[source] = { active, productId: best.product_id, expiresAt: best.expires_at, sandbox: best.environment === "Sandbox" };
    }
    return out;
  }

  /** POST /v1/entitlements/appstore `{ jws }`: a StoreKit 2 transaction of one of the operator's products, for its
   *  bundle id, signed by Apple — the account's now (a purchase is the last reporting account's). */
  private appStoreEntitlement(a: Authed, b: Record<string, unknown>) {
    const st = this.cfg.appstore!;
    const jws = typeof b.jws === "string" && b.jws.length <= 12 * 1024 ? b.jws : "";
    if (!jws) throw new HttpError(400, "invalid_request", "jws is a StoreKit transaction");
    const now = this.now();
    const tx = (this.deps.storeKit ?? verifyStoreKit)(jws, now);
    if (!tx) throw new HttpError(400, "invalid_grant", "not a transaction signed by Apple");
    if (tx.bundleId !== st.bundleId || !st.products.includes(tx.productId)) throw new HttpError(400, "invalid_grant", "not a transaction of this app's products");
    this.store.putEntitlement({ source: "appstore", original_id: tx.originalTransactionId, account_id: a.account.id, product_id: tx.productId, expires_at: tx.expiresDate ?? null, revoked_at: tx.revocationDate ?? null, environment: tx.environment, updated_at: now });
    this.log(`[account] App Store purchase reported for ${short(a.account.id)}${tx.environment === "Sandbox" ? " (sandbox)" : ""}`);
    return { entitlements: this.entitlements(a.account.id) };
  }

  /** POST /v1/join-keys: a one-use join key for the account, short-lived — what a signed-in app hands a computer it is
   *  paired with (over their own connection) so the computer joins the account by itself. Only an app's session (a
   *  web page's could be any script's). */
  private appJoinKey(a: Authed) {
    if (a.session.kind !== "app") throw new HttpError(403, "invalid_token", "an app's session only");
    const now = this.now();
    if (this.store.countJoinKeys(a.account.id, now) >= this.l.appJoinKeysOpen) throw new HttpError(429, "slow_down", "too many join keys not used yet: wait");
    const key = this.store.createJoinKey(a.account.id, 1, now + APP_JOIN_KEY_TTL_MS, now);
    this.log(`[account] join key for ${short(a.account.id)} made by device ${short(a.session.device_id ?? "")}`);
    return { key, server: this.cfg.publicUrl, expiresAt: now + APP_JOIN_KEY_TTL_MS };
  }

  /**
   * DELETE /v1/me `{ authorizationCode? }`: the account deleted by its own person (from the app: Apple's rule for apps
   * with accounts). Everything of it goes — its computers leave it (the signed list says so), its devices are signed
   * out —, but no tombstone stays: signing in again makes a new account. With a fresh Sign in with Apple
   * authorization code and the operator's key, the Apple grant is revoked too (Apple unreachable, or the code not of
   * this account: deleted all the same, `revoked: false`).
   */
  private async deleteAccount(a: Authed, b: Record<string, unknown>) {
    if (a.session.kind !== "app" && a.session.kind !== "hosted") throw new HttpError(403, "invalid_token");
    const now = this.now();
    const sec = Math.floor(now / 1000);
    const acc = a.account;
    this.store.tx(() => {
      const devices = this.store.devicesOf(acc.id).map((d) => d.id);
      const computers = this.store.computersOf(acc.id).map((c) => c.link_id);
      // (the revocations outlive the account, keyed by its id, never handed out again: its computers learn of it)
      this.store.revoke(acc.id, { devices, computers, disabled: sec }, sec, now);
      this.store.run("DELETE FROM app_codes WHERE account_id = ?", acc.id);
      this.store.run("DELETE FROM enrollments WHERE approved_account = ?", acc.id);
      this.store.run("DELETE FROM accounts WHERE id = ?", acc.id);
    });
    this.log(`[account] account ${short(acc.id)} deleted by its own device ${short(a.session.device_id ?? "")}`);
    await this.deliverNotices();
    let revoked = false;
    const code = typeof b.authorizationCode === "string" && b.authorizationCode.length <= 512 ? b.authorizationCode : "";
    const client = this.cfg.apple?.client;
    if (client && code && acc.iss === APPLE_ISSUER) {
      try {
        revoked = await revokeAppleGrant(client, code, acc.sub, this.deps.appleFetch, now);
      } catch (e) {
        this.log(`[account] Sign in with Apple: revoking failed (${(e as Error).message.slice(0, 80)})`);
      }
    }
    return { ok: true, revoked };
  }

  // --------------------------------------------------------------------------- revocation

  /** The device's session ended, and the device on the revocation list (its computers stop taking what it holds). */
  async endDeviceSession(a: Authed, reason: string) {
    const now = this.now();
    this.store.tx(() => {
      this.store.endSessions("id", a.session.id, reason, now);
      if (a.session.device_id) {
        this.store.revoke(a.account.id, { devices: [a.session.device_id] }, Math.floor(now / 1000), now);
        // (one with no key could never sign in again as itself: its row would only count against the account's limit)
        this.store.run("UPDATE devices SET removed_at = ? WHERE id = ? AND key_digest IS NULL AND removed_at IS NULL", now, a.session.device_id);
      }
    });
    this.log(`[account] session of ${short(a.account.id)} ended (${reason})`);
    await this.deliverNotices();
  }

  /** A session the IdP re-check ended (recheck.ts): its device on the revocation list, the notice pushed. */
  async sessionEnded(s: Session) {
    const now = this.now();
    if (s.device_id) this.store.revoke(s.account_id, { devices: [s.device_id] }, Math.floor(now / 1000), now);
    await this.deliverNotices();
  }

  /** The queued revocations (store.revoke puts them in the outbox; admin.ts too, from its process) take effect on the
   *  computers: those waiting on the account's list are answered with it now. */
  deliverNotices(): Promise<void> {
    if (this.delivering) return this.delivering.then(() => this.deliverNotices());
    const run = (async () => {
      for (const row of this.store.outbox()) {
        const p = JSON.parse(row.payload) as { devices: { id: string; at: number }[]; computers: { id: string; at: number }[]; disabled: number | null };
        const linkIds = [...new Set([...this.store.computersOf(row.account_id).map((c) => c.link_id), ...p.computers.map((c) => c.id)])];
        try {
          if (this.deps.deliver) await this.deps.deliver({ account: row.account_id, seq: row.seq, linkIds });
          this.store.outboxDone(row.id);
          for (const wake of [...(this.waiters.get(row.account_id) ?? [])]) wake();
          this.log(`[account] revocation ${short(row.account_id)} #${row.seq}: ${p.devices.length} device(s), ${p.computers.length} computer(s)${p.disabled !== null ? ", disabled" : ""} → ${linkIds.length} computer(s)`);
        } catch (e) {
          this.log(`[account] revocation ${short(row.account_id)} #${row.seq}: not delivered (${(e as Error).message.slice(0, 80)}), kept`);
          break;
        }
      }
    })();
    this.delivering = run.finally(() => {
      this.delivering = null;
    });
    return this.delivering;
  }

  // --------------------------------------------------------------------------- computers and tickets

  private ownComputer(a: Authed, linkId: string): Computer {
    const c = this.store.computer(linkId);
    if (!c || c.account_id !== a.account.id) throw new HttpError(404, "not_found", "no such computer in this account");
    return c;
  }

  private async renameComputer(a: Authed, linkId: string, b: Record<string, unknown>) {
    this.ownComputer(a, linkId);
    const name = typeof b.name === "string" ? cleanText(b.name, 64) : "";
    if (!name) throw new HttpError(400, "invalid_request", "name");
    this.store.run("UPDATE computers SET name = ?, updated_at = ? WHERE link_id = ?", name, this.now(), linkId);
    return { computer: computerBody(this.store.computer(linkId)!) };
  }

  private async removeComputer(a: Authed, linkId: string) {
    this.ownComputer(a, linkId);
    const now = this.now();
    this.store.tx(() => {
      this.store.run("DELETE FROM computers WHERE link_id = ?", linkId);
      this.store.revoke(a.account.id, { computers: [linkId] }, Math.floor(now / 1000), now);
    });
    this.log(`[account] computer ${linkId.slice(0, 8)} taken out of ${short(a.account.id)}`);
    await this.deliverNotices();
    return { ok: true };
  }

  private async ticket(a: Authed, b: Record<string, unknown>) {
    const linkId = String(b.computer ?? "");
    if (!LINK_ID_RE.test(linkId)) throw new HttpError(400, "invalid_request", "computer is a Link id");
    const dev = a.session.device_id ? this.store.device(a.session.device_id) : undefined;
    if (!dev) throw new HttpError(403, "invalid_token");
    this.limited(this.tickets, dev.id, "tickets");
    const c = this.ownComputer(a, linkId);
    const now = this.now();
    const keyDigest = dev.key_digest ?? undefined;
    const ticket = await signTicket(this.deps.ring, {
      issuer: this.cfg.publicUrl, account: a.account.id, accountName: a.account.name, linkId: c.link_id, device: { id: dev.id, name: dev.name, ...(keyDigest ? { key: keyDigest } : {}) },
      sessionExpiresAt: a.session.expires_at, now,
    });
    return { ticket, expiresIn: TICKET_TTL_S };
  }

  private async removeDevice(a: Authed, id: string) {
    const d = this.store.device(id);
    if (!d || d.account_id !== a.account.id || d.removed_at !== null) throw new HttpError(404, "not_found", "no such device in this account");
    const now = this.now();
    this.store.tx(() => {
      this.store.run("UPDATE devices SET removed_at = ? WHERE id = ?", now, id);
      this.store.endSessions("device_id", id, "device_removed", now);
      this.store.revoke(a.account.id, { devices: [id] }, Math.floor(now / 1000), now);
    });
    this.log(`[account] device ${short(id)} removed from ${short(a.account.id)} by device ${short(a.session.device_id ?? "")}`);
    await this.deliverNotices();
    return { ok: true };
  }

  // --------------------------------------------------------------------------- sign-in by QR code

  /**
   * POST /v1/auth/qr `{ device: { name, platform?, key } }`: a new device (a browser, a desktop client) asks to be
   * signed in by one that is. It gets a code to show (as a QR code and as text: what the signed-in device looks up and
   * approves) and `request`, a secret only it holds, to poll with. Its session will be bound to `device.key` (raw
   * Ed25519, base64url; each request signed, `<ns>-proof`), so the secret alone is worth nothing to anyone without the
   * key. 150 seconds, once.
   */
  private async qrStart(req: IncomingMessage, ip: string, ipKey: string) {
    const b = await this.readBody(req);
    this.limited(this.qrStarts, ipKey, "QR sign-ins");
    const now = this.now();
    if (this.store.openQrSigninAddresses(now).filter((x) => ipBucket(x) === ipKey).length >= this.l.qrOpenPerAddress) throw new HttpError(429, "slow_down", "too many open QR sign-ins from this address");
    if (this.store.get<{ n: number }>("SELECT count(*) AS n FROM qr_signins WHERE expires_at > ? AND status IN ('pending','approved')", now)!.n >= this.l.qrOpenMax) throw new HttpError(503, "temporarily_unavailable", "too many open QR sign-ins");
    const d = (b.device && typeof b.device === "object" ? b.device : {}) as Record<string, unknown>;
    if (typeof d.key !== "string" || !B64URL_RE.test(d.key) || Buffer.from(d.key, "base64url").length !== 32) throw new HttpError(400, "invalid_request", "device.key is a raw Ed25519 public key, base64url (the session is bound to it)");
    const name = typeof d.name === "string" && cleanText(d.name, 64) ? cleanText(d.name, 64) : "Browser";
    const platform = typeof d.platform === "string" && /^[a-z]{1,16}$/.test(d.platform) ? d.platform : "web";
    const request = randomBytes(32).toString("base64url");
    let code = "";
    for (let i = 0; i < 5 && !code; i++) {
      const c = newCode();
      if (!this.store.qrSigninOfCode(c)) code = c;
    }
    if (!code) throw new HttpError(503, "temporarily_unavailable");
    this.store.run(
      "INSERT INTO qr_signins (id, request_hash, user_code, device_name, platform, key, ip, created_at, expires_at, status) VALUES (?,?,?,?,?,?,?,?,?, 'pending')",
      randomId("q_", 12), sha256(request), code, name, platform, d.key, ip, now, now + QR_SIGNIN_TTL_MS,
    );
    this.log(`[account] QR sign-in asked (${platform})`);
    return { request, code, user_code: showCode(code), expires_in: QR_SIGNIN_TTL_MS / 1000, expiresAt: now + QR_SIGNIN_TTL_MS, interval: POLL_INTERVAL_S };
  }

  /** The open QR sign-in of a code looked up or approved on a signed-in device: wrong codes count like a computer's
   *  (the session, the address, the account); 404 for a wrong or used one, 429 once over. */
  private qrTarget(a: Authed, raw: string, ipKey: string) {
    const keys: [FailureLimiter, string][] = [
      [this.codeFailSession, a.session.id],
      [this.codeFailAddress, ipKey],
      [this.codeFailAccount, a.account.id],
    ];
    for (const [l, k] of keys) {
      const w = l.blockedFor(k);
      if (w) {
        this.refuse("QR sign-ins over the wrong-code limit");
        throw new HttpError(429, "slow_down", "too many wrong codes: wait", { "retry-after": String(w) });
      }
    }
    const code = normCode(raw);
    const q = validCode(code) ? this.store.qrSigninOfCode(code) : undefined;
    if (!q || q.expires_at <= this.now() || !(q.status === "pending" || (q.status === "approved" && q.approved_account === a.account.id))) {
      for (const [l, k] of keys) l.fail(k);
      this.refuse("wrong, used or expired QR sign-in codes");
      throw new HttpError(404, "not_found", "no such code (or it expired, or it was used)");
    }
    return q;
  }

  /** GET /v1/auth/qr/lookup?code=: what asks to be signed in, for the person to check before approving. */
  private qrLookup(a: Authed, raw: string, ipKey: string) {
    const q = this.qrTarget(a, raw, ipKey);
    return {
      device: { name: q.device_name, platform: q.platform },
      requestedAt: q.created_at,
      from: q.ip,
      expiresIn: Math.max(0, Math.round((q.expires_at - this.now()) / 1000)),
      status: q.status,
      account: { id: a.account.id, name: a.account.name },
    };
  }

  /** POST /v1/auth/qr/approve `{ code }`: the new device signs in to this account (at its next poll). The first
   *  approval wins. */
  private qrApprove(a: Authed, raw: string, ipKey: string) {
    if (a.session.kind !== "app" && a.session.kind !== "hosted") throw new HttpError(403, "invalid_token", "an app's or a web page's session only");
    const q = this.qrTarget(a, raw, ipKey);
    if (q.status !== "pending") throw new HttpError(409, "already_approved", "this code was already approved");
    const now = this.now();
    const digest = createHash("sha256").update(Buffer.from(q.key, "base64url")).digest("base64url");
    const known = this.store.get<{ id: string }>("SELECT id FROM devices WHERE account_id = ? AND key_digest = ? AND removed_at IS NULL", a.account.id, digest);
    if (!known && this.store.countDevices(a.account.id, now) >= this.l.devicesPerAccount) throw new HttpError(403, "too_many_devices", `an account has ${this.l.devicesPerAccount} devices at most: remove one`);
    const won = this.store.run(
      "UPDATE qr_signins SET status = 'approved', approved_account = ?, approved_device = ?, approved_at = ? WHERE id = ? AND status = 'pending' AND expires_at > ?",
      a.account.id, a.session.device_id, now, q.id, now,
    );
    if (!won) throw new HttpError(409, "already_approved", "this code was already approved");
    this.log(`[account] QR sign-in approved for ${short(a.account.id)} by device ${short(a.session.device_id ?? "")}`);
    return { status: "approved", device: { name: q.device_name, platform: q.platform } };
  }

  /** POST /v1/auth/qr/decline `{ code }`: refused; the new device's poll says `access_denied`. */
  private qrDecline(a: Authed, raw: string, ipKey: string) {
    const q = this.qrTarget(a, raw, ipKey);
    this.store.run("UPDATE qr_signins SET status = 'declined' WHERE id = ? AND status IN ('pending','approved')", q.id);
    this.log(`[account] QR sign-in declined by device ${short(a.session.device_id ?? "")}`);
    return { ok: true };
  }

  /**
   * POST /v1/auth/qr/poll `{ request }`: the new device's wait, as RFC 8628's — 400 `authorization_pending` (ask again
   * in `interval` s), `slow_down`, `access_denied` (declined), `expired_token`; 200 its session (once: the code is
   * used up), key-bound like a web page's.
   */
  private async qrPoll(req: IncomingMessage, ipKey: string): Promise<{ status: number; body: unknown }> {
    const b = await this.readBody(req);
    this.limited(this.qrPolls, ipKey, "QR sign-in polls");
    const blocked = this.badTokens.blockedFor(ipKey);
    if (blocked) throw new HttpError(429, "slow_down", "too many unknown requests: wait", { "retry-after": String(blocked) });
    const request = String(b.request ?? "");
    const q = /^[A-Za-z0-9_-]{43}$/.test(request) ? this.store.qrSigninOfRequest(request) : undefined;
    if (!q) {
      this.badTokens.fail(ipKey);
      this.refuse("QR sign-in polls with an unknown request");
      throw new HttpError(400, "invalid_grant", "unknown request");
    }
    const now = this.now();
    if (q.status === "done") return { status: 400, body: { error: "invalid_grant", error_description: "already signed in" } };
    if (q.expires_at <= now) return { status: 400, body: { error: "expired_token", error_description: "the code expired: start again" } };
    const tooSoon = q.last_poll_at !== null && now - q.last_poll_at < POLL_INTERVAL_S * 1000 - 250;
    this.store.run("UPDATE qr_signins SET last_poll_at = ? WHERE id = ?", now, q.id);
    if (tooSoon) return { status: 400, body: { error: "slow_down", interval: POLL_INTERVAL_S + 1 } };
    if (q.status === "pending") return { status: 400, body: { error: "authorization_pending", interval: POLL_INTERVAL_S } };
    if (q.status === "declined") return { status: 400, body: { error: "access_denied", error_description: "declined" } };
    const a = this.store.account(q.approved_account ?? "");
    const approver = q.approved_device ? this.store.device(q.approved_device) : undefined;
    // (the approving device must still be one of the account's: one removed since approves nothing)
    if (!a || a.disabled_at !== null || (q.approved_device && (!approver || approver.removed_at !== null))) {
      this.store.run("UPDATE qr_signins SET status = 'declined' WHERE id = ?", q.id);
      return { status: 400, body: { error: "access_denied" } };
    }
    if (!this.store.run("UPDATE qr_signins SET status = 'done' WHERE id = ? AND status = 'approved'", q.id)) return { status: 400, body: { error: "invalid_grant", error_description: "already signed in" } };
    this.log(`[account] QR sign-in ${short(a.id)}: session made`);
    return { status: 200, body: this.deviceSession(a, { name: q.device_name, key: q.key }, true, null, q.platform) };
  }

  // --------------------------------------------------------------------------- the join code

  private async enroll(req: IncomingMessage, ip: string, ipKey: string) {
    const b = await this.readBody(req);
    this.limited(this.enrolls, ipKey, "join codes");
    const now = this.now();
    if (this.store.openEnrollmentAddresses(now).filter((x) => ipBucket(x) === ipKey).length >= this.l.enrollOpenPerAddress) throw new HttpError(429, "slow_down", "too many open join codes from this address");
    if (this.store.countEnrollments(now) >= this.l.enrollOpenMax) throw new HttpError(503, "temporarily_unavailable", "too many open join codes");
    const linkId = String(b.linkId ?? "");
    if (!LINK_ID_RE.test(linkId)) throw new HttpError(400, "invalid_request", "linkId is the computer's Link id (64 hex)");
    const name = typeof b.name === "string" ? cleanText(b.name, 64) : "";
    if (!name) throw new HttpError(400, "invalid_request", "name");
    const f = computerFields(b);
    let expect: { account?: string; sub?: string } | null = null;
    if (b.expect !== undefined && b.expect !== null) {
      const e = b.expect as Record<string, unknown>;
      if (typeof e !== "object" || (e.account === undefined && e.sub === undefined)) throw new HttpError(400, "invalid_request", "expect is { account } or { sub }");
      expect = {};
      if (e.account !== undefined) {
        if (typeof e.account !== "string" || !/^a_[A-Za-z0-9_-]{10,40}$/.test(e.account)) throw new HttpError(400, "invalid_request", "expect.account");
        expect.account = e.account;
      }
      if (e.sub !== undefined) {
        if (typeof e.sub !== "string" || !e.sub || e.sub.length > 255) throw new HttpError(400, "invalid_request", "expect.sub");
        expect.sub = e.sub;
      }
    }
    const deviceCode = randomBytes(32).toString("base64url");
    let code = "";
    for (let i = 0; i < 5 && !code; i++) {
      const c = newCode();
      if (!this.store.enrollmentOfCode(c)) code = c;
    }
    if (!code) throw new HttpError(503, "temporarily_unavailable");
    this.store.run(
      "INSERT INTO enrollments (id, device_code_hash, user_code, link_id, name, fingerprint, relays, direct, origins, signal, info, expect, ip, created_at, expires_at, status) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?, 'pending')",
      randomId("e_", 12), sha256(deviceCode), code, linkId, name, f.fingerprint ?? null, JSON.stringify(f.relays ?? []), JSON.stringify(f.direct ?? []), JSON.stringify(f.origins ?? []), f.signal ?? null, f.info ?? null, expect ? JSON.stringify(expect) : null, ip, now, now + JOIN_TTL_MS,
    );
    this.log(`[account] join code for ${linkId.slice(0, 8)}${expect ? " (expects an account)" : ""}`);
    const host = new URL(this.cfg.publicUrl);
    return {
      device_code: deviceCode,
      user_code: showCode(code),
      // the QR's text, for the app's scanner (no page answers at it): all upper case, so it fits QR's alphanumeric
      // mode (v2 at level M for a short host); the app reads this server and the code from it
      qr: `${host.protocol.toUpperCase()}//${host.host.toUpperCase()}/C/${code}`,
      expires_in: JOIN_TTL_MS / 1000,
      interval: POLL_INTERVAL_S,
    };
  }

  /** The open enrollment of a code typed or scanned on a phone, counting wrong ones against the session, the address
   *  and the account; 404 for a wrong code, 429 once over. */
  private codeTarget(a: Authed, raw: string, ipKey: string): Enrollment {
    const keys: [FailureLimiter, string][] = [
      [this.codeFailSession, a.session.id],
      [this.codeFailAddress, ipKey],
      [this.codeFailAccount, a.account.id],
    ];
    for (const [l, k] of keys) {
      const w = l.blockedFor(k);
      if (w) {
        this.refuse("join codes over the wrong-code limit");
        throw new HttpError(429, "slow_down", "too many wrong codes: wait", { "retry-after": String(w) });
      }
    }
    const code = normCode(raw);
    const e = validCode(code) ? this.store.enrollmentOfCode(code) : undefined;
    const now = this.now();
    const visible = e && e.expires_at > now && (e.status === "pending" || e.approved_account === a.account.id);
    if (!e || !visible) {
      for (const [l, k] of keys) l.fail(k);
      this.refuse("wrong or expired join codes");
      throw new HttpError(404, "not_found", "no such code (or it expired)");
    }
    return e;
  }

  private lookup(a: Authed, raw: string, ipKey: string) {
    const e = this.codeTarget(a, raw, ipKey);
    const expect = e.expect ? (JSON.parse(e.expect) as { account?: string; sub?: string }) : null;
    return {
      computer: { linkId: e.link_id, name: e.name, fingerprint: e.fingerprint },
      requestedAt: e.created_at,
      from: e.ip,
      expiresIn: Math.max(0, Math.round((e.expires_at - this.now()) / 1000)),
      status: e.status,
      expectsAccount: expect !== null,
      matchesExpected: expect ? expectMatches(expect, a.account) : null,
      account: { id: a.account.id, name: a.account.name },
    };
  }

  private approve(a: Authed, raw: string, ipKey: string) {
    const e = this.codeTarget(a, raw, ipKey);
    if (e.status !== "pending") throw new HttpError(409, "already_approved", "this code was already approved");
    const expect = e.expect ? (JSON.parse(e.expect) as { account?: string; sub?: string }) : null;
    if (expect && !expectMatches(expect, a.account)) {
      this.log(`[account] join ${e.link_id.slice(0, 8)}: approval by ${short(a.account.id)} refused (the computer expects another account)`);
      throw new HttpError(403, "wrong_account", "this computer was set up to join another account");
    }
    const existing = this.store.computer(e.link_id);
    if ((!existing || existing.account_id !== a.account.id) && this.store.countComputers(a.account.id) >= this.l.computersPerAccount) {
      throw new HttpError(403, "too_many_computers", `an account has ${this.l.computersPerAccount} computers at most`);
    }
    const now = this.now();
    const dev = a.session.device_id ? this.store.device(a.session.device_id) : undefined;
    // the first approval wins; a second one (another phone, another account, the same code at once) gets 409
    const won = this.store.run(
      "UPDATE enrollments SET status = 'approved', approved_account = ?, approved_device_name = ?, approved_at = ?, expires_at = max(expires_at, ?) WHERE id = ? AND status = 'pending' AND expires_at > ?",
      a.account.id, dev?.name ?? "a device", now, now + JOIN_CONFIRM_MS, e.id, now,
    );
    if (!won) throw new HttpError(409, "already_approved", "this code was already approved");
    this.log(`[account] join ${e.link_id.slice(0, 8)}: approved by ${short(a.account.id)} (device ${dev ? short(dev.id) : "?"})`);
    return { status: "approved", computer: { linkId: e.link_id, name: e.name }, next: "confirm on the computer" };
  }

  private async deviceCodeEnrollment(req: IncomingMessage): Promise<{ e: Enrollment; b: Record<string, unknown>; deviceCode: string }> {
    const b = await this.readBody(req);
    const deviceCode = String(b.device_code ?? "");
    const e = /^[A-Za-z0-9_-]{43}$/.test(deviceCode) ? this.store.enrollmentOfDeviceCode(deviceCode) : undefined;
    if (!e) {
      this.refuse("join polls with an unknown device code");
      throw new HttpError(400, "invalid_grant", "unknown device code");
    }
    if (e.expires_at <= this.now()) throw new HttpError(400, "expired_token", "the code expired: start again");
    return { e, b, deviceCode };
  }

  private async poll(req: IncomingMessage): Promise<{ status: number; body: unknown }> {
    const { e } = await this.deviceCodeEnrollment(req);
    const now = this.now();
    const tooSoon = e.last_poll_at !== null && now - e.last_poll_at < POLL_INTERVAL_S * 1000 - 250;
    this.store.run("UPDATE enrollments SET last_poll_at = ? WHERE id = ?", now, e.id);
    if (tooSoon) return { status: 400, body: { error: "slow_down", interval: POLL_INTERVAL_S + 1 } };
    if (e.status === "pending") return { status: 400, body: { error: "authorization_pending", interval: POLL_INTERVAL_S } };
    if (e.status === "declined") return { status: 400, body: { error: "access_denied" } };
    if (e.status === "confirmed") return { status: 400, body: { error: "invalid_grant", error_description: "already confirmed" } };
    const a = this.store.account(e.approved_account ?? "");
    if (!a || a.disabled_at !== null) return { status: 400, body: { error: "access_denied" } };
    return {
      status: 200,
      body: {
        status: "approved",
        // what the computer shows before the person there confirms (or, headless, compares with what it expects)
        claimant: { account: { id: a.id, name: a.name }, idp: { issuer: a.iss, name: this.idpNameOf(a), sub: a.sub }, approvedAt: e.approved_at, by: e.approved_device_name },
        server: { url: this.cfg.publicUrl, keys: this.deps.ring.jwks() },
        confirmBy: e.expires_at,
      },
    };
  }

  private async confirm(req: IncomingMessage) {
    const { e, b, deviceCode } = await this.deviceCodeEnrollment(req);
    if (e.status !== "approved" || !e.approved_account) throw new HttpError(400, e.status === "pending" ? "authorization_pending" : "invalid_grant", "nothing approved to confirm");
    const proof = String(b.proof ?? "");
    if (!verifyLinkSignature(e.link_id, this.cfg.wire.joinProofText(this.cfg.publicUrl, e.link_id, e.approved_account, deviceCode), proof)) {
      this.log(`[account] join ${e.link_id.slice(0, 8)}: confirmation refused (not signed by that Link id)`);
      throw new HttpError(403, "bad_proof", "the confirmation must be signed with the computer's Link key");
    }
    const now = this.now();
    const a = this.store.account(e.approved_account);
    if (!a || a.disabled_at !== null) throw new HttpError(400, "access_denied");
    const moved = this.store.tx(() => {
      const won = this.store.run("UPDATE enrollments SET status = 'confirmed' WHERE id = ? AND status = 'approved'", e.id);
      if (!won) throw new HttpError(400, "invalid_grant", "already confirmed");
      return this.admit(a.id, { linkId: e.link_id, name: e.name, fingerprint: e.fingerprint, relays: e.relays, direct: e.direct, origins: e.origins, signal: e.signal ?? null, info: e.info ?? null }, now);
    });
    this.log(`[account] join ${e.link_id.slice(0, 8)}: confirmed on the computer, now in ${short(a.id)}${moved ? ` (left ${short(moved)})` : ""}`);
    if (moved) await this.deliverNotices();
    return { account: { id: a.id, name: a.name, iss: a.iss, sub: a.sub }, server: { url: this.cfg.publicUrl, keys: this.deps.ring.jwks() }, computer: computerBody(this.store.computer(e.link_id)!) };
  }

  /** The computer is in `account` now (inside a transaction): a new row, or its row updated; one that was in another
   *  account leaves that one (whose devices drop it). → the account it left, or null. */
  private admit(account: string, c: { linkId: string; name: string; fingerprint: string | null; relays: string; direct: string; origins: string; signal: string | null; info: string | null }, now: number): string | null {
    const old = this.store.computer(c.linkId);
    if (old && old.account_id !== account) {
      // the person at the computer chose another account: the old one's devices drop it
      this.store.run("DELETE FROM computers WHERE link_id = ?", c.linkId);
      this.store.revoke(old.account_id, { computers: [c.linkId] }, Math.floor(now / 1000), now);
    }
    // (back in an account it was once taken out of: that entry would make it leave again)
    this.store.run("DELETE FROM revocations WHERE account_id = ? AND kind = 'computer' AND id = ?", account, c.linkId);
    if (old && old.account_id === account) {
      this.store.run("UPDATE computers SET name = ?, fingerprint = ?, relays = ?, direct = ?, origins = ?, signal = ?, info = ?, joined_at = ?, updated_at = ? WHERE link_id = ?", c.name, c.fingerprint, c.relays, c.direct, c.origins, c.signal, c.info, now, now, c.linkId);
    } else {
      this.store.run("INSERT INTO computers (link_id, account_id, name, fingerprint, relays, direct, origins, signal, info, joined_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)", c.linkId, account, c.name, c.fingerprint, c.relays, c.direct, c.origins, c.signal, c.info, now, now);
    }
    return old && old.account_id !== account ? old.account_id : null;
  }

  /**
   * A computer joins with a join key (admin.ts join-key): the admin's word stands in for a device's approval, and
   * whoever runs the command on the computer for its own confirmation. The request is signed with the computer's Link
   * key (the id is its own), and a wrong key counts against the address like a wrong sign-in.
   */
  private async joinWithKey(req: IncomingMessage, ipKey: string) {
    const b = await this.readBody(req);
    this.limited(this.enrolls, ipKey, "join codes");
    const blocked = this.badTokens.blockedFor(ipKey);
    if (blocked) throw new HttpError(429, "slow_down", "too many wrong keys: wait", { "retry-after": String(blocked) });
    const linkId = String(b.linkId ?? "");
    if (!LINK_ID_RE.test(linkId)) throw new HttpError(400, "invalid_request", "linkId is the computer's Link id (64 hex)");
    const name = typeof b.name === "string" ? cleanText(b.name, 64) : "";
    if (!name) throw new HttpError(400, "invalid_request", "name");
    const f = computerFields(b);
    const key = String(b.key ?? "");
    if (!this.cfg.wire.joinKeyRe.test(key) || !verifyLinkSignature(linkId, this.cfg.wire.joinKeyProofText(this.cfg.publicUrl, linkId, key), String(b.proof ?? ""))) {
      this.badTokens.fail(ipKey);
      this.refuse("joins with a malformed key or a bad proof");
      throw new HttpError(403, "bad_proof", "a join key, and the request signed with the computer's Link key");
    }
    const now = this.now();
    const out = this.store.tx(() => {
      const account = this.store.useJoinKey(key, now);
      const a = account ? this.store.account(account) : undefined;
      if (!a) return null;
      // (thrown inside the transaction: the key's use is given back)
      if (a.disabled_at !== null) throw new HttpError(403, "account_disabled", "that account is disabled");
      const existing = this.store.computer(linkId);
      if ((!existing || existing.account_id !== a.id) && this.store.countComputers(a.id) >= this.l.computersPerAccount) {
        throw new HttpError(403, "too_many_computers", `an account has ${this.l.computersPerAccount} computers at most`);
      }
      const moved = this.admit(a.id, { linkId, name, fingerprint: f.fingerprint ?? null, relays: JSON.stringify(f.relays ?? []), direct: JSON.stringify(f.direct ?? []), origins: JSON.stringify(f.origins ?? []), signal: f.signal ?? null, info: f.info ?? null }, now);
      return { a, moved };
    });
    if (!out) {
      this.badTokens.fail(ipKey);
      this.refuse("joins with an unknown, used or expired key");
      throw new HttpError(403, "invalid_grant", "unknown, used or expired join key");
    }
    this.log(`[account] join ${linkId.slice(0, 8)}: with a join key, now in ${short(out.a.id)}${out.moved ? ` (left ${short(out.moved)})` : ""}`);
    if (out.moved) await this.deliverNotices();
    return { account: { id: out.a.id, name: out.a.name, iss: out.a.iss, sub: out.a.sub }, server: { url: this.cfg.publicUrl, keys: this.deps.ring.jwks() }, computer: computerBody(this.store.computer(linkId)!) };
  }

  private async decline(req: IncomingMessage) {
    const { e } = await this.deviceCodeEnrollment(req);
    this.store.run("UPDATE enrollments SET status = 'declined' WHERE id = ? AND status IN ('pending','approved')", e.id);
    this.log(`[account] join ${e.link_id.slice(0, 8)}: declined on the computer`);
    return { ok: true };
  }

  // --------------------------------------------------------------------------- what the account brings a computer

  /**
   * GET /v1/computer/services (a member computer, signed): what this server lends a computer of an account here, so
   * that being in the account is all it takes (nothing to paste) — each of `cfg.services` by its name, in order: a
   * `fixed` one as it is now (the same for every computer: a relay's origin and token, say), a `token` one as its
   * origin and a service token of this computer's own, a day long (asked again before it runs out; a computer taken
   * out of its account, or of a disabled account, gets no more). null: not lent now.
   */
  private async services(c: Computer) {
    if (this.store.revocationState(c.account_id).disabled !== null) throw new HttpError(403, "access_denied", "the account is disabled");
    const out: Record<string, Record<string, string | number> | null> = {};
    for (const s of this.cfg.services) {
      out[s.name] = s.kind === "fixed"
        ? s.value()
        : { url: s.url, ...(await signServiceToken(this.deps.ring, { issuer: this.cfg.publicUrl, account: c.account_id, linkId: c.link_id, service: this.cfg.wire.service(s.service), now: this.now() })) };
    }
    return out;
  }

  // --------------------------------------------------------------------------- a member computer's own requests

  /** `Authorization: <Ns>Link <linkId>.<unix seconds>.<signature>`, the signature over `Wire.computerProofText`. */
  private async computerRequest(req: IncomingMessage, url: URL, method: string) {
    const raw = method === "GET" ? (req.resume(), "") : await this.readRaw(req);
    const m = this.linkRe.exec(req.headers.authorization ?? "");
    const now = this.now();
    if (!m || Math.abs(Number(m[2]) - now / 1000) > 120) {
      this.refuse("computer requests without a fresh signature");
      throw new HttpError(401, "invalid_token", "sign the request with the Link key (and a current time)");
    }
    const linkId = m[1]!;
    const pathQ = `${url.pathname}${url.search}`;
    const bodyHash = createHash("sha256").update(raw, "utf8").digest("base64url");
    if (!verifyLinkSignature(linkId, this.cfg.wire.computerProofText(this.cfg.publicUrl, method, pathQ, Number(m[2]), bodyHash), m[3]!)) {
      this.refuse("computer requests with a bad signature");
      throw new HttpError(401, "invalid_token", "bad signature");
    }
    this.limited(this.computerReqs, linkId, "computer requests");
    const c = this.store.computer(linkId);
    if (method === "GET" && url.pathname === "/v1/computer/revocations") {
      // the account the computer pinned as its owner: its list, while the computer is in it or was taken out of it
      // `after` + `wait`: answered when the list is past version `after`, or after `wait` seconds (25 at most) with
      // the list as it is — how a computer learns of a revocation within seconds without anything being pushed
      const account = url.searchParams.get("account") ?? c?.account_id ?? "";
      const member = (st: { computers: { id: string }[] }) => this.store.computer(linkId)?.account_id === account || st.computers.some((x) => x.id === linkId);
      let state = this.store.revocationState(account);
      if (!account || !member(state)) throw new HttpError(404, "not_in_account");
      const after = Number(url.searchParams.get("after") ?? NaN);
      const wait = Math.min(this.l.revocationWaitS, Math.max(0, Number(url.searchParams.get("wait") ?? 0) || 0));
      if (Number.isInteger(after) && state.version <= after && wait > 0 && this.waiting < this.l.revocationWaitersMax) {
        await this.waitForRevocation(req, account, linkId, wait * 1000);
        state = this.store.revocationState(account);
        if (!member(state)) throw new HttpError(404, "not_in_account");
      }
      return { version: state.version, list: await signRevocationList(this.deps.ring, this.cfg.publicUrl, state, this.now()), keys: this.deps.ring.jwks() };
    }
    if (!c) throw new HttpError(404, "not_in_account");
    if (method === "GET" && url.pathname === "/v1/computer/services") return this.services(c);
    if (method === "POST" && url.pathname === "/v1/computer/update") {
      let b: Record<string, unknown>;
      try {
        b = raw ? (JSON.parse(raw) as Record<string, unknown>) : {};
      } catch {
        throw new HttpError(400, "invalid_request", "the body is a JSON object");
      }
      const f = computerFields(b);
      const name = b.name === undefined ? c.name : typeof b.name === "string" && cleanText(b.name, 64) ? cleanText(b.name, 64) : null;
      if (name === null) throw new HttpError(400, "invalid_request", "name");
      this.store.run(
        "UPDATE computers SET name = ?, fingerprint = ?, relays = ?, direct = ?, origins = ?, signal = ?, info = ?, updated_at = ? WHERE link_id = ?",
        name, f.fingerprint === undefined ? c.fingerprint : f.fingerprint, f.relays === undefined ? c.relays : JSON.stringify(f.relays), f.direct === undefined ? c.direct : JSON.stringify(f.direct), f.origins === undefined ? c.origins : JSON.stringify(f.origins), f.signal === undefined ? c.signal : f.signal, f.info === undefined ? c.info : f.info, now, linkId,
      );
      return { computer: computerBody(this.store.computer(linkId)!) };
    }
    if (method === "POST" && url.pathname === "/v1/computer/leave") {
      this.store.tx(() => {
        this.store.run("DELETE FROM computers WHERE link_id = ?", linkId);
        this.store.revoke(c.account_id, { computers: [linkId] }, Math.floor(now / 1000), now);
      });
      this.log(`[account] computer ${linkId.slice(0, 8)} left ${short(c.account_id)} (its own request)`);
      await this.deliverNotices();
      return { ok: true };
    }
    throw new HttpError(404, "not_found");
  }

  /** Until a revocation of `account` takes effect, `ms` pass, or the computer hangs up. */
  private waitForRevocation(req: IncomingMessage, account: string, linkId: string, ms: number): Promise<void> {
    // one wait per computer: a second one answers the first (a computer that asks again has given the first up)
    this.waitingBy.get(linkId)?.();
    return new Promise((resolve) => {
      let set = this.waiters.get(account);
      if (!set) this.waiters.set(account, (set = new Set()));
      const done = () => {
        if (!set!.delete(done)) return;
        if (this.waitingBy.get(linkId) === done) this.waitingBy.delete(linkId);
        this.waiting--;
        if (!set!.size) this.waiters.delete(account);
        clearTimeout(timer);
        req.socket.off("close", done);
        resolve();
      };
      const timer = setTimeout(done, ms);
      timer.unref();
      set.add(done);
      this.waitingBy.set(linkId, done);
      this.waiting++;
      req.socket.once("close", done);
    });
  }

  /** Every waiting computer answered now (the server is stopping). */
  releaseWaiters() {
    for (const set of [...this.waiters.values()]) for (const wake of [...set]) wake();
  }
}

/** A request's path as the logs have it: no query. */
const logPath = (url: string | undefined) => ((url ?? "").split("?")[0] ?? "").slice(0, 40);

/** A host a computer's own page may be reached at over plain http: loopback, or a private network's address (no name:
 *  a name is whatever the network it is asked on says it is). */
function homeHost(host: string): boolean {
  const h = host.replace(/^\[|\]$/g, "").toLowerCase();
  if (h === "localhost") return true;
  const kind = addressKind(h);
  return kind === "loopback" || kind === "private";
}

function expectMatches(expect: { account?: string; sub?: string }, a: Account): boolean {
  return (expect.account === undefined || expect.account === a.id) && (expect.sub === undefined || expect.sub === a.sub);
}

/** The optional fields a computer gives about itself (at enroll and update): undefined = not given. */
function computerFields(b: Record<string, unknown>): { fingerprint?: string | null; relays?: string[]; direct?: string[]; origins?: string[]; signal?: string | null; info?: string | null } {
  const out: { fingerprint?: string | null; relays?: string[]; direct?: string[]; origins?: string[]; signal?: string | null; info?: string | null } = {};
  // `info`: what the computer says of itself for its product's own clients (a JSON object; this server does not read
  // it), or null. Too big or not an object: refused
  if (b.info !== undefined) {
    if (b.info === null) out.info = null;
    else {
      const text = b.info && typeof b.info === "object" && !Array.isArray(b.info) ? JSON.stringify(b.info) : "";
      if (!text || Buffer.byteLength(text) > INFO_MAX) throw new HttpError(400, "invalid_request", `info is a JSON object of ${INFO_MAX} bytes at most`);
      out.info = text;
    }
  }
  // `signal`: the signaling service it waits for browsers' offers at — an origin (https; http only on loopback), or
  // null. What a hosted web client sends its offer to 
  if (b.signal !== undefined) {
    let u: URL | null = null;
    try {
      u = typeof b.signal === "string" && b.signal.length <= 256 ? new URL(b.signal) : null;
    } catch {
      // not a URL
    }
    // (one the server does not take — not an origin, plain http to anything but this machine — is left out, as an
    // origin of its page is: what a computer says of itself as a whole must not be refused over it)
    const local = !!u && ["localhost", "127.0.0.1", "[::1]"].includes(u.hostname);
    const ok = !!u && u.origin === String(b.signal).replace(/\/$/, "") && (u.protocol === "https:" || (u.protocol === "http:" && local));
    out.signal = ok ? u!.origin : null;
  }
  // `direct`: the `ip:port` / `[ipv6]:port` its Link entry listens on (its interfaces', a router mapping): what the
  // account's devices try before, and beside, the relays
  if (b.direct !== undefined) {
    if (!Array.isArray(b.direct) || b.direct.length > 16 || !b.direct.every((d) => typeof d === "string" && d.length <= 64 && /^(\[[0-9A-Fa-f:.%a-z]+\]|[0-9.]+):\d{1,5}$/.test(d))) throw new HttpError(400, "invalid_request", "direct is a list of at most 16 ip:port");
    out.direct = b.direct as string[];
  }
  if (b.fingerprint !== undefined) {
    if (b.fingerprint !== null && (typeof b.fingerprint !== "string" || !/^[A-Za-z0-9 :+/=_-]{8,200}$/.test(b.fingerprint))) throw new HttpError(400, "invalid_request", "fingerprint");
    out.fingerprint = b.fingerprint as string | null;
  }
  const urls = (k: "relays" | "origins", max: number) => {
    const v = b[k];
    if (v === undefined) return undefined;
    if (!Array.isArray(v) || v.length > max) throw new HttpError(400, "invalid_request", `${k} is a list of at most ${max}`);
    const kept: string[] = [];
    for (const x of v) {
      let u: URL | null = null;
      try {
        u = new URL(String(x));
      } catch {
        // not a URL
      }
      if (k === "origins") {
        // an origin this server does not take as a way back (not a URL, plain http to anything but a home address —
        // loopback, a private network —, more than an origin) is left out: what a computer says of itself as a whole
        // (its relays, its name) must not be refused over one of its addresses
        if (!u || String(x).length > 512 || u.pathname !== "/" || u.search || u.hash || u.username) continue;
        if (u.protocol !== "https:" && !(u.protocol === "http:" && homeHost(u.hostname))) continue;
        if (!kept.includes(u.origin)) kept.push(u.origin);
        continue;
      }
      if (!u) throw new HttpError(400, "invalid_request", `${k}: not a URL`);
      const local = u.hostname === "localhost" || u.hostname === "127.0.0.1";
      if (String(x).length > 512 || (u.protocol !== "https:" && !(u.protocol === "http:" && local))) throw new HttpError(400, "invalid_request", `${k}: https URLs`);
      kept.push(u.toString());
    }
    return kept;
  };
  const relays = urls("relays", 4);
  if (relays) out.relays = relays;
  const origins = urls("origins", 16);
  if (origins) out.origins = origins;
  return out;
}

function computerBody(c: Computer) {
  return { linkId: c.link_id, name: c.name, fingerprint: c.fingerprint, relays: JSON.parse(c.relays) as string[], direct: JSON.parse(c.direct) as string[], signal: c.signal ?? null, info: c.info ? (JSON.parse(c.info) as Record<string, unknown>) : null, joinedAt: c.joined_at, updatedAt: c.updated_at };
}
