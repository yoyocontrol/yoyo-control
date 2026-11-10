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
/** The server's `link.probe.done` as its half of the report. */
export declare function probeServerReport(m: Record<string, unknown>): ProbeServerReport;
/** (min, p50, p90) of RTT samples; null without any. */
export declare function rttSummary(samples: number[]): [number, number, number] | null;
/** The client's half of the report: the media counters' change over the test and the probe stream's counters. */
export declare function probeReport(p: {
    path: PathKind;
    iface: Iface;
    durationMs: number;
    rttIdleMs: number | null;
    rtts: number[];
    before: MediaCounters | null;
    after: MediaCounters | null;
    probe: ProbeCounters | null;
    done: Record<string, unknown> | null;
}): ProbeReport;
