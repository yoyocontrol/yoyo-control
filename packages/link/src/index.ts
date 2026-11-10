// @yoyocontrol/link: uu Link for Node (docs/LINK.md). Endpoints, sessions, control messages, RPC, datagram channels
// over the shared Rust core (link/, the native addon in native/).

import {
  native,
  type ClientMediaEvent,
  type FrameMeta,
  type ServerMediaEvent,
  type NativeAddrInfo,
  type NativeAuthRequest,
  type NativeEndpoint,
  type NativeHello,
  type NativeListener,
  type NativeRpcRequest,
  type NativeRpcResponder,
  type NativeRpcResponse,
  type NativeSession,
  type NativeWelcome,
} from "./native.js";

export { nativeName } from "./native.js";
export type { AudioPacket, ClientMediaEvent, FrameMeta, InputEvent, ServerMediaEvent, VideoFrame } from "./native.js";

/** The media layer's datagram channels (byte 0 of a datagram is `channel << 4 | 1`). They belong to the session's
 * media API (`sendFrame`, `nextClientEvent`, …); raw datagrams are for the app's own channels 6–15. */
export const Channel = { video: 1, audio: 2, input: 3, feedback: 4, cursor: 5 } as const;

/** QUIC application close codes. */
export const CloseCode = {
  normal: 0,
  unauthorized: 1,
  rateLimited: 2,
  busy: 3,
  protocol: 4,
  shuttingDown: 5,
  replaced: 6,
} as const;

export type DenyCode = "unauthorized" | "rate-limited" | "busy";
export type PathKind = "relay" | "lan" | "direct" | "punched" | "none";
export type Iface = "wifi" | "cellular" | "wired" | "other";
export type ErrorKind =
  | "invalid-argument"
  | "bind"
  | "connect"
  | "timeout"
  | "denied"
  | "protocol"
  | "closed"
  | "binding"
  | "datagram"
  | "io"
  | "media"
  | "internal";

/** Every error of this package. `code` is the deny code for `kind: "denied"`. */
export class LinkError extends Error {
  constructor(
    readonly kind: ErrorKind,
    message: string,
    readonly code?: DenyCode,
  ) {
    super(message);
    this.name = "LinkError";
  }
}

function lift(e: unknown): LinkError {
  if (e instanceof LinkError) return e;
  const message = e instanceof Error ? e.message : String(e);
  const m = /^\[([a-z-]+)(?::([a-z-]+))?\] ([\s\S]*)$/.exec(message);
  if (!m) return new LinkError("internal", message);
  return new LinkError(m[1] as ErrorKind, m[3] ?? "", m[2] as DenyCode | undefined);
}

async function call<T>(f: () => Promise<T>): Promise<T> {
  try {
    return await f();
  } catch (e) {
    throw lift(e);
  }
}

function sync<T>(f: () => T): T {
  try {
    return f();
  } catch (e) {
    throw lift(e);
  }
}

// MARK: keys and binding

export interface Binding {
  /** hex of the link public key (the endpoint id) */
  id: string;
  /** base64 of the identity's P-256 public key (65 bytes, X9.63) */
  key: string;
  /** base64 of the ECDSA P-256 / SHA-256 signature r ‖ s over "yoyocontrol-link-v1:" ‖ id */
  sig: string;
}

export const version = (): string => native().version();
/** A new random link secret key (32 bytes). */
export const generateLinkKey = (): Buffer => native().generateLinkKey();
/** hex of the public key (endpoint id) of a link secret key. */
export const linkPublicKey = (secretKey: Buffer): string => sync(() => native().linkPublicKey(secretKey));
/** The link secret key in `path` (32 bytes, 0600), made on first use. */
export const loadOrCreateLinkKey = (path: string): Buffer => sync(() => native().loadOrCreateLinkKey(path));
/** `"sha256:" + hex(SHA-256(public key))` of a 97-byte X9.63 identity private key. */
export const identityFingerprint = (identityKey: Buffer): string => sync(() => native().identityFingerprint(identityKey));
/** The identity's binding over a link public key (hex). */
export const signBinding = (identityKey: Buffer, linkPublicKey: string): Binding =>
  sync(() => native().signBinding(identityKey, linkPublicKey));
/** Checks a binding against the pinned fingerprint; returns the endpoint id it vouches for. */
export const verifyBinding = (binding: Binding, fingerprint: string): string =>
  sync(() => native().verifyBinding(binding, fingerprint));

export type LogLevel = "debug" | "info" | "warn" | "error";
/** Where the link's log lines go (`link:` stats, sessions, paths, guard); `null`: nowhere. */
export function setLogSink(sink: ((level: LogLevel, message: string) => void) | null): void {
  native().setLogSink(sink ? (level, message) => sink(level as LogLevel, message) : null);
}

