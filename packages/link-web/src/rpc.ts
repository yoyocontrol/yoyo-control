import { ChannelCredit, type CreditPool, messageCost, SendGate } from "./credit.js";
import { LinkError } from "./errors.js";
import { encodeFrame, FrameReader, MAX_RPC_HEAD, messageBytes } from "./framing.js";

/** One request to the server's routes (docs/LINK.md「RPC 流」): `path` with its query; header names lower case. */
export interface RpcRequest {
  method: string;
  path: string;
  headers?: Record<string, string>;
}

/** Messages a body goes in (well under every browser's SCTP max-message-size). */
export const RPC_CHUNK = 16 * 1024;
/** `readAll`'s default limit. */
export const RPC_READ_LIMIT = 64 * 1024 * 1024;
/** A request body's pieces wait while the channel holds more than this unsent (a browser refuses sends past its
 *  queue's size: Chrome's is 16 MiB); they go on at `bufferedamountlow` (half of it). */
export const RPC_SEND_HIGH = 1024 * 1024;

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
export function rpcRequest(
  pc: RTCPeerConnection,
  req: RpcRequest,
  body: Uint8Array | undefined,
  timeoutMs: number,
  streams?: Set<SessionStream>,
  credit?: CreditPool | null,
): Promise<RpcResponse> {
  const ch = pc.createDataChannel("rpc", { ordered: true });
  ch.binaryType = "arraybuffer";
  const response = new RpcResponse(ch, streams, credit ? new ChannelCredit(ch, credit) : null);
  return new Promise<RpcResponse>((resolve, reject) => {
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const arm = (what: string) => {
      clearTimeout(timer);
      timer = setTimeout(() => fail(new LinkError("timeout", `${what} ${req.method} ${req.path} in ${timeoutMs} ms`)), timeoutMs);
    };
    const fail = (e: LinkError) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      response.cancel();
      reject(e);
    };
    response.onHead = (err) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (err) reject(err);
      else resolve(response);
    };
    arm("no channel for");
    const upload = async () => {
      try {
        const head: Record<string, unknown> = { m: req.method.toUpperCase(), p: req.path, h: lowerHeaders(req.headers ?? {}) };
        if (!settled) arm("no progress sending");
        // the head too goes in pieces: each fits the initial window
        for (const part of [encodeFrame(head, MAX_RPC_HEAD), body ?? new Uint8Array(0)]) {
          for (let i = 0; i < part.length; i += RPC_CHUNK) {
            const piece = part.slice(i, i + RPC_CHUNK);
            if (!response.canSend(piece.length)) {
              await response.room(piece.length);
              if (!settled) arm("no progress sending");
            }
            response.send(piece);
          }
        }
        ch.send(new Uint8Array(0));
        // from here on the clock is the answer's
        if (!settled) arm("no answer to");
      } catch (e) {
        // (once the head came, the response says how the exchange ended)
        fail(e instanceof LinkError ? e : new LinkError("closed", e instanceof Error ? e.message : String(e)));
      }
    };
    ch.addEventListener("open", () => void upload());
  });
}

function lowerHeaders(h: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(h)) if (k.toLowerCase() !== "host") out[k.toLowerCase()] = String(v);
  return out;
}

/**
 * The answer of one RPC: its status and headers, then the body as it streams in (`/events`' NDJSON, a file) until
 * the server's FIN. A channel closed without the FIN is a reset: the body ends with an error, not truncated.
 */
export class RpcResponse {
  /** HTTP status (0 until the head came). */
  status = 0;
  /** The response headers (lower-case names). */
  headers: Record<string, string> = {};
  /** @internal the head came (or failed) */
  onHead: ((err: LinkError | null) => void) | null = null;
  private readonly reader = new FrameReader(MAX_RPC_HEAD);
  private gotHead = false;
  /** The body's pieces as they came, each with what it costs against the window (granted again once read). */
  private chunks: { bytes: Uint8Array; cost: number }[] = [];
  private done = false;
  private error: LinkError | null = null;
  private wake: (() => void) | null = null;
  private readonly gate: SendGate;

  /** @internal `streams`: the session's open ones (it ends them when it ends); `credit`: the channel's, under the
   *  credit window */
  constructor(
    private readonly ch: RTCDataChannel,
    streams?: Set<SessionStream>,
    private readonly credit: ChannelCredit | null = null,
  ) {
    this.gate = new SendGate(ch, RPC_SEND_HIGH, credit);
    ch.addEventListener("message", (ev) => this.message(ev.data));
    ch.addEventListener("close", () => this.end(this.done ? null : new LinkError("closed", "the request was reset")));
    ch.addEventListener("error", () => this.end(new LinkError("closed", "the request channel failed")));
    if (streams) {
      streams.add(this);
      const off = () => streams.delete(this);
      ch.addEventListener("close", off);
      ch.addEventListener("error", off);
    }
  }

