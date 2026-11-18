import { ChannelCredit, type CreditPool, SendGate } from "./credit.js";
import { LinkError } from "./errors.js";
import { type RpcRequest, type SessionStream } from "./rpc.js";
/** Largest message of a duplex stream (its payload; docs/LINK.md「RPC 流」「双工请求」). */
export declare const MAX_DUPLEX_MESSAGE: number;
/** The `welcome` feature of a server that takes duplex requests. */
export declare const DUPLEX_FEATURE = "duplex";
/** A stream's writes wait while its channel holds more than this unsent (as the server's rtc streams do). */
export declare const DUPLEX_SEND_HIGH: number;
/** What a stream may hold received and not yet read (the server's bound, `RTC_DUPLEX_RECV_MAX`): past it the stream
 *  is reset. Each message counts `DUPLEX_ENTRY_COST` more than its bytes. */
export declare const DUPLEX_RECV_MAX: number;
/** One message of a duplex stream (a WebSocket's: text, binary, or a close with its code). */
export type DuplexMessage = {
    type: "text";
    text: string;
} | {
    type: "binary";
    data: Uint8Array;
} | {
    type: "close";
    code: number;
    reason: string;
};
/** `u8 type + u32 BE length + payload`; a close's payload is `u16 BE code + reason`. Throws `protocol` past 1 MiB. */
export declare function encodeDuplexMessage(m: DuplexMessage): Uint8Array<ArrayBuffer>;
/** Bytes in (a data channel's messages carry the stream as bytes: a message may be split or several in one), messages out. */
export declare class DuplexReader {
    private buf;
    /** Appends `bytes`; returns every message now whole. Throws `protocol` on one over 1 MiB, an unknown type, bad UTF-8. */
    push(bytes: Uint8Array): DuplexMessage[];
    /** @internal `push` that keeps what came before a malformed message: every message now whole (with its size on the
     *  wire), and the error that stopped the reading (nothing after it is read). */
    take(bytes: Uint8Array): {
        messages: {
            message: DuplexMessage;
            size: number;
        }[];
        error: LinkError | null;
    };
    /** Bytes waiting for the rest of their message. */
    get pending(): number;
}
/**
 * An accepted duplex stream (docs/LINK.md「双工请求」): messages both ways, each at most 1 MiB, until either side
 * finishes. Over the `rpc` DataChannel it was asked on: messages as bytes in ≤ 16 KiB data-channel messages, a
 * zero-length message = this direction's FIN, the channel closed without one = a reset. The same shape as the Node
 * binding's `Duplex`.
 *
 * WebRTC has no half-close of a stream's incoming side: `cancel()` closes the channel, which ends both directions (the
 * server's writes fail, and so do this side's). And the server bounds what a stream may hold unread
 * (`RTC_DUPLEX_RECV_MAX`, about 2 MiB): sends wait while the channel's buffer is full, but a server that never reads
 * resets the stream instead of holding the client back as QUIC's flow control would. This side holds the server to
 * the same bound (`DUPLEX_RECV_MAX`).
 *
 * Sends (and `finish`) go out one after the other in the order they were called, each message whole: they needn't
 * be awaited one by one. Several `recv`s may wait at once (each gets its own message).
 */
