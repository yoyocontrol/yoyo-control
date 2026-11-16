import { LinkError } from "./errors.js";

// The credit window over WebRTC (docs/LINK.md「信用窗口」), as the Rust core's: a data channel has no receive window,
// so each `rpc` channel's receiver grants the sender bytes as its reader takes them, and the sender waits for them.
// Both sides count the same way: each non-empty binary message's length plus `CREDIT_MESSAGE_COST` (the FIN is free).
// Grants are text messages on the channel, `{"credit": <total granted>}` (the stream's own messages are binary).

/** The `hello` / `welcome` feature: both say it, or neither side uses the window (then the receive bounds and their
 *  resets are all there is). */
export const CREDIT_FEATURE = "credit";
/** What one message costs on top of its length. */
export const CREDIT_MESSAGE_COST = 64;
/** Each stream's window to start with (each direction), and what it keeps whatever the session's pool. */
export const CREDIT_INITIAL = 64 * 1024;
/** The most a receiver lets a stream's sender have unread. */
export const CREDIT_WINDOW = 1024 * 1024;
/** A session's pool (`RTC_SESSION_RECV_MAX`): a window grows past `CREDIT_INITIAL` only as far as the other streams'
 *  unread bytes leave room. Fairness, not the memory bound: that is each stream's window (32 x 1 MiB unread per
 *  session at most on the server's side). */
export const CREDIT_POOL = 8 * 1024 * 1024;
/** A grant goes out once it would add at least this much… */
const MIN_GRANT = 64 * 1024;
/** …or whenever the sender has less left than its largest message costs (16 KiB + 64: it couldn't send at all). */
const CHUNK_COST = 16 * 1024 + CREDIT_MESSAGE_COST;

/** What a message of `n` bytes costs (0: a FIN). */
export function messageCost(n: number): number {
  return n === 0 ? 0 : n + CREDIT_MESSAGE_COST;
}

/** @internal A session's receiving side: the pool its streams' windows share. */
export class CreditPool {
  readonly streams = new Set<ChannelCredit>();
  /** A grant was held back for the pool: try every stream again as it frees. */
  starved = false;

  /** What the streams but `except` hold of the pool: what came on them and wasn't read (memory, as QUIC's
   *  connection window counts it — not credit given and unused: an idle stream holds none). */
  used(except: ChannelCredit): number {
    let n = 0;
    for (const s of this.streams) if (s !== except) n += s.unread;
    return n;
  }

  regrantAll(): void {
    this.starved = false;
    for (const s of this.streams) s.grant();
  }
}

/** @internal One `rpc` channel's credit, both directions. */
export class ChannelCredit {
  /** Receiving: what this side allowed (the initial window and every grant). */
  private granted = CREDIT_INITIAL;
  /** Receiving: what came. */
  private received = 0;
  /** Receiving: what the reader took. */
  private consumed = 0;
  /** Sending: what the peer allowed. */
  private peerGranted = CREDIT_INITIAL;
  /** Sending: what went. */
  private sent = 0;
  private ended = false;
  /** A grant's send failed (the browser's queue was full): tried again at `bufferedamountlow` or the next read. */
  private pending = false;
  private readonly onGrant: (() => void)[] = [];

  constructor(
    private readonly ch: RTCDataChannel,
    private readonly pool: CreditPool,
  ) {
    pool.streams.add(this);
    ch.addEventListener("message", (ev) => {
      if (typeof ev.data !== "string") return;
      let n: unknown;
      try {
        n = (JSON.parse(ev.data) as { credit?: unknown }).credit;
      } catch {
        return;
      }
      if (typeof n === "number" && n > this.peerGranted) {
        this.peerGranted = n;
        for (const f of this.onGrant) f();
      }
    });
    ch.addEventListener("close", () => this.end());
    ch.addEventListener("error", () => this.end());
    ch.addEventListener("bufferedamountlow", () => {
      if (this.pending) this.grant();
    });
  }

  /** What the peer may still send plus what waits unread. */
  get commitment(): number {
    return this.granted - this.consumed;
  }

