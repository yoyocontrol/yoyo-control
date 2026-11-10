import { LinkError } from "./errors.js";
import { encodeFrame, FrameReader, MAX_RPC_HEAD, messageBytes } from "./framing.js";
/** Messages a body goes in (well under every browser's SCTP max-message-size). */
export const RPC_CHUNK = 16 * 1024;
/** `readAll`'s default limit. */
export const RPC_READ_LIMIT = 64 * 1024 * 1024;
/**
 * Opens an `rpc` DataChannel (ordered, reliable, in-band) and sends the request on it: the head frame `{m, p, h}`, the
 * body in pieces, then a zero-length message (the FIN). Resolves with the response once its head came.
 */
export function rpcRequest(pc, req, body, timeoutMs) {
    const ch = pc.createDataChannel("rpc", { ordered: true });
    ch.binaryType = "arraybuffer";
    const response = new RpcResponse(ch);
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => fail(new LinkError("timeout", `no answer to ${req.method} ${req.path} in ${timeoutMs} ms`)), timeoutMs);
        const fail = (e) => {
            clearTimeout(timer);
            response.cancel();
            reject(e);
        };
        response.onHead = (err) => {
            clearTimeout(timer);
            if (err)
                reject(err);
            else
                resolve(response);
        };
        ch.addEventListener("open", () => {
            try {
                const head = { m: req.method.toUpperCase(), p: req.path, h: lowerHeaders(req.headers ?? {}) };
                ch.send(encodeFrame(head, MAX_RPC_HEAD));
                const b = body ?? new Uint8Array(0);
                for (let i = 0; i < b.length; i += RPC_CHUNK)
                    ch.send(b.slice(i, i + RPC_CHUNK));
                ch.send(new Uint8Array(0));
            }
            catch (e) {
                fail(e instanceof LinkError ? e : new LinkError("closed", e instanceof Error ? e.message : String(e)));
            }
        });
    });
}
function lowerHeaders(h) {
    const out = {};
    for (const [k, v] of Object.entries(h))
        if (k.toLowerCase() !== "host")
            out[k.toLowerCase()] = String(v);
    return out;
}
/**
 * The answer of one RPC: its status and headers, then the body as it streams in (`/events`' NDJSON, a file) until
 * the server's FIN. A channel closed without the FIN is a reset: the body ends with an error, not truncated.
 */
export class RpcResponse {
    ch;
    /** HTTP status (0 until the head came). */
    status = 0;
    /** The response headers (lower-case names). */
    headers = {};
    /** @internal the head came (or failed) */
    onHead = null;
    reader = new FrameReader(MAX_RPC_HEAD);
    gotHead = false;
    chunks = [];
    done = false;
    error = null;
    wake = null;
    /** @internal */
    constructor(ch) {
        this.ch = ch;
        ch.addEventListener("message", (ev) => this.message(ev.data));
        ch.addEventListener("close", () => this.end(this.done ? null : new LinkError("closed", "the request was reset")));
        ch.addEventListener("error", () => this.end(new LinkError("closed", "the request channel failed")));
    }
    message(data) {
        if (this.done)
            return;
        let bytes;
        try {
            bytes = messageBytes(data);
        }
        catch (e) {
            this.end(e);
            return;
        }
        if (!this.gotHead) {
            if (bytes.length === 0) {
                this.end(new LinkError("protocol", "the response ended before its head"));
                return;
            }
            try {
                this.reader.append(bytes);
                const head = this.reader.next();
                if (!head)
                    return;
                this.gotHead = true;
                this.status = typeof head.s === "number" ? head.s : 0;
                const h = head.h && typeof head.h === "object" ? head.h : {};
                for (const [k, v] of Object.entries(h))
                    this.headers[k.toLowerCase()] = String(v);
                const rest = this.reader.rest();
                if (rest.length)
                    this.chunks.push(rest);
                this.onHead?.(null);
                this.onHead = null;
            }
            catch (e) {
                this.end(e instanceof LinkError ? e : new LinkError("protocol", String(e)));
            }
            return;
        }
        if (bytes.length === 0) {
            // the FIN: the body is complete
            this.done = true;
            this.wake?.();
            this.ch.close();
            return;
        }
        this.chunks.push(bytes);
        this.wake?.();
    }
    end(err) {
        if (this.done && !err)
            return;
        if (!this.done) {
            this.done = true;
            this.error = err;
        }
        if (this.onHead) {
            this.onHead(err ?? new LinkError("closed", "the request ended before its head"));
            this.onHead = null;
        }
        this.wake?.();
    }
    /** The next piece of the body; null at its end. Throws `closed` when the request was reset. */
    async chunk() {
        for (;;) {
            const c = this.chunks.shift();
            if (c)
                return c;
            if (this.done) {
                if (this.error)
                    throw this.error;
                return null;
            }
            await new Promise((r) => (this.wake = r));
            this.wake = null;
        }
    }
    /** The rest of the body (at most `limit` bytes: more is an error). */
    async readAll(limit = RPC_READ_LIMIT) {
        const parts = [];
        let n = 0;
        for (let c = await this.chunk(); c; c = await this.chunk()) {
            n += c.length;
            if (n > limit) {
                this.cancel();
                throw new LinkError("protocol", `the response body is over ${limit} bytes`);
            }
            parts.push(c);
        }
        const out = new Uint8Array(n);
        let at = 0;
        for (const p of parts) {
            out.set(p, at);
            at += p.length;
        }
        return out;
    }
    async text() {
        return new TextDecoder().decode(await this.readAll());
    }
    async json() {
        return JSON.parse(await this.text());
    }
    async *[Symbol.asyncIterator]() {
        for (let c = await this.chunk(); c; c = await this.chunk())
            yield c;
    }
    /** Stops reading: the channel closes (the server's writes fail, a streamed answer ends). */
    cancel() {
        if (!this.done) {
            this.done = true;
            this.error = new LinkError("closed", "cancelled");
            this.wake?.();
        }
        if (this.ch.readyState === "open" || this.ch.readyState === "connecting")
            this.ch.close();
    }
    /** As a fetch `Response` (status, headers, the body streamed): for code written against HTTP. */
    toResponse() {
        const self = this;
        const body = new ReadableStream({
            async pull(c) {
                try {
                    const chunk = await self.chunk();
                    if (chunk)
                        c.enqueue(chunk);
                    else
                        c.close();
                }
                catch (e) {
                    c.error(e);
                }
            },
            cancel() {
                self.cancel();
            },
        });
        const nullBody = this.status === 204 || this.status === 304;
        return new Response(nullBody ? null : body, { status: this.status >= 200 && this.status <= 599 ? this.status : 502, headers: this.headers });
    }
}
