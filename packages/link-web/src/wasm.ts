import init, { ClientMedia as WasmClientMedia } from "./wasm/uu_link_wasm.js";

/**
 * The media layer as WebAssembly (link/wasm: `uu-link-media`'s `ClientMedia`). One module per page; every session
 * makes its own `ClientMedia` from it.
 *
 * Where the `.wasm` comes from: by default the file shipped next to this module (`dist/wasm/uu_link_wasm_bg.wasm`,
 * resolved with `new URL(…, import.meta.url)`, which Vite and other bundlers turn into an asset URL). A host that
 * serves it elsewhere passes `wasm`: a URL, a `Response`, the bytes, or a compiled `WebAssembly.Module`.
 */
export type WasmSource = string | URL | Response | BufferSource | WebAssembly.Module;

/** The client config (every field optional; the media layer's defaults otherwise). */
export interface ClientMediaConfig {
  /** Largest datagram the transport takes (bytes; WebRTC: 1200). */
  maxDatagram?: number;
  feedbackIntervalMs?: number;
  feedbackIdleMs?: number;
  audioReportIntervalMs?: number;
  /** Every NACK goes again this long after the first (0: once). */
  nackRepeatMs?: number;
  inputMaxUnacked?: number;
}

/** A frame for the decoder: in order, its reference chain intact. `au` is a fresh copy the caller owns. */
export interface MediaFrame {
  type: "frame";
  stream: number;
  frame: number;
  codec: "h264" | "hevc";
  kind: "key" | "delta" | "refine" | "keepalive" | "recovery";
  width: number;
  height: number;
  /** The sender's capture time (µs since 1970; 0: not said). */
  captureUs: number;
  /** Recovery frames: the frame they reference (0: none). */
  recoveryBase: number;
  /** Media clock (µs): its first shard, and when it was delivered. */
  firstArrivalUs: number;
  deliveredUs: number;
  au: Uint8Array;
}

/** What the media layer reports. */
export type MediaEvent =
  | MediaFrame
  /** One Opus packet in `seq` order (`gapBefore` packets are missing before it). `timeUs`: the sender's clock. */
  | { type: "audio"; stream: number; seq: number; timeUs: number; data: Uint8Array; recovered: boolean; gapBefore: number }
  /** A newer cursor position (JSON `{x, y, visible, shapeId}`). */
  | { type: "cursor"; stream: number; cseq: number; json: string }
  /** Every discrete input event up to `through` arrived. */
  | { type: "inputAcked"; through: number }
  /** A discrete input event was not acknowledged within 2 s and was dropped. */
  | { type: "inputFailed"; seq: number };

/** The media layer's counters since the session started (unknown values null). */
export interface MediaCounters {
  atUs: number;
  rttMinMs: number | null;
  rttP50Ms: number | null;
  rttP90Ms: number | null;
  lossPct: number | null;
  mediaReceived: number;
  mediaMissing: number;
  fecRecovered: number;
  nackRecovered: number;
  nackSent: number;
  framesDelivered: number;
  framesLost: number;
  framesSkipped: number;
  freezes: number;
  freezeMs: number;
  fps: number | null;
  inputP50Ms: number | null;
  inputP90Ms: number | null;
  inputEvents: number;
  inputFailed: number;
  audioLossPct: number | null;
  audioLost: number;
  audioRecovered: number;
}

/** One frame's fate on this side (the playout report's `rx`). Times: ms on the media clock. */
export interface RxTrace {
  stream: number;
  frame: number;
  fate: "delivered" | "skipped" | "lost";
  kind: number | null;
  au: number;
  captureMs: number | null;
  firstMs: number | null;
  lastMs: number | null;
  completeMs: number | null;
  decidedMs: number;
  shards: number;
  fec: number;
  retx: number;
  nacks: number;
}

/** A speed-test stream's counters (rates in bits/s; null: not enough yet). */
export interface ProbeCounters {
  frames: number;
  bytes: number;
  spanUs: number;
  meanBps: number | null;
  peakBps: number | null;
  finalBps: number | null;
  finalFps: number | null;
}

/** The typed face of the wasm `ClientMedia` (times in µs on the caller's clock). */
export interface ClientMediaEngine {
  setMaxDatagram(n: number): void;
  setRtt(nowUs: number, rttUs: number): void;
  openVideo(stream: number): void;
  closeVideo(stream: number): void;
  /** Older wasm builds lack the three below (the speed test then says so). */
  hasVideo?(stream: number): boolean;
  openProbe?(stream: number, nowUs: number): void;
  probeStats?(stream: number, nowUs: number): ProbeCounters | undefined;
  openAudio(stream: number): void;
  closeAudio(stream: number): void;
  onDatagram(bytes: Uint8Array, nowUs: number): boolean;
  pollTransmit(nowUs: number): Uint8Array | undefined;
  pollEvent(): MediaEvent | undefined;
  pollTimeout(nowUs: number): number | undefined;
  handleTimeout(nowUs: number): void;
  /** Returns the seq; throws `"overflow"` / `"too-large"`. */
  sendInput(nowUs: number, json: string, move: boolean): number;
  frameDecoded(stream: number, frame: number, ok: boolean): void;
  requestKeyframe(stream: number): void;
  inputUnacked(): number;
  malformed(): number;
  stats(nowUs: number): MediaCounters;
  takeRxTraces(): RxTrace[];
  /** Frees the wasm memory (the session ended). */
  free(): void;
}

/** The loaded module: makes media layers. */
export interface LinkMediaModule {
  createClientMedia(config?: ClientMediaConfig): ClientMediaEngine;
}

/** The `.wasm` shipped next to this module. */
export const defaultWasmUrl = (): URL => new URL("./wasm/uu_link_wasm_bg.wasm", import.meta.url);

let loaded: Promise<LinkMediaModule> | null = null;

const MODULE: LinkMediaModule = {
  createClientMedia: (config) => new WasmClientMedia(config ?? {}) as unknown as ClientMediaEngine,
};

/**
 * Loads (once per page) and returns the media layer. `wasm` overrides where the `.wasm` comes from (see `WasmSource`);
 * the first call's source wins (one instance per page), a failed load is tried again on the next call.
 */
export function loadLinkMedia(wasm?: WasmSource): Promise<LinkMediaModule> {
  if (loaded) return loaded;
  const source = typeof wasm === "string" ? new URL(wasm, globalThis.location?.href) : (wasm ?? defaultWasmUrl());
  loaded = init({ module_or_path: source }).then(
    () => MODULE,
    (e: unknown) => {
      loaded = null;
      throw e;
    },
  );
  return loaded;
}
