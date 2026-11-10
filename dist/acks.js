/**
 * What an ack's HTTP status means: 2xx ok; 404 (no such stream) gone; 5xx (and network errors / timeouts, outside
 * this) failed, sent again shortly; any other 4xx is no answer that will change by retrying (401 after a sign-in
 * expired, 403, 400, 413): gone, and `ends` — the stream itself ends with it (the page decides what next by the status).
 */
export function ackOutcome(status) {
    if (status >= 200 && status < 300)
        return { outcome: "ok", ends: false };
    if (status === 404)
        return { outcome: "gone", ends: false };
    if (status >= 400 && status < 500 && status !== 408 && status !== 429)
        return { outcome: "gone", ends: true };
    return { outcome: "failed", ends: false };
}
export const MAX_IN_FLIGHT = 4;
export const RETRY_MS = 100;
/** An ack that hasn't come back by then is given up (it would hold an in-flight slot): iOS 1.5 s. */
export const ACK_TIMEOUT_MS = 1500;
export class AckSender {
    stream;
    transport;
    schedule;
    newest = null;
    /** Highest seq sent (in flight or acked). */
    sent = null;
    wantKey = false;
    report = null;
    inFlight = 0;
    stopped = false;
    retryTimer = null;
    constructor(stream, transport, schedule = (fn, ms) => setTimeout(fn, ms)) {
        this.stream = stream;
        this.transport = transport;
        this.schedule = schedule;
    }
    get acksInFlight() {
        return this.inFlight;
    }
    get isStopped() {
        return this.stopped;
    }
    /** A whole picture part arrived (before it is decoded). */
    received(seq) {
        if (this.newest === null || seq > this.newest)
            this.newest = seq;
        this.pump();
    }
    /** The decoder needs a key picture: asked for with the next ack (right away when a slot is free). */
    requestKeyframe() {
        this.wantKey = true;
        this.pump();
    }
    /** A playout report: it goes with the next ack (a newer one replaces it while it waits). */
    attach(report) {
        this.report = report;
    }
    stop() {
        this.stopped = true;
        if (this.retryTimer)
            clearTimeout(this.retryTimer);
        this.retryTimer = null;
    }
    pump() {
        if (this.stopped || this.inFlight >= MAX_IN_FLIGHT || this.newest === null)
            return;
        const newest = this.newest;
        const fresh = this.sent === null || newest > this.sent;
        if (!fresh && !this.wantKey)
            return;
        this.inFlight++;
        if (fresh)
            this.sent = newest;
        const ack = { stream: this.stream, seq: newest };
        if (this.wantKey)
            ack.keyframe = true;
        if (this.report)
            ack.report = this.report;
        this.wantKey = false;
        this.report = null;
        this.transport(ack).then((o) => this.finished(ack, o), () => this.finished(ack, "failed"));
    }
    finished(ack, outcome) {
        this.inFlight--;
        if (this.stopped)
            return;
        switch (outcome) {
            case "ok":
                this.pump();
                return;
            case "gone":
                this.stop();
                return;
            case "failed":
                // again shortly, not right away (a dead network would spin)
                if (ack.keyframe)
                    this.wantKey = true;
                if (this.sent === ack.seq)
                    this.sent = ack.seq - 1; // resend it even if nothing newer arrives
                if (!this.retryTimer)
                    this.retryTimer = this.schedule(() => {
                        this.retryTimer = null;
                        this.pump();
                    }, RETRY_MS);
                return;
        }
    }
}
