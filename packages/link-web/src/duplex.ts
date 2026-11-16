import { ChannelCredit, type CreditPool, messageCost, SendGate } from "./credit.js";
import { LinkError } from "./errors.js";
import { encodeFrame, FrameReader, MAX_RPC_HEAD, messageBytes } from "./framing.js";
import { RPC_CHUNK, RPC_READ_LIMIT, type RpcRequest, type SessionStream } from "./rpc.js";

/** Largest message of a duplex stream (its payload; docs/LINK.md「RPC 流」「双工请求」). */
export const MAX_DUPLEX_MESSAGE = 1024 * 1024;
/** The `welcome` feature of a server that takes duplex requests. */
export const DUPLEX_FEATURE = "duplex";
/** A stream's writes wait while its channel holds more than this unsent (as the server's rtc streams do). */
export const DUPLEX_SEND_HIGH = 192 * 1024;
/** What a stream may hold received and not yet read (the server's bound, `RTC_DUPLEX_RECV_MAX`): past it the stream
 *  is reset. Each message counts `DUPLEX_ENTRY_COST` more than its bytes. */
export const DUPLEX_RECV_MAX = 2 * MAX_DUPLEX_MESSAGE + 64 * 1024;
/** What one queued message costs on top of its bytes (against `DUPLEX_RECV_MAX`). */
const DUPLEX_ENTRY_COST = 64;

const TEXT = 1;
const BINARY = 2;
const CLOSE = 8;

/** One message of a duplex stream (a WebSocket's: text, binary, or a close with its code). */
export type DuplexMessage = { type: "text"; text: string } | { type: "binary"; data: Uint8Array } | { type: "close"; code: number; reason: string };

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true });

/** `u8 type + u32 BE length + payload`; a close's payload is `u16 BE code + reason`. Throws `protocol` past 1 MiB. */
export function encodeDuplexMessage(m: DuplexMessage): Uint8Array<ArrayBuffer> {
  let type: number;
  let payload: Uint8Array;
  if (m.type === "text") {
    type = TEXT;
    payload = encoder.encode(m.text);
  } else if (m.type === "binary") {
    type = BINARY;
    payload = m.data;
  } else {
    if (!Number.isInteger(m.code) || m.code < 0 || m.code > 0xffff) throw new LinkError("protocol", `close code ${m.code} is not a u16`);
    const reason = encoder.encode(m.reason);
    type = CLOSE;
    payload = new Uint8Array(2 + reason.length);
    new DataView(payload.buffer).setUint16(0, m.code);
    payload.set(reason, 2);
  }
  if (payload.length > MAX_DUPLEX_MESSAGE) throw new LinkError("protocol", `duplex message of ${payload.length} bytes is over ${MAX_DUPLEX_MESSAGE}`);
  const out = new Uint8Array(5 + payload.length);
  out[0] = type;
  new DataView(out.buffer).setUint32(1, payload.length);
  out.set(payload, 5);
  return out;
}

/** Bytes in (a data channel's messages carry the stream as bytes: a message may be split or several in one), messages out. */
export class DuplexReader {
  private buf: Uint8Array = new Uint8Array(0);

  /** Appends `bytes`; returns every message now whole. Throws `protocol` on one over 1 MiB, an unknown type, bad UTF-8. */
  push(bytes: Uint8Array): DuplexMessage[] {
    const r = this.take(bytes);
    if (r.error) throw r.error;
    return r.messages.map((m) => m.message);
  }

