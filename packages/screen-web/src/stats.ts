import { netQualityLine } from "./net.js";
import type { NetQuality, PlayoutReport } from "./types.js";

/**
 * The screen page's stats line (three fingers on iOS): what the iOS kit's `ScreenSession.statsText` shows, as data and
 * a formatter. Numbers, units and protocol codes only: never localized, nothing for a page to translate.
 *
 * ```
 *  h264 · 60 fps · 412 KB/s · 2.1 ms · link lan · live ready
 *  smooth · 60 Hz · gap 17/18 · arr 16/24 · hitch 0.0/s · stall 0.0/0.0/s · buf 28 ms · jit 24 · cap 100 · drop 0.5/s · ~62 ms
 *  lan wifi rtt 0.4/1.2/2.0 ms loss 0.0 % …            (a link's own line; else the server's grade: net good · rtt 9/12)
 *  audio 120 ms (buf 118) · 0 underruns · 0 drops · 96 kbps
 * ```
 */

/** The stream's numbers over the window since the previous snapshot (`VideoStream.stats()`). */
export interface StreamStatsSnapshot {
  /** `h264` (`-` before the first picture). */
  codec: string;
  /** Pictures drawn per second. */
  fps: number;
  kilobytesPerSecond: number;
  /** Average decode time of the window's pictures (null: none decoded). */
  decodeMs: number | null;
  /** The playout of the last few seconds (null: nothing drawn). */
  playout: PlayoutReport | null;
  /** The playout is responsive right now (the user interacts). */
  interactive: boolean;
  /** The server's latest grade of the stream's network (null: none; on a link: none, the link's line stands in). */
  net: NetQuality | null;
  /** The input's way to the computer: p50 of the input round trips (ms; null: none answered). */
  inputRttP50Ms: number | null;
  /** The freshest round trip of the stream's path (ms; the ack answers' or the link's min; null: none). */
  rttMinMs: number | null;
}

/** `h264 · 30 fps · 412 KB/s · 2.1 ms` (`· live` while interactive). */
export function streamLine(s: Pick<StreamStatsSnapshot, "codec" | "fps" | "kilobytesPerSecond" | "decodeMs" | "interactive">): string {
  const parts = [s.codec, `${Math.round(s.fps)} fps`, `${Math.round(s.kilobytesPerSecond)} KB/s`];
  if (s.decodeMs !== null) parts.push(`${s.decodeMs.toFixed(1)} ms`);
  if (s.interactive) parts.push("live");
  return parts.join(" · ");
}

/** The playout report's line: `smooth · 60 Hz · pace 33 · gap 33/41 · arr 33/52 · hitch 0.3/s · stall 0.3/0.0/s ·
 *  buf 28 ms · jit 24 · cap 100 · drop 0.5/s`; interactive: `responsive · … · touch 21 ms`. */
export function playoutReportLine(r: PlayoutReport): string {
  const ms = (v: number | undefined) => (v === undefined ? "-" : String(Math.round(v)));
  const parts = [r.mode === "smooth" ? "smooth" : "responsive"];
  if (r.refreshHz !== undefined) parts.push(`${Math.round(r.refreshHz)} Hz`);
  if (r.paceMs !== undefined) parts.push(`pace ${Math.round(r.paceMs)}`);
  parts.push(`gap ${ms(r.gapP50Ms)}/${ms(r.gapP90Ms)}`, `arr ${ms(r.arrivalGapP50Ms)}/${ms(r.arrivalGapP90Ms)}`);
  if (r.hitchesPerSec !== undefined) parts.push(`hitch ${r.hitchesPerSec.toFixed(1)}/s`);
  if (r.stall150PerSec !== undefined) parts.push(`stall ${r.stall150PerSec.toFixed(1)}/${(r.stall300PerSec ?? 0).toFixed(1)}/s`);
  if (r.bufferMs !== undefined) parts.push(`buf ${Math.round(r.bufferMs)} ms`);
  if (r.jitterP95Ms !== undefined) parts.push(`jit ${Math.round(r.jitterP95Ms)}`);
  if (r.bufferCapMs !== undefined) parts.push(`cap ${Math.round(r.bufferCapMs)}`);
  if (r.touchBufferMs !== undefined) parts.push(`touch ${Math.round(r.touchBufferMs)} ms`);
  if (r.droppedPerSec !== undefined) parts.push(`drop ${r.droppedPerSec.toFixed(1)}/s`);
  return parts.join(" · ");
}

