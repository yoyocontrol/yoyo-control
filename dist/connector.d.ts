import type { ScreenRoute, ScreenRouting } from "./contracts.js";
/**
 * A `ScreenRouting` over candidate ways to one computer (the iOS kit's YoyoConnect, ios/README.md「YoyoConnect」), for
 * one visit of the Screen page: the backend supplies candidates and probes them (`ConnectSource`), the connector decides
 * which way is current and the page moves its stream and sound with it.
 *
 * - **Races**, happy eyeballs (`ConnectPolicy.offsets`): when the page shows, when a stream is about to open, every
 *   `retryIntervalMs` while on a worse way than the network allows, and after a change of network. Only candidates
 *   better than the way in use race. The first reached becomes current. A stream about to open waits up to
 *   `decisionWaitMs` for a race that may move it off a fallback.
 * - **Link** first: a `link` candidate (a uu Link session) is better than every other way; it starts alone, the
 *   others start `offsets` later only if it isn't reached by then, and one of them reached first is taken meanwhile
 *   while the link may still win within `linkGraceMs` (the stream moves to it). A link whose session ends
 *   (`ConnectSource.ended`) is left at once.
 * - **Shortcuts** (a non-fallback way while the ways have a fallback): their stream failing, `ackFailuresToLeave` acks
 *   lost in a row, or a request failing on the way (`classify`) goes back to the fallback at once (the request is sent
 *   again there); then no race for `retryIntervalMs`.
 * - **Credentials**: a held supply is asked anew once when racing it reached nothing; a 401 on the way in use goes to
 *   the fallback and races a fresh supply at once, once. A supply that `expires` is renewed `renewBeforeMs` before.
 * - **Network**: `online` / `offline` and `navigator.connection` changes (a browser can't see its interfaces: `lan`
 *   candidates are tried unless the connection type says cellular). Going offline leaves a shortcut at once.
 */
export type CandidateKind = "lan" | "direct" | "relay" | "tunnel" | "link";
/** One way to reach a computer that a connector may race and use. `data`: the backend's own (an address, a ticket). */
export interface Candidate {
    /** The route's id. Default `<kind>:<host>`. */
    id: string;
    kind: CandidateKind;
    label: string;
    isLocalNetwork: boolean;
    /** What its requests authenticate with: a candidate with another credential is another one. */
    credential?: string | null;
    report: ScreenRoute["report"];
    data?: unknown;
}
/** A candidate with the defaults filled in. */
export declare function candidate(c: {
    kind: CandidateKind;
    id?: string;
    host?: string;
    label?: string;
    isLocalNetwork?: boolean;
    credential?: string | null;
    report?: ScreenRoute["report"];
    data?: unknown;
}): Candidate;
export declare function routeOf(c: Candidate, hasFallback: boolean): ScreenRoute;
export type Probe<L> = {
    t: "reached";
    link: L;
    as?: Candidate;
} | {
    t: "unauthorized";
} | {
    t: "unreachable";
};
export type Refresh = "held" | "stale" | "unauthorized" | "renew";
export interface Supply {
    /** The shortcuts; fallbacks are the ways'. */
    candidates: Candidate[];
    /** Just asked for, not held from before. */
    fresh: boolean;
    /** When their credential expires (ms since 1970). */
    expires?: number | null;
}
/** What a connector does on the network, from its host. */
export interface ConnectSource<L> {
    /** The candidates now; null: the computer has no other way (no more races this visit); a throw: tried again later. */
    candidates(why: Refresh): Promise<Supply | null>;
    /** Probes one candidate; `signal` aborts when another wins. */
    probe(c: Candidate, signal: AbortSignal): Promise<Probe<L>>;
    /** A link no longer in use. */
    release?(link: L): void;
    /** Resolves true when a link in use stops working by itself (a uu Link session ending); false: it doesn't. */
    ended?(link: L): Promise<boolean>;
}
export type Failure = "answer" | "unauthorized" | "link";
/** The default: a refusal by the computer (400 / 403 / 404 / 409 / 413, another device in control) is an answer; 401
 *  is unauthorized; anything else (a network error, 5xx) is the way. */
