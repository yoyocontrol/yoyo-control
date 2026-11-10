import type { SendInput } from "./input.js";
import type { NetQuality, NetReport } from "./types.js";
/**
 * This side of the network for the playout report's `net` (docs/PROTOCOL.md「网络质量」, the iOS kit's
 * `ScreenNetSampler`), pure: every time is passed in (ms, the page's clock). The route the stream uses, the network path
 * (`browserNetPath()`), input round trips of the last `windowMs` on that route (cleared when it changes), input and ack
 * requests that failed on the way in the same window, and the stream's bytes over the last `rxWindowMs`.
 */
export declare class NetSampler {
    readonly windowMs: number;
    readonly rxWindowMs: number;
    /** At most this many round trips / failures are kept. */
    static readonly MAX_SAMPLES = 512;
    private static readonly BUCKET_MS;
    /** What the network path says (null: unknown). */
    path: NetPath | null;
    private routeIs;
    private rtts;
    private failures;
    private rx;
    private rxSince;
    constructor(windowMs?: number, rxWindowMs?: number);
    get route(): NetReport["route"] | null;
    /** The stream now goes this way: round trips measured on another one no longer count. */
    setRoute(route: NetReport["route"] | null): void;
    /** A new stream: its bytes are counted from `now`. */
    streamStarted(now: number): void;
    /** An input was answered after `ms` on `route` (one on a route other than the stream's is left out). */
    inputAnswered(route: NetReport["route"], ms: number, now: number): void;
    /** An input or ack request failed on the way (`isNetworkFailure`). */
    failed(now: number): void;
    received(bytes: number, now: number): void;
    /** The report at `now`; null when nothing is known. */
    report(now: number): NetReport | null;
    private prune;
}
/** The network path as the report names it. A browser has no radio information. */
export interface NetPath {
    iface?: "wifi" | "cellular" | "wired" | "other";
    expensive?: boolean;
    constrained?: boolean;
}
/** The parts of the Network Information API (`navigator.connection`) read here; absent on Safari and Firefox. */
export interface ConnectionLike {
    type?: string;
    saveData?: boolean;
}
/** The path from `navigator.connection` when the browser has one (Chromium): `type` → iface (`ethernet` → wired,
 *  `wifi`, `cellular`, `none` → no path, anything else other), `saveData` → constrained; cellular is expensive. Null
 *  without the API or without a `type`. */
export declare function browserNetPath(connection?: ConnectionLike | null | undefined): NetPath | null;
/** Statuses a proxy or CDN in front of the computer answers when it couldn't reach it (the default `isWayDown`). */
export declare function isUnreachableStatus(status: number): boolean;
/**
 * A request that failed on the way counts as a network failure: a fetch that threw (a `TypeError`, a timeout) or an
 * answer saying the way to the computer is broken (`isWayDown`, default `isUnreachableStatus`). An answer from the
 * computer's server (409, 400, 404, its own 503) and an abort don't.
 */
export declare function isNetworkFailure(error: unknown, isWayDown?: (status: number, message: string | null) => boolean): boolean;
/** The server's grade from an ack answer's `net` (or a link's own), leniently: null when it isn't an object; an unknown
 *  grade is `unknown`, negative or non-finite numbers are dropped, at most 8 reasons of ≤ 32 characters. */
export declare function parseNetQuality(net: unknown): NetQuality | null;
/** The stats line's part: `net fair (rtt, jitter) · rtt 165/210 · jitter 73` (codes and numbers only). */
export declare function netQualityLine(q: NetQuality): string;
/**
 * `send` (InputQueue's `SendInput`, HTTP) that reports each input's round trip to `net` on the route it went (`route()`
 * when it was sent), and a network failure (`isNetworkFailure`) as one. Over a link input isn't answered one by one;
 * the link's own input round trips are in its stats line.
 */
export declare function withNetSampler(send: SendInput, net: NetSampler, route: () => NetReport["route"], now?: () => number): SendInput;
