// @yoyocontrol/account's protocol (docs/ACCOUNT-LIB.md): what a computer checks of the account server's word —
// tickets, the signed revocation list, the chain of endorsements a new signing key comes with — and what a service
// checks of the tokens the account server gives its computers. The account server (@yoyocontrol/account-server) signs
// with this same file's names, so the two never disagree.
//
// All are compact JWS with EdDSA; each has its own `typ` and each check insists on it, so one is never passed off as
// another.
//
// A ticket says: device `dev` of account `sub` may come into computer `aud` (its Link id), for 120 s, once (`jti`).
// A computer takes it only when the signature is by a key it pinned, `iss` is the server it joined, `aud` is itself,
// `sub` is the owner it pinned, the `jti` is new, and the device is not on its revocation list.
//
// A service token says: computer `cmp` (its Link id) of account `sub` may use service `aud` until `exp` — what the
// account server gives its member computers for the services run beside it, so that being in the account is all a
// computer needs. The service checks it (ServiceKeys below); a computer only carries it.
//
// Every name on the wire (the `typ`s, what is signed, token prefixes, headers) comes from a namespace (`Wire`): one
// deployment's tickets are never another's, and a deployment that started with other names keeps them.
import { createHash, createPublicKey, type KeyObject } from "node:crypto";
import { compactVerify, decodeProtectedHeader, importJWK, jwtVerify, type JWK, type JWTPayload } from "jose";

const sha256 = (s: string) => createHash("sha256").update(s, "utf8").digest("base64url");
/** The namespace every wire name is made of: lowercase letters and digits, 2-16, starting with a letter. */
export const NAMESPACE_RE = /^[a-z][a-z0-9]{1,15}$/;
/** The library's own (a deployment that never had other names uses it). */
export const DEFAULT_NAMESPACE = "yoyo";

/**
 * The names on the wire, made of one namespace `ns`: `typ`s `<ns>-ticket+jwt`, `<ns>-revocations+jwt`,
 * `<ns>-service+jwt`, `<ns>-key-endorsement+jwt`; a key's endorsement in its JWK as `<ns>_endorsement`; sessions
 * `<ns>_as_…`, join keys `<ns>_jk_…`; a computer's own requests `Authorization: <Ns>Link …`; a hosted web client's
 * proof header `<ns>-proof`; a service `<ns>-<name>` (a service token's `aud`). The account server and its computers
 * (and the services) must use the same one.
 */