/** The computer's part of a touch's way (capture 14 + encode ~12 + write, ms). */
export const LATENCY_COMPUTER_MS = 30;

/**
 * How long a touch takes to show here (ms; null: no round trip known), as the iOS kit's `ScreenLatencyEstimate`: the
 * input's way (half the input round trip's p50; half the path's min while no input was answered), the computer's part,
 * the picture's way back (half the path's min; half the input p50 without one), the playout's hold, the decode and one
 * refresh.
 */
export function latencyEstimate(o: { inputRttP50Ms: number | null; rttMinMs: number | null; holdMs: number | null; decodeMs: number | null; refreshHz: number | null }): number | null {
  const ms = (v: number | null) => (v !== null && Number.isFinite(v) && v >= 0 ? v : null);
  const input = ms(o.inputRttP50Ms), path = ms(o.rttMinMs);
  const up = input ?? path, down = path ?? input;
  if (up === null || down === null) return null;
  const hz = ms(o.refreshHz) || 60;
  return up / 2 + LATENCY_COMPUTER_MS + down / 2 + (ms(o.holdMs) ?? 0) + (ms(o.decodeMs) ?? 0) + 1000 / hz;
}

/** The sound's stats (`ScreenAudio.stats()`). */
export interface AudioStats {
  /** The depth asked for and what is buffered now (ms; null: not playing yet). */
  depthMs: number | null;
  bufferedMs: number | null;
  underruns: number;
  /** Packets dropped (late, or over the queue's cap). */
  drops: number;
  kbps: number;
}

/** `audio 120 ms (buf 118) · 0 underruns · 0 drops · 96 kbps` (`audio · 96 kbps` before it plays). */
export function audioStatsLine(a: AudioStats): string {
  if (a.depthMs === null) return `audio · ${Math.round(a.kbps)} kbps`;
  return `audio ${Math.round(a.depthMs)} ms (buf ${Math.round(a.bufferedMs ?? 0)}) · ${a.underruns} underruns · ${a.drops} drops · ${Math.round(a.kbps)} kbps`;
}

/** What `statsLines` puts together. */
export interface StatsLineInput {
  stream: StreamStatsSnapshot;
  /** The way: a link's `pathLabel` (`link lan`), else the host's name for its route (`tunnel`, `lan`…). */
  way: string;
  /** The connection's codes (`ConnectionModel.statsText`): `live ready`, `reconnecting helper-restart · locked`. */
  connection: string;
  /** A link's own line (`ScreenLink.statsLine`): in place of the server's grade. */
  linkLine?: string | null;
  /** The sound, while a sound stream is open. */
  audio?: AudioStats | null;
}

/** The stats line's rows (1–4): stream · way · connection; playout · latency; the network; the sound. */
export function statsLines(i: StatsLineInput): string[] {
  const s = i.stream;
  const lines = [[streamLine(s), i.way, i.connection].filter((p) => p).join(" · ")];
  const latency = latencyEstimate({ inputRttP50Ms: s.inputRttP50Ms, rttMinMs: s.rttMinMs, holdMs: s.playout?.bufferMs ?? null, decodeMs: s.decodeMs, refreshHz: s.playout?.refreshHz ?? null });
  const second = [s.playout ? playoutReportLine(s.playout) : null, latency !== null ? `~${Math.round(latency)} ms` : null].filter((p): p is string => p !== null);
  if (second.length) lines.push(second.join(" · "));
  const net = i.linkLine ?? (s.net ? netQualityLine(s.net) : null);
  if (net) lines.push(net);
  if (i.audio) lines.push(audioStatsLine(i.audio));
  return lines;
}
