/**
 * A browser's side of an account server (`@yoyocontrol/account-server`, docs/ACCOUNT-LIB.md): sign in with the
 * account, then its computers and a ticket into each — what an app does, from a web page.
 *
 * - Sign-in: code + PKCE through `/v1/signin` (the password is typed on the sign-in system's page only, never here),
 *   back to the page's registered address (the server's `ACCOUNT_WEB_REDIRECTS`), then `POST /v1/token` with this
 *   browser's device key.
 * - The device key is Ed25519, made in this browser and **not extractable** (WebCrypto): kept as a `CryptoKey` in
 *   IndexedDB, it can sign but nothing can read it out. The session's token is bound to it: every request carries
 *   `<ns>-proof` (`hostedProofText`, over the body too), so a token copied out of the page (a log, a proxy) is worth
 *   nothing anywhere else. It does not stand against a hostile script on the page itself: that is the trust in where
 *   the page's scripts come from. The same key signs in again as the same device.
 * - Sign-in by QR code (`beginQrSignIn`): this browser shows a code another device of the account (signed in already:
 *   the app, a web page) scans and approves; the session it then gets is bound to this browser's key all the same. A
 *   signed-in page approves others' codes too (`lookupSignIn` / `approveSignIn`).
 * - Tickets are for one computer, two minutes, once: the computer trades one for a token of its own (a Link `hello`'s
 *   `Ticket <ticket>`), bound to this browser.
 *
 * Requests go through `fetch` (injectable). No service address is built in: the page names its account server.
 */

/** The names on the wire (the account server's `ACCOUNT_NAMESPACE`; default `yoyo`). */
export class WebWire {
  readonly proofHeader: string;
  readonly hostedProof: string;
  constructor(readonly namespace = "yoyo") {
    if (!/^[a-z][a-z0-9]{1,15}$/.test(namespace)) throw new Error(`account-web: a namespace is 2–16 of a–z 0–9, starting with a letter: ${namespace}`);
    this.proofHeader = `${namespace}-proof`;
    this.hostedProof = `${namespace}-hosted-v1`;
  }

  /** What the page signs for each request (the account server's `Wire.hostedProofText`). */
  hostedProofText(server: string, method: string, pathQ: string, ts: number, bodyHash: string): string {
    return `${this.hostedProof}\n${server}\n${method}\n${pathQ}\n${ts}\n${bodyHash}`;
  }
}

/** A computer of the account, as the list gives it (`GET /v1/computers`). */
export interface AccountComputer {
  linkId: string;
  name: string;
  /** Its Link entry's WebRTC identity (`sha256:<hex>`) when it says one; null = none. */
  fingerprint: string | null;
  /** Its relays. */
  relays: string[];
  /** Where its Link entry listens (`ip:port`). */
  direct: string[];
  /** The signaling service it says it waits for browsers' offers at (an origin), or null. */
  signal: string | null;
  /** What the product's computers say of themselves (the server doesn't read it): e.g. a server id, the platform,
   *  an identity fingerprint. null: nothing. */
  info: Record<string, unknown> | null;
  joinedAt: number;
  updatedAt: number;
}

/** This browser's sign-in, as kept (IndexedDB in a browser: the private key is a non-extractable CryptoKey). */
export interface SavedSignIn {
  server: string;
  session: string;
  expiresAt: number;
  account: { id: string; name: string };
  device: { id: string; name: string };
  key: CryptoKeyPair;
}

/** Where the sign-in is kept between visits (`idbKeep` in a browser; memory in tests). */
export interface Keep {
  get(): Promise<SavedSignIn | null>;
  set(v: SavedSignIn | null): Promise<void>;
  /** The device key kept across sign-ins (the same key signs in as the same device). */
  getKey(): Promise<CryptoKeyPair | null>;
  setKey(k: CryptoKeyPair | null): Promise<void>;
}

