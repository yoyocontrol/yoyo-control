import { type IncomingHttpHeaders, type IncomingMessage } from "node:http";
import type { Readable } from "node:stream";
/** Where a server listens: a unix socket (the app's, a child's) or TCP (a remote server, tests). */
export type Target = {
    socketPath: string;
} | {
    host: string;
    port: number;
};
/** A response whose body is still streaming. */
export interface RawResponse {
    status: number;
    headers: IncomingHttpHeaders;
    body: IncomingMessage;
}
export interface RawRequestOptions {
    /** Sent as JSON (with its content-type and content-length). */
    body?: unknown;
    signal?: AbortSignal;
    headers?: Record<string, string>;
    /** `Authorization: Bearer <token>` (a TCP server; a unix socket is guarded by its file permissions). */
    token?: string;
}
/** One HTTP/1.1 request; resolves when the response headers arrive. */
export declare function rawRequest(target: Target, method: string, path: string, opts?: RawRequestOptions): Promise<RawResponse>;
/** The whole body. */
export declare function readAll(stream: Readable): Promise<Buffer>;
/** JSON of a body, or null when it isn't. */
export declare function safeJson(buf: Buffer): unknown;
/** A `?a=1&b=2` query of the defined values ("" when there are none). */
export declare function query(p: object): string;
/** An `Accept` to pass on to the server (a stream's / the sound's media type names), when there is one. */
export declare function acceptHeader(accept: string | undefined): Record<string, string>;
