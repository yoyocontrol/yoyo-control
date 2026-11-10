// The signaling client (docs/RELAY.md, protocol v1): keeps this server registered in its room at the signaling server
// (`relay/signal` is one; none is built in) — a WebSocket signed in with the identity key, so only the holder of that
// key can hold the room. Phones and browsers ask the room for the uu Link binding (`setLink`: `{"type":"link", …}`,
// docs/LINK.md「身份与信任」, sent after `ready` and whenever it changes).
//
// Reconnects after a drop (1 s, doubling to 60 s); a `ping` every 30 s, and no `pong` for 45 s more counts as a drop.
// Node 22's global WebSocket.

import { sign } from "node:crypto";
import { EventEmitter } from "node:events";
import type { Identity } from "./identity.js";

/** Where a server keeps its room: `explicit`, else `YOYO_SIGNAL_URL`; none is built in (`""`: no signaling server). */
export function signalUrl(explicit?: string): string {
  return (explicit || process.env.YOYO_SIGNAL_URL || "").trim().replace(/\/+$/, "");
}
export const RELAY_PING_MS = 30_000;
export const RELAY_PONG_TIMEOUT_MS = 45_000;
export const RELAY_MAX_BACKOFF_MS = 60_000;
const SIGNED_PREFIX = "yoyocontrol-relay-v1:";

type WebSocketCtor = new (url: string) => WebSocket;

export interface SignalOptions {
  identity: Pick<Identity, "key" | "publicKey" | "keyFingerprint">;
  /** Default `signalUrl()`. */
  url?: string;
  log?: (line: string) => void;
  /** Tests: another WebSocket. */
  WebSocket?: WebSocketCtor;
}

/** The room of a key: 64 lowercase hex digits (its fingerprint without "sha256:"). */
export function relayRoom(keyFingerprint: string): string {
  return keyFingerprint.replace(/^sha256:/, "");
}

/** The answer to the room's challenge: `{ type: "hello", v: 1, key, sig }`, `sig` = raw r ‖ s over "yoyocontrol-relay-v1:" + nonce. */
export function relayHello(nonce: string, identity: Pick<Identity, "key" | "publicKey">): string {
  const sig = sign("sha256", Buffer.from(SIGNED_PREFIX + nonce, "utf8"), { key: identity.key, dsaEncoding: "ieee-p1363" });
  return JSON.stringify({ key: identity.publicKey.toString("base64"), sig: sig.toString("base64"), type: "hello", v: 1 });
}

/** The uu Link the room tells phones about (docs/RELAY.md「候选」): the binding and where the endpoint is. */
export interface SignalLink {
  id: string;
  key: string;
  sig: string;
  relays: string[];
  direct: string[];
}

/** `{"direct":[…],"id","key","relays":[…],"sig","type":"link"}`. */
export function linkMessage(link: SignalLink): string {
  return JSON.stringify({ direct: link.direct, id: link.id, key: link.key, relays: link.relays, sig: link.sig, type: "link" });
}

/** `{"id","type":"account"}` (`"id":null`: none). */
export function accountMessage(id: string | null): string {
  return JSON.stringify({ id, type: "account" });
}

/** Events: `change` (registered or not: `registered`); `unlinked` (the room says it isn't in its account any more). */
export class SignalClient extends EventEmitter {
  readonly base: string;
  readonly room: string;
  private readonly opts: SignalOptions;
  private readonly log: (line: string) => void;
  private readonly WS: WebSocketCtor;
  private control: WebSocket | null = null;
  private running = false;
  private _registered = false;
  private backoff = 1000;
  private lastPong = 0;
  private pinger: ReturnType<typeof setInterval> | null = null;
  private retry: ReturnType<typeof setTimeout> | null = null;
  private linkText: string | null = null;
  private account: string | null = null;

  constructor(opts: SignalOptions) {
    super();
    this.opts = opts;
    this.log = opts.log ?? (() => {});
    this.base = signalUrl(opts.url);
    if (!this.base) throw new Error("SignalClient: no signaling server (opts.url or YOYO_SIGNAL_URL); none is built in");
    this.room = relayRoom(opts.identity.keyFingerprint);
    const WS = opts.WebSocket ?? (globalThis as { WebSocket?: WebSocketCtor }).WebSocket;
    if (!WS) throw new Error("no WebSocket in this Node (22 or later is needed)");
    this.WS = WS;
  }

  get registered(): boolean {
    return this._registered;
  }

  start(): void {
    if (this.running) return;
    this.running = true;
    this.connect();
  }