export declare class Duplex {
    private readonly ch;
    private readonly gate;
    private readonly reader;
    private queue;
    /** What `queue` costs (bytes + `DUPLEX_ENTRY_COST` each). */
    private queued;
    private finIn;
    private finOut;
    private ended;
    private cancelled;
    private readers;
    private closedWaiters;
    private isClosed;
    /** The last queued write (send / finish): the next one goes after it. */
    private writing;
    private readonly credit;
    /** Under the window: the channel messages not yet released (their last byte's offset in the stream, their cost).
     *  One is granted again once every byte of it went to the app — or, while no whole message waits for the app, at
     *  once: a message still coming in (up to 1 MiB, more than the window with its overhead) must be able to finish. So
     *  what waits here is at most the window and one message. */
    private arrivals;
    /** Bytes of the stream that came, that were decoded, that went to the app (offsets). */
    private arrived;
    private decoded;
    private delivered;
    /** @internal `early`: bytes after the 101's head in the same message (`earlyCost`: that message's cost). */
    constructor(ch: RTCDataChannel, early: Uint8Array, gate: SendGate, earlyCost?: number);
    /** @internal the response's message handler hands this one over */
    message(bytes: Uint8Array): void;
    private take;
    private wakeReaders;
    private channelClosed;
    /** @internal the session ended: so does the stream, whether or not the channel says so (a closed peer connection
     *  needn't fire its channels' `close`). */
    sessionEnded(err: LinkError): void;
    /** Both directions done (this side's FIN sent, the other's received): the client closes the channel, as for any RPC. */
    private maybeClose;
    /** Sends one message, after the sends (and `finish`) called before it; waits while the channel's buffer is full.
     *  Throws `closed` once the stream is over, `protocol` past 1 MiB. */
    send(message: DuplexMessage): Promise<void>;
    /** Runs `f` once every write queued before it is done (failed or not): one message's chunks never mix with
     *  another's, and the FIN never lands inside one. */
    private serially;
    sendText(text: string): Promise<void>;
    sendBinary(data: Uint8Array): Promise<void>;
    /** Until a piece of `n` bytes may go (buffer room; under the window, the server's credit). */
    private room;
    /** The next message; `null` once the other side finished, or after `cancel` (a waiting one too). Throws `closed`
     *  when the stream was reset, `protocol` on a malformed message. */
    recv(): Promise<DuplexMessage | null>;
    /** Under the window: grants again what went to the app (`arrivals`). */
    private release;
    [Symbol.asyncIterator](): AsyncIterator<DuplexMessage>;
    /** Ends this side's direction (the FIN), after the sends called before it: the other side's `recv` ends. Waits
     *  for room like `send`. */
    finish(): Promise<void>;
    /** Stops reading: a waiting `recv` and every later one return `null`. Over WebRTC this closes the channel: the other
     *  side's sends fail, and so do this side's. */
    cancel(): void;
    /** Resolves when the other side stopped reading (the channel closed) or the session ended. */
    stopped(): Promise<void>;
}
/** The answer to a duplex request: accepted (101, `duplex`), or any other response (`readAll` for its body). */
export declare class DuplexResponse {
    private readonly ch;
    /** HTTP status: 101 = accepted. */
    status: number;
    /** The response headers (lower-case names). */
    headers: Record<string, string>;
    /** The accepted stream (status 101); `null` otherwise. */
    duplex: Duplex | null;
    /** @internal */
    onHead: ((err: LinkError | null) => void) | null;
    private readonly reader;
    private gotHead;
    private chunks;
    private done;
    private error;
    private wake;
    /** @internal the channel's sending side (the head here, then the stream's) */
    readonly gate: SendGate;
    private readonly credit;
    /** @internal `streams`: the session's open ones (it ends them when it ends); `credit`: the channel's, under the
     *  credit window */
    constructor(ch: RTCDataChannel, streams?: Set<SessionStream>, credit?: ChannelCredit | null);
    /** @internal the session ended: the stream (or the wait for the answer, or its body) ends with `err`. */
    sessionEnded(err: LinkError): void;
    private message;
    private end;
    /** Not accepted: the response's body (at most `limit` bytes). Accepted: empty. */
    readAll(limit?: number): Promise<Uint8Array>;
}
/**
 * Opens an `rpc` DataChannel and sends a duplex request's head (`"duplex": true`, no body, no FIN); resolves once the
 * answer's head came: 101 with the stream, or any other status with its body.
 */
export declare function duplexRequest(pc: RTCPeerConnection, req: RpcRequest, timeoutMs: number, streams?: Set<SessionStream>, credit?: CreditPool | null): Promise<DuplexResponse>;
