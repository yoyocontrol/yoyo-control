import { request as httpRequest, type IncomingHttpHeaders, type IncomingMessage } from "node:http";
import type { Readable } from "node:stream";

/** Where a server listens: a unix socket (the app's, a child's) or TCP (a remote server, tests). */
export type Target = { socketPath: string } | { host: string; port: number };

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
export function rawRequest(target: Target, method: string, path: string, opts: RawRequestOptions = {}): Promise<RawResponse> {
  let headers = opts.headers ?? {};
  if (opts.token) headers = { ...headers, authorization: `Bearer ${opts.token}` };
  return new Promise((resolve, reject) => {
    const payload = opts.body === undefined ? undefined : Buffer.from(JSON.stringify(opts.body));
    const req = httpRequest(
      {
        ...target,
        path,
        method,
        headers: payload ? { ...headers, "content-type": "application/json", "content-length": payload.length } : headers,
        ...(opts.signal ? { signal: opts.signal } : {}),
      },
      (res) => resolve({ status: res.statusCode ?? 502, headers: res.headers, body: res }),
    );
    req.on("error", reject);
    req.end(payload);
  });
}

/** The whole body. */
export async function readAll(stream: Readable): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const c of stream) chunks.push(c as Buffer);
  return Buffer.concat(chunks);
}

/** JSON of a body, or null when it isn't. */
export function safeJson(buf: Buffer): unknown {
  try {
    return JSON.parse(buf.toString("utf8"));
  } catch {
    return null;
  }
}

/** A `?a=1&b=2` query of the defined values ("" when there are none). */
export function query(p: object): string {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(p)) if (v !== undefined) q.set(k, String(v));
  const s = q.toString();
  return s ? `?${s}` : "";
}

/** An `Accept` to pass on to the server (a stream's / the sound's media type names), when there is one. */
export function acceptHeader(accept: string | undefined): Record<string, string> {
  return accept?.trim() ? { accept: accept.trim().slice(0, 500) } : {};
}
