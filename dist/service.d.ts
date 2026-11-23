import type { IncomingMessage, ServerResponse } from "node:http";
import type { AccountConfig } from "./config.js";
import type { KeyRing } from "./keys.js";
import { type Idp } from "./oidc.js";
import { type AppleKeys, type StoreTransaction } from "./apple.js";
import { type Account, type Session, type Store } from "./store.js";
export declare const SESSION_MAX_AGE_MS: number;
/** The hosted web client's device session (a page whose token a script could read: shorter than an app's). */
export declare const HOSTED_SESSION_MAX_AGE_MS: number;
/** How far a hosted web client's request proof may be from the server's clock (s). */
export declare const HOSTED_PROOF_MAX_AGE_S = 120;
/**
 * What the hosted web client signs for each request with its device key (Ed25519, kept non-extractable in the
 * browser): the token alone is worth nothing without the key — one copied out of the page, a log or a proxy is no
 * session anywhere else. `bodyHash`: SHA-256 of the body as sent (base64url; of nothing for a request without one).
 * Header `<ns>-proof: <unix seconds>.<bodyHash>.<signature, base64url>` over `Wire.hostedProofText`.
 */
export declare const SIGNIN_TTL_MS: number;
export declare const APP_CODE_TTL_MS = 60000;
export declare const JOIN_TTL_MS: number;
/** A join key an app made for a computer it is paired with: one use, this long. */
export declare const APP_JOIN_KEY_TTL_MS: number;
/** What a computer says of itself for its product's clients (`info`, a JSON object): this many bytes at most. */
export declare const INFO_MAX = 2048;
/** After an approval the computer has this long to confirm it on its own screen. */
export declare const JOIN_CONFIRM_MS: number;
export declare const POLL_INTERVAL_S = 2;
export declare const BODY_MAX: number;
/** RFC 8628's alphabet: 20 consonants (no vowels: no words; no 0/O, 1/I). 8 of them = 34.6 bits. */
export declare const CODE_ALPHABET = "BCDFGHJKLMNPQRSTVWXZ";
export declare const CODE_LEN = 8;
export declare const LIMITS: {
    /** Sign-ins started, callbacks, and code exchanges (each its own budget) per address: 20 at once, then 20 a minute
     *  (a home or a phone network behind one IPv4 address signs in several people). */
    signinBurst: number;
    signinEveryMs: number;
    /** Requests with a bad bearer token or cookie per address and minute, before 429 for the rest of it. */
    badTokensPerMinute: number;
    /** Join codes started per address: 6 at once, then 6 a minute; at most 5 open per address, 2000 in all. */
    enrollBurst: number;
    enrollEveryMs: number;
    enrollOpenPerAddress: number;
    enrollOpenMax: number;
    /** Wrong join codes (lookups and approvals): per session and minute, per address and minute, per account and hour. */
    codeFailuresPerSession: number;
    codeFailuresPerAddress: number;
    codeFailuresPerAccountHour: number;
    /** Tickets per device: 30 at once, then 30 a minute. */
    ticketBurst: number;
    ticketEveryMs: number;
    /** A member computer's own requests (revocation list, update): 10 at once, then 30 a minute. */
    computerBurst: number;
    computerEveryMs: number;
    /** A computer's wait on its revocation list at most (seconds), and how many may wait at once (past it: no wait). */
    revocationWaitS: number;
    revocationWaitersMax: number;
    /** Sign-ins on their way through the IdP, in all. */
    signinsOpenMax: number;
    computersPerAccount: number;
    /** Join keys an app may have made for its account and not yet used. */
    appJoinKeysOpen: number;
    /** Devices signed in at once (a device that is signed out does not count). */
    devicesPerAccount: number;
    /** A request's body must have arrived within this. */
    bodyTimeoutMs: number;
};
export type Limits = typeof LIMITS;
export declare const normCode: (s: string) => string;
export declare const validCode: (c: string) => boolean;
export declare const showCode: (c: string) => string;
export declare function newCode(): string;
/** True when `sig` (base64url) is Link id `id`'s (hex of an Ed25519 public key) signature over `text`. */
export declare function verifyLinkSignature(id: string, text: string, sig: string): boolean;
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
export declare class AccountService {
    private readonly deps;
    private readonly cfg;
    private readonly sessionRe;
    private readonly linkRe;
    private readonly store;
    private readonly l;
    private readonly now;
    private readonly log;
    private readonly signins;
    private readonly callbacks;
    private readonly exchanges;
    private readonly enrolls;
    private readonly tickets;
    private readonly computerReqs;
    private readonly badTokens;
    private readonly codeFailSession;
    private readonly codeFailAddress;
    private readonly codeFailAccount;
    private readonly webOrigins;
    private readonly appleKeys;
    private refused;
    private refusedLogged;
    private delivering;
    /** Computers waiting on their account's revocation list (GET /v1/computer/revocations?wait=), by account. */
    private waiters;
    private waitingBy;
    private waiting;
    /** A hosted web client's request: the body hash its proof covers (readBody checks the body against it). */
    private readonly signedBodies;
    constructor(deps: ServiceDeps);
    /** Where a request comes from: the socket, or behind the trusted TLS front on loopback its last X-Forwarded-For. */
    addressOf(req: IncomingMessage): string;
    private refuse;
    private send;
    private page;
    private redirect;
    private readBody;
    /** The raw body too (a computer's signature covers it). */
    private readRaw;
    private limited;
    handle: (req: IncomingMessage, res: ServerResponse) => void;
    private route;
    private corsHeaders;
    configBody(): {
        server: {
            url: string;
            name: string;
        };
        idp: {
            issuer: string;
            name: string;
        };
        signin: {
            appReturn: string;
            redirects: string[];
            oidc: boolean;
            apple: boolean;
        };
        ticketTtl: number;
        sessionMaxAgeDays: number;
    };
    private redirectAllowed;
    private signin;
    private callback;
    private token;
    /** A new session for the device a sign-in named (`device`: `{ name, platform, key }`, each optional): the account's
     *  device with that key, else a new one. What /v1/token and /v1/auth/apple answer. */
    private deviceSession;
    /**
     * POST /v1/auth/apple `{ identityToken, nonce, name?, device }`: an app's native Sign in with Apple. The token is
     * checked here (Apple's key, one of the apps' bundle ids, not expired, SHA-256 of `nonce`); the account is Apple's
     * `iss` + `sub` — the same one a web sign-in through Apple as an OpenID provider would be. `name`: what the app got
     * from Apple at the first sign-in (Apple says it only then), the shown name; else the email, if any.
     */
    private appleSignIn;
    /** The device session of a request's bearer token (an app's), or 401 / 429. */
    private bearer;
    /** A hosted web client's request: signed, just now, with the key its session was made for. */
    private hostedProofOk;
    /** The session of `token` if it is one of `kinds`, current, and passes `check` (before it counts as used). */
    private sessionAuth;
    private me;
    /** What the account has bought, by source: `appstore` → `{ active, productId, expiresAt, sandbox }` from its newest
     *  purchase that is not revoked (absent: none ever reported). */
    private entitlements;
    /** POST /v1/entitlements/appstore `{ jws }`: a StoreKit 2 transaction of one of the operator's products, for its
     *  bundle id, signed by Apple — the account's now (a purchase is the last reporting account's). */
    private appStoreEntitlement;
    /** POST /v1/join-keys: a one-use join key for the account, short-lived — what a signed-in app hands a computer it is
     *  paired with (over their own connection) so the computer joins the account by itself. Only an app's session (a
     *  web page's could be any script's). */
    private appJoinKey;
    /**
     * DELETE /v1/me `{ authorizationCode? }`: the account deleted by its own person (from the app: Apple's rule for apps
     * with accounts). Everything of it goes — its computers leave it (the signed list says so), its devices are signed
     * out —, but no tombstone stays: signing in again makes a new account. With a fresh Sign in with Apple
     * authorization code and the operator's key, the Apple grant is revoked too (Apple unreachable, or the code not of
     * this account: deleted all the same, `revoked: false`).
     */
    private deleteAccount;
    /** The device's session ended, and the device on the revocation list (its computers stop taking what it holds). */
    endDeviceSession(a: Authed, reason: string): Promise<void>;
    /** A session the IdP re-check ended (recheck.ts): its device on the revocation list, the notice pushed. */
    sessionEnded(s: Session): Promise<void>;
    /** The queued revocations (store.revoke puts them in the outbox; admin.ts too, from its process) take effect on the
     *  computers: those waiting on the account's list are answered with it now. */
    deliverNotices(): Promise<void>;
    private ownComputer;
    private renameComputer;
    private removeComputer;
    private ticket;
    private removeDevice;
    private enroll;
    /** The open enrollment of a code typed or scanned on a phone, counting wrong ones against the session, the address
     *  and the account; 404 for a wrong code, 429 once over. */
    private codeTarget;
    private lookup;
    private approve;
    private deviceCodeEnrollment;
    private poll;
    private confirm;
    /** The computer is in `account` now (inside a transaction): a new row, or its row updated; one that was in another
     *  account leaves that one (whose devices drop it). → the account it left, or null. */
    private admit;
    /**
     * A computer joins with a join key (admin.ts join-key): the admin's word stands in for a device's approval, and
     * whoever runs the command on the computer for its own confirmation. The request is signed with the computer's Link
     * key (the id is its own), and a wrong key counts against the address like a wrong sign-in.
     */
    private joinWithKey;
    private decline;
    /**
     * GET /v1/computer/services (a member computer, signed): what this server lends a computer of an account here, so
     * that being in the account is all it takes (nothing to paste) — each of `cfg.services` by its name, in order: a
     * `fixed` one as it is now (the same for every computer: a relay's origin and token, say), a `token` one as its
     * origin and a service token of this computer's own, a day long (asked again before it runs out; a computer taken
     * out of its account, or of a disabled account, gets no more). null: not lent now.
     */
    private services;
    /** `Authorization: <Ns>Link <linkId>.<unix seconds>.<signature>`, the signature over `Wire.computerProofText`. */
    private computerRequest;
    /** Until a revocation of `account` takes effect, `ms` pass, or the computer hangs up. */
    private waitForRevocation;
    /** Every waiting computer answered now (the server is stopping). */
    releaseWaiters(): void;
}
export {};