export class Wire {
  readonly ticketTyp: string;
  readonly revocationsTyp: string;
  readonly serviceTyp: string;
  readonly endorsementTyp: string;
  readonly endorsementField: `${string}_endorsement`;
  readonly sessionPrefix: string;
  readonly joinKeyPrefix: string;
  /** The scheme of a computer's signed requests: `Authorization: <scheme> <linkId>.<unix seconds>.<signature>`. */
  readonly linkScheme: string;
  /** The hosted web client's per-request proof: its header (lowercase) and what it signs. */
  readonly proofHeader: string;
  readonly hostedProof: string;
  readonly joinKeyRe: RegExp;
  constructor(readonly ns: string = DEFAULT_NAMESPACE) {
    if (!NAMESPACE_RE.test(ns)) throw new Error(`a wire namespace is 2-16 of [a-z0-9], starting with a letter: ${JSON.stringify(ns)}`);
    this.ticketTyp = `${ns}-ticket+jwt`;
    this.revocationsTyp = `${ns}-revocations+jwt`;
    this.serviceTyp = `${ns}-service+jwt`;
    this.endorsementTyp = `${ns}-key-endorsement+jwt`;
    this.endorsementField = `${ns}_endorsement`;
    this.sessionPrefix = `${ns}_as_`;
    this.joinKeyPrefix = `${ns}_jk_`;
    this.linkScheme = `${ns[0]!.toUpperCase()}${ns.slice(1)}Link`;
    this.proofHeader = `${ns}-proof`;
    this.hostedProof = `${ns}-hosted-v1`;
    this.joinKeyRe = new RegExp(`^${ns}_jk_[A-Za-z0-9_-]{43}$`);
  }
  /** A service's name as a service token's `aud`. */
  service(name: string): string {
    return `${this.ns}-${name}`;
  }
  /** What a computer signs (with its Link key) for its own requests to the account server:
   *  `Authorization: <linkScheme> <linkId>.<unix seconds>.<signature>`; `bodyHash`: base64url SHA-256 of the body ("" for none). */
  computerProofText(origin: string, method: string, pathAndQuery: string, ts: number, bodyHash: string): string {
    return `${this.ns}-account-computer-v1\n${origin}\n${method} ${pathAndQuery}\n${ts}\n${bodyHash}`;
  }
  /** … for its confirmation of a join somebody approved (the account it agrees to, and the join it is). */
  joinProofText(origin: string, linkId: string, account: string, deviceCode: string): string {
    return `${this.ns}-account-join-v1\n${origin}\n${linkId}\n${account}\n${sha256(deviceCode)}`;
  }
  /** … to join with a join key (it proves the Link id is its own; the key itself goes in the body). */
  joinKeyProofText(origin: string, linkId: string, key: string): string {
    return `${this.ns}-account-joinkey-v1\n${origin}\n${linkId}\n${sha256(key)}`;
  }
  /** What a hosted web client signs with its device key for each request (`<proofHeader>: <ts>.<bodyHash>.<sig>`). */
  hostedProofText(server: string, method: string, pathQ: string, ts: number, bodyHash: string): string {
    return `${this.hostedProof}\n${server}\n${method}\n${pathQ}\n${ts}\n${bodyHash}`;
  }
}

/** The default namespace's names. */
export const DEFAULT_WIRE = new Wire();

export interface PublicJwk {
  kty: "OKP";
  crv: "Ed25519";
  x: string;
  kid: string;
  alg: "EdDSA";
  use: "sig";
  /** A key after the first: a compact JWS by the key before it (typ `<ns>-key-endorsement+jwt`) over `{ kid, x, iat }`,
   *  under the namespace's field name (`Wire.endorsementField`). */
  [endorsement: `${string}_endorsement`]: string | undefined;
}

/** A ticket's life at most (seconds). */
export const TICKET_TTL_S = 120;
/** A service token's life at most (seconds): how long a computer taken out of its account can still use the service. */
export const SERVICE_TTL_S = 24 * 3600;
/** Clock skew a computer allows (seconds). */
export const SKEW_S = 30;

/** A public JWK as a verifying key (null when it is not an Ed25519 signing key). */
export function publicKeyOf(j: Partial<PublicJwk>): KeyObject | null {
  if (j.kty !== "OKP" || j.crv !== "Ed25519" || typeof j.x !== "string" || typeof j.kid !== "string") return null;
  try {
    return createPublicKey({ key: { kty: "OKP", crv: "Ed25519", x: j.x }, format: "jwk" });
  } catch {
    return null;
  }
}

/** What is kept of a key somebody offered: its own fields and nothing else (null: not an Ed25519 signing key). */
export function cleanJwk(j: unknown, wire: Wire = DEFAULT_WIRE): PublicJwk | null {
  const k = j as Partial<PublicJwk> | null;
  if (!k || typeof k !== "object" || !publicKeyOf(k) || k.kid!.length > 64) return null;
  const e = k[wire.endorsementField];
  return { kty: "OKP", crv: "Ed25519", x: k.x!, kid: k.kid!, alg: "EdDSA", use: "sig", ...(typeof e === "string" && e.length <= 1024 ? { [wire.endorsementField]: e } : {}) };
}

/**
 * The keys a computer may trust after it fetched `offered` (the server's JWKS), given the ones it `pinned`: those
 * pinned, plus each offered key endorsed by a key already trusted (repeatedly: a chain). A key offered without a valid
 * endorsement from a trusted key is left out, whatever the HTTPS answer says.
 */
