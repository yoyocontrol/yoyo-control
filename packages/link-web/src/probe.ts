import type { Iface, PathKind } from "./stats.js";
import type { MediaCounters, ProbeCounters } from "./wasm.js";

/**
 * The speed test's result (docs/LINK.md「测速」; `LinkSession.probe`): what this session's path carries the way a
 * picture goes. The same shape (camelCase) as the native Link's report. Rates in Mbit/s, times in ms; null = not
 * measured.
 */
export interface ProbeReport {
  transport: "quic" | "rtc";
  path: PathKind;
  iface: Iface;
  durationMs: number;
  /** The idle path's RTT (lowest of the 10 s before), and the RTT under the test's load. */
  rttIdleMs: number | null;
  rttP50Ms: number | null;
  rttP90Ms: number | null;
  /** Frames delivered; their payload rate over the whole test, the best second, the last two seconds. */
  frames: number;
  receivedMbps: number | null;
  peakMbps: number | null;
  finalMbps: number | null;
  /** Frames per second over the last two seconds (the frame-rate cap follows the rate). */
  finalFps: number | null;
  /** Media datagrams lost before FEC (%), and what FEC / NACK got back. */
  lossPct: number | null;
  fecRecovered: number;
  nackRecovered: number;
  lostFrames: number;
  skippedFrames: number;
  freezes: number;
  freezeMs: number;
  /** The computer's half (`link.probe.done`; null: it didn't come). */
  server: ProbeServerReport | null;
}

export interface ProbeServerReport {
  /** The rate control's target at the end, and the highest it reached. */
  targetMbps: number;
  maxTargetMbps: number;
  /** The encoder rate at the end, and the frame-rate cap at that rate. */
  encoderMbps: number;
  fpsCap: number;
  /** Everything it sent (FEC, retransmits included). */
  sentMbps: number | null;
  frames: number;
  bytes: number;
  rateCuts: number;
  rateLossCuts: number;
  retransmits: number;
  jitterMs: number | null;
  /** "done" or "stopped". */
  reason: string;
}

const mbps = (bps: number | null | undefined): number | null => (typeof bps === "number" ? Math.round(bps / 1e4) / 100 : null);
const num = (v: unknown, d = 0): number => (typeof v === "number" && Number.isFinite(v) ? v : d);
const numOrNull = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);

/** The server's `link.probe.done` as its half of the report. */
export function probeServerReport(m: Record<string, unknown>): ProbeServerReport {
  return {
    targetMbps: num(m.targetMbps),
    maxTargetMbps: num(m.maxTargetMbps),
    encoderMbps: num(m.encoderMbps),
    fpsCap: num(m.fpsCap),
    sentMbps: numOrNull(m.sentMbps),
    frames: num(m.frames),
    bytes: num(m.bytes),
    rateCuts: num(m.rateCuts),
    rateLossCuts: num(m.rateLossCuts),
    retransmits: num(m.retransmits),
    jitterMs: numOrNull(m.jitterMs),
    reason: typeof m.reason === "string" ? m.reason : "done",
  };
}

/** (min, p50, p90) of RTT samples; null without any. */
export function rttSummary(samples: number[]): [number, number, number] | null {
  if (!samples.length) return null;
  const v = [...samples].sort((a, b) => a - b);
  const at = (p: number) => v[Math.round((v.length - 1) * p)]!;
  return [v[0]!, at(0.5), at(0.9)];
}

/** The client's half of the report: the media counters' change over the test and the probe stream's counters. */
export function probeReport(p: {
  path: PathKind;
  iface: Iface;
  durationMs: number;
  rttIdleMs: number | null;
  rtts: number[];
  before: MediaCounters | null;
  after: MediaCounters | null;
  probe: ProbeCounters | null;
  done: Record<string, unknown> | null;
}): ProbeReport {
  const d = (k: keyof MediaCounters) => Math.max(0, num(p.after?.[k]) - num(p.before?.[k]));
  const received = d("mediaReceived");
  const missing = d("mediaMissing");
  const loaded = rttSummary(p.rtts);
  const r2 = (v: number | null) => (v === null ? null : Math.round(v * 100) / 100);
  return {
    transport: "rtc",
    path: p.path,
    iface: p.iface,
    durationMs: p.durationMs,
    rttIdleMs: p.rttIdleMs,
    rttP50Ms: loaded ? loaded[1] : null,
    rttP90Ms: loaded ? loaded[2] : null,
    frames: num(p.probe?.frames),
    receivedMbps: mbps(p.probe?.meanBps),
    peakMbps: mbps(p.probe?.peakBps),
    finalMbps: mbps(p.probe?.finalBps),
    finalFps: p.probe?.finalFps == null ? null : Math.round(p.probe.finalFps * 10) / 10,
    lossPct: received + missing > 0 ? r2((missing * 100) / (received + missing)) : null,
    fecRecovered: d("fecRecovered"),
    nackRecovered: d("nackRecovered"),
    lostFrames: d("framesLost"),
    skippedFrames: d("framesSkipped"),
    freezes: d("freezes"),
    freezeMs: d("freezeMs"),
    server: p.done ? probeServerReport(p.done) : null,
  };
}
