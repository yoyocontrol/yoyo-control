/** The `hello` / `welcome` feature: both say it, or neither side uses the window (then the receive bounds and their
 *  resets are all there is). */
export declare const CREDIT_FEATURE = "credit";
/** What one message costs on top of its length. */
export declare const CREDIT_MESSAGE_COST = 64;
/** Each stream's window to start with (each direction), and what it keeps whatever the session's pool. */
export declare const CREDIT_INITIAL: number;
/** The most a receiver lets a stream's sender have unread. */
export declare const CREDIT_WINDOW: number;
/** A session's pool (`RTC_SESSION_RECV_MAX`): a window grows past `CREDIT_INITIAL` only as far as the other streams'
 *  unread bytes leave room. Fairness, not the memory bound: that is each stream's window (32 x 1 MiB unread per
 *  session at most on the server's side). */
export declare const CREDIT_POOL: number;
/** What a message of `n` bytes costs (0: a FIN). */
export declare function messageCost(n: number): number;
/** @internal A session's receiving side: the pool its streams' windows share. */
export declare class CreditPool {
    readonly streams: Set<ChannelCredit>;
    /** A grant was held back for the pool: try every stream again as it frees. */
    starved: boolean;
    /** What the streams but `except` hold of the pool: what came on them and wasn't read (memory, as QUIC's
     *  connection window counts it — not credit given and unused: an idle stream holds none). */
    used(except: ChannelCredit): number;
    regrantAll(): void;
}
/** @internal One `rpc` channel's credit, both directions. */
export declare class ChannelCredit {
    private readonly ch;
    private readonly pool;
    /** Receiving: what this side allowed (the initial window and every grant). */
    private granted;
    /** Receiving: what came. */
    private received;
    /** Receiving: what the reader took. */
    private consumed;
    /** Sending: what the peer allowed. */
    private peerGranted;
    /** Sending: what went. */
    private sent;
    private ended;
    /** A grant's send failed (the browser's queue was full): tried again at `bufferedamountlow` or the next read. */
    private pending;
    private readonly onGrant;
    constructor(ch: RTCDataChannel, pool: CreditPool);
    /** What the peer may still send plus what waits unread. */
    get commitment(): number;
    /** What came and wasn't read. */
    get unread(): number;
    /** `f` runs at every grant from the peer (a waiting send may go on). */
    onPeerGrant(f: () => void): void;
    /** Receiving: a message of `n` bytes came; false when it went past the window (the peer broke the protocol). */
    arrive(n: number): boolean;
    /** Receiving: the reader took `cost` (`messageCost` of what came); grants (`grant`). */
    consume(cost: number): void;
    /** @internal Tops the window up to `CREDIT_WINDOW` past what was read, as far as the pool allows (the initial
     *  window always): once half of it is used (at least `MIN_GRANT` more), or at once when the sender has less left
     *  than a message costs. */
    grant(): void;
    /** Sending: whether a message of `n` bytes fits the peer's window. */
    canSend(n: number): boolean;
    /** Sending: a message of `n` bytes went. */
    spent(n: number): void;
    /** The channel is done: its window leaves the pool. */
    end(): void;
}
/** @internal Where a channel's sender waits: for room in its buffer (`high` unsent at most; `bufferedamountlow`)
 *  and, under the window, for the peer's credit. One per channel. */
export declare class SendGate {
    private readonly ch;
    private readonly high;
    readonly credit: ChannelCredit | null;
    private waiters;
    constructor(ch: RTCDataChannel, high: number, credit: ChannelCredit | null);
    /** Wakes every waiting `room` (to look again: the stream may be over). */
    wake(): void;
    /** Until a message of `n` bytes may go; `check` throws once the stream is over (it runs at every look). */
    room(n: number, check: () => void): Promise<void>;
    /** Sends `bytes` (after `room`), counting it against the peer's window. */
    send(bytes: Uint8Array<ArrayBuffer>): void;
}