  /** @internal `push` that keeps what came before a malformed message: every message now whole (with its size on the
   *  wire), and the error that stopped the reading (nothing after it is read). */
  take(bytes: Uint8Array): { messages: { message: DuplexMessage; size: number }[]; error: LinkError | null } {
    if (this.buf.length === 0) this.buf = bytes;
    else {
      const b = new Uint8Array(this.buf.length + bytes.length);
      b.set(this.buf);
      b.set(bytes, this.buf.length);
      this.buf = b;
    }
    const messages: { message: DuplexMessage; size: number }[] = [];
    try {
      while (this.buf.length >= 5) {
        const view = new DataView(this.buf.buffer, this.buf.byteOffset, this.buf.byteLength);
        const n = view.getUint32(1);
        if (n > MAX_DUPLEX_MESSAGE) throw new LinkError("protocol", `duplex message of ${n} bytes is over ${MAX_DUPLEX_MESSAGE}`);
        if (this.buf.length < 5 + n) break;
        const type = this.buf[0]!;
        const payload = this.buf.slice(5, 5 + n);
        this.buf = this.buf.subarray(5 + n);
        messages.push({ message: decodeDuplexMessage(type, payload), size: 5 + n });
      }
    } catch (e) {
      this.buf = new Uint8Array(0);
      return { messages, error: e instanceof LinkError ? e : new LinkError("protocol", String(e)) };
    }
    return { messages, error: null };
  }

  /** Bytes waiting for the rest of their message. */
  get pending(): number {
    return this.buf.length;
  }
}

