import { request as httpRequest } from "node:http";
/** One HTTP/1.1 request; resolves when the response headers arrive. */
export function rawRequest(target, method, path, opts = {}) {
    let headers = opts.headers ?? {};
    if (opts.token)
        headers = { ...headers, authorization: `Bearer ${opts.token}` };
    return new Promise((resolve, reject) => {
        const payload = opts.body === undefined ? undefined : Buffer.from(JSON.stringify(opts.body));
        const req = httpRequest({
            ...target,
            path,
            method,
            headers: payload ? { ...headers, "content-type": "application/json", "content-length": payload.length } : headers,
            ...(opts.signal ? { signal: opts.signal } : {}),
        }, (res) => resolve({ status: res.statusCode ?? 502, headers: res.headers, body: res }));
        req.on("error", reject);
        req.end(payload);
    });
}
/** The whole body. */
export async function readAll(stream) {
    const chunks = [];
    for await (const c of stream)
        chunks.push(c);
    return Buffer.concat(chunks);
}
/** JSON of a body, or null when it isn't. */
export function safeJson(buf) {
    try {
        return JSON.parse(buf.toString("utf8"));
    }
    catch {
        return null;
    }
}
/** A `?a=1&b=2` query of the defined values ("" when there are none). */
export function query(p) {
    const q = new URLSearchParams();
    for (const [k, v] of Object.entries(p))
        if (v !== undefined)
            q.set(k, String(v));
    const s = q.toString();
    return s ? `?${s}` : "";
}
/** An `Accept` to pass on to the server (a stream's / the sound's media type names), when there is one. */
export function acceptHeader(accept) {
    return accept?.trim() ? { accept: accept.trim().slice(0, 500) } : {};
}
