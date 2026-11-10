import { FrameReader } from "./framing.js";
import type { LinkMedia } from "./media.js";
import { type ProbeReport } from "./probe.js";
import { type RpcRequest, type RpcResponse } from "./rpc.js";
import { type Iface, type LinkStats, type PathInfo } from "./stats.js";
/** The client's `hello` (without `t` / `v`). */
export interface Hello {
    /** Opaque to the link: `Bearer <device token>`, an authority-mode ticket, `Pair <code>`… */
    credential: string;
    device: {
        id: string;
        name: string;
    };
    app: {
        name: string;
        version: string;
    };
    features: string[];
}
/** The server's `welcome` (without `t` / `v`). */
export interface Welcome {
    server: {
        id: string;
        name: string;
        platform: string;
    };
    /** Who the server says the client is (its authenticator's answer). */
    principal: unknown;
    features: string[];
    maxDatagram: number;
}
/** A control message: a JSON object with a string `t`. */
export type ControlMessage = {
    t: string;
} & Record<string, unknown>;
/** How a session ended. */
export interface CloseInfo {
    /** The close code (`CloseCode`; `bye.code`); absent for transport-level ends (ICE failed, idle). */
    code?: number;
    reason: string;
    /** The server (or the network) ended it, not this side. */
    remote: boolean;
    description: string;
}
/** The stats of a session as `stats()` returns them: `link.stats` plus the `link:` line's body. */
export type SessionStats = LinkStats & {
    line: string;
};
/** Largest datagram payload over WebRTC (SCTP over DTLS over UDP, safe on every path). */
export declare const MAX_DATAGRAM = 1200;
/** `link.stats` goes this often. */
export declare const STATS_EVERY_MS = 2000;
/** The media layer gets the path's RTT this often. */
export declare const RTT_EVERY_MS = 100;
/** `getStats()` is read this often (the RTT it reports changes with the ICE consent checks). */
export declare const PEER_STATS_EVERY_MS = 500;
/** Nothing from the server for this long: the session is dead (the server sends `link.stats` every 2 s). */
export declare const IDLE_MS = 20000;
/** While the app expects traffic (`setActivityTimeout`, e.g. a video stream is open: the server sends `link.stats`
 *  every 2 s and the stream's keepalives), this much silence ends the session. */
export declare const ACTIVE_IDLE_MS = 3000;
/** `dgram`'s send buffer: past it a datagram is dropped rather than queued (new datagrams are what matters). */
export declare const DGRAM_BUFFER: number;
/** RPC answers start within this long. */
export declare const RPC_TIMEOUT_MS = 30000;
/** A lost path (ICE `disconnected` / `failed`: the network changed, Wi-Fi ↔ 5G) is looked for again this long by ICE
 *  restarts before the session ends (the server keeps a silent connection about 20 s). */
export declare const RECOVER_MS = 15000;
/** ICE gets this long to come back by itself before the first restart (a short blip). */
export declare const RESTART_AFTER_MS = 1000;
/** A restart that found no path by then is tried again. */
export declare const RESTART_EVERY_MS = 4000;
/** How long the dial took to each step (ms from its start): ICE gathering done (the offer went), the answer came,
 *  the control channel opened (ICE + DTLS + SCTP), `welcome` came. */
export interface DialTiming {
    gatheredMs: number;
    answeredMs: number;
    connectedMs: number;
    welcomeMs: number;
}
/** What `dialRtc` hands over once `welcome` came. @internal */
export interface SessionParts {
    pc: RTCPeerConnection;
    control: RTCDataChannel;
    dgram: RTCDataChannel;
    reader: FrameReader;
    /** Control frames that came with or right after `welcome`. */
    early: Record<string, unknown>[];
    hello: Hello;
    welcome: Welcome;
    media: LinkMedia | null;
    iface: () => Iface;
    timing: DialTiming;
    /** One ICE restart through the signaling path (resolves once the answer is applied, with whether the server takes
     *  another); absent when the server takes none (older servers: a lost path ends the session). */
    restartIce?: () => Promise<boolean>;
}
/**
 * One uu Link session over WebRTC (docs/LINK.md「会话协议」, 「WebRTC」): control messages both ways, RPC requests,
 * datagram channels 6–15 for the app, the media layer on channels 1–5 (`media`), the path and its stats. The same
 * shape as `@yoyocontrol/link`'s Node `Session`, client side. It ends when either side closes it (`bye`), the
 * peer connection closes, or nothing came for `IDLE_MS` (`setActivityTimeout` while traffic is expected:
 * `ACTIVE_IDLE_MS` with a video stream open through `linkScreen`). A lost path (ICE `disconnected` / `failed`: the
 * network changed) is looked for again with ICE restarts for up to `RECOVER_MS` when the server takes them
 * (`recovering`, `onRecovering`); the session ends only when none is found (at once with servers that don't).
 */
