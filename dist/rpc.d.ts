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
/**
 * Opens an `rpc` DataChannel (ordered, reliable, in-band) and sends the request on it: the head frame `{m, p, h}`, the
 * body in pieces, then a zero-length message (the FIN). Resolves with the response once its head came.
 */
export declare function rpcRequest(pc: RTCPeerConnection, req: RpcRequest, body: Uint8Array | undefined, timeoutMs: number): Promise<RpcResponse>;
/**
 * The answer of one RPC: its status and headers, then the body as it streams in (`/events`' NDJSON, a file) until
 * the server's FIN. A channel closed without the FIN is a reset: the body ends with an error, not truncated.
 */
export declare class RpcResponse {
    private readonly ch;
    /** HTTP status (0 until the head came). */
    status: number;
    /** The response headers (lower-case names). */
    headers: Record<string, string>;
    /** @internal the head came (or failed) */
    onHead: ((err: LinkError | null) => void) | null;
    private readonly reader;
    private gotHead;
    private chunks;
    private done;
    private error;
    private wake;
    /** @internal */
    constructor(ch: RTCDataChannel);
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
