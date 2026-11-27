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
export declare class WebWire {
    readonly namespace: string;
    readonly proofHeader: string;
    readonly hostedProof: string;
    constructor(namespace?: string);
    /** What the page signs for each request (the account server's `Wire.hostedProofText`). */
    hostedProofText(server: string, method: string, pathQ: string, ts: number, bodyHash: string): string;
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
    account: {
        id: string;
        name: string;
    };
    device: {
        id: string;
        name: string;
    };
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
/** The account server's origin, as it names itself (what the proofs carry): https, or http on loopback (tests). */
export declare function serverOrigin(raw: string): string;
/**
 * Starts a sign-in: where to send the browser (the account server's `/v1/signin`), and what to keep until it comes
 * back (`finishSignIn`). `returnUrl`: the page's registered address (`ACCOUNT_WEB_REDIRECTS`), exactly.
 */
export declare function beginSignIn(server: string, returnUrl: string, now?: number): Promise<{
    url: string;
    pending: PendingSignIn;
}>;
/** Why a sign-in did not finish (`code`: the account server's error, or `state` / `expired` / `no_code` / `unbound`). */
export declare class SignInError extends Error {
    readonly code: string;
    constructor(code: string, message: string);
}
/** The page's address carries a sign-in's answer (`code` or `error`, with `state`): `finishSignIn` it. */
export declare function isSignInReturn(url: string): boolean;
/**
 * The browser came back to `returnedUrl` with a code: trade it for this browser's session, bound to its device key
 * (the kept one, else a new one). Only for the sign-in this tab started (`pending`, its `state`).
 */
export declare function finishSignIn(returnedUrl: string, pending: PendingSignIn | null, o: ClientOptions & {
    keep: Keep;
    deviceName: string;
    now?: number;
}): Promise<AccountClient>;
/**
 * Email and password (the account server's `ACCOUNT_PASSWORD`, docs/ACCOUNT-LIB.md「邮箱和密码」). Refusals are
 * `AccountError`s with the server's `error`: `invalid_email`, `weak_password` (8–256 characters), `invalid_code`,
 * `code_expired`, `invalid_credentials` (a wrong email or password: one answer), `already_registered`,
 * `access_denied`, `mail_failed`, `slow_down` (429).
 */
export declare const emailSignIn: {
    /** Mails a sign-up code (`locale`: the mail's language). The same answer for an email that has a login (its mail
     *  says so instead). */
    register(server: string, email: string, password: string, o?: {
        locale?: string;
        fetch?: Fetch;
    }): Promise<void>;
    /** The mailed code: the account is made, and this browser signed in to it. */
    verify(server: string, email: string, code: string, o: ClientOptions & {
        keep: Keep;
        deviceName: string;
        name?: string;
    }): Promise<AccountClient>;
    /** Signs in with email and password. */
    signIn(server: string, email: string, password: string, o: ClientOptions & {
        keep: Keep;
        deviceName: string;
    }): Promise<AccountClient>;
    /** Mails a reset code when the email has a login (the same answer when it has none). */
    reset(server: string, email: string, o?: {
        locale?: string;
        fetch?: Fetch;
    }): Promise<void>;
    /** The reset code and the new password: the account's other sessions end; this browser is signed in. */
    confirmReset(server: string, email: string, code: string, password: string, o: ClientOptions & {
        keep: Keep;
        deviceName: string;
    }): Promise<AccountClient>;
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
    wait(o?: {
        signal?: AbortSignal;
    }): Promise<AccountClient>;
}
/**
 * Starts a sign-in by QR code (the account server's `/v1/auth/qr`): this browser's device key (the kept one, else a
 * new one) is the one the session will be bound to; only this tab holds the secret it polls with. `platform`: how the
 * account's lists show this device (default `web`).
 */
export declare function beginQrSignIn(server: string, o: ClientOptions & {
    keep: Keep;
    deviceName: string;
    platform?: string;
}): Promise<QrSignIn>;
/**
 * The link a sign-in's QR code carries: `base` (the page that approves it, e.g. `https://example.com/app/login`) with
 * the code after `#` (a fragment: it never reaches a server's logs).
 */
export declare function qrSignInLink(base: string, code: string): string;
/**
 * A sign-in code as scanned or typed: the link (`…#BCDFGHJK`), `BCDF-GHJK`, lower case, spaces — its 8 letters, or ""
 * when it is none.
 */
export declare function signInCode(raw: string): string;
/** What asks to be signed in with a code (`GET /v1/auth/qr/lookup`), for the person to check before approving. */
export interface SignInLookup {
    code: string;
    device: {
        name: string;
        platform: string;
    };
    /** When it asked (unix ms) and from which address. */
    requestedAt: number | null;
    from: string | null;
    expiresIn: number;
    /** The account it would sign in to (this browser's). */
    account: string;
}
/** The signed-in account (null: not signed in, or the sign-in ran out). */
export declare function resumeSignIn(o: ClientOptions & {
    keep: Keep;
    now?: number;
}): Promise<AccountClient | null>;
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
export declare function joinCode(raw: string): string;
/** An answer of the account server's that was not 2xx (`code`: its `error`). `signedOut`: the session is over. */
export declare class AccountError extends Error {
    readonly status: number;
    readonly code: string;
    constructor(status: number, code: string);
    get signedOut(): boolean;
}
/** `GET /v1/me`: the account, this device, and what the account has bought (`entitlements`, by source). */
export interface AccountMe {
    account: {
        id: string;
        name: string;
    };
    device: {
        id: string;
        name: string;
    } | null;
    entitlements: Record<string, unknown>;
}
export declare class AccountClient {
    readonly saved: SavedSignIn;
    private readonly keep;
    /** The server's clock minus this browser's (s), once a refusal showed they are apart. */
    private skew;
    private readonly wire;
    private readonly f;
    private readonly clock;
    constructor(saved: SavedSignIn, keep: Keep, o?: ClientOptions);
    get account(): {
        id: string;
        name: string;
    };
    get device(): {
        id: string;
        name: string;
    };
    get server(): string;
    /**
     * A signed request (`Authorization` + `<ns>-proof`). A 401 with the server's clock well apart from this browser's
     * is asked once more by the server's time (a wrong clock is not a sign-out); any other 401 forgets the sign-in —
     * when it is still the one kept (another tab may have signed in anew since) — and the key stays: same device next time.
     */
    request<T>(method: "GET" | "POST" | "PATCH" | "DELETE", pathQ: string, body?: unknown): Promise<T>;
    /** The account, this device and the account's entitlements. */
    me(): Promise<AccountMe>;
    computers(): Promise<AccountComputer[]>;
    /** What a computer's join code stands for (`GET /v1/computers/lookup`), for the person to check before approving. */
    lookupJoin(code: string): Promise<JoinLookup>;
    /** Puts the computer of a join code into this account (`POST /v1/computers/approve`); it then asks its own person. */
    approveJoin(code: string): Promise<void>;
    /** What asks to be signed in with a sign-in code (scanned or typed), for the person to check before approving. */
    lookupSignIn(code: string): Promise<SignInLookup>;
    /** Signs the device of a sign-in code in to this account (it gets its session at its next poll). */
    approveSignIn(code: string): Promise<void>;
    /** Refuses a sign-in code. */
    declineSignIn(code: string): Promise<void>;
    /** A ticket into the computer of `linkId` (for a Link `hello`'s `Ticket <ticket>`). One use, two minutes. */
    ticket(linkId: string): Promise<string>;
    /** Signs out: the session ends and the account's computers stop taking this browser. The key stays. */
    signOut(): Promise<void>;
}
/** The kept sign-in in IndexedDB (`name`, default `yoyo-account`): structured clone keeps the CryptoKey as it is, still
 *  not extractable. */
export declare function idbKeep(name?: string): Keep;
/** A sign-in on its way, kept in this tab's sessionStorage under `name` (default `yoyo-account-signin`). */
export declare function pendingKeep(name?: string): {
    get(): PendingSignIn | null;
    set(p: PendingSignIn | null): void;
};