export declare function classifyFailure(error: unknown): Failure;
export interface ConnectPolicy {
    /** When each kind's probes start after a race begins, relative to the best kind present (ms). */
    offsets: Record<CandidateKind, number>;
    linkGraceMs: number;
    decisionWaitMs: number;
    openTimeoutMs: number;
    retryIntervalMs: number;
    ackFailuresToLeave: number;
    renewBeforeMs: number;
    pathSettleMs: number;
    keepRetiredMs: number;
    classify: (error: unknown) => Failure;
}
export declare const DEFAULT_POLICY: Readonly<ConnectPolicy>;
/** The timers a connector uses (tests pass their own). */
export interface Clock {
    now(): number;
    setTimeout(fn: () => void, ms: number): unknown;
    clearTimeout(h: unknown): void;
}
export declare const browserClock: Clock;
export type Outcome<L> = {
    t: "reached";
    link: L;
    candidate: Candidate;
} | {
    t: "unauthorized";
} | {
    t: "unreachable";
};
/** The first of `candidates` reached, each kind starting at its offset; the others are aborted, a late one released. */
export declare function raceFirst<L>(candidates: Candidate[], offsets: Record<CandidateKind, number>, probe: ConnectSource<L>["probe"], release: (l: L) => void, signal: AbortSignal, clock?: Clock): Promise<Outcome<L>>;
/** The ways of one backend to its computer: shared by the backend (which link a request on a route goes through) and
 *  its connector (which way is current). It starts with `initial` and knows the fallbacks it may go back to. */
export declare class ConnectWays<L> {
    private ways;
    private cur;
    private next;
    private closedFlag;
    readonly fallbacks: Candidate[];
    readonly hasFallback: boolean;
    constructor(initial: Candidate, link: L, fallbacks?: Candidate[]);
    get current(): ScreenRoute;
    get currentCandidate(): Candidate;
    get currentLink(): L | null;
    get isClosed(): boolean;
    route(c: Candidate): ScreenRoute;
    /** The link of `route` (null: no such way any more). */
    link(route: ScreenRoute): L | null;
    candidate(route: ScreenRoute): Candidate | null;
    put(c: Candidate, link: L, current: boolean): {
        token: number;
        replaced: L | null;
    } | null;
    token(id: string): number | null;
    setCurrent(id: string): boolean;
    heldFallback(): Candidate | null;
    remove(id: string, token: number): L | null;
    close(): L[];
}
/** What of the network decides which candidates are worth a try. */
export interface ConnectPath {
    online: boolean;
    /** A `lan` candidate is worth a try (a Wi-Fi / wired connection, or the browser doesn't say). */
    hasLocal: boolean;
}
export declare function browserPath(): ConnectPath;
export declare class Connector<L> implements ScreenRouting {
    readonly ways: ConnectWays<L>;
    private readonly source;
    private readonly clock;
    onChange: (() => void) | null;
    readonly policy: ConnectPolicy;
    /** The source may give a `link` candidate: races try for it from any other way. Set before `activate`. */
    linkPossible: boolean;
    /** Off: the host calls `pathUpdated` itself (tests). */
    watchesPath: boolean;
    shortcutsAllowed: boolean;
    supported: boolean;
    path: ConnectPath;
    private active;
    private closed;
    private attempt;
    private racing;
    private raceWaits;
    private settling;
    private nextTry;
    private renewAt;
    private renewing;
    private timer;
    private reachingFallback;
    private lostAcks;
    private reissued;
    private pathSig;
    private linkRacing;
    private currentEnded;
    private unwatch;
    constructor(ways: ConnectWays<L>, source: ConnectSource<L>, policy?: Partial<ConnectPolicy>, clock?: Clock);
    get current(): ScreenRoute;
    get decisionWaitMs(): number;
    get openTimeoutMs(): number;
    get isDeciding(): boolean;
    private get kind();
    newVisit(): void;
    activate(): void;
    streamWillOpen(): void;
    leave(): void;
    streamFailed(route: ScreenRoute, unauthorized: boolean): void;
    ackAnswered(route: ScreenRoute, status: number | null): void;
    fallback(route: ScreenRoute, error: unknown): Promise<ScreenRoute | null>;
    setShortcutsAllowed(on: boolean): void;
    close(): void;
    /** A change of network (the connector's own watch's, or the host's with `watchesPath` off). */
    pathUpdated(next: ConnectPath): void;
    private get bestRankHere();
    private get canImprove();
    private usable;
    private raceable;
    private tryBetter;
    private race;
    private reach;
    private take;
    private renewDeadline;
    private cancelRace;
    private watchEnd;
    private wayEnded;
    private failed;
    private unauthorized;
    private demote;
    private reachFallback;
    private move;
    private retire;
    private retireLink;
    private renew;
    private renewed;
    private clearTimer;
    private schedule;
    private fire;
    private changed;
    private startPathWatch;
}
