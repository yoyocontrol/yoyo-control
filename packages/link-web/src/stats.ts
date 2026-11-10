import type { MediaCounters } from "./wasm.js";

/** Which road a session's packets take (docs/LINK.md「端点、地址、路径」; WebRTC has no `relay` this round). */
export type PathKind = "relay" | "lan" | "direct" | "punched" | "none";
/** This device's network interface. */
export type Iface = "wifi" | "cellular" | "wired" | "other";

/** The session's path: its kind and the remote address (`ip:port`) when known. */
export interface PathInfo {
  kind: PathKind;
  remote?: string;
}

/**
 * The media fields of `link.stats` (all optional: a session without media has none), as the Rust core's
 * `MediaStats` serializes them.
 */
export interface LinkMediaStats {
  lossPct?: number;
  mediaReceived?: number;
  mediaMissing?: number;
  fecRecovered?: number;
  nackRecovered?: number;
  nackSent?: number;
  lostFrames?: number;
  skippedFrames?: number;
  freezeCount?: number;
  freezeMs?: number;
  rateTargetMbps?: number;
  rateSentMbps?: number;
  rateCuts?: number;
  rateLossCuts?: number;
  jitterMs?: number;
  fps?: number;
  inputP50Ms?: number;
  inputP90Ms?: number;
  inputN?: number;
  audioLossPct?: number;
  audioRed?: number;
}

/** One end's view of a session: the `link.stats` object (docs/LINK.md「统计与日志」). */
export interface LinkStats extends LinkMediaStats {
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
}

/** The client media layer's counters as `link.stats`' media fields (what the Rust core's driver reports). */
export function linkMediaStats(m: MediaCounters): LinkMediaStats {
  const out: LinkMediaStats = {
    mediaReceived: m.mediaReceived,
    mediaMissing: m.mediaMissing,
    fecRecovered: m.fecRecovered,
    nackRecovered: m.nackRecovered,
    nackSent: m.nackSent,
    lostFrames: m.framesLost,
    skippedFrames: m.framesSkipped,
    freezeCount: m.freezes,
    freezeMs: m.freezeMs,
    inputN: m.inputEvents,
  };
  if (m.lossPct !== null) out.lossPct = m.lossPct;
  if (m.fps !== null) out.fps = m.fps;
  if (m.inputP50Ms !== null) out.inputP50Ms = m.inputP50Ms;
  if (m.inputP90Ms !== null) out.inputP90Ms = m.inputP90Ms;
  if (m.audioLossPct !== null) out.audioLossPct = m.audioLossPct;
  return out;
}

const ms = (v: number) => (v >= 10 ? String(Math.round(v)) : v.toFixed(1));
const one = (v: number) => v.toFixed(1);

/** `<path> <iface> rtt <min>/<p50>/<p90> ms loss … red …` (the `link:` line's body, as the Rust core writes it). */
export function statsLine(s: LinkStats): string {
  let out = `${s.path} ${s.iface} rtt ${ms(s.rttMinMs)}/${ms(s.rttP50Ms)}/${ms(s.rttP90Ms)} ms`;
  if (s.lossPct !== undefined) out += ` loss ${one(s.lossPct)} %`;
  if (s.fecRecovered !== undefined) out += ` fec ${s.fecRecovered}`;
  if (s.nackRecovered !== undefined || s.nackSent !== undefined) out += ` nack ${s.nackRecovered ?? 0}/${s.nackSent ?? 0}`;
  if (s.lostFrames !== undefined) out += ` lost ${s.lostFrames}`;
  if (s.skippedFrames !== undefined) out += ` skip ${s.skippedFrames}`;
  if (s.freezeCount !== undefined || s.freezeMs !== undefined) out += ` freeze ${s.freezeCount ?? 0}/${s.freezeMs ?? 0}`;
  if (s.rateTargetMbps !== undefined || s.rateSentMbps !== undefined) out += ` rate ${one(s.rateTargetMbps ?? 0)}/${one(s.rateSentMbps ?? 0)} Mbps`;
  if (s.rateCuts !== undefined || s.rateLossCuts !== undefined) out += ` cuts ${s.rateCuts ?? 0}/${s.rateLossCuts ?? 0}`;
  if (s.jitterMs !== undefined) out += ` jitter ${ms(s.jitterMs)} ms`;
  if (s.fps !== undefined) out += ` fps ${Math.round(s.fps)}`;
  if (s.inputP50Ms !== undefined || s.inputN !== undefined) out += ` input ${ms(s.inputP50Ms ?? 0)}/${ms(s.inputP90Ms ?? 0)} ms (${s.inputN ?? 0})`;
  if (s.audioLossPct !== undefined || s.audioRed !== undefined) {
    out += ` audio loss ${one(s.audioLossPct ?? 0)} %`;
    if (s.audioRed !== undefined) out += ` red ${s.audioRed}`;
  }
  return out;
}