/** A sign-in on its way through the sign-in system (`pendingKeep`: sessionStorage, this tab only). */
export interface PendingSignIn {
  server: string;
  returnUrl: string;
  state: string;
  verifier: string;
  at: number;
}

export type Fetch = (url: string, init?: RequestInit) => Promise<Response>;

/** What every call may take: the wire's namespace, `fetch`, the clock (ms). */
export interface ClientOptions {
  namespace?: string;
  fetch?: Fetch;
  clock?: () => number;
}

const b64url = (b: ArrayBuffer | Uint8Array): string => {
  const bytes = b instanceof Uint8Array ? b : new Uint8Array(b);
  let s = "";
  for (const x of bytes) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};
const randomB64 = (n: number) => b64url(crypto.getRandomValues(new Uint8Array(n)));
const defaultFetch: Fetch = (u, i) => fetch(u, i);

/** The account server's origin, as it names itself (what the proofs carry): https, or http on loopback (tests). */
export function serverOrigin(raw: string): string {
  const u = new URL(raw);
  if (u.protocol !== "https:" && !(u.protocol === "http:" && (u.hostname === "127.0.0.1" || u.hostname === "localhost"))) throw new Error("the account server is an https address");
  return u.origin;
}

const CODE_ALPHABET = "BCDFGHJKLMNPQRSTVWXZ";

/** Sign-ins older than this are not finished (the server's own state lasts 10 minutes). */
const PENDING_MAX_MS = 10 * 60_000;

/**
 * Starts a sign-in: where to send the browser (the account server's `/v1/signin`), and what to keep until it comes
 * back (`finishSignIn`). `returnUrl`: the page's registered address (`ACCOUNT_WEB_REDIRECTS`), exactly.
 */
export async function beginSignIn(server: string, returnUrl: string, now = Date.now()): Promise<{ url: string; pending: PendingSignIn }> {
  const origin = serverOrigin(server);
  const verifier = randomB64(32);
  const challenge = b64url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)));
  const state = randomB64(24);
  const q = new URLSearchParams({ redirect_uri: returnUrl, code_challenge: challenge, code_challenge_method: "S256", state });
  return { url: `${origin}/v1/signin?${q}`, pending: { server: origin, returnUrl, state, verifier, at: now } };
}

/** Why a sign-in did not finish (`code`: the account server's error, or `state` / `expired` / `no_code` / `unbound`). */
export class SignInError extends Error {
  constructor(readonly code: string, message: string) {
    super(message);
    this.name = "SignInError";
  }
}

/** The page's address carries a sign-in's answer (`code` or `error`, with `state`): `finishSignIn` it. */
export function isSignInReturn(url: string): boolean {
  const p = new URL(url).searchParams;
  return p.has("state") && (p.has("code") || p.has("error"));
}

/**
 * The browser came back to `returnedUrl` with a code: trade it for this browser's session, bound to its device key
 * (the kept one, else a new one). Only for the sign-in this tab started (`pending`, its `state`).
 */
