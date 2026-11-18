import { ChannelCredit, type CreditPool } from "./credit.js";
import { LinkError } from "./errors.js";
/** One request to the server's routes (docs/LINK.md「RPC 流」): `path` with its query; header names lower case. */
export interface RpcRequest {
    method: string;
    path: string;
    headers?: Record<string, string>;
}
/** Messages a body goes in (well under every browser's SCTP max-message-size). */
export declare const RPC_CHUNK: number;
/** `readAll`'s default limit. */
export declare const RPC_READ_LIMIT: number;
/** A request body's pieces wait while the channel holds more than this unsent (a browser refuses sends past its
 *  queue's size: Chrome's is 16 MiB); they go on at `bufferedamountlow` (half of it). */
export declare const RPC_SEND_HIGH: number;
/** @internal A request or stream the session ends itself when it ends (a closed peer connection needn't fire its
 *  channels' `close`). */
export interface SessionStream {
    sessionEnded(err: LinkError): void;
}
/**
 * Opens an `rpc` DataChannel (ordered, reliable, in-band) and sends the request on it: the head frame `{m, p, h}` and
 * the body in pieces (paced by the channel's buffer, `RPC_SEND_HIGH`, and under the credit window by the server's
 * grants), then a zero-length message (the FIN). Resolves with the response once its head came. `timeoutMs` is how
 * long the channel may take to open, an upload may go without progress, and the answer may take after the FIN (an
 * upload's own length doesn't count against it). `streams`: the session's open ones; `credit`: its pool, when both
 * sides took the credit window.
 */
export declare function rpcRequest(pc: RTCPeerConnection, req: RpcRequest, body: Uint8Array | undefined, timeoutMs: number, streams?: Set<SessionStream>, credit?: CreditPool | null): Promise<RpcResponse>;
/**
 * The answer of one RPC: its status and headers, then the body as it streams in (`/events`' NDJSON, a file) until
 * the server's FIN. A channel closed without the FIN is a reset: the body ends with an error, not truncated.
 */
export declare class RpcResponse {
    private readonly ch;
    private readonly credit;
    /** HTTP status (0 until the head came). */
    status: number;
    /** The response headers (lower-case names). */
    headers: Record<string, string>;
    /** @internal the head came (or failed) */
    onHead: ((err: LinkError | null) => void) | null;
    private readonly reader;
    private gotHead;
    /** The body's pieces as they came, each with what it costs against the window (granted again once read). */
    private chunks;
    private done;
    private error;
    private wake;
    private readonly gate;
    /** @internal `streams`: the session's open ones (it ends them when it ends); `credit`: the channel's, under the
     *  credit window */
    constructor(ch: RTCDataChannel, streams?: Set<SessionStream>, credit?: ChannelCredit | null);
    /** @internal the session ended: so does the exchange (a waiting head, body read or upload). */
    sessionEnded(err: LinkError): void;
    /** @internal Whether a request piece of `n` bytes may go now (buffer room, the server's credit). */
    canSend(n: number): boolean;
    /** @internal Until a request piece of `n` bytes may go; throws once the exchange is over (the answer complete, a
     *  reset, a cancel, the session's end). */
    room(n: number): Promise<void>;
    /** @internal Sends a request piece (counted against the server's window). */
    send(bytes: Uint8Array<ArrayBuffer>): void;
    private roomMade;
    private message;
    private end;
    /** The next piece of the body; null at its end. Throws `closed` when the request was reset. */
    chunk(): Promise<Uint8Array | null>;
    /** The rest of the body (at most `limit` bytes: more is an error). */
    readAll(limit?: number): Promise<Uint8Array>;
    text(): Promise<string>;
    json(): Promise<unknown>;
    [Symbol.asyncIterator](): AsyncIterator<Uint8Array>;
    /** Stops reading: the channel closes (the server's writes fail, a streamed answer ends). */
    cancel(): void;
    /** As a fetch `Response` (status, headers, the body streamed): for code written against HTTP. */
    toResponse(): Response;
}