// MARK: endpoint

export interface GuardSettings {
  failureLimit?: number;
  failureWindowMs?: number;
  cooldownMs?: number;
  maxSessions?: number;
  maxUnauthenticated?: number;
  /** IP addresses never limited (besides loopback). */
  exempt?: string[];
}

export interface EndpointConfig {
  role: "server" | "client";
  /** The link secret key (32 bytes). */
  secretKey: Buffer;
  /** UDP port on 0.0.0.0 and [::] (default 0 = any). */
  port?: number;
  /** Relay URLs; empty = direct only. */
  relays?: string[];
  /** Router port mapping (default: servers yes, clients no). */
  portmapper?: boolean;
  guard?: GuardSettings;
  /** Also open the WebRTC socket(s) on this UDP port (0 = any; uu's servers use the link port + 1): servers then
   * answer browsers' offers (`Listener.acceptRtcOffer`, docs/LINK.md「WebRTC」). Absent = no rtc. */
  rtcPort?: number;
  /** STUN servers (`host:port`) for the server's public address in rtc answers. */
  rtcStunServers?: string[];
  /** rtc answers offer only the external addresses (`addRtcExternalAddr`, STUN), not the interfaces'. */
  rtcExternalOnly?: boolean;
}

export type AddrInfo = NativeAddrInfo;
export type Hello = NativeHello;
export type Welcome = NativeWelcome;
export interface ServerInfo { id: string; name: string; platform: string }

export interface DialTarget {
  /** hex endpoint id (from a verified binding) */
  id: string;
  relays?: string[];
  /** `ip:port` / `[ipv6]:port` */
  direct?: string[];
}

export interface AuthRequest {
  hello: Hello;
  /** hex of the client's link public key: bind a device token to it on first use (an rtc client:
   * `dtls-sha256:<hex>` of its DTLS certificate) */
  clientKey: string;
  sourceAddr?: string;
  sourceRelay?: string;
  path: PathKind;
}

export type AuthDecision =
  | { ok: true; principal?: unknown; features?: string[] }
  | { ok: false; code: DenyCode; message?: string };

export interface RpcRequest {
  method: string;
  /** path and query */
  path: string;
  headers?: Record<string, string>;
}

export type RpcHandler = (session: Session, request: RpcRequest, body: Buffer, response: RpcResponder) => void | Promise<void>;

export interface ListenOptions {
  server: ServerInfo;
  features?: string[];
  authenticate: (request: AuthRequest) => AuthDecision | Promise<AuthDecision>;
  rpc?: RpcHandler;
  /** Paths answered 404 (default: the channels' HTTP paths: /stream, /stream/ack, /audio, /input, /control). */
  rpcBlockedPaths?: string[];
  maxRequestBody?: number;
  /** Every NACK also asks for a recovery frame at once (`recoveryNeeded`): for an encoder whose recovery frames are
   * cheap (long-term references). Default off (an x264 recovery is a key frame). */
  recoveryOnNack?: boolean;
  /** The identity private key (97-byte X9.63) that signs rtc answers; without it `acceptRtcOffer` refuses. */
  identityKey?: Buffer;
}

export async function bindEndpoint(config: EndpointConfig): Promise<Endpoint> {
  const ep = await call(() => native().bindEndpoint(config));
  return new Endpoint(ep);
}

export class Endpoint {
  /** @internal */
  constructor(private readonly ep: NativeEndpoint) {}

  /** hex of the link public key */
  get id(): string {
    return this.ep.id;
  }

  get port(): number {
    return this.ep.port;
  }

  /** The rtc UDP port; `null` without rtc. */
  get rtcPort(): number | null {
    return this.ep.rtcPort;
  }

  /** The rtc port's router mapping (`ip:port`): rtc answers offer it until removed. False without rtc. */
  addRtcExternalAddr(addr: string): boolean {
    return sync(() => this.ep.addRtcExternalAddr(addr));
  }

  removeRtcExternalAddr(addr: string): boolean {
    return sync(() => this.ep.removeRtcExternalAddr(addr));
  }

  addrInfo(): AddrInfo {
    return this.ep.addrInfo();
  }

  /** Calls `cb` now and at every change of the address info, until the endpoint is closed. */
  watchAddr(cb: (info: AddrInfo) => void): void {
    this.ep.watchAddr(cb);
  }

  /** The identity's binding over this endpoint's key (97-byte X9.63 identity private key). */
  binding(identityKey: Buffer): Binding {
    return sync(() => this.ep.binding(identityKey));
  }