export async function finishSignIn(returnedUrl: string, pending: PendingSignIn | null, o: ClientOptions & { keep: Keep; deviceName: string; now?: number }): Promise<AccountClient> {
  const wire = new WebWire(o.namespace);
  const back = new URL(returnedUrl);
  const p = back.searchParams;
  if (!pending || p.get("state") !== pending.state) throw new SignInError("state", "this sign-in was not started here: start again");
  if ((o.now ?? Date.now()) - pending.at > PENDING_MAX_MS) throw new SignInError("expired", "the sign-in took too long: start again");
  const ret = new URL(pending.returnUrl);
  if (back.origin + back.pathname !== ret.origin + ret.pathname) throw new SignInError("state", "not this page's sign-in");
  const err = p.get("error");
  if (err) throw new SignInError(err, `the account server said ${err}`);
  const code = p.get("code");
  if (!code) throw new SignInError("no_code", "no code came back");
  const f = o.fetch ?? defaultFetch;
  const key = (await o.keep.getKey()) ?? ((await crypto.subtle.generateKey({ name: "Ed25519" }, false, ["sign", "verify"])) as CryptoKeyPair);
  const raw = b64url(await crypto.subtle.exportKey("raw", key.publicKey));
  const res = await f(`${pending.server}/v1/token`, {
    method: "POST",
    credentials: "omit",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ grant_type: "authorization_code", code, code_verifier: pending.verifier, redirect_uri: pending.returnUrl, device: { name: o.deviceName, platform: "web", key: raw } }),
  });
  const b = (await res.json().catch(() => ({}))) as { session?: string; expiresAt?: number; account?: { id: string; name: string }; device?: { id: string; name: string }; proof?: string; error?: string };
  if (!res.ok || typeof b.session !== "string" || !b.account || !b.device) throw new SignInError(b.error ?? `http_${res.status}`, `the account server refused the sign-in (${res.status})`);
  // (a server that does not bind the session to the key would take the token alone: not one this page signs in to)
  if (b.proof !== wire.hostedProof) throw new SignInError("unbound", "this account server does not bind a web page's session to its key");
  await o.keep.setKey(key);
  const saved: SavedSignIn = { server: pending.server, session: b.session, expiresAt: b.expiresAt ?? 0, account: b.account, device: b.device, key };
  await o.keep.set(saved);
  return new AccountClient(saved, o.keep, { ...o, fetch: f });
}

/** A new session from an account server's own sign-in (`path`: email and password's), bound to this browser's
 *  device key (the kept one, else a new one), kept. Refusals: `AccountError` with the server's `error`. */
async function keyBoundSession(server: string, path: string, body: Record<string, unknown>, o: ClientOptions & { keep: Keep; deviceName: string }): Promise<AccountClient> {
  const origin = serverOrigin(server);
  const wire = new WebWire(o.namespace);
  const f = o.fetch ?? defaultFetch;
  const key = (await o.keep.getKey()) ?? ((await crypto.subtle.generateKey({ name: "Ed25519" }, false, ["sign", "verify"])) as CryptoKeyPair);
  const raw = b64url(await crypto.subtle.exportKey("raw", key.publicKey));
  const res = await f(`${origin}${path}`, {
    method: "POST",
    credentials: "omit",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ ...body, device: { name: o.deviceName, platform: "web", key: raw } }),
  });
  const b = (await res.json().catch(() => ({}))) as { session?: string; expiresAt?: number; account?: { id: string; name: string }; device?: { id: string; name: string }; proof?: string; error?: string };
  if (!res.ok || typeof b.session !== "string" || !b.account || !b.device) throw new AccountError(res.status, b.error ?? `http_${res.status}`);
  if (b.proof !== wire.hostedProof) throw new SignInError("unbound", "this account server does not bind a web page's session to its key");
  await o.keep.setKey(key);
  const saved: SavedSignIn = { server: origin, session: b.session, expiresAt: b.expiresAt ?? 0, account: b.account, device: b.device, key };
  await o.keep.set(saved);
  return new AccountClient(saved, o.keep, { ...o, fetch: f });
}

