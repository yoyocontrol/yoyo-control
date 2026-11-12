// The native addon (link/node, crate uu-link-node): its shape, and where it is loaded from.
//
// Order: $YOYO_LINK_NATIVE (a path to a .node file), then native/uu-link.<platform>-<arch>[-gnu].node beside dist/
// (the prebuilt files a release ships), then the workspace build (link/target/{release-node,debug}) for development.

import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export interface NativeBinding { id: string; key: string; sig: string }
export interface NativeAddrInfo { id: string; relays: string[]; direct: string[] }
export interface NativeHello {
  credential: string;
  device: { id: string; name: string };
  app: { name: string; version: string };
  features?: string[];
}
export interface NativeServerInfo { id: string; name: string; platform: string }
export interface NativeWelcome { server: NativeServerInfo; principal: unknown; features: string[]; maxDatagram: number }
export interface NativeAuthRequest {
  hello: NativeHello;
  clientKey: string;
  sourceAddr?: string;
  sourceRelay?: string;
  path: string;
}
export interface NativeAuthAnswer {
  ok: boolean;
  principal?: unknown;
  features?: string[];
  code?: string;
  message?: string;
}
export interface NativeRpcRequest { method: string; path: string; headers?: Record<string, string> }
export interface NativeCloseInfo { code?: number; reason: string; remote: boolean; description: string }

export interface NativeRpcResponse {
  readonly status: number;
  readonly headers: Record<string, string>;
  chunk(): Promise<Buffer | null>;
  readAll(limit?: number): Promise<Buffer>;
  cancel(): void;
}

export interface NativeRpcResponder {
  head(status: number, headers?: Record<string, string>): Promise<void>;
  write(data: Buffer): Promise<void>;
  finish(): Promise<void>;
  respond(status: number, headers?: Record<string, string>, body?: Buffer): Promise<void>;
  stopped(): Promise<void>;
}

export interface FrameMeta {
  codec: "h264" | "hevc";
  kind: "delta" | "key" | "refine" | "keepalive" | "recovery";
  width: number;
  height: number;
  /** µs since the Unix epoch (latency stats only) */
  captureUs?: number;
  /** recovery frames: the frame they reference */
  recoveryBase?: number;
}
export interface VideoFrame {
  stream: number;
  frame: number;
  meta: FrameMeta;
  /** the Annex-B access unit */
  au: Buffer;
  firstArrivalUs: number;
  deliveredAtUs: number;
}
export interface AudioPacket { stream: number; aseq: number; timeUs: number; data: Buffer; recovered: boolean; gapBefore: number }
export interface InputEvent { seq: number; kind: "discrete" | "move"; json: Buffer }
export type ServerMediaEvent =
  | { type: "targetBitrate"; targetBps: number; encoderBps: number }
  | { type: "frameDelivered"; stream: number; frame: number }
  | { type: "recoveryNeeded"; stream: number; lastDelivered?: number }
  | { type: "keyframeNeeded"; stream: number }
  | { type: "input"; input: InputEvent };
export type ClientMediaEvent =
  | { type: "frame"; frame: VideoFrame }
  | { type: "audio"; audio: AudioPacket }
  | { type: "cursor"; stream: number; cseq: number; json: Buffer }
  | { type: "inputAcked"; through: number }
  | { type: "inputFailed"; seq: number };

export interface NativeSession {
  readonly id: number;
  readonly isServer: boolean;
  readonly remoteId: string;
  readonly transport: "quic" | "rtc";
  readonly maxDatagramSize: number;
  targetBitrate: number;
  readonly isClosed: boolean;
  hello(): NativeHello;
  welcome(): NativeWelcome;
  sendControl(message: unknown): Promise<void>;
  recvControl(): Promise<Record<string, unknown> | null>;
  request(request: NativeRpcRequest, body?: Buffer): Promise<NativeRpcResponse>;
  sendDatagram(channel: number, payload: Buffer): void;
  sendDatagramRaw(datagram: Buffer): void;
  recvDatagram(channel: number): Promise<Buffer | null>;
  path(): { kind: string; remote?: string };
  stats(): Record<string, unknown>;
  peerStats(): Record<string, unknown> | null;
  setMediaStats(stats: Record<string, unknown>): void;
  close(code?: number, reason?: string): Promise<void>;
  closed(): Promise<NativeCloseInfo>;
  openVideo(stream: number): void;
  closeVideo(stream: number): void;
  openAudio(stream: number): void;
  closeAudio(stream: number): void;
  canSendFrame(stream: number): boolean;
  /** Missing in addons built before it. */
  frameRateCap?(stream: number): number | null;
  sendFrame(stream: number, meta: FrameMeta, au: Buffer): number;
  sendAudio(stream: number, timeUs: number, opus: Buffer): number;
  sendCursor(stream: number, json: Buffer): void;
  requestKeyframe(stream: number): void;
  nextServerEvent(): Promise<ServerMediaEvent | null>;
  sendInput(kind: "discrete" | "move", json: Buffer): number;
  frameDecoded(stream: number, frame: number, ok: boolean): void;
  nextClientEvent(): Promise<ClientMediaEvent | null>;
}