/** A peer's `link.stats` message, leniently (null when it isn't one). */
export function parseLinkStats(m: Record<string, unknown>): LinkStats | null {
  const num = (k: string) => (typeof m[k] === "number" && Number.isFinite(m[k]) ? (m[k] as number) : undefined);
  const path = m.path, iface = m.iface;
  if (typeof path !== "string" || typeof iface !== "string") return null;
  const s: LinkStats = {
    path: (["relay", "lan", "direct", "punched"].includes(path) ? path : "none") as PathKind,
    iface: (["wifi", "cellular", "wired"].includes(iface) ? iface : "other") as Iface,
    rttMinMs: num("rttMinMs") ?? 0,
    rttP50Ms: num("rttP50Ms") ?? 0,
    rttP90Ms: num("rttP90Ms") ?? 0,
    bytesSent: num("bytesSent") ?? 0,
    bytesReceived: num("bytesReceived") ?? 0,
    packetsLost: num("packetsLost") ?? 0,
    datagramsSent: num("datagramsSent") ?? 0,
    datagramsReceived: num("datagramsReceived") ?? 0,
    datagramDrops: num("datagramDrops") ?? 0,
  };
  if (typeof m.remote === "string") s.remote = m.remote;
  const media: (keyof LinkMediaStats)[] = ["lossPct", "mediaReceived", "mediaMissing", "fecRecovered", "nackRecovered", "nackSent", "lostFrames", "skippedFrames", "freezeCount", "freezeMs", "rateTargetMbps", "rateSentMbps", "rateCuts", "rateLossCuts", "jitterMs", "fps", "inputP50Ms", "inputP90Ms", "inputN", "audioLossPct", "audioRed"];
  for (const k of media) {
    const v = num(k);
    if (v !== undefined) s[k] = v;
  }
  return s;
}

/** RTT samples over a sliding window (ms; times in ms): min / p50 / p90 as the Rust core summarizes them. */
export class RttWindow {
  private samples: { at: number; ms: number }[] = [];

  constructor(private readonly windowMs = 10_000) {}

  push(at: number, rttMs: number): void {
    this.samples.push({ at, ms: rttMs });
    while (this.samples.length && at - this.samples[0]!.at > this.windowMs) this.samples.shift();
  }

  /** (min, p50, p90); zeros without samples. */
  summary(): [number, number, number] {
    if (this.samples.length === 0) return [0, 0, 0];
    const v = this.samples.map((s) => s.ms).sort((a, b) => a - b);
    const at = (p: number) => v[Math.round((v.length - 1) * p)]!;
    return [v[0]!, at(0.5), at(0.9)];
  }
}

/** An IP address on the local network: private, link-local, loopback, CGNAT excluded (100.64/10 counts as public), ULA. */
export function isLocalAddress(ip: string): boolean {
  const a = ip.trim().toLowerCase().replace(/^\[|\]$/g, "");
  if (a.endsWith(".local")) return true;
  const v4 = /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(a.startsWith("::ffff:") ? a.slice(7) : a);
  if (v4) {
    const [x, y] = [Number(v4[1]), Number(v4[2])];
    return x === 10 || x === 127 || (x === 172 && y >= 16 && y <= 31) || (x === 192 && y === 168) || (x === 169 && y === 254);
  }
  return a === "::1" || /^f[cd][0-9a-f]{0,2}:/.test(a) || /^fe[89ab][0-9a-f]?:/.test(a);
}

/** One side of the selected candidate pair, as `getStats()` reports it. */
export interface CandidateInfo {
  candidateType?: string;
  address?: string;
  port?: number;
}

/**
 * The path kind of the selected candidate pair (docs/LINK.md「WebRTC」): a private remote address = `lan`; the
 * server's own public address (a host candidate: an interface or the router mapping it advertises) = `direct`; a
 * reflexive one (srflx / prflx: learned through NAT) = `punched`; a relayed one = `relay`.
 */
export function classifyPath(local: CandidateInfo | undefined, remote: CandidateInfo | undefined): PathInfo {
  if (!remote) return { kind: "none" };
  const r: PathInfo = { kind: "none" };
  if (remote.address) r.remote = remote.address.includes(":") ? `[${remote.address}]:${remote.port ?? 0}` : `${remote.address}:${remote.port ?? 0}`;
  if (remote.candidateType === "relay" || local?.candidateType === "relay") r.kind = "relay";
  else if (remote.address && isLocalAddress(remote.address)) r.kind = "lan";
  else if (remote.candidateType === "srflx" || remote.candidateType === "prflx") r.kind = "punched";
  else r.kind = "direct";
  return r;
}

/** This device's interface from `navigator.connection` (Chrome / Android; Safari has none: `other`). */
export function browserIface(): Iface {
  const c = (globalThis.navigator as { connection?: { type?: string } } | undefined)?.connection;
  switch (c?.type) {
    case "wifi":
      return "wifi";
    case "cellular":
      return "cellular";
    case "ethernet":
      return "wired";
    default:
      return "other";
  }
}