  /** An `ip:port` this endpoint is reachable on that it can't see itself (a router port mapping the app made):
   * advertised with its own addresses until removed. */
  addExternalAddr(addr: string): Promise<void> {
    return call(() => this.ep.addExternalAddr(addr));
  }

  removeExternalAddr(addr: string): Promise<boolean> {
    return call(() => this.ep.removeExternalAddr(addr));
  }

  /** The network changed: re-probe addresses and paths now. */
  networkChanged(iface?: Iface): Promise<void> {
    return call(() => this.ep.networkChanged(iface));
  }

  async dial(target: DialTarget, hello: Hello, options: { connectTimeoutMs?: number } = {}): Promise<Session> {
    const s = await call(() => this.ep.dial(target, hello, options.connectTimeoutMs));
    return new Session(s);
  }

  /** Dials a server over WebRTC the way a browser does (docs/LINK.md「WebRTC」): `signal(offerJson)` carries the offer
   * to the server's `acceptRtcOffer` (any path: HTTP, a relay) and resolves with the answer JSON, which is checked
   * against the pinned identity `fingerprint` before connecting. Needs `rtcPort` in the endpoint config. */
  async dialRtc(
    signal: (offerJson: string) => Promise<string>,
    fingerprint: string,
    hello: Hello,
    options: { connectTimeoutMs?: number } = {},
  ): Promise<Session> {
    const s = await call(() => this.ep.dialRtc(signal, fingerprint, hello, options.connectTimeoutMs));
    return new Session(s);
  }

  /** Starts accepting sessions (servers, once). */
  listen(options: ListenOptions): Listener {
    const authenticate = async (r: NativeAuthRequest) => {
      const d = await options.authenticate({ ...r, path: r.path as PathKind });
      return d.ok
        ? { ok: true, principal: d.principal ?? null, features: d.features }
        : { ok: false, code: d.code, message: d.message ?? "" };
    };
    const handler = options.rpc;
    const rpc = handler
      ? (s: NativeSession, req: NativeRpcRequest, body: Buffer, res: NativeRpcResponder) => {
          const response = new RpcResponder(res);
          Promise.resolve()
            .then(() => handler(new Session(s), { ...req, headers: req.headers ?? {} }, body, response))
            .catch((e: unknown) => response.fail(e));
        }
      : undefined;
    const settings = {
      server: options.server,
      features: options.features,
      rpcBlockedPaths: options.rpcBlockedPaths,
      maxRequestBody: options.maxRequestBody,
      recoveryOnNack: options.recoveryOnNack,
      identityKey: options.identityKey,
    };
    return new Listener(sync(() => this.ep.listen(settings, authenticate, rpc)));
  }

  close(): Promise<void> {
    return this.ep.close();
  }
}

export class Listener {
  /** @internal */
  constructor(private readonly l: NativeListener) {}

  /** The next authenticated session; `null` once the endpoint is closed. */
  async accept(): Promise<Session | null> {
    const s = await this.l.accept();
    return s ? new Session(s) : null;
  }

  /** A browser's WebRTC offer JSON (`{"v":1,"offer","device"}`) → the signed answer JSON; the session comes out of
   * `accept` once it connected and said hello (docs/LINK.md「WebRTC」). `sourceIp`: the signaling request's address
   * when known. Rejects with `LinkError` kind `invalid-argument` (no rtc / identity, a bad offer) or `denied`
   * (`rate-limited`: the source is blocked; `busy`: too many sessions or pending offers). */
  acceptRtcOffer(offerJson: string, sourceIp?: string): Promise<string> {
    return call(() => this.l.acceptRtcOffer(offerJson, sourceIp));
  }

  async *[Symbol.asyncIterator](): AsyncIterator<Session> {
    for (;;) {
      const s = await this.accept();
      if (!s) return;
      yield s;
    }
  }
}

// MARK: session

export interface CloseInfo {
  /** application close code (`CloseCode`); absent for transport-level ends (idle timeout, reset) */
  code?: number;
  reason: string;
  remote: boolean;
  description: string;
}

/** A control message: a JSON object with a string `t`. */
export type ControlMessage = { t: string } & Record<string, unknown>;

export interface Stats {
  path: PathKind;
  iface: Iface;
  remote?: string;
  rttMinMs: number;
  rttP50Ms: number;
  rttP90Ms: number;
  bytesSent: number;
  bytesReceived: number;
  packetsLost: number;
  datagramsSent: number;
  datagramsReceived: number;
  datagramDrops: number;
  /** the `link:` line's body */
  line: string;
  [media: string]: unknown;
}