export interface NativeListener {
  accept(): Promise<NativeSession | null>;
  acceptRtcOffer(offerJson: string, sourceIp?: string): Promise<string>;
}

export interface NativeEndpoint {
  readonly id: string;
  readonly port: number;
  readonly rtcPort: number | null;
  addRtcExternalAddr(addr: string): boolean;
  removeRtcExternalAddr(addr: string): boolean;
  addrInfo(): NativeAddrInfo;
  watchAddr(cb: (info: NativeAddrInfo) => void): void;
  binding(identityKey: Buffer): NativeBinding;
  networkChanged(iface?: string): Promise<void>;
  addExternalAddr(addr: string): Promise<void>;
  removeExternalAddr(addr: string): Promise<boolean>;
  dial(target: { id: string; relays?: string[]; direct?: string[] }, hello: NativeHello, connectTimeoutMs?: number): Promise<NativeSession>;
  dialRtc(signal: (offerJson: string) => Promise<string>, fingerprint: string, hello: NativeHello, connectTimeoutMs?: number): Promise<NativeSession>;
  listen(
    settings: { server: NativeServerInfo; features?: string[]; rpcBlockedPaths?: string[]; maxRequestBody?: number; recoveryOnNack?: boolean; identityKey?: Buffer },
    authenticate: (request: NativeAuthRequest) => Promise<NativeAuthAnswer>,
    rpc?: (session: NativeSession, request: NativeRpcRequest, body: Buffer, responder: NativeRpcResponder) => void,
  ): NativeListener;
  close(): Promise<void>;
}

export interface NativeAddon {
  version(): string;
  generateLinkKey(): Buffer;
  linkPublicKey(secretKey: Buffer): string;
  loadOrCreateLinkKey(path: string): Buffer;
  identityFingerprint(identityKey: Buffer): string;
  signBinding(identityKey: Buffer, linkPublicKey: string): NativeBinding;
  verifyBinding(binding: NativeBinding, fingerprint: string): string;
  setLogSink(sink: ((level: string, message: string) => void) | null): void;
  bindEndpoint(config: {
    role: "server" | "client";
    secretKey: Buffer;
    port?: number;
    relays?: string[];
    portmapper?: boolean;
    guard?: object;
    rtcPort?: number;
    rtcStunServers?: string[];
    rtcExternalOnly?: boolean;
    bindIps?: string[];
  }): Promise<NativeEndpoint>;
}

export function nativeName(platform = process.platform, arch = process.arch): string {
  return `uu-link.${platform}-${arch}${platform === "linux" ? "-gnu" : ""}.node`;
}

function candidates(): string[] {
  const here = dirname(fileURLToPath(import.meta.url));
  const pkg = join(here, "..");
  const ext = process.platform === "darwin" ? "dylib" : "so";
  const target = join(pkg, "..", "..", "link", "target");
  // beside the JS too: a copy of dist/ with the addon in it (the Linux server's vendor/link)
  const list = [join(pkg, "native", nativeName()), join(here, nativeName())];
  list.push(join(target, "release-node", `libuu_link_node.${ext}`), join(target, "debug", `libuu_link_node.${ext}`));
  const env = process.env.YOYO_LINK_NATIVE;
  return env ? [env, ...list] : list;
}

let loaded: NativeAddon | null = null;

export function native(): NativeAddon {
  if (loaded) return loaded;
  const tried: string[] = [];
  for (const path of candidates()) {
    if (!existsSync(path)) {
      tried.push(path);
      continue;
    }
    const m = { exports: {} as NativeAddon };
    process.dlopen(m, path);
    loaded = m.exports;
    return loaded;
  }
  throw new Error(`@yoyocontrol/link: no native addon for ${process.platform}-${process.arch} (looked at ${tried.join(", ")})`);
}