/** A request of email and password's that answers no session (`{ sent: true }`). */
async function plainPost(server: string, path: string, body: Record<string, unknown>, f: Fetch = defaultFetch): Promise<void> {
  const res = await f(`${serverOrigin(server)}${path}`, { method: "POST", credentials: "omit", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
  const b = (await res.json().catch(() => ({}))) as { error?: string };
  if (!res.ok) throw new AccountError(res.status, b.error ?? `http_${res.status}`);
}

/**
 * Email and password (the account server's `ACCOUNT_PASSWORD`, docs/ACCOUNT-LIB.md「邮箱和密码」). Refusals are
 * `AccountError`s with the server's `error`: `invalid_email`, `weak_password` (8–256 characters), `invalid_code`,
 * `code_expired`, `invalid_credentials` (a wrong email or password: one answer), `already_registered`,
 * `access_denied`, `mail_failed`, `slow_down` (429).
 */
export const emailSignIn = {
  /** Mails a sign-up code (`locale`: the mail's language). The same answer for an email that has a login (its mail
   *  says so instead). */
  register(server: string, email: string, password: string, o: { locale?: string; fetch?: Fetch } = {}): Promise<void> {
    return plainPost(server, "/v1/auth/password/register", { email, password, ...(o.locale ? { locale: o.locale } : {}) }, o.fetch);
  },
  /** The mailed code: the account is made, and this browser signed in to it. */
  verify(server: string, email: string, code: string, o: ClientOptions & { keep: Keep; deviceName: string; name?: string }): Promise<AccountClient> {
    return keyBoundSession(server, "/v1/auth/password/verify", { email, code, ...(o.name ? { name: o.name } : {}) }, o);
  },
  /** Signs in with email and password. */
  signIn(server: string, email: string, password: string, o: ClientOptions & { keep: Keep; deviceName: string }): Promise<AccountClient> {
    return keyBoundSession(server, "/v1/auth/password", { email, password }, o);
  },
  /** Mails a reset code when the email has a login (the same answer when it has none). */
  reset(server: string, email: string, o: { locale?: string; fetch?: Fetch } = {}): Promise<void> {
    return plainPost(server, "/v1/auth/password/reset", { email, ...(o.locale ? { locale: o.locale } : {}) }, o.fetch);
  },
  /** The reset code and the new password: the account's other sessions end; this browser is signed in. */
  confirmReset(server: string, email: string, code: string, password: string, o: ClientOptions & { keep: Keep; deviceName: string }): Promise<AccountClient> {
    return keyBoundSession(server, "/v1/auth/password/reset/confirm", { email, code, password }, o);
  },
};

/** A sign-in by QR code on its way (`beginQrSignIn`): what to show, and the wait for another device's approval. */
export interface QrSignIn {
  /** The code (8 letters): what goes into the QR code's link (`qrSignInLink`). */
  code: string;
  /** The same, as a person reads and types it (`BCDF-GHJK`). */
  userCode: string;
  /** When it runs out (unix ms, this browser's clock): start a new one then. */
  expiresAt: number;
  /**
   * Waits for the approval (polls every few seconds): this browser signed in, kept. Throws `SignInError`
   * `access_denied` (declined), `expired_token` (ran out), `aborted` (`signal`), or an `AccountError`.
   */
  wait(o?: { signal?: AbortSignal }): Promise<AccountClient>;
}

/**
 * Starts a sign-in by QR code (the account server's `/v1/auth/qr`): this browser's device key (the kept one, else a
 * new one) is the one the session will be bound to; only this tab holds the secret it polls with. `platform`: how the
 * account's lists show this device (default `web`).
 */
export async function beginQrSignIn(server: string, o: ClientOptions & { keep: Keep; deviceName: string; platform?: string }): Promise<QrSignIn> {
  const origin = serverOrigin(server);
  const wire = new WebWire(o.namespace);
  const f = o.fetch ?? defaultFetch;
  const clock = o.clock ?? Date.now;
  const key = (await o.keep.getKey()) ?? ((await crypto.subtle.generateKey({ name: "Ed25519" }, false, ["sign", "verify"])) as CryptoKeyPair);
  const raw = b64url(await crypto.subtle.exportKey("raw", key.publicKey));
  const post = (path: string, body: unknown) => f(`${origin}${path}`, { method: "POST", credentials: "omit", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
  const res = await post("/v1/auth/qr", { device: { name: o.deviceName, platform: o.platform ?? "web", key: raw } });
  const b = (await res.json().catch(() => ({}))) as { request?: string; code?: string; user_code?: string; expires_in?: number; interval?: number; error?: string };
  if (!res.ok || typeof b.request !== "string" || typeof b.code !== "string") throw new AccountError(res.status, b.error ?? `http_${res.status}`);
  const request = b.request;
  const expiresAt = clock() + (Number(b.expires_in) || 150) * 1000;
  let interval = Math.max(1, Number(b.interval) || 2);
  return {
    code: b.code,
    userCode: typeof b.user_code === "string" ? b.user_code : `${b.code.slice(0, 4)}-${b.code.slice(4)}`,
    expiresAt,
    async wait(w = {}) {
      for (;;) {
        await new Promise<void>((resolve, reject) => {
          if (w.signal?.aborted) return reject(new SignInError("aborted", "stopped"));
          const t = setTimeout(() => {
            w.signal?.removeEventListener("abort", stop);
            resolve();
          }, interval * 1000);
          const stop = () => {
            clearTimeout(t);
            reject(new SignInError("aborted", "stopped"));
          };
          w.signal?.addEventListener("abort", stop, { once: true });
        });
        let r: Response;
        try {
          r = await post("/v1/auth/qr/poll", { request });
        } catch {
          // (offline a moment: ask again, until it runs out)
          if (clock() > expiresAt) throw new SignInError("expired_token", "the code ran out: start again");
          continue;
        }
        const j = (await r.json().catch(() => ({}))) as { error?: string; interval?: number; session?: string; expiresAt?: number; account?: { id: string; name: string }; device?: { id: string; name: string }; proof?: string };
        if (r.ok && typeof j.session === "string" && j.account && j.device) {
          if (j.proof !== wire.hostedProof) throw new SignInError("unbound", "this account server does not bind the session to this browser's key");
          await o.keep.setKey(key);
          const saved: SavedSignIn = { server: origin, session: j.session, expiresAt: j.expiresAt ?? 0, account: j.account, device: j.device, key };
          await o.keep.set(saved);
          return new AccountClient(saved, o.keep, { ...o, fetch: f });
        }
        if (j.error === "authorization_pending") continue;
        if (j.error === "slow_down") {
          interval = Math.max(interval + 1, Number(j.interval) || 0);
          continue;
        }
        if (j.error === "access_denied" || j.error === "expired_token") throw new SignInError(j.error, j.error === "access_denied" ? "declined" : "the code ran out: start again");
        if (r.status === 429) {
          interval = Math.min(interval * 2, 30);
          continue;
        }
        throw new AccountError(r.status, j.error ?? `http_${r.status}`);
      }
    },
  };
}

/**
 * The link a sign-in's QR code carries: `base` (the page that approves it, e.g. `https://example.com/app/login`) with
 * the code after `#` (a fragment: it never reaches a server's logs).
 */
export function qrSignInLink(base: string, code: string): string {
  const u = new URL(base);
  u.hash = code;
  return u.toString();
}

/**
 * A sign-in code as scanned or typed: the link (`…#BCDFGHJK`), `BCDF-GHJK`, lower case, spaces — its 8 letters, or ""
 * when it is none.
 */
export function signInCode(raw: string): string {
  const t = raw.trim();
  const hash = t.indexOf("#");
  const c = (hash >= 0 ? t.slice(hash + 1) : t).toUpperCase().replace(/[^A-Z]/g, "");
  return c.length === 8 && [...c].every((ch) => CODE_ALPHABET.includes(ch)) ? c : "";
}

/** What asks to be signed in with a code (`GET /v1/auth/qr/lookup`), for the person to check before approving. */
export interface SignInLookup {
  code: string;
  device: { name: string; platform: string };
  /** When it asked (unix ms) and from which address. */
  requestedAt: number | null;
  from: string | null;
  expiresIn: number;
  /** The account it would sign in to (this browser's). */
  account: string;
}

/** The signed-in account (null: not signed in, or the sign-in ran out). */
export async function resumeSignIn(o: ClientOptions & { keep: Keep; now?: number }): Promise<AccountClient | null> {
  const s = await o.keep.get();
  if (!s || s.expiresAt <= (o.now ?? Date.now())) return null;
  return new AccountClient(s, o.keep, o);
}

/** How far this browser's clock may be from the server's before the proof's time is set by the server's (s). */
const SKEW_S = 60;

/** A computer's join code as it was approved (`GET /v1/computers/lookup`). */
export interface JoinLookup {
  /** The code, as the server takes it (8 letters). */
  code: string;
  linkId: string;
  name: string;
  /** When the computer asked (unix ms) and from which address. */
  requestedAt: number | null;
  from: string | null;
  /** `pending`, or `approved` (by this account: only the computer's own yes is missing). */
  status: string;
  /** The computer said beforehand which account it expects; `matchesExpected` false = not this one. */
  expectsAccount: boolean;
  matchesExpected: boolean | null;
  /** The account it would join (this browser's). */
  account: string;
}

/**
 * A join code as typed or pasted: `BCDF-GHJK`, lower case, spaces, or the computer's QR text
 * (`HTTPS://ACCOUNT.EXAMPLE.COM/C/BCDFGHJK`) — the code's 8 letters, or "" when it is none.
 */
export function joinCode(raw: string): string {
  const t = raw.trim().toUpperCase();
  const m = /\/C\/([A-Z-]+)\/?$/.exec(t);
  const c = (m ? m[1]! : t).replace(/[^A-Z]/g, "");
  return c.length === 8 && [...c].every((ch) => CODE_ALPHABET.includes(ch)) ? c : "";
}

/** An answer of the account server's that was not 2xx (`code`: its `error`). `signedOut`: the session is over. */
export class AccountError extends Error {
  constructor(readonly status: number, readonly code: string) {
    super(`account server: ${status} ${code}`);
    this.name = "AccountError";
  }
  get signedOut(): boolean {
    return this.status === 401;
  }
}

/** `GET /v1/me`: the account, this device, and what the account has bought (`entitlements`, by source). */
export interface AccountMe {
  account: { id: string; name: string };
  device: { id: string; name: string } | null;
  entitlements: Record<string, unknown>;
}

export class AccountClient {
  /** The server's clock minus this browser's (s), once a refusal showed they are apart. */
  private skew = 0;
  private readonly wire: WebWire;
  private readonly f: Fetch;
  private readonly clock: () => number;

  constructor(readonly saved: SavedSignIn, private readonly keep: Keep, o: ClientOptions = {}) {
    this.wire = new WebWire(o.namespace);
    this.f = o.fetch ?? defaultFetch;
    this.clock = o.clock ?? Date.now;
  }

  get account() {
    return this.saved.account;
  }
  get device() {
    return this.saved.device;
  }
  get server() {
    return this.saved.server;
  }

  /**
   * A signed request (`Authorization` + `<ns>-proof`). A 401 with the server's clock well apart from this browser's
   * is asked once more by the server's time (a wrong clock is not a sign-out); any other 401 forgets the sign-in —
   * when it is still the one kept (another tab may have signed in anew since) — and the key stays: same device next time.
   */
  async request<T>(method: "GET" | "POST" | "PATCH" | "DELETE", pathQ: string, body?: unknown): Promise<T> {
    const text = body === undefined ? "" : JSON.stringify(body);
    // (the proof covers the body as sent: the same headers carry no other one)
    const hash = b64url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
    for (let attempt = 0; ; attempt++) {
      const ts = Math.floor(this.clock() / 1000 + this.skew);
      const sig = await crypto.subtle.sign("Ed25519", this.saved.key.privateKey, new TextEncoder().encode(this.wire.hostedProofText(this.saved.server, method, pathQ, ts, hash)));
      const res = await this.f(`${this.saved.server}${pathQ}`, {
        method,
        credentials: "omit",
        headers: { authorization: `Bearer ${this.saved.session}`, [this.wire.proofHeader]: `${ts}.${hash}.${b64url(sig)}`, ...(body === undefined ? {} : { "content-type": "application/json" }) },
        ...(body === undefined ? {} : { body: text }),
      });
      const j = (await res.json().catch(() => ({}))) as T & { error?: string };
      if (res.ok) return j;
      if (res.status === 401 && attempt === 0) {
        const server = Date.parse(res.headers.get("date") ?? "") / 1000;
        if (Number.isFinite(server) && Math.abs(server - (this.clock() / 1000 + this.skew)) > SKEW_S) {
          this.skew = server - this.clock() / 1000;
          continue;
        }
      }
      if (res.status === 401 && (await this.keep.get())?.session === this.saved.session) await this.keep.set(null);
      throw new AccountError(res.status, j.error ?? res.statusText);
    }
  }

  /** The account, this device and the account's entitlements. */
  async me(): Promise<AccountMe> {
    const b = await this.request<Partial<AccountMe>>("GET", "/v1/me");
    return {
      account: b.account ?? this.saved.account,
      device: b.device ?? null,
      entitlements: b.entitlements && typeof b.entitlements === "object" ? b.entitlements : {},
    };
  }

  async computers(): Promise<AccountComputer[]> {
    const b = await this.request<{ computers?: Partial<AccountComputer>[] }>("GET", "/v1/computers");
    const strings = (v: unknown) => (Array.isArray(v) ? v.filter((r): r is string => typeof r === "string") : []);
    return (b.computers ?? []).filter((c) => typeof c.linkId === "string").map((c) => ({
      linkId: c.linkId!,
      name: typeof c.name === "string" ? c.name : c.linkId!.slice(0, 8),
      fingerprint: typeof c.fingerprint === "string" ? c.fingerprint : null,
      relays: strings(c.relays),
      direct: strings(c.direct),
      signal: typeof c.signal === "string" ? c.signal : null,
      info: c.info && typeof c.info === "object" && !Array.isArray(c.info) ? c.info : null,
      joinedAt: Number(c.joinedAt) || 0,
      updatedAt: Number(c.updatedAt) || 0,
    }));
  }

  /** What a computer's join code stands for (`GET /v1/computers/lookup`), for the person to check before approving. */
  async lookupJoin(code: string): Promise<JoinLookup> {
    const c = joinCode(code);
    const b = await this.request<Record<string, unknown>>("GET", `/v1/computers/lookup?code=${encodeURIComponent(c)}`);
    const computer = (b.computer ?? {}) as { linkId?: unknown; name?: unknown };
    if (typeof computer.linkId !== "string") throw new AccountError(502, "unreadable");
    const account = (b.account ?? {}) as { name?: unknown; id?: unknown };
    return {
      code: c,
      linkId: computer.linkId,
      name: typeof computer.name === "string" ? computer.name : "",
      requestedAt: Number(b.requestedAt) || null,
      from: typeof b.from === "string" ? b.from : null,
      status: typeof b.status === "string" ? b.status : "pending",
      expectsAccount: b.expectsAccount === true,
      matchesExpected: typeof b.matchesExpected === "boolean" ? b.matchesExpected : null,
      account: typeof account.name === "string" && account.name ? account.name : typeof account.id === "string" ? account.id : "",
    };
  }

  /** Puts the computer of a join code into this account (`POST /v1/computers/approve`); it then asks its own person. */
  async approveJoin(code: string): Promise<void> {
    await this.request("POST", "/v1/computers/approve", { user_code: joinCode(code) });
  }

  /** What asks to be signed in with a sign-in code (scanned or typed), for the person to check before approving. */
  async lookupSignIn(code: string): Promise<SignInLookup> {
    const c = signInCode(code);
    const b = await this.request<Record<string, unknown>>("GET", `/v1/auth/qr/lookup?code=${encodeURIComponent(c)}`);
    const d = (b.device ?? {}) as { name?: unknown; platform?: unknown };
    const account = (b.account ?? {}) as { name?: unknown; id?: unknown };
    return {
      code: c,
      device: { name: typeof d.name === "string" ? d.name : "", platform: typeof d.platform === "string" ? d.platform : "web" },
      requestedAt: Number(b.requestedAt) || null,
      from: typeof b.from === "string" ? b.from : null,
      expiresIn: Number(b.expiresIn) || 0,
      account: typeof account.name === "string" && account.name ? account.name : typeof account.id === "string" ? account.id : "",
    };
  }

  /** Signs the device of a sign-in code in to this account (it gets its session at its next poll). */
  async approveSignIn(code: string): Promise<void> {
    await this.request("POST", "/v1/auth/qr/approve", { code: signInCode(code) });
  }

  /** Refuses a sign-in code. */
  async declineSignIn(code: string): Promise<void> {
    await this.request("POST", "/v1/auth/qr/decline", { code: signInCode(code) });
  }

  /** A ticket into the computer of `linkId` (for a Link `hello`'s `Ticket <ticket>`). One use, two minutes. */
  async ticket(linkId: string): Promise<string> {
    const b = await this.request<{ ticket?: string }>("POST", "/v1/tickets", { computer: linkId });
    if (typeof b.ticket !== "string") throw new AccountError(502, "no ticket");
    return b.ticket;
  }

  /** Signs out: the session ends and the account's computers stop taking this browser. The key stays. */
  async signOut(): Promise<void> {
    try {
      await this.request("POST", "/v1/signout", {});
    } finally {
      if ((await this.keep.get())?.session === this.saved.session) await this.keep.set(null);
    }
  }
}

/** The kept sign-in in IndexedDB (`name`, default `yoyo-account`): structured clone keeps the CryptoKey as it is, still
 *  not extractable. */
export function idbKeep(name = "yoyo-account"): Keep {
  const open = () =>
    new Promise<IDBDatabase>((resolve, reject) => {
      const r = indexedDB.open(name, 1);
      r.onupgradeneeded = () => r.result.createObjectStore("kv");
      r.onsuccess = () => resolve(r.result);
      r.onerror = () => reject(r.error);
    });
  const op = async <T>(mode: IDBTransactionMode, f: (s: IDBObjectStore) => IDBRequest): Promise<T> => {
    const db = await open();
    try {
      return await new Promise<T>((resolve, reject) => {
        const req = f(db.transaction("kv", mode).objectStore("kv"));
        req.onsuccess = () => resolve(req.result as T);
        req.onerror = () => reject(req.error);
      });
    } finally {
      db.close();
    }
  };
  const get = <T>(k: string) => op<T | undefined>("readonly", (s) => s.get(k)).then((v) => v ?? null);
  const put = (k: string, v: unknown) => op<unknown>("readwrite", (s) => (v === null ? s.delete(k) : s.put(v, k))).then(() => {});
  return {
    get: () => get<SavedSignIn>("signin"),
    set: (v) => put("signin", v),
    getKey: () => get<CryptoKeyPair>("key"),
    setKey: (k) => put("key", k),
  };
}

/** A sign-in on its way, kept in this tab's sessionStorage under `name` (default `yoyo-account-signin`). */
export function pendingKeep(name = "yoyo-account-signin"): { get(): PendingSignIn | null; set(p: PendingSignIn | null): void } {
  return {
    get() {
      try {
        const raw = sessionStorage.getItem(name);
        const p = raw ? (JSON.parse(raw) as PendingSignIn) : null;
        return p && typeof p.state === "string" && typeof p.verifier === "string" ? p : null;
      } catch {
        return null;
      }
    },
    set(p) {
      try {
        if (p) sessionStorage.setItem(name, JSON.stringify(p));
        else sessionStorage.removeItem(name);
      } catch {
        // storage off: the sign-in can't finish in this tab
      }
    },
  };
}
