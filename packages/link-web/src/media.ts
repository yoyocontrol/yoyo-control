import { LinkError, LinkRequestError } from "./errors.js";
import type { ClientMediaEngine, MediaCounters, MediaEvent, ProbeCounters, RxTrace } from "./wasm.js";

/**
 * A session's media layer, driven (docs/LINK.md「媒体」): the `dgram` channel's media datagrams (channels 1–5) go
 * into the wasm `ClientMedia`, what it hands out goes back on `dgram`, its events go to the listeners, and one timer
 * runs at its `pollTimeout`. Every call runs the loop once (there may be datagrams or events now). Main thread; the
 * wasm calls are cheap.
 */
export class LinkMedia {
  private readonly listeners = new Set<(e: MediaEvent) => void>();
  private timer: ReturnType<typeof setTimeout> | null = null;
  private timerAt = Infinity;
  private pumping = false;
  private ended = false;
  private usedFlag = false;

  /**
   * `send`: one datagram onto `dgram` (false: dropped, counted by the session). `now`: the media clock in µs
   * (monotonic; the session's `performance.now()`-based one).
   */
  constructor(
    private readonly engine: ClientMediaEngine,
    private readonly send: (datagram: Uint8Array) => void,
    readonly now: () => number,
  ) {}

  /** Media flowed (a stream opened, a datagram, an input): `link.stats` gets the media fields. */
  get used(): boolean {
    return this.usedFlag;
  }

  /** Hears every media event, in order; returns the unsubscribe. */
  onEvent(listener: (e: MediaEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  /** A datagram of channels 1–5 from the server. False: the media layer refused it (malformed / not for this side). */
  datagram(bytes: Uint8Array): boolean {
    if (this.ended) return false;
    this.usedFlag = true;
    const ok = this.engine.onDatagram(bytes, this.now());
    this.pump();
    return ok;
  }

  /** The transport's facts: the selected path's RTT (ms) and the largest datagram. */
  setTransport(rttMs: number | null, maxDatagram: number): void {
    if (this.ended) return;
    if (rttMs !== null && rttMs > 0) this.engine.setRtt(this.now(), rttMs * 1000);
    this.engine.setMaxDatagram(maxDatagram);
  }

  /** Start receiving video stream `stream` (call before `video.open`: pictures may beat `video.opened`). */
  openVideo(stream: number): void {
    this.call((e) => e.openVideo(stream));
  }

  closeVideo(stream: number): void {
    this.call((e) => e.closeVideo(stream));
  }

  openAudio(stream: number): void {
    this.call((e) => e.openAudio(stream));
  }

  /** The media layer has the speed test's receiving side (docs/LINK.md「测速」). */
  get canProbe(): boolean {
    return !this.ended && typeof this.engine.openProbe === "function";
  }

  /** The highest video stream id not open (null: none, or no speed test in this build). */
  freeVideoStream(): number | null {
    if (this.ended || !this.engine.hasVideo) return null;
    for (let s = 255; s >= 1; s--) if (!this.engine.hasVideo(s)) return s;
    return null;
  }

  /** Opens `stream` for a speed test: its frames are acknowledged and counted inside, never events. */
  openProbe(stream: number): void {
    this.call((e) => e.openProbe?.(stream, this.now()));
  }

  /** A speed-test stream's counters (null: not one). */
  probeCounters(stream: number): ProbeCounters | null {
    return this.ended ? null : (this.engine.probeStats?.(stream, this.now()) ?? null);
  }

  closeAudio(stream: number): void {
    this.call((e) => e.closeAudio(stream));
  }

  /** The decoder took (`ok`) or failed on a frame (`ok = false` asks for a key frame). */
  frameDecoded(stream: number, frame: number, ok: boolean): void {
    this.call((e) => e.frameDecoded(stream, frame, ok));
  }

  /** The decoder can't go on: a key frame. */
  requestKeyframe(stream: number): void {
    this.call((e) => e.requestKeyframe(stream));
  }

  /**
   * One input event (`/input`'s JSON): `move` = a pointer move (the newest wins), else discrete (exactly once, in
   * order). Returns its seq. Throws `LinkRequestError(429)` when too many discrete events wait for their ack, and
   * `LinkError("closed")` after the session ended.
   */
  sendInput(json: string, move: boolean): number {
    if (this.ended) throw new LinkError("closed", "the session ended");
    this.usedFlag = true;
    let seq: number;
    try {
      seq = this.engine.sendInput(this.now(), json, move);
    } catch (e) {
      if (e === "overflow") throw new LinkRequestError(429, "too many input events waiting", { error: "too many input events waiting" });
      throw new LinkError("media", typeof e === "string" ? `input ${e}` : String(e));
    }
    this.pump();
    return seq;
  }

  /** Discrete input events waiting for an ack. */
  get inputUnacked(): number {
    return this.ended ? 0 : this.engine.inputUnacked();
  }

  /** The counters since the session started (null after it ended). */
  counters(): MediaCounters | null {
    return this.ended ? null : this.engine.stats(this.now());
  }

  /** Every frame's fate since the last call. */
  takeRxTraces(): RxTrace[] {
    return this.ended ? [] : this.engine.takeRxTraces();
  }

  /** Malformed datagrams so far. */
  get malformed(): number {
    return this.ended ? 0 : this.engine.malformed();
  }

  /** The session ended: no more calls, the wasm memory goes. */
  end(): void {
    if (this.ended) return;
    this.ended = true;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.listeners.clear();
    this.engine.free();
  }

  private call(f: (e: ClientMediaEngine) => void): void {
    if (this.ended) return;
    this.usedFlag = true;
    f(this.engine);
    this.pump();
  }

  /** Datagrams out, events out, the timer re-armed. Re-entrant calls (a listener calling back in) fold into this one. */
  private pump(): void {
    if (this.pumping || this.ended) return;
    this.pumping = true;
    try {
      for (let round = 0; round < 64; round++) {
        const now = this.now();
        let any = false;
        for (let d = this.engine.pollTransmit(now); d; d = this.engine.pollTransmit(now)) {
          any = true;
          this.send(d);
        }
        for (let e = this.engine.pollEvent(); e; e = this.engine.pollEvent()) {
          any = true;
          for (const l of this.listeners) {
            try {
              l(e);
            } catch (err) {
              // a listener's bug must not stop the media loop
              queueMicrotask(() => {
                throw err;
              });
            }
            if (this.ended) return;
          }
        }
        if (!any) break;
      }
      this.arm();
    } finally {
      this.pumping = false;
    }
  }

  private arm(): void {
    const now = this.now();
    const t = this.engine.pollTimeout(now);
    if (t === undefined) {
      if (this.timer) clearTimeout(this.timer);
      this.timer = null;
      this.timerAt = Infinity;
      return;
    }
    // everything queued went out: a timer at or before now would only spin
    const at = Math.max(t, now + 1000);
    if (this.timer && Math.abs(at - this.timerAt) < 500) return;
    if (this.timer) clearTimeout(this.timer);
    this.timerAt = at;
    this.timer = setTimeout(() => {
      this.timer = null;
      this.timerAt = Infinity;
      if (this.ended) return;
      this.engine.handleTimeout(this.now());
      this.pump();
    }, (at - now) / 1000);
  }
}