export async function verifyKeyChain(pinned: PublicJwk[], offered: PublicJwk[], wire: Wire = DEFAULT_WIRE): Promise<PublicJwk[]> {
  const ENDORSEMENT_TYP = wire.endorsementTyp;
  const trusted = new Map(pinned.filter((k) => publicKeyOf(k)).map((k) => [k.kid, k]));
  let grew = true;
  while (grew) {
    grew = false;
    for (const k of offered) {
      const endorsement = k[wire.endorsementField];
      if (trusted.has(k.kid) || !endorsement || !publicKeyOf(k)) continue;
      try {
        const { payload, protectedHeader } = await compactVerify(endorsement, async (h) => {
          const signer = h.kid ? trusted.get(h.kid) : undefined;
          if (!signer || h.alg !== "EdDSA" || h.typ !== ENDORSEMENT_TYP) throw new Error("not endorsed by a trusted key");
          return importJWK({ kty: signer.kty, crv: signer.crv, x: signer.x } as JWK, "EdDSA");
        });
        const p = JSON.parse(new TextDecoder().decode(payload)) as { kid?: unknown; x?: unknown };
        if (protectedHeader.typ === ENDORSEMENT_TYP && p.kid === k.kid && p.x === k.x) {
          trusted.set(k.kid, k);
          grew = true;
        }
      } catch {
        /* not endorsed */
      }
    }
  }
  return [...trusted.values()];
}

export interface TicketDevice {
  id: string;
  name: string;
  /** base64url SHA-256 of the device's public key, when it registered one. */
  key?: string;
}

export interface TicketClaims {
  iss: string;
  sub: string;
  aud: string;
  iat: number;
  exp: number;
  jti: string;
  dev: TicketDevice;
  /** The account's shown name, for the computer's own lists. */
  name?: string;
  /** Unix seconds: when the device's session at the account server ends. What a computer hands out for this ticket
   *  ends then at the latest, so a device's way into a computer never outlives its sign-in. */
  sx?: number;
}

export class TicketError extends Error {
  constructor(readonly code: "malformed" | "unknown_key" | "bad_signature" | "expired" | "wrong_issuer" | "wrong_computer" | "not_owner" | "replayed" | "revoked" | "busy", message?: string) {
    super(message ?? code);
  }
}

/** The `jti`s a computer has taken, until they would have expired anyway. Bounded: when full of live ones it refuses
 *  (a flood of valid tickets is the account server's doing, and failing closed is the safe side). */
export class ReplayCache {
  private seen = new Map<string, number>();
  constructor(private readonly max = 20_000) {}
  /** True when `jti` is new (and now remembered until `expSec`). */
  take(jti: string, expSec: number, nowMs: number): boolean | "full" {
    if (this.seen.has(jti)) return false;
    if (this.seen.size >= this.max) {
      for (const [k, e] of this.seen) if (e * 1000 + SKEW_S * 1000 < nowMs) this.seen.delete(k);
      if (this.seen.size >= this.max) return "full";
    }
    this.seen.set(jti, expSec);
    return true;
  }
}

/** A pinned key set as a jose key resolver: only these kids, only EdDSA. */
function resolver(keys: PublicJwk[]) {
  return async (h: { kid?: string; alg?: string }) => {
    const k = h.kid ? keys.find((x) => x.kid === h.kid) : undefined;
    if (!k || h.alg !== "EdDSA") throw new TicketError("unknown_key");
    return importJWK({ kty: k.kty, crv: k.crv, x: k.x } as JWK, "EdDSA");
  };
}

