import { TicketError, type PublicJwk, type RevocationEntry, type TicketClaims } from "./protocol.js";
/** An https origin a URL parser takes too (its port in range): no path, query or fragment. */
export declare const validOrigin: (u: unknown) => u is string;
export interface MemberRecord {
    v: 1;
    /** The account server's origin: what its signatures name as `iss`. */
    server: string;
    keys: PublicJwk[];
    /** The owner, pinned when this computer joined. */
    account: {
        id: string;
        name: string | null;
    };
    /** The Link id this computer joined as (tickets are for it). */
    linkId: string;
    /** Unix ms. */
    joinedAt: number;
    /** When it joined by the account server's clock (unix ms): a ticket made before that is of an earlier membership
     *  (this computer left and came back) and counts for nothing. */
    since: number;
    /** The account's revocation list has been fetched since it joined: until then no ticket is taken. */
    synced: boolean;
    revocations: {
        version: number;
        devices: RevocationEntry[];
        disabled: number | null;
    };
    /** What the account brings this computer, as the account server last said (`services()`). */
    services?: AccountServices;
}
/** One thing an account lends its computers (GET /v1/computer/services), as the account server's operator set it up:
 *  where it is (`url`, an https origin) and what goes with it — a token the same for every computer (`token`), or one
 *  of this computer's own that runs out (`token` + `expiresAt`, unix ms: asked for again before it does), or any other
 *  short strings (a key). */
export interface LentService {
    url: string;
    token?: string;
    expiresAt?: number;
    [field: string]: string | number | undefined;
}
/** What an account brings its computers, by name (`relay`, `push`…: the operator's names; the library does not know
 *  what they are). */
export type AccountServices = Record<string, LentService>;
/**
 * The server's answer (or what the file kept) as services: only what is whole. A name is 1-32 of [a-z0-9-]; each is an
 * object whose `url` is an https origin — or, from an account server on this computer itself (tests, a local run), one
 * on loopback: a server elsewhere never points this computer's requests at its own loopback — and whose other fields
 * are short printable strings or (`expiresAt`) a time. At most 16; anything else is left out. What a service's own
 * rules are (which needs which) is the caller's: `AccountMemberOptions.validServices`.
 */
export declare function validServices(j: unknown, server: string): AccountServices;
/** How long a ticket's token may count when its ticket names no end of the device's session (an older account server):
 *  the longest a session lives there. */
export declare const TICKET_SESSION_MAX_S: number;
/** What this computer tells the account server about itself. */
export interface ComputerSelf {
    linkId: string;
    name: string;
    fingerprint?: string;
    /** Link relay URLs (with their tokens: the account's devices dial through them). */
    relays: string[];
    /** The `ip:port` its Link entry listens on (its interfaces', a router mapping): what devices try directly. */
    direct: string[];
    /** The https origins of pages this computer serves itself (the account server lists them; most have none). */
    origins: string[];
    /** The signaling service it waits for browsers' offers at (an origin): where a hosted web client sends its offer. */
    signal?: string | null;
}
export interface PendingJoin {
    server: string;
    userCode: string;
    /** The QR code's text: the app's 「添加电脑」 scans it; the code itself is typed in a client instead. */
    qr: string;
    /** Unix ms. */
    expiresAt: number;
    state: "waiting" | "approved" | "failed";
    /** Who approved (the server's word), once somebody did. */
    claimant?: {
        account: {
            id: string;
            name: string | null;
        };
        idp?: {
            name?: string;
            sub?: string;
        };
        by?: string;
    };
    error?: string;
}
export interface AccountMemberStatus {
    member: {
        server: string;
        account: {
            id: string;
            name: string | null;
        };
        joinedAt: number;
        disabled: boolean;
        listVersion: number;
    } | null;
    pending: PendingJoin | null;
    /** The last exchange with the server: unix ms, and what went wrong if it did. */
    sync: {
        at: number;
        error?: string;
    } | null;
}
export interface AccountMemberOptions {
    file: string;
    /** The wire names' namespace (protocol.ts `Wire`): the account server's. Default "yoyo". */
    namespace?: string;
    /** A caller's own rules for what is kept of the services the server lends (this one only with that one): given what
     *  `validServices` kept, it returns what stays. */
    validServices?: (services: AccountServices, server: string) => AccountServices;
    self: () => ComputerSelf | null;
    /** The Link key's signature over `text` (base64url Ed25519): null when `id` is not this computer's key. */
    sign: (id: string, text: string) => string | null;
    fetch?: typeof fetch;
    log?: (line: string) => void;
    now?: () => number;
    /** Seconds a revocation request waits at the server, and the retry backoff (tests). */
    timing?: {
        waitS?: number;
        retryMinMs?: number;
        retryMaxMs?: number;
    };
    /** Called when what counts changed: a new revocation list, this computer out of its account. */
    onChange?: () => void;
    /** Called when what the account brings this computer changed (`services()`): a relay, a new push token, none. */
    onServices?: () => void;
}
export declare class JoinError extends Error {
    readonly status: number;
    constructor(status: number, message: string);
}
declare const sha256: (s: string) => string;
/** An account server's address as it is kept and compared: an https origin (http only on loopback). */
export declare function serverOrigin(raw: unknown): string | null;
/** How long what a sign-in registered here is still sent to after the sign-in itself ran out (seconds). The device was
 *  not removed, and a notification is what brings its person back to sign in again — but only for a while: a device
 *  whose sign-in ran out is no longer in the account's list of devices, so nobody could remove it any more. */
