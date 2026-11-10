import type { MediaCounters } from "./wasm.js";
/** Which road a session's packets take (docs/LINK.md「端点、地址、路径」; WebRTC has no `relay` this round). */
export type PathKind = "relay" | "lan" | "direct" | "punched" | "none";
/** This device's network interface. */
export type Iface = "wifi" | "cellular" | "wired" | "other";
/** The session's path: its kind and the remote address (`ip:port`) when known. */
export interface PathInfo {
    kind: PathKind;
    remote?: string;
}
/**
 * The media fields of `link.stats` (all optional: a session without media has none), as the Rust core's
 * `MediaStats` serializes them.
 */
export interface LinkMediaStats {
    lossPct?: number;
    mediaReceived?: number;
    mediaMissing?: number;
    fecRecovered?: number;
    nackRecovered?: number;
    nackSent?: number;
    lostFrames?: number;
    skippedFrames?: number;
    freezeCount?: number;
    freezeMs?: number;
    rateTargetMbps?: number;
    rateSentMbps?: number;
    rateCuts?: number;
    rateLossCuts?: number;
    jitterMs?: number;
    fps?: number;
    inputP50Ms?: number;
    inputP90Ms?: number;
    inputN?: number;
    audioLossPct?: number;
    audioRed?: number;
}
/** One end's view of a session: the `link.stats` object (docs/LINK.md「统计与日志」). */
export interface LinkStats extends LinkMediaStats {
    path: PathKind;
    iface: Iface;
    remote?: string;
    rttMinMs: number;
    rttP50Ms: number;
    rttP90Ms: number;
    bytesSent: number;
    bytesReceived: number;
    packetsLost: number;
    datagramsSent: number;
    datagramsReceived: number;
    datagramDrops: number;
}
/** The client media layer's counters as `link.stats`' media fields (what the Rust core's driver reports). */
export declare function linkMediaStats(m: MediaCounters): LinkMediaStats;
/** `<path> <iface> rtt <min>/<p50>/<p90> ms loss … red …` (the `link:` line's body, as the Rust core writes it). */
export declare function statsLine(s: LinkStats): string;
/** A peer's `link.stats` message, leniently (null when it isn't one). */
export declare function parseLinkStats(m: Record<string, unknown>): LinkStats | null;
/** RTT samples over a sliding window (ms; times in ms): min / p50 / p90 as the Rust core summarizes them. */
export declare class RttWindow {
    private readonly windowMs;
    private samples;
    constructor(windowMs?: number);
    push(at: number, rttMs: number): void;
    /** (min, p50, p90); zeros without samples. */
    summary(): [number, number, number];
}
/** An IP address on the local network: private, link-local, loopback, CGNAT excluded (100.64/10 counts as public), ULA. */
export declare function isLocalAddress(ip: string): boolean;
/** One side of the selected candidate pair, as `getStats()` reports it. */
export interface CandidateInfo {
    candidateType?: string;
    address?: string;
    port?: number;
}
/**
 * The path kind of the selected candidate pair (docs/LINK.md「WebRTC」): a private remote address = `lan`; the
 * server's own public address (a host candidate: an interface or the router mapping it advertises) = `direct`; a
 * reflexive one (srflx / prflx: learned through NAT) = `punched`; a relayed one = `relay`.
 */
export declare function classifyPath(local: CandidateInfo | undefined, remote: CandidateInfo | undefined): PathInfo;
/** This device's interface from `navigator.connection` (Chrome / Android; Safari has none: `other`). */
export declare function browserIface(): Iface;