export class Session {
  /** @internal */
  constructor(private readonly s: NativeSession) {}

  get id(): number {
    return this.s.id;
  }

  get isServer(): boolean {
    return this.s.isServer;
  }

  /** hex of the other side's link public key (an rtc client: `dtls-sha256:<hex>` of its DTLS certificate) */
  get remoteId(): string {
    return this.s.remoteId;
  }

  /** "quic" or "rtc" (WebRTC: a browser) */
  get transport(): "quic" | "rtc" {
    return this.s.transport;
  }

  /** the client's hello (both sides) */
  get hello(): Hello {
    return this.s.hello();
  }

  /** the server's welcome (both sides) */
  get welcome(): Welcome {
    return this.s.welcome();
  }

  get principal(): unknown {
    return this.s.welcome().principal;
  }

  sendControl(message: ControlMessage): Promise<void> {
    return call(() => this.s.sendControl(message));
  }

  /** The next control message; `null` once the session ended. */
  recvControl(): Promise<ControlMessage | null> {
    return this.s.recvControl() as Promise<ControlMessage | null>;
  }

  async *controlMessages(): AsyncGenerator<ControlMessage> {
    for (;;) {
      const m = await this.recvControl();
      if (!m) return;
      yield m;
    }
  }

  async request(request: RpcRequest, body?: Buffer): Promise<RpcResponse> {
    const r = await call(() => this.s.request(request, body));
    return new RpcResponse(r);
  }

  /** Sends `channel << 4 | 1` then `payload`. */
  sendDatagram(channel: number, payload: Buffer): void {
    sync(() => this.s.sendDatagram(channel, payload));
  }

  /** Sends a whole datagram (byte 0 already the header). */
  sendDatagramRaw(datagram: Buffer): void {
    sync(() => this.s.sendDatagramRaw(datagram));
  }

  /** The next datagram of `channel`, whole (byte 0 = header); `null` once the session ended. */
  recvDatagram(channel: number): Promise<Buffer | null> {
    return call(() => this.s.recvDatagram(channel));
  }

  async *datagrams(channel: number): AsyncGenerator<Buffer> {
    for (;;) {
      const d = await this.recvDatagram(channel);
      if (!d) return;
      yield d;
    }
  }

  get maxDatagramSize(): number {
    return this.s.maxDatagramSize;
  }

  /** bits per second every path's congestion window follows */
  get targetBitrate(): number {
    return this.s.targetBitrate;
  }

  set targetBitrate(bps: number) {
    this.s.targetBitrate = bps;
  }

  path(): { kind: PathKind; remote?: string } {
    const p = this.s.path();
    return { kind: p.kind as PathKind, remote: p.remote };
  }

  stats(): Stats {
    return this.s.stats() as unknown as Stats;
  }

  peerStats(): Stats | null {
    return this.s.peerStats() as unknown as Stats | null;
  }

  /** The media layer's numbers (lossPct, fecRecovered, fps, …). */
  setMediaStats(stats: Record<string, number | undefined>): void {
    sync(() => this.s.setMediaStats(stats));
  }

  /** Sends `bye` and closes with `code` (default normal). */
  close(code: number = CloseCode.normal, reason = ""): Promise<void> {
    return this.s.close(code, reason);
  }

  get isClosed(): boolean {
    return this.s.isClosed;
  }

  // media (channels 1–5)

  /** Opens video stream `stream` (server: per `video.open`, frames from 1; client: per `video.opened`). */
  openVideo(stream: number): void {
    sync(() => this.s.openVideo(stream));
  }

  closeVideo(stream: number): void {
    sync(() => this.s.closeVideo(stream));
  }

  openAudio(stream: number): void {
    sync(() => this.s.openAudio(stream));
  }

  closeAudio(stream: number): void {
    sync(() => this.s.closeAudio(stream));
  }

  /** Server: whether to encode the next picture now (false: skip it, the newest picture wins). */
  canSendFrame(stream: number): boolean {
    return sync(() => this.s.canSendFrame(stream));
  }

  /**
   * Server: the frame-rate cap of `stream` (frames/s, follows the encoder rate; null: no such stream). An encoder
   * that budgets per frame at a fixed frame rate (x264 without VFR) should get `encoderBps × its fps / cap`.
   * Older native addons don't have it: null.
   */
  frameRateCap(stream: number): number | null {
    if (typeof this.s.frameRateCap !== "function") return null;
    return sync(() => this.s.frameRateCap!(stream)) ?? null;
  }

  /** Server: one encoded frame (Annex-B); returns its frame number. */
  sendFrame(stream: number, meta: FrameMeta, au: Buffer): number {
    return sync(() => this.s.sendFrame(stream, meta, au));
  }