  /** Leaves the room. */
  stop(): void {
    this.running = false;
    if (this.retry) clearTimeout(this.retry);
    this.retry = null;
    this.stopPinging();
    const c = this.control;
    this.control = null;
    try {
      c?.close(1000);
    } catch {
      // closing anyway
    }
    this.setRegistered(false);
  }

  /** The link told to the room (null: none — not sent; a room keeps the last one until this server registers again). */
  setLink(link: SignalLink | null): void {
    const text = link ? linkMessage(link) : null;
    if (text === this.linkText) return;
    this.linkText = text;
    if (text && this._registered && this.control) this.send(this.control, text);
  }

  /**
   * The account this server is in (docs/ACCOUNT.md; null: none), told to the room after `ready` and when it changes.
   * The room answers `{"type":"account","state"}`; "unlinked" (it isn't in that account's directory any more) is the
   * `unlinked` event.
   */
  setAccount(id: string | null): void {
    if (id === this.account) return;
    this.account = id;
    if (this._registered && this.control) this.send(this.control, accountMessage(id));
  }

  private connect(): void {
    if (!this.running) return;
    let ws: WebSocket;
    try {
      ws = new this.WS(`${this.base}/v1/mac/${this.room}`);
    } catch (err) {
      this.log(`remote: signal: ${err instanceof Error ? err.message : String(err)}`);
      this.again();
      return;
    }
    this.control = ws;
    ws.addEventListener("message", (ev) => {
      if (this.control !== ws) return;
      if (typeof ev.data === "string") this.handle(ev.data, ws);
    });
    const dropped = (why: string) => this.dropped(ws, why);
    ws.addEventListener("close", (ev) => dropped(`closed ${ev.code}${ev.reason ? ` ${ev.reason}` : ""}`));
    ws.addEventListener("error", () => dropped("connection failed"));
  }

  private handle(text: string, ws: WebSocket): void {
    if (text === "pong") {
      this.lastPong = Date.now();
      return;
    }
    let msg: { type?: unknown; nonce?: unknown; state?: unknown };
    try {
      msg = JSON.parse(text);
    } catch {
      return;
    }
    switch (msg.type) {
      case "challenge":
        if (typeof msg.nonce !== "string") return this.dropped(ws, "a challenge it can't answer");
        this.send(ws, relayHello(msg.nonce, this.opts.identity));
        return;
      case "ready":
        this.backoff = 1000;
        this.lastPong = Date.now();
        this.setRegistered(true);
        this.startPinging(ws);
        if (this.linkText) this.send(ws, this.linkText);
        this.send(ws, accountMessage(this.account));
        this.log(`remote: signal: registered (${hostOf(this.base)})`);
        return;
      case "account":
        if (msg.state === "unlinked" && this.account !== null) {
          this.account = null;
          this.emit("unlinked");
        }
        return;
    }
  }

  private send(ws: WebSocket, text: string): void {
    try {
      if (ws.readyState === 1) ws.send(text);
    } catch {
      // the drop handler takes it from here
    }
  }

  private startPinging(ws: WebSocket): void {
    this.stopPinging();
    this.pinger = setInterval(() => {
      if (this.control !== ws) return;
      if (Date.now() - this.lastPong > RELAY_PING_MS + RELAY_PONG_TIMEOUT_MS) this.dropped(ws, "no pong");
      else this.send(ws, "ping");
    }, RELAY_PING_MS);
    this.pinger.unref();
  }

  private stopPinging(): void {
    if (this.pinger) clearInterval(this.pinger);
    this.pinger = null;
  }

  private dropped(ws: WebSocket, why: string): void {
    if (this.control !== ws) return;
    this.control = null;
    this.stopPinging();
    try {
      ws.close();
    } catch {
      // gone already
    }
    if (this._registered || this.backoff === 1000) this.log(`remote: signal: disconnected from ${hostOf(this.base)} (${why}); again in ${this.backoff / 1000} s`);
    this.setRegistered(false);
    this.again();
  }

  private again(): void {
    if (!this.running || this.retry) return;
    const wait = this.backoff;
    this.backoff = Math.min(this.backoff * 2, RELAY_MAX_BACKOFF_MS);
    this.retry = setTimeout(() => {
      this.retry = null;
      if (this.running && !this.control) this.connect();
    }, wait);
    this.retry.unref();
  }

  private setRegistered(on: boolean): void {
    if (this._registered === on) return;
    this._registered = on;
    this.emit("change", on);
  }
}

function hostOf(url: string): string {
  try {
    return new URL(url).host;
  } catch {
    return url;
  }
}