  /** What came and wasn't read. */
  get unread(): number {
    return this.received - this.consumed;
  }

  /** `f` runs at every grant from the peer (a waiting send may go on). */
  onPeerGrant(f: () => void): void {
    this.onGrant.push(f);
  }

  /** Receiving: a message of `n` bytes came; false when it went past the window (the peer broke the protocol). */
  arrive(n: number): boolean {
    this.received += messageCost(n);
    return this.received <= this.granted;
  }

  /** Receiving: the reader took `cost` (`messageCost` of what came); grants (`grant`). */
  consume(cost: number): void {
    if (cost <= 0 && !this.pending) return;
    this.consumed += cost;
    this.grant();
    if (this.pool.starved) this.pool.regrantAll();
  }

  /** @internal Tops the window up to `CREDIT_WINDOW` past what was read, as far as the pool allows (the initial
   *  window always): once half of it is used (at least `MIN_GRANT` more), or at once when the sender has less left
   *  than a message costs. */
  grant(): void {
    if (this.ended || this.ch.readyState !== "open") return;
    const room = Math.max(0, CREDIT_POOL - this.pool.used(this));
    const target = Math.min(CREDIT_WINDOW, CREDIT_INITIAL + room);
    if (target < CREDIT_WINDOW) this.pool.starved = true;
    const granted = this.consumed + target;
    if (granted <= this.granted) return;
    const worth = this.commitment <= CREDIT_WINDOW / 2 && granted - this.granted >= MIN_GRANT;
    if (!worth && this.granted - this.received >= CHUNK_COST) return;
    // counted as given only once it went (else the server waits for credit this side thinks it has)
    try {
      this.ch.send(JSON.stringify({ credit: granted }));
    } catch {
      this.pending = this.ch.readyState === "open";
      return;
    }
    this.pending = false;
    this.granted = granted;
  }

  /** Sending: whether a message of `n` bytes fits the peer's window. */
  canSend(n: number): boolean {
    return this.sent + messageCost(n) <= this.peerGranted;
  }

  /** Sending: a message of `n` bytes went. */
  spent(n: number): void {
    this.sent += messageCost(n);
  }

  /** The channel is done: its window leaves the pool. */
  end(): void {
    if (this.ended) return;
    this.ended = true;
    this.pool.streams.delete(this);
    for (const f of this.onGrant) f();
    if (this.pool.starved) this.pool.regrantAll();
  }
}

/** @internal Where a channel's sender waits: for room in its buffer (`high` unsent at most; `bufferedamountlow`)
 *  and, under the window, for the peer's credit. One per channel. */
export class SendGate {
  private waiters: (() => void)[] = [];

  constructor(
    private readonly ch: RTCDataChannel,
    private readonly high: number,
    readonly credit: ChannelCredit | null,
  ) {
    ch.bufferedAmountLowThreshold = high / 2;
    ch.addEventListener("bufferedamountlow", () => this.wake());
    ch.addEventListener("close", () => this.wake());
    ch.addEventListener("error", () => this.wake());
    credit?.onPeerGrant(() => this.wake());
  }

  /** Wakes every waiting `room` (to look again: the stream may be over). */
  wake(): void {
    for (const w of this.waiters.splice(0)) w();
  }

  /** Until a message of `n` bytes may go; `check` throws once the stream is over (it runs at every look). */
  async room(n: number, check: () => void): Promise<void> {
    for (;;) {
      check();
      if (this.ch.readyState !== "open") throw new LinkError("closed", "the stream is closed");
      if (this.ch.bufferedAmount <= this.high && (!this.credit || this.credit.canSend(n))) return;
      await new Promise<void>((r) => this.waiters.push(r));
    }
  }

  /** Sends `bytes` (after `room`), counting it against the peer's window. */
  send(bytes: Uint8Array<ArrayBuffer>): void {
    try {
      this.ch.send(bytes);
    } catch (e) {
      throw new LinkError("closed", e instanceof Error ? e.message : String(e));
    }
    this.credit?.spent(bytes.length);
  }
}