async function verifyTyped(jwt: string, typ: string, keys: PublicJwk[], issuer: string, nowMs: number, extra: { audience?: string } = {}): Promise<JWTPayload & Record<string, unknown>> {
  let header: ReturnType<typeof decodeProtectedHeader>;
  try {
    header = decodeProtectedHeader(jwt);
  } catch {
    throw new TicketError("malformed");
  }
  if (header.typ !== typ) throw new TicketError("malformed", `typ is not ${typ}`);
  if (!header.kid || !keys.some((k) => k.kid === header.kid)) throw new TicketError("unknown_key");
  try {
    const { payload } = await jwtVerify(jwt, resolver(keys), {
      algorithms: ["EdDSA"],
      typ,
      currentDate: new Date(nowMs),
      clockTolerance: SKEW_S,
      requiredClaims: ["iss", "sub", "iat"],
    });
    if (payload.iss !== issuer) throw new TicketError("wrong_issuer");
    if (extra.audience !== undefined && payload.aud !== extra.audience) throw new TicketError("wrong_computer");
    return payload as JWTPayload & Record<string, unknown>;
  } catch (e) {
    if (e instanceof TicketError) throw e;
    const code = (e as { code?: string }).code;
    if (code === "ERR_JWT_EXPIRED") throw new TicketError("expired");
    if (code === "ERR_JWS_SIGNATURE_VERIFICATION_FAILED") throw new TicketError("bad_signature");
    throw new TicketError("malformed", (e as Error).message);
  }
}

/** The `kid` a token names (null: not a JWS header). What a computer looks at to decide whether to fetch new keys. */
export function kidOf(jwt: string): string | null {
  try {
    const kid = decodeProtectedHeader(jwt).kid;
    return typeof kid === "string" ? kid : null;
  } catch {
    return null;
  }
}

/** What a service token says. */
export interface ServiceClaims {
  /** The account (`sub`). */
  account: string;
  /** The computer's Link id (`cmp`). */
  computer: string;
  /** Unix seconds. */
  exp: number;
}

/** The service's check of a token a computer brought: signed by one of the account server's keys, by that server, for
 *  this service, not run out (nor made to last longer than a service token does). Throws a TicketError. */
export async function verifyServiceToken(jwt: string, o: { issuer: string; keys: PublicJwk[]; service: string; now?: number; wire?: Wire }): Promise<ServiceClaims> {
  const now = o.now ?? Date.now();
  const p = await verifyTyped(jwt, (o.wire ?? DEFAULT_WIRE).serviceTyp, o.keys, o.issuer, now, { audience: o.service });
  if (typeof p.exp !== "number" || typeof p.iat !== "number" || typeof p.sub !== "string" || !p.sub || typeof p.cmp !== "string" || !/^[0-9a-f]{64}$/.test(p.cmp)) throw new TicketError("malformed");
  if (p.exp - p.iat > SERVICE_TTL_S) throw new TicketError("malformed", "a service token lives a day at most");
  if (p.iat * 1000 > now + SKEW_S * 1000) throw new TicketError("malformed", "issued in the future");
  return { account: p.sub, computer: p.cmp, exp: p.exp };
}

/**
 * A service's side of service tokens: the account server's keys, kept, and a token checked against them. The keys are
 * the server's own list (`keysUrl`: its /.well-known/jwks.json — on the machine's own loopback when both run there),
 * read at the first token, when a token names a key not held (a rotation) and once an hour — and never more than once
 * in 30 s, whatever comes and whether or not the server answers: strangers' tokens cannot make a service ask in a spin,
 * nor fill its log (one line when what it says of the keys changes). The keys held go on counting while the account
 * server is away. A computer taken out of its account simply gets no next token: what it holds runs out within the day.
 */
export class ServiceKeys {
  private keys: PublicJwk[] = [];
  private askedAt = -Infinity;
  private gotAt = -Infinity;
  private asking: Promise<void> | null = null;
  private said = "";
  private readonly fetchFn: typeof fetch;
  private readonly now: () => number;
  private readonly log: (line: string) => void;