function decodeDuplexMessage(type: number, payload: Uint8Array): DuplexMessage {
  const utf8 = (b: Uint8Array, what: string) => {
    try {
      return decoder.decode(b);
    } catch {
      throw new LinkError("protocol", `duplex ${what} is not UTF-8`);
    }
  };
  if (type === TEXT) return { type: "text", text: utf8(payload, "text") };
  if (type === BINARY) return { type: "binary", data: payload };
  if (type === CLOSE) {
    if (payload.length < 2) throw new LinkError("protocol", "duplex close without a code");
    return { type: "close", code: new DataView(payload.buffer, payload.byteOffset, 2).getUint16(0), reason: utf8(payload.subarray(2), "close reason") };
  }
  throw new LinkError("protocol", `duplex message of type ${type}`);
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
export class Duplex {
  private readonly reader = new DuplexReader();
  private queue: { message: DuplexMessage; cost: number; end: number }[] = [];
  /** What `queue` costs (bytes + `DUPLEX_ENTRY_COST` each). */
  private queued = 0;
  private finIn = false;
  private finOut = false;
  private ended: LinkError | null = null;
  private cancelled = false;
  private readers: (() => void)[] = [];
  private closedWaiters: (() => void)[] = [];
  private isClosed = false;
  /** The last queued write (send / finish): the next one goes after it. */
  private writing: Promise<void> = Promise.resolve();
  private readonly credit: ChannelCredit | null;
  /** Under the window: the channel messages not yet released (their last byte's offset in the stream, their cost).
   *  One is granted again once every byte of it went to the app — or, while no whole message waits for the app, at
   *  once: a message still coming in (up to 1 MiB, more than the window with its overhead) must be able to finish. So
   *  what waits here is at most the window and one message. */
  private arrivals: { end: number; cost: number }[] = [];
  /** Bytes of the stream that came, that were decoded, that went to the app (offsets). */
  private arrived = 0;
  private decoded = 0;
  private delivered = 0;

  /** @internal `early`: bytes after the 101's head in the same message (`earlyCost`: that message's cost). */
  constructor(
    private readonly ch: RTCDataChannel,
    early: Uint8Array,
    private readonly gate: SendGate,
    earlyCost = 0,
  ) {
    this.credit = gate.credit;
    ch.addEventListener("message", (ev) => {
      // under the window, text messages are the server's grants (ChannelCredit takes them)
      if (this.credit && typeof ev.data === "string") return;
      this.message(messageBytes(ev.data));
    });
    ch.addEventListener("close", () => this.channelClosed());
    ch.addEventListener("error", () => this.channelClosed());
    if (early.length) this.take(early, earlyCost);
  }

  /** @internal the response's message handler hands this one over */
  message(bytes: Uint8Array): void {
    if (this.cancelled || this.finIn || this.ended) return;
    if (bytes.length === 0) {
      this.finIn = true;
      this.wakeReaders();
      this.maybeClose();
      return;
    }
    if (this.credit && !this.credit.arrive(bytes.length)) {
      this.ended = new LinkError("protocol", "the server sent past its credit");
      if (this.ch.readyState === "open" || this.ch.readyState === "connecting") this.ch.close();
      this.wakeReaders();
      return;
    }
    this.take(bytes, messageCost(bytes.length));
  }

  private take(bytes: Uint8Array, cost: number): void {
    this.arrived += bytes.length;
    this.arrivals.push({ end: this.arrived, cost });
    const { messages, error } = this.reader.take(bytes);
    // what came before a malformed message is still read
    for (const { message, size } of messages) {
      const cost = size + DUPLEX_ENTRY_COST;
      this.decoded += size;
      this.queue.push({ message, cost, end: this.decoded });
      this.queued += cost;
    }
    this.release();
    let end = error;
    if (!end && this.queued + this.reader.pending > DUPLEX_RECV_MAX) {
      end = new LinkError("closed", `the stream was reset: more than ${DUPLEX_RECV_MAX} bytes came that weren't read`);
    }
    if (end) {
      // a malformed message, or more than may wait: this side stops reading (as the Rust core's receiver does), the
      // stream ends; `recv` gives what was queued, then says why
      this.ended = end;
      if (this.ch.readyState === "open" || this.ch.readyState === "connecting") this.ch.close();
    }
    this.wakeReaders();
  }

  private wakeReaders(): void {
    for (const w of this.readers.splice(0)) w();
  }

  private channelClosed(err?: LinkError): void {
    if (this.isClosed) return;
    this.isClosed = true;
    if (!this.finIn && !this.cancelled && !this.ended) this.ended = err ?? new LinkError("closed", "the stream was reset");
    this.wakeReaders();
    for (const w of this.closedWaiters.splice(0)) w();
    this.gate.wake();
    this.credit?.end();
  }

  /** @internal the session ended: so does the stream, whether or not the channel says so (a closed peer connection
   *  needn't fire its channels' `close`). */
  sessionEnded(err: LinkError): void {
    this.channelClosed(err);
  }

  /** Both directions done (this side's FIN sent, the other's received): the client closes the channel, as for any RPC. */
  private maybeClose(): void {
    if (this.finIn && this.finOut && !this.isClosed) this.ch.close();
  }

  /** Sends one message, after the sends (and `finish`) called before it; waits while the channel's buffer is full.
   *  Throws `closed` once the stream is over, `protocol` past 1 MiB. */
  send(message: DuplexMessage): Promise<void> {
    let bytes: Uint8Array<ArrayBuffer>;
    try {
      bytes = encodeDuplexMessage(message);
    } catch (e) {
      return Promise.reject(e);
    }
    return this.serially(async () => {
      for (let i = 0; i < bytes.length; i += RPC_CHUNK) {
        const piece = bytes.subarray(i, Math.min(bytes.length, i + RPC_CHUNK));
        await this.room(piece.length);
        this.gate.send(piece);
      }
    });
  }

  /** Runs `f` once every write queued before it is done (failed or not): one message's chunks never mix with
   *  another's, and the FIN never lands inside one. */
  private serially(f: () => Promise<void>): Promise<void> {
    const p = this.writing.then(f);
    this.writing = p.catch(() => {});
    return p;
  }

  sendText(text: string): Promise<void> {
    return this.send({ type: "text", text });
  }

  sendBinary(data: Uint8Array): Promise<void> {
    return this.send({ type: "binary", data });
  }

  /** Until a piece of `n` bytes may go (buffer room; under the window, the server's credit). */
  private room(n: number): Promise<void> {
    return this.gate.room(n, () => {
      if (this.finOut) throw new LinkError("closed", "duplex stream finished");
      if (this.isClosed) throw new LinkError("closed", "the stream is closed");
    });
  }

  /** The next message; `null` once the other side finished, or after `cancel` (a waiting one too). Throws `closed`
   *  when the stream was reset, `protocol` on a malformed message. */
  async recv(): Promise<DuplexMessage | null> {
    for (;;) {
      if (this.cancelled) return null;
      const q = this.queue.shift();
      if (q) {
        this.queued -= q.cost;
        this.delivered = q.end;
        this.release();
        return q.message;
      }
      if (this.ended) throw this.ended;
      if (this.finIn) return null;
      await new Promise<void>((r) => this.readers.push(r));
    }
  }

  /** Under the window: grants again what went to the app (`arrivals`). */
  private release(): void {
    if (!this.credit) return;
    const upTo = this.queue.length ? this.delivered : Infinity;
    let cost = 0;
    while (this.arrivals.length && this.arrivals[0]!.end <= upTo) cost += this.arrivals.shift()!.cost;
    this.credit.consume(cost);
  }

  async *[Symbol.asyncIterator](): AsyncIterator<DuplexMessage> {
    for (;;) {
      const m = await this.recv();
      if (!m) return;
      yield m;
    }
  }

  /** Ends this side's direction (the FIN), after the sends called before it: the other side's `recv` ends. Waits
   *  for room like `send`. */
  finish(): Promise<void> {
    return this.serially(async () => {
      if (this.finOut) return;
      await this.room(0);
      this.gate.send(new Uint8Array(0));
      this.finOut = true;
      this.maybeClose();
    });
  }

  /** Stops reading: a waiting `recv` and every later one return `null`. Over WebRTC this closes the channel: the other
   *  side's sends fail, and so do this side's. */
  cancel(): void {
    if (!this.cancelled) {
      this.cancelled = true;
      this.queue = [];
      this.queued = 0;
      this.wakeReaders();
    }
    if (this.ch.readyState === "open" || this.ch.readyState === "connecting") this.ch.close();
    // a waiting send sees the channel closing
    this.gate.wake();
  }

  /** Resolves when the other side stopped reading (the channel closed) or the session ended. */
  stopped(): Promise<void> {
    if (this.isClosed) return Promise.resolve();
    return new Promise((r) => this.closedWaiters.push(r));
  }
}

/** The answer to a duplex request: accepted (101, `duplex`), or any other response (`readAll` for its body). */
export class DuplexResponse {
  /** HTTP status: 101 = accepted. */
  status = 0;
  /** The response headers (lower-case names). */
  headers: Record<string, string> = {};
  /** The accepted stream (status 101); `null` otherwise. */
  duplex: Duplex | null = null;
  /** @internal */
  onHead: ((err: LinkError | null) => void) | null = null;
  private readonly reader = new FrameReader(MAX_RPC_HEAD);
  private gotHead = false;
  private chunks: { bytes: Uint8Array; cost: number }[] = [];
  private done = false;
  private error: LinkError | null = null;
  private wake: (() => void) | null = null;
  /** @internal the channel's sending side (the head here, then the stream's) */
  readonly gate: SendGate;
  private readonly credit: ChannelCredit | null;

  /** @internal `streams`: the session's open ones (it ends them when it ends); `credit`: the channel's, under the
   *  credit window */
  constructor(
    private readonly ch: RTCDataChannel,
    streams?: Set<SessionStream>,
    credit: ChannelCredit | null = null,
  ) {
    this.credit = credit;
    this.gate = new SendGate(ch, DUPLEX_SEND_HIGH, credit);
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

  /** @internal the session ended: the stream (or the wait for the answer, or its body) ends with `err`. */
  sessionEnded(err: LinkError): void {
    if (this.duplex) this.duplex.sessionEnded(err);
    else this.end(err);
    this.credit?.end();
  }

  private message(data: unknown): void {
    if (this.duplex || this.done) return;
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
          this.credit?.consume(cost);
          return;
        }
        this.gotHead = true;
        this.status = typeof head.s === "number" ? head.s : 0;
        const h = head.h && typeof head.h === "object" ? (head.h as Record<string, unknown>) : {};
        for (const [k, v] of Object.entries(h)) this.headers[k.toLowerCase()] = String(v);
        const rest = this.reader.rest();
        if (!rest.length) this.credit?.consume(cost);
        if (this.status === 101) {
          // from here on the channel is the stream's: its messages go to the Duplex (with the cost of the bytes
          // that came with the head)
          this.duplex = new Duplex(this.ch, rest, this.gate, rest.length ? cost : 0);
        } else {
          // refused: nothing more goes up (this side's FIN); the body follows
          try {
            this.ch.send(new Uint8Array(0));
          } catch {
            // closed already: the body read says so
          }
          if (rest.length) this.chunks.push({ bytes: rest, cost });
        }
        this.onHead?.(null);
        this.onHead = null;
      } catch (e) {
        this.end(e instanceof LinkError ? e : new LinkError("protocol", String(e)));
      }
      return;
    }
    if (bytes.length === 0) {
      this.done = true;
      this.wake?.();
      this.ch.close();
      return;
    }
    this.chunks.push({ bytes, cost });
    this.wake?.();
  }

  private end(err: LinkError | null): void {
    if (this.duplex) return;
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

  /** Not accepted: the response's body (at most `limit` bytes). Accepted: empty. */
  async readAll(limit = RPC_READ_LIMIT): Promise<Uint8Array> {
    if (this.duplex) return new Uint8Array(0);
    const parts: Uint8Array[] = [];
    let n = 0;
    for (;;) {
      const c = this.chunks.shift();
      if (c) {
        this.credit?.consume(c.cost);
        n += c.bytes.length;
        if (n > limit) {
          this.ch.close();
          throw new LinkError("protocol", `the response body is over ${limit} bytes`);
        }
        parts.push(c.bytes);
        continue;
      }
      if (this.done) {
        if (this.error) throw this.error;
        break;
      }
      await new Promise<void>((r) => (this.wake = r));
      this.wake = null;
    }
    const out = new Uint8Array(n);
    let at = 0;
    for (const p of parts) {
      out.set(p, at);
      at += p.length;
    }
    return out;
  }
}