export declare const REGISTRATION_GRACE_S: number;
export declare class AccountMember {
    private readonly o;
    private rec;
    /** The file is there but is not a record: this computer is in an account it cannot read — nothing comes in by ticket,
     *  and joining again needs `leave` first. */
    private broken;
    private readonly replay;
    private pending;
    private pollTimer;
    private sync;
    private running;
    private stopped;
    private wake;
    private inflight;
    private sentSelf;
    /** The membership whose services were last asked for and answered in this run (`servicesKey`), when, when not to ask
     *  before and how long to wait after the next ask that fails, and whether an ask was wanted (`refreshServices`). */
    private servicesFor;
    private servicesAt;
    private servicesNotBefore;
    private servicesRetryMs;
    private servicesWanted;
    private servicesSaid;
    private keysFetchedAt;
    private readonly fetch;
    private readonly wire;
    private readonly keep;
    private readonly log;
    private readonly now;
    constructor(o: AccountMemberOptions);
    private load;
    private save;
    current(): MemberRecord | null;
    status(): AccountMemberStatus;
    /** Whether one of this computer's own tokens made for a ticket still counts: the same account and this membership of
     *  it (a ticket from before this computer last joined is void), the device's session at the server not over (`sx`),
     *  the device not revoked since the ticket (`tat`, unix seconds), the account not disabled. */
    ticketValid(t: {
        acc: string;
        dev: string;
        tat: number;
        sx: number;
    }): boolean;
    /** What the account brings this computer now (null: in no account, or its account disabled): each service the
     *  server lent, those with a token of this computer's own while it has not run out. */
    services(): AccountServices | null;
    /** A service refused this computer's token (it ran out early, the server's key changed): asked for again on the
     *  loop's next round, a minute after the last answer at the earliest. */
    refreshServices(): void;
    /** Whether what a sign-in of the account registered here to be sent to later still counts (a push registration,
     *  say): its device not removed or signed out since, this computer still in that account — and
     *  the sign-in not run out for longer than REGISTRATION_GRACE_S. */
    registrationCounts(t: {
        acc: string;
        dev: string;
        tat: number;
        sx: number;
    }): boolean;
    /** The device that came in with a ticket issued at `tat` is still one of this computer's account, not removed since
     *  (`ticketValid` without the sign-in's own end). */
    private deviceCounts;
    /** A ticket taken (once): its claims, or a TicketError. */
    redeem(jwt: string): Promise<TicketClaims>;
    /** The server's keys fetched (a minute apart at most): a new one is kept only through the chain of endorsements
     *  from one already pinned. */
    private refreshKeys;
    private canJoin;
    private post;
    /** What the server answered a join with, taken as this computer's membership. */
    private adopt;
    /** With a join key the server's admin made: no approval, no confirmation. */
    joinWithKey(serverRaw: unknown, key: unknown): Promise<MemberRecord>;
    /** A join code asked of the server: shown here, approved by somebody signed in (a phone that scans it, or a client the code is typed in).
     *  `expect`: the account (its id, or its `sub` at the sign-in system) that may have this computer — an approval by
     *  that account is confirmed without anyone at this computer. */
    startJoin(serverRaw: unknown, expect?: {
        account?: string;
        sub?: string;
    } | null): Promise<PendingJoin>;
    private schedulePoll;
    private poll;
    /** The person at this computer agrees to who approved (or it was the expected account): this computer is theirs. */
    confirmJoin(): Promise<MemberRecord>;
    /** The join under way given up (and the server told, so the code is dead). */
    cancelJoin(): Promise<void>;
    private endPending;
    /** Out of the account (from this computer itself): the record goes, so every token made for a ticket is void at
     *  once; the server is told when it can be reached. */
    leave(): Promise<boolean>;
    private signed;
    /** The loop: what this computer is (name, relays, …) told to the server when it changed; the revocation list asked
     *  for and waited on. Runs while the server does; idle while this computer is in no account. */
    start(): void;
    stop(): void;
    private kick;
    private sleep;
    private loop;
    /** One membership: the account, and when this computer joined it (leaving and joining again is another). */
    private servicesKey;
    private servicesDue;
    /**
     * Asks the account server what the account brings this computer. Only a good answer changes what is held. A server
     * that says "nothing for you" without a signature (404: an older one without the route, or one that lost its list;
     * 403: the account disabled, which its signed list says too) is taken as an answer of nothing new — what is held
     * stays, asked again in a few hours: a computer is taken out of its account by a signed list alone, and what it held
     * goes with the membership then. Anything else (the server away, an error of its own) is asked again soon, each
     * wait twice the last.
     */
    private pullServices;
    private tellSelf;
    private pull;
}
export { TicketError };
export { sha256 as accountSha256 };