  /** `name`: what its log lines begin with ("[push-relay]"); `service`: the whole `aud` (`wire.service("push")`). */
  constructor(private readonly o: { issuer: string; keysUrl: string; service: string; name: string; wire?: Wire; fetch?: typeof fetch; now?: () => number; log?: (line: string) => void }) {
    this.fetchFn = o.fetch ?? fetch;
    this.now = o.now ?? Date.now;
    this.log = o.log ?? ((l) => console.warn(l));
  }

  /** What the token says, or null when it is not one this service takes. */
  async claims(token: string): Promise<ServiceClaims | null> {
    const kid = kidOf(token);
    if (!kid) return null;
    const now = this.now();
    const unknown = !this.keys.some((k) => k.kid === kid);
    if ((unknown || now - this.gotAt >= 3600_000) && now - this.askedAt >= 30_000) await this.refresh();
    // (the keys are being read for somebody else's token right now — the first ones after a start: this one waits for
    // them too, instead of being checked against none)
    else if (unknown && this.asking) await this.asking;
    try {
      return await verifyServiceToken(token, { issuer: this.o.issuer, keys: this.keys, service: this.o.service, now: this.now(), ...(this.o.wire ? { wire: this.o.wire } : {}) });
    } catch {
      return null;
    }
  }

  private refresh(): Promise<void> {
    this.asking ??= (async () => {
      this.askedAt = this.now();
      try {
        const res = await this.fetchFn(this.o.keysUrl, { redirect: "error", signal: AbortSignal.timeout(5_000) });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        // (a key list: a few KB; no more than a handful of keys are ever held)
        const text = await res.text();
        if (text.length > 65_536) throw new Error("the answer is too long");
        const b = JSON.parse(text) as { keys?: unknown };
        const keys = (Array.isArray(b.keys) ? b.keys.slice(0, 32) : []).map((k) => cleanJwk(k, this.o.wire)).filter((k): k is PublicJwk => !!k);
        if (!keys.length) throw new Error("no keys in the answer");
        if (this.said !== "ok" || keys.map((k) => k.kid).join() !== this.keys.map((k) => k.kid).join()) this.log(`${this.o.name} the account server's keys: ${keys.length}`);
        this.said = "ok";
        this.keys = keys;
        this.gotAt = this.now();
      } catch (err) {
        // (said once, not at every ask that fails the same way)
        const line = `${this.o.name} cannot read the account server's keys (${(err as Error).message.slice(0, 120)}): ${this.keys.length ? "keeping the ones held" : "its computers are refused until it answers"}`;
        if (this.said !== line) this.log(line);
        this.said = line;
      } finally {
        this.asking = null;
      }
    })();
    return this.asking;
  }
}

/** A service's settings for it, checked: the account server's origin as that server writes it (what its tokens name as
 *  `iss` is compared whole; https, or a loopback address for a local run) and where its keys are read (https, or
 *  loopback). Throws with what is wrong. */
export function serviceIssuer(issuerRaw: string, keysUrlRaw?: string): { issuer: string; keysUrl: string } {
  const local = (u: URL) => u.hostname === "localhost" || u.hostname === "127.0.0.1" || u.hostname === "[::1]";
  const u = new URL(issuerRaw.trim());
  const k = new URL(keysUrlRaw?.trim() || `${u.origin}/.well-known/jwks.json`);
  if ((u.protocol !== "https:" && !local(u)) || u.pathname !== "/" || u.search || u.hash) throw new Error("ACCOUNT_ISSUER is the account server's origin: https://host[:port]");
  if (k.protocol !== "https:" && !local(k)) throw new Error("ACCOUNT_KEYS_URL is https, or an address on loopback");
  return { issuer: u.origin, keysUrl: k.toString() };
}

/** What a computer knows of revocations: the newest list it has. */
export interface Revoked {
  /** True when anything of `devId` issued at `iatSec` is void. */
  isRevoked(devId: string, iatSec: number): boolean;
}