  /** @internal the session ended: so does the exchange (a waiting head, body read or upload). */
  sessionEnded(err: LinkError): void {
    this.end(err);
    this.credit?.end();
  }

  /** @internal Whether a request piece of `n` bytes may go now (buffer room, the server's credit). */
  canSend(n: number): boolean {
    return this.ch.bufferedAmount <= RPC_SEND_HIGH && (!this.credit || this.credit.canSend(n));
  }

  /** @internal Until a request piece of `n` bytes may go; throws once the exchange is over (the answer complete, a
   *  reset, a cancel, the session's end). */
  room(n: number): Promise<void> {
    return this.gate.room(n, () => {
      if (this.done) throw this.error ?? new LinkError("closed", "the request is over");
    });
  }

  /** @internal Sends a request piece (counted against the server's window). */
  send(bytes: Uint8Array<ArrayBuffer>): void {
    this.gate.send(bytes);
  }

  private roomMade(): void {
    this.gate.wake();
  }

  private message(data: unknown): void {
    if (this.done) return;
    // under the window, text messages are the server's grants (ChannelCredit takes them)
    if (this.credit && typeof data === "string") return;
    let bytes: Uint8Array;
    try {
      bytes = messageBytes(data);
    } catch (e) {
      this.end(e as LinkError);
      return;
    }
    const cost = messageCost(bytes.length);
    if (bytes.length && this.credit && !this.credit.arrive(bytes.length)) {
      // past the window this side gave: the server broke the protocol
      this.end(new LinkError("protocol", "the server sent past its credit"));
      this.ch.close();
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
        if (!head) {
          // (the head's pieces are read at once)
          this.credit?.consume(cost);
          return;
        }
        this.gotHead = true;
        this.status = typeof head.s === "number" ? head.s : 0;
        const h = head.h && typeof head.h === "object" ? (head.h as Record<string, unknown>) : {};
        for (const [k, v] of Object.entries(h)) this.headers[k.toLowerCase()] = String(v);
        const rest = this.reader.rest();
        if (rest.length) this.chunks.push({ bytes: rest, cost });
        else this.credit?.consume(cost);
        this.onHead?.(null);
        this.onHead = null;
      } catch (e) {
        this.end(e instanceof LinkError ? e : new LinkError("protocol", String(e)));
      }
      return;
    }
    if (bytes.length === 0) {
      // the FIN: the body is complete
      this.done = true;
      this.wake?.();
      this.roomMade();
      this.ch.close();
      return;
    }
    this.chunks.push({ bytes, cost });
    this.wake?.();
  }

  private end(err: LinkError | null): void {
    if (this.done && !err) return;
    if (!this.done) {
      this.done = true;
      this.error = err;
    }
    if (this.onHead) {
      this.onHead(err ?? new LinkError("closed", "the request ended before its head"));
      this.onHead = null;
    }
    this.wake?.();
    this.roomMade();
  }

  /** The next piece of the body; null at its end. Throws `closed` when the request was reset. */
  async chunk(): Promise<Uint8Array | null> {
    for (;;) {
      const c = this.chunks.shift();
      if (c) {
        // read: the server may send as much again
        this.credit?.consume(c.cost);
        return c.bytes;
      }
      if (this.done) {
        if (this.error) throw this.error;
        return null;
      }
      await new Promise<void>((r) => (this.wake = r));
      this.wake = null;
    }
  }

  /** The rest of the body (at most `limit` bytes: more is an error). */
  async readAll(limit = RPC_READ_LIMIT): Promise<Uint8Array> {
    const parts: Uint8Array[] = [];
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

  async text(): Promise<string> {
    return new TextDecoder().decode(await this.readAll());
  }

  async json(): Promise<unknown> {
    return JSON.parse(await this.text());
  }

  async *[Symbol.asyncIterator](): AsyncIterator<Uint8Array> {
    for (let c = await this.chunk(); c; c = await this.chunk()) yield c;
  }

  /** Stops reading: the channel closes (the server's writes fail, a streamed answer ends). */
  cancel(): void {
    if (!this.done) {
      this.done = true;
      this.error = new LinkError("closed", "cancelled");
      this.wake?.();
    }
    if (this.ch.readyState === "open" || this.ch.readyState === "connecting") this.ch.close();
    this.roomMade();
  }

  /** As a fetch `Response` (status, headers, the body streamed): for code written against HTTP. */
  toResponse(): Response {
    const self = this;
    const body = new ReadableStream<Uint8Array>({
      async pull(c) {
        try {
          const chunk = await self.chunk();
          if (chunk) c.enqueue(chunk);
          else c.close();
        } catch (e) {
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
