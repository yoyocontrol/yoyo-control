import { percentile } from "./playout.js";
import type { PlayoutReport } from "./types.js";

/**
 * The playout report's measurements over a sliding window (the iOS kit's `ScreenPlayoutMeter`), pure: every time is
 * passed in (ms, the page's clock). Pictures shown (with their decode time and, for live pictures, their `X-Frame-Time`),
 * whole picture parts arrived and decoded pictures dropped undrawn. Gaps longer than `pauseMs` are pauses of the content,
 * not gaps of the playout, and are left out. A hitch is a gap of more than twice the median (and at least `minHitchMs`);
 * a stall is live pictures in a row shown `STALL_MS.short` / `.long` further apart than the computer captured them.
 */
export class PlayoutMeter {
  /** The two stall lengths reported (`stall150PerSec` / `stall300PerSec`). */
  static readonly STALL_MS = { short: 150, long: 300 } as const;

  private since: number | null = null;
  private arrivals: number[] = [];
  private shownAt: { at: number; decodeMs: number | null; macTime: number | null }[] = [];
  private drops: { at: number; count: number }[] = [];

  constructor(
    readonly windowMs = 3000,
    readonly pauseMs = 250,
    readonly minHitchMs = 50,
  ) {}

  /** Starts over (a new stream). */
  reset(now: number): void {
    this.since = now;
    this.arrivals = [];
    this.shownAt = [];
    this.drops = [];
  }

  /** A whole live picture part arrived. */
  arrived(t: number): void {
    this.since ??= t;
    this.arrivals.push(t);
    this.prune(t);
  }

  /** A picture was drawn at `t`; `macTime`: a live picture's `X-Frame-Time` (null for refine / keepalive). */
  shown(t: number, decodeMs: number | null, macTime: number | null = null): void {
    this.since ??= t;
    const ok = (v: number | null) => (v !== null && Number.isFinite(v) ? v : null);
    const d = ok(decodeMs);
    this.shownAt.push({ at: t, decodeMs: d !== null && d >= 0 ? d : null, macTime: ok(macTime) });
    this.prune(t);
  }

  /** Decoded pictures that were never drawn. */
  dropped(count: number, t: number): void {
    if (count <= 0) return;
    this.drops.push({ at: t, count });
    this.prune(t);
  }

  /** The window's measurements (null when nothing was shown in it); the caller adds the playout's own fields. */
  report(mode: PlayoutReport["mode"], now: number): PlayoutReport | null {
    const from = now - this.windowMs;
    const shown = this.shownAt.filter((s) => s.at > from);
    if (shown.length === 0 || this.since === null) return null;
    const span = Math.max(Math.min(this.windowMs, now - this.since), 500) / 1000;
    const gaps = PlayoutMeter.gaps(shown.map((s) => s.at), this.pauseMs);
    const arrivalGaps = PlayoutMeter.gaps(this.arrivals.filter((a) => a > from), this.pauseMs);
    const p50 = percentile(gaps, 0.5);
    const r: PlayoutReport = { mode, fps: shown.length / span };
    if (p50 !== undefined) {
      r.gapP50Ms = p50;
      r.gapP90Ms = percentile(gaps, 0.9)!;
      r.hitchesPerSec = gaps.filter((g) => g > Math.max(2 * p50, this.minHitchMs)).length / span;
    }
    const a50 = percentile(arrivalGaps, 0.5);
    if (a50 !== undefined) {
      r.arrivalGapP50Ms = a50;
      r.arrivalGapP90Ms = percentile(arrivalGaps, 0.9)!;
    }
    r.droppedPerSec = this.drops.filter((d) => d.at > from).reduce((n, d) => n + d.count, 0) / span;
    const decodes = shown.map((s) => s.decodeMs).filter((d): d is number => d !== null);
    if (decodes.length) r.decodeMs = decodes.reduce((a, b) => a + b, 0) / decodes.length;
    const live = shown.filter((s) => s.macTime !== null);
    if (live.length >= 2) {
      const excess: number[] = [];
      for (let i = 1; i < live.length; i++) excess.push(live[i]!.at - live[i - 1]!.at - (live[i]!.macTime! - live[i - 1]!.macTime!));
      const stalls = (over: number) => excess.filter((e) => e >= over - 1e-6).length / span;
      r.stall150PerSec = stalls(PlayoutMeter.STALL_MS.short);
      r.stall300PerSec = stalls(PlayoutMeter.STALL_MS.long);
    }
    return r;
  }

  private static gaps(times: number[], pause: number): number[] {
    const out: number[] = [];
    for (let i = 1; i < times.length; i++) {
      const g = times[i]! - times[i - 1]!;
      if (g >= 0 && g <= pause) out.push(g);
    }
    return out;
  }

  private prune(now: number): void {
    const from = now - this.windowMs;
    while (this.arrivals.length && this.arrivals[0]! <= from) this.arrivals.shift();
    while (this.shownAt.length && this.shownAt[0]!.at <= from) this.shownAt.shift();
    while (this.drops.length && this.drops[0]!.at <= from) this.drops.shift();
  }
}

/** A report's numbers rounded to 0.1 and the non-finite ones left out (what goes on the wire). */
export function roundReport(r: PlayoutReport): PlayoutReport {
  const out: PlayoutReport = { mode: r.mode };
  for (const [k, v] of Object.entries(r)) {
    if (k === "mode") continue;
    if (typeof v === "number") {
      if (Number.isFinite(v)) out[k] = Math.round(v * 10) / 10;
    } else if (v !== undefined) {
      out[k] = v;
    }
  }
  return out;
}