  /** Server: one Opus packet; returns its aseq. */
  sendAudio(stream: number, timeUs: number, opus: Buffer): number {
    return sync(() => this.s.sendAudio(stream, timeUs, opus));
  }

  /** Server: the newest cursor position (`{x, y, visible, shapeId}`). */
  sendCursor(stream: number, cursor: Buffer | object): void {
    const json = Buffer.isBuffer(cursor) ? cursor : Buffer.from(JSON.stringify(cursor));
    sync(() => this.s.sendCursor(stream, json));
  }

  /** Server: force a key frame next; client: ask for one. */
  requestKeyframe(stream: number): void {
    sync(() => this.s.requestKeyframe(stream));
  }

  /** Server: the next media event (target bitrate, deliveries, recovery / key frame needed, input). */
  nextServerEvent(): Promise<ServerMediaEvent | null> {
    return this.s.nextServerEvent();
  }

  async *serverEvents(): AsyncGenerator<ServerMediaEvent> {
    for (;;) {
      const e = await this.nextServerEvent();
      if (!e) return;
      yield e;
    }
  }

  /** Client: one input event (the `/input` body); returns its seq. A `media` error with "Overflow" is a 429. */
  sendInput(kind: "discrete" | "move", event: Buffer | object): number {
    const json = Buffer.isBuffer(event) ? event : Buffer.from(JSON.stringify(event));
    return sync(() => this.s.sendInput(kind, json));
  }

  /** Client: the decoder took (`ok`) or failed on a frame. */
  frameDecoded(stream: number, frame: number, ok = true): void {
    sync(() => this.s.frameDecoded(stream, frame, ok));
  }

  /** Client: the next media event (frames, audio packets, cursor, input acked / failed). */
  nextClientEvent(): Promise<ClientMediaEvent | null> {
    return this.s.nextClientEvent();
  }

  async *clientEvents(): AsyncGenerator<ClientMediaEvent> {
    for (;;) {
      const e = await this.nextClientEvent();
      if (!e) return;
      yield e;
    }
  }

  closed(): Promise<CloseInfo> {
    return this.s.closed();
  }
}

// MARK: RPC

export class RpcResponse {
  /** @internal */
  constructor(private readonly r: NativeRpcResponse) {}

  get status(): number {
    return this.r.status;
  }

  /** lower-case names */
  get headers(): Record<string, string> {
    return this.r.headers;
  }

  /** The next piece of the body; `null` at its end. */
  chunk(): Promise<Buffer | null> {
    return call(() => this.r.chunk());
  }

  /** The rest of the body (at most `limit` bytes, default 64 MiB). */
  readAll(limit?: number): Promise<Buffer> {
    return call(() => this.r.readAll(limit));
  }

  async text(): Promise<string> {
    return (await this.readAll()).toString("utf8");
  }

  async json(): Promise<unknown> {
    return JSON.parse(await this.text());
  }

  async *[Symbol.asyncIterator](): AsyncIterator<Buffer> {
    for (;;) {
      const c = await this.chunk();
      if (!c) return;
      yield c;
    }
  }

  /** Stops reading (a streamed response ends). */
  cancel(): void {
    this.r.cancel();
  }
}

export class RpcResponder {
  private started = false;

  /** @internal */
  constructor(private readonly r: NativeRpcResponder) {}

  head(status: number, headers: Record<string, string> = {}): Promise<void> {
    this.started = true;
    return call(() => this.r.head(status, headers));
  }

  write(data: Buffer | string): Promise<void> {
    return call(() => this.r.write(typeof data === "string" ? Buffer.from(data) : data));
  }

  /** Ends the body (a 200 head first if none was sent). */
  finish(): Promise<void> {
    this.started = true;
    return call(() => this.r.finish());
  }

  /** Head, body, finish. */
  respond(status: number, headers: Record<string, string> = {}, body?: Buffer | string): Promise<void> {
    this.started = true;
    const b = typeof body === "string" ? Buffer.from(body) : body;
    return call(() => this.r.respond(status, headers, b));
  }

  json(status: number, value: unknown, headers: Record<string, string> = {}): Promise<void> {
    return this.respond(status, { "content-type": "application/json", ...headers }, JSON.stringify(value));
  }

  /** Resolves when the client stopped reading (cancelled) or the session ended. */
  stopped(): Promise<void> {
    return this.r.stopped();
  }

  /** @internal a handler threw */
  fail(e: unknown): void {
    if (this.started) return;
    const message = e instanceof Error ? e.message : String(e);
    void this.json(500, { error: message }).catch(() => {});
  }
}