export declare class LinkSession {
    readonly hello: Hello;
    readonly welcome: Welcome;
    /** The media layer (null when the session was dialed without one). */
    readonly media: LinkMedia | null;
    /** How long the dial took to each step. */
    readonly timing: DialTiming;
    private readonly pc;
    private readonly control;
    private readonly dgram;
    private readonly reader;
    private readonly iface;
    private readonly controlListeners;
    private readonly datagramListeners;
    private readonly closedListeners;
    private closeInfo;
    private readonly closedPromise;
    private resolveClosed;
    private readonly rtt;
    private latestRtt;
    private pathInfo;
    private bytes;
    private counts;
    private peer;
    private lastReceived;
    private activityTimeoutMs;
    private tick;
    private ticks;
    private readingStats;
    /** @internal the first read of the selected candidate pair (`dialRtc` waits for it: the path is known at once). */
    readonly firstStats: Promise<void>;
    private readonly pathListeners;
    private early;
    private restartIce;
    private recoveringSince;
    private readonly recoveringListeners;
    /** ICE restarts that found a new path. */
    private restarts;
    /** The running speed test hears its `link.probe.*` replies here. */
    private probeListener;
    /** @internal use `dialRtc` */
    constructor(p: SessionParts);
    /**
     * How long silence from the server may last before the session ends: `ms` while the app expects traffic (a video
     * stream open: `ACTIVE_IDLE_MS`), null for `IDLE_MS` again. Anything received (control or datagram) counts.
     */
    setActivityTimeout(ms: number | null): void;
    /** The server's identity as it says (`welcome.server`). */
    get server(): Welcome["server"];
    /** Who the server says this client is (`welcome.principal`). */
    get principal(): unknown;
    /** Largest datagram payload (bytes). */
    get maxDatagramSize(): number;
    get isClosed(): boolean;
    /** The path was lost and ICE restarts are looking for a new one (the session goes on if one is found). */
    get recovering(): boolean;
    /** How many times a lost path was found again (ICE restarts that worked). */
    get recoveries(): number;
    /** Hears `recovering` change (true: the path is lost, false: found again; the session's end is `closed`). */
    onRecovering(listener: (recovering: boolean) => void): () => void;
    /** Sends a control message (not `hello` / `welcome` / `denied`). Throws `closed` once the session ended. */
    sendControl(message: ControlMessage): void;
    /** Hears every control message from the server but `link.stats` (kept: `peerStats()`) and `bye`; returns the
     *  unsubscribe. */
    onControl(listener: (m: ControlMessage) => void): () => void;
    /** The control messages from now on, until the session ends. */
    controlMessages(): AsyncGenerator<ControlMessage>;
    /** One request (docs/LINK.md「RPC 流」); resolves with the answer once its head came. */
    request(request: RpcRequest, body?: Uint8Array): Promise<RpcResponse>;
    /**
     * `fetch` over RPC: `path` (with its query) and a `RequestInit` (method, headers, a string / bytes / Blob body;
     * `signal` cancels) → a `Response` streaming the answer's body. For code written against HTTP (a `ScreenTransport`).
     */
    fetch(path: string, init?: RequestInit): Promise<Response>;
    /** One datagram on an app channel (6–15). Dropped (counted) when `dgram`'s buffer is full or past the size. */
    sendDatagram(channel: number, payload: Uint8Array): void;
    /** @internal a datagram with its header byte (the media layer's and `sendDatagram`'s). */
    sendDatagramRaw(d: Uint8Array): void;
    /** Hears the datagrams of an app channel (6–15), payload without the header byte; returns the unsubscribe. */
    onDatagram(channel: number, listener: (payload: Uint8Array) => void): () => void;
    /** The selected candidate pair's path now. */
    path(): PathInfo;
    /** Hears path changes (kind or remote address); returns the unsubscribe. */
    onPath(listener: (p: PathInfo) => void): () => void;
    /** This side's stats now (what goes out as `link.stats` every 2 s) and the `link:` line's body. */
    stats(): SessionStats;
    /** The server's latest `link.stats` (null: none yet). */
    peerStats(): LinkStats | null;
    /** The latest RTT sample of the selected path (ms; null: none yet). */
    get rttMs(): number | null;
    /**
     * The speed test (docs/LINK.md「测速」): the computer sends filler frames through this session's video path for
     * `durationMs` (it keeps it within 1000–20000; 8000 lets the rate control's startup climb reach its ceiling) and
     * the report says what a picture would get. Run it on a session that shows no picture (open streams share the
     * rate). Throws `LinkError("unsupported")` when this build or the computer has no speed test (the computer: after
     * 3 s), `"closed"` when the session ends; `signal` stops it.
     */
    probe(durationMs?: number, opts?: {
        signal?: AbortSignal;
    }): Promise<ProbeReport>;
    /** Sends `bye` and closes (code `CloseCode.normal` by default). */
    close(code?: number, reason?: string): Promise<void>;
    /** Resolves when the session ended (by either side or the network). */
    closed(): Promise<CloseInfo>;
    /** How it ended (null: it hasn't). */
    get closeReason(): CloseInfo | null;
    /** Hears the end (at once when it ended already); returns the unsubscribe. */
    onClosed(listener: (info: CloseInfo) => void): () => void;
    private writeControl;
    private flushEarly;
    private onControlData;
    private dispatch;
    private receiveDatagram;
    private onTick;
    /** The selected candidate pair: its RTT, path and byte counts. */
    private readPeerStats;
    private readonly onNetworkChange;
    /** The path is lost (ICE says so, or nothing came for the idle limit): look for a new one when the server takes
     *  restarts, else end. `firstAfterMs`: how long it gets to come back by itself first. */
    private pathLost;
    /** Resolves once something came from the server after `since` (or after `ms`, or when the session ended). */
    private untilHeard;
    /**
     * Restarts ICE until the server is heard again over the path it finds (or `RECOVER_MS` passed, or the server
     * refused the restart: it doesn't know the connection any more). `lost`: the path is known to be gone (else this is
     * a network change with the old path maybe still working: `recovering` only shows once a restart didn't help).
     */
    private recover;
    private finish;
}
/** The selected candidate pair of a stats report (Chrome / Safari: the transport's; Firefox: `selected`). */
export declare function selectedPair(report: RTCStatsReport): (RTCIceCandidatePairStats & Record<string, unknown>) | undefined;
/** Resolves when `ch` sent what it buffered (or after `maxMs`). */
export declare function waitDrained(ch: RTCDataChannel, maxMs: number): Promise<void>;
