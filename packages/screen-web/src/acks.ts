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
export function ackOutcome(status: number): { outcome: AckOutcome; ends: boolean } {
  if (status >= 200 && status < 300) return { outcome: "ok", ends: false };
  if (status === 404) return { outcome: "gone", ends: false };
  if (status >= 400 && status < 500 && status !== 408 && status !== 429) return { outcome: "gone", ends: true };
  return { outcome: "failed", ends: false };
}

export const MAX_IN_FLIGHT = 4;
export const RETRY_MS = 100;
/** An ack that hasn't come back by then is given up (it would hold an in-flight slot): iOS 1.5 s. */
export const ACK_TIMEOUT_MS = 1500;

export class AckSender {
  private newest: number | null = null;
  /** Highest seq sent (in flight or acked). */
  private sent: number | null = null;
  private wantKey = false;
  private report: PlayoutReport | null = null;
  private inFlight = 0;
  private stopped = false;
  private retryTimer: ReturnType<typeof setTimeout> | null = null;

  constructor(
    readonly stream: string,
    private readonly transport: AckTransport,
    private readonly schedule: (fn: () => void, ms: number) => ReturnType<typeof setTimeout> = (fn, ms) => setTimeout(fn, ms),
  ) {}

  get acksInFlight(): number {
    return this.inFlight;
  }
  get isStopped(): boolean {
    return this.stopped;
  }

  /** A whole picture part arrived (before it is decoded). */
  received(seq: number): void {
    if (this.newest === null || seq > this.newest) this.newest = seq;
    this.pump();
  }

  /** The decoder needs a key picture: asked for with the next ack (right away when a slot is free). */
  requestKeyframe(): void {
    this.wantKey = true;
    this.pump();
  }

  /** A playout report: it goes with the next ack (a newer one replaces it while it waits). */
  attach(report: PlayoutReport): void {
    this.report = report;
  }

  stop(): void {
    this.stopped = true;
    if (this.retryTimer) clearTimeout(this.retryTimer);
    this.retryTimer = null;
  }

  private pump(): void {
    if (this.stopped || this.inFlight >= MAX_IN_FLIGHT || this.newest === null) return;
    const newest = this.newest;
    const fresh = this.sent === null || newest > this.sent;
    if (!fresh && !this.wantKey) return;
    this.inFlight++;
    if (fresh) this.sent = newest;
    const ack: StreamAck = { stream: this.stream, seq: newest };
    if (this.wantKey) ack.keyframe = true;
    if (this.report) ack.report = this.report;
    this.wantKey = false;
    this.report = null;
    this.transport(ack).then(
      (o) => this.finished(ack, o),
      () => this.finished(ack, "failed"),
    );
  }

  private finished(ack: StreamAck, outcome: AckOutcome): void {
    this.inFlight--;
    if (this.stopped) return;
    switch (outcome) {
      case "ok":
        this.pump();
        return;
      case "gone":
        this.stop();
        return;
      case "failed":
        // again shortly, not right away (a dead network would spin)
        if (ack.keyframe) this.wantKey = true;
        if (this.sent === ack.seq) this.sent = ack.seq - 1; // resend it even if nothing newer arrives
        if (!this.retryTimer)
          this.retryTimer = this.schedule(() => {
            this.retryTimer = null;
            this.pump();
          }, RETRY_MS);
        return;
    }
  }
}
