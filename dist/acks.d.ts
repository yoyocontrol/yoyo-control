import type { PlayoutReport, StreamAck } from "./types.js";
/**
 * Acks of one screen stream (`POST /stream/ack`, docs/PROTOCOL.md「确认与流控」), as the iOS ScreenAckSender: each
 * picture part is acked as soon as it is whole (before it is decoded), cumulatively, up to `MAX_IN_FLIGHT` acks at
 * once; beyond that only the newest seq is remembered and sent when one returns (one at a time is not enough: a
 * picture arriving while the previous ack is out would wait a whole round trip, which the server reads as queueing).
 * A key picture request and a playout report ride on the next ack. 404 (the stream is gone) stops acking; a failure
 * is sent again after `RETRY_MS` (the server holds pictures back until it is acked).
 */
export type AckOutcome = "ok" | "gone" | "failed";
export type AckTransport = (ack: StreamAck) => Promise<AckOutcome>;
/**
 * What an ack's HTTP status means: 2xx ok; 404 (no such stream) gone; 5xx (and network errors / timeouts, outside
 * this) failed, sent again shortly; any other 4xx is no answer that will change by retrying (401 after a sign-in
 * expired, 403, 400, 413): gone, and `ends` — the stream itself ends with it (the page decides what next by the status).
 */
export declare function ackOutcome(status: number): {
    outcome: AckOutcome;
    ends: boolean;
};
export declare const MAX_IN_FLIGHT = 4;
export declare const RETRY_MS = 100;
/** An ack that hasn't come back by then is given up (it would hold an in-flight slot): iOS 1.5 s. */
export declare const ACK_TIMEOUT_MS = 1500;
export declare class AckSender {
    readonly stream: string;
    private readonly transport;
    private readonly schedule;
    private newest;
    /** Highest seq sent (in flight or acked). */
    private sent;
    private wantKey;
    private report;
    private inFlight;
    private stopped;
    private retryTimer;
    constructor(stream: string, transport: AckTransport, schedule?: (fn: () => void, ms: number) => ReturnType<typeof setTimeout>);
    get acksInFlight(): number;
    get isStopped(): boolean;
    /** A whole picture part arrived (before it is decoded). */
    received(seq: number): void;
    /** The decoder needs a key picture: asked for with the next ack (right away when a slot is free). */
    requestKeyframe(): void;
    /** A playout report: it goes with the next ack (a newer one replaces it while it waits). */
    attach(report: PlayoutReport): void;
    stop(): void;
    private pump;
    private finished;
}