/** The ticket check. Returns the claims, or throws a TicketError. */
export async function verifyTicket(
  jwt: string,
  o: { issuer: string; keys: PublicJwk[]; owner: string; linkId: string; replay: ReplayCache; revoked?: Revoked; now?: number; wire?: Wire },
): Promise<TicketClaims> {
  const now = o.now ?? Date.now();
  const p = await verifyTyped(jwt, (o.wire ?? DEFAULT_WIRE).ticketTyp, o.keys, o.issuer, now, { audience: o.linkId });
  const dev = p.dev as Partial<TicketDevice> | undefined;
  if (typeof p.exp !== "number" || typeof p.iat !== "number" || typeof p.jti !== "string" || !p.jti || typeof dev?.id !== "string" || !dev.id || typeof dev.name !== "string") {
    throw new TicketError("malformed");
  }
  if (p.exp - p.iat > TICKET_TTL_S) throw new TicketError("malformed", "a ticket lives 120 s at most");
  if (p.iat * 1000 > now + SKEW_S * 1000) throw new TicketError("malformed", "issued in the future");
  if (p.sx !== undefined && (!Number.isInteger(p.sx) || (p.sx as number) * 1000 <= now)) throw new TicketError(Number.isInteger(p.sx) ? "expired" : "malformed");
  if (p.sub !== o.owner) throw new TicketError("not_owner");
  if (o.revoked?.isRevoked(dev.id, p.iat)) throw new TicketError("revoked");
  const fresh = o.replay.take(p.jti, p.exp, now);
  if (fresh === "full") throw new TicketError("busy");
  if (!fresh) throw new TicketError("replayed");
  return p as unknown as TicketClaims;
}

// ----------------------------------------------------------------------------- revocation

export interface RevocationEntry {
  /** A device id, or a computer's Link id (in `computers`). */
  id: string;
  /** Seconds: anything of it issued at or before this is void. */
  at: number;
}

/** An account's revocations: the whole list, which a computer pulls (and waits on) over HTTPS; `version` only grows. */
export interface RevocationState {
  account: string;
  version: number;
  devices: RevocationEntry[];
  /** Computers taken out of the account (the computer whose id is here leaves the account). */
  computers: RevocationEntry[];
  /** Seconds: the account was disabled or removed then (nothing of it is taken while this is set). */
  disabled: number | null;
}

const entries = (v: unknown): RevocationEntry[] | null =>
  Array.isArray(v) && v.length <= 10_000 && v.every((e) => e && typeof e.id === "string" && e.id.length <= 128 && Number.isInteger(e.at)) ? (v as RevocationEntry[]).map((e) => ({ id: e.id, at: e.at })) : null;

/** The list check: signed by a pinned key, this server, this owner, and no older than what it has. */
export async function verifyRevocationList(jwt: string, o: { issuer: string; keys: PublicJwk[]; owner: string; minVersion: number; now?: number; wire?: Wire }): Promise<RevocationState> {
  const p = await verifyTyped(jwt, (o.wire ?? DEFAULT_WIRE).revocationsTyp, o.keys, o.issuer, o.now ?? Date.now());
  if (p.sub !== o.owner) throw new TicketError("not_owner");
  const devices = entries(p.devices);
  const computers = entries(p.computers);
  if (!Number.isInteger(p.ver) || !devices || !computers || (p.disabled !== null && !Number.isInteger(p.disabled))) throw new TicketError("malformed");
  if ((p.ver as number) < o.minVersion) throw new TicketError("replayed", "an older list than the one held");
  return { account: p.sub, version: p.ver as number, devices, computers, disabled: p.disabled as number | null };
}

/** A computer's view of the list it holds: what `verifyTicket` and its own tokens' checks ask. */
export class RevocationView implements Revoked {
  constructor(public state: RevocationState) {}
  isRevoked(devId: string, iatSec: number): boolean {
    if (this.state.disabled !== null) return true;
    return this.state.devices.some((d) => d.id === devId && iatSec <= d.at);
  }
}