/**
 * Opens an `rpc` DataChannel and sends a duplex request's head (`"duplex": true`, no body, no FIN); resolves once the
 * answer's head came: 101 with the stream, or any other status with its body.
 */
export function duplexRequest(
  pc: RTCPeerConnection,
  req: RpcRequest,
  timeoutMs: number,
  streams?: Set<SessionStream>,
  credit?: CreditPool | null,
): Promise<DuplexResponse> {
  const ch = pc.createDataChannel("rpc", { ordered: true });
  ch.binaryType = "arraybuffer";
  const response = new DuplexResponse(ch, streams, credit ? new ChannelCredit(ch, credit) : null);
  return new Promise<DuplexResponse>((resolve, reject) => {
    const timer = setTimeout(() => fail(new LinkError("timeout", `no answer to ${req.method} ${req.path} in ${timeoutMs} ms`)), timeoutMs);
    const fail = (e: LinkError) => {
      clearTimeout(timer);
      response.onHead = null;
      if (ch.readyState === "open" || ch.readyState === "connecting") ch.close();
      reject(e);
    };
    response.onHead = (err) => {
      clearTimeout(timer);
      if (err) reject(err);
      else resolve(response);
    };
    ch.addEventListener("open", () => {
      void (async () => {
        try {
          const h: Record<string, string> = {};
          for (const [k, v] of Object.entries(req.headers ?? {})) if (k.toLowerCase() !== "host") h[k.toLowerCase()] = String(v);
          const head = encodeFrame({ m: req.method.toUpperCase(), p: req.path, h, duplex: true }, MAX_RPC_HEAD);
          // in pieces: each fits the initial window
          for (let i = 0; i < head.length; i += RPC_CHUNK) {
            const piece = head.slice(i, i + RPC_CHUNK);
            await response.gate.room(piece.length, () => {});
            response.gate.send(piece);
          }
        } catch (e) {
          fail(e instanceof LinkError ? e : new LinkError("closed", e instanceof Error ? e.message : String(e)));
        }
      })();
    });
  });
}
