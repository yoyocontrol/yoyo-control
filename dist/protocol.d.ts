import { type KeyObject } from "node:crypto";
/** The namespace every wire name is made of: lowercase letters and digits, 2-16, starting with a letter. */
export declare const NAMESPACE_RE: RegExp;
/** The library's own (a deployment that never had other names uses it). */
export declare const DEFAULT_NAMESPACE = "yoyo";
/**
 * The names on the wire, made of one namespace `ns`: `typ`s `<ns>-ticket+jwt`, `<ns>-revocations+jwt`,
 * `<ns>-service+jwt`, `<ns>-key-endorsement+jwt`; a key's endorsement in its JWK as `<ns>_endorsement`; sessions
 * `<ns>_as_…`, join keys `<ns>_jk_…`; a computer's own requests `Authorization: <Ns>Link …`; a hosted web client's
 * proof header `<ns>-proof`; a service `<ns>-<name>` (a service token's `aud`). The account server and its computers
 * (and the services) must use the same one.
 */
export declare class Wire {
    readonly ns: string;
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
    constructor(ns?: string);
    /** A service's name as a service token's `aud`. */
    service(name: string): string;
    /** What a computer signs (with its Link key) for its own requests to the account server:
     *  `Authorization: <linkScheme> <linkId>.<unix seconds>.<signature>`; `bodyHash`: base64url SHA-256 of the body ("" for none). */
    computerProofText(origin: string, method: string, pathAndQuery: string, ts: number, bodyHash: string): string;
    /** … for its confirmation of a join somebody approved (the account it agrees to, and the join it is). */
    joinProofText(origin: string, linkId: string, account: string, deviceCode: string): string;
    /** … to join with a join key (it proves the Link id is its own; the key itself goes in the body). */
    joinKeyProofText(origin: string, linkId: string, key: string): string;
    /** What a hosted web client signs with its device key for each request (`<proofHeader>: <ts>.<bodyHash>.<sig>`). */
    hostedProofText(server: string, method: string, pathQ: string, ts: number, bodyHash: string): string;
}
/** The default namespace's names. */
export declare const DEFAULT_WIRE: Wire;
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
export declare const TICKET_TTL_S = 120;
/** A service token's life at most (seconds): how long a computer taken out of its account can still use the service. */
export declare const SERVICE_TTL_S: number;
/** Clock skew a computer allows (seconds). */
export declare const SKEW_S = 30;
/** A public JWK as a verifying key (null when it is not an Ed25519 signing key). */
export declare function publicKeyOf(j: Partial<PublicJwk>): KeyObject | null;
/** What is kept of a key somebody offered: its own fields and nothing else (null: not an Ed25519 signing key). */
export declare function cleanJwk(j: unknown, wire?: Wire): PublicJwk | null;
/**
 * The keys a computer may trust after it fetched `offered` (the server's JWKS), given the ones it `pinned`: those
 * pinned, plus each offered key endorsed by a key already trusted (repeatedly: a chain). A key offered without a valid
 * endorsement from a trusted key is left out, whatever the HTTPS answer says.
 */
export declare function verifyKeyChain(pinned: PublicJwk[], offered: PublicJwk[], wire?: Wire): Promise<PublicJwk[]>;
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
export declare class TicketError extends Error {
    readonly code: "malformed" | "unknown_key" | "bad_signature" | "expired" | "wrong_issuer" | "wrong_computer" | "not_owner" | "replayed" | "revoked" | "busy";
    constructor(code: "malformed" | "unknown_key" | "bad_signature" | "expired" | "wrong_issuer" | "wrong_computer" | "not_owner" | "replayed" | "revoked" | "busy", message?: string);
}
/** The `jti`s a computer has taken, until they would have expired anyway. Bounded: when full of live ones it refuses
 *  (a flood of valid tickets is the account server's doing, and failing closed is the safe side). */
export declare class ReplayCache {
    private readonly max;
    private seen;
    constructor(max?: number);
    /** True when `jti` is new (and now remembered until `expSec`). */
    take(jti: string, expSec: number, nowMs: number): boolean | "full";
}
/** The `kid` a token names (null: not a JWS header). What a computer looks at to decide whether to fetch new keys. */
export declare function kidOf(jwt: string): string | null;
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
export declare function verifyServiceToken(jwt: string, o: {
    issuer: string;
    keys: PublicJwk[];
    service: string;
    now?: number;
    wire?: Wire;
}): Promise<ServiceClaims>;
/**
 * A service's side of service tokens: the account server's keys, kept, and a token checked against them. The keys are
 * the server's own list (`keysUrl`: its /.well-known/jwks.json — on the machine's own loopback when both run there),
 * read at the first token, when a token names a key not held (a rotation) and once an hour — and never more than once
 * in 30 s, whatever comes and whether or not the server answers: strangers' tokens cannot make a service ask in a spin,
 * nor fill its log (one line when what it says of the keys changes). The keys held go on counting while the account
 * server is away. A computer taken out of its account simply gets no next token: what it holds runs out within the day.
 */
export declare class ServiceKeys {
    private readonly o;
    private keys;
    private askedAt;
    private gotAt;
    private asking;
    private said;
    private readonly fetchFn;
    private readonly now;
    private readonly log;
    /** `name`: what its log lines begin with ("[push-relay]"); `service`: the whole `aud` (`wire.service("push")`). */
    constructor(o: {
        issuer: string;
        keysUrl: string;
        service: string;
        name: string;
        wire?: Wire;
        fetch?: typeof fetch;
        now?: () => number;
        log?: (line: string) => void;
    });
    /** What the token says, or null when it is not one this service takes. */
    claims(token: string): Promise<ServiceClaims | null>;
    private refresh;
}
/** A service's settings for it, checked: the account server's origin as that server writes it (what its tokens name as
 *  `iss` is compared whole; https, or a loopback address for a local run) and where its keys are read (https, or
 *  loopback). Throws with what is wrong. */
export declare function serviceIssuer(issuerRaw: string, keysUrlRaw?: string): {
    issuer: string;
    keysUrl: string;
};
/** What a computer knows of revocations: the newest list it has. */
export interface Revoked {
    /** True when anything of `devId` issued at `iatSec` is void. */
    isRevoked(devId: string, iatSec: number): boolean;
}
/** The ticket check. Returns the claims, or throws a TicketError. */
export declare function verifyTicket(jwt: string, o: {
    issuer: string;
    keys: PublicJwk[];
    owner: string;
    linkId: string;
    replay: ReplayCache;
    revoked?: Revoked;
    now?: number;
    wire?: Wire;
}): Promise<TicketClaims>;
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
/** The list check: signed by a pinned key, this server, this owner, and no older than what it has. */
export declare function verifyRevocationList(jwt: string, o: {
    issuer: string;
    keys: PublicJwk[];
    owner: string;
    minVersion: number;
    now?: number;
    wire?: Wire;
}): Promise<RevocationState>;
/** A computer's view of the list it holds: what `verifyTicket` and its own tokens' checks ask. */
export declare class RevocationView implements Revoked {
    state: RevocationState;
    constructor(state: RevocationState);
    isRevoked(devId: string, iatSec: number): boolean;
}
