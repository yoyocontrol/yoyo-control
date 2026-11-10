import type { SendInput } from "./input.js";
import { percentile } from "./playout.js";
import { RequestError } from "./transport.js";
import type { NetQuality, NetReport } from "./types.js";

/**
 * This side of the network for the playout report's `net` (docs/PROTOCOL.md「网络质量」, the iOS kit's
 * `ScreenNetSampler`), pure: every time is passed in (ms, the page's clock). The route the stream uses, the network path
 * (`browserNetPath()`), input round trips of the last `windowMs` on that route (cleared when it changes), input and ack
 * requests that failed on the way in the same window, and the stream's bytes over the last `rxWindowMs`.
 */
export class NetSampler {
  /** At most this many round trips / failures are kept. */
  static readonly MAX_SAMPLES = 512;
  private static readonly BUCKET_MS = 100;

  /** What the network path says (null: unknown). */
  path: NetPath | null = null;
  private routeIs: NetReport["route"] | null = null;
  private rtts: { at: number; ms: number }[] = [];
  private failures: number[] = [];
  private rx: { at: number; bytes: number }[] = [];
  private rxSince: number | null = null;

  constructor(
    readonly windowMs = 10_000,
    readonly rxWindowMs = 3000,
  ) {}

  get route(): NetReport["route"] | null {
    return this.routeIs;
  }

  /** The stream now goes this way: round trips measured on another one no longer count. */
  setRoute(route: NetReport["route"] | null): void {
    if (route !== this.routeIs) this.rtts = [];
    this.routeIs = route;
  }

  /** A new stream: its bytes are counted from `now`. */
  streamStarted(now: number): void {
    this.rx = [];
    this.rxSince = now;
  }

  /** An input was answered after `ms` on `route` (one on a route other than the stream's is left out). */
  inputAnswered(route: NetReport["route"], ms: number, now: number): void {
    if (route !== this.routeIs || !Number.isFinite(ms) || ms < 0) return;
    this.rtts.push({ at: now, ms });
    if (this.rtts.length > NetSampler.MAX_SAMPLES) this.rtts.splice(0, this.rtts.length - NetSampler.MAX_SAMPLES);
    this.prune(now);
  }

  /** An input or ack request failed on the way (`isNetworkFailure`). */
  failed(now: number): void {
    this.failures.push(now);
    if (this.failures.length > NetSampler.MAX_SAMPLES) this.failures.splice(0, this.failures.length - NetSampler.MAX_SAMPLES);
    this.prune(now);
  }

  received(bytes: number, now: number): void {
    if (bytes <= 0) return;
    this.rxSince ??= now;
    const last = this.rx[this.rx.length - 1];
    if (last && now >= last.at && now - last.at < NetSampler.BUCKET_MS) last.bytes += bytes;
    else this.rx.push({ at: now, bytes });
    this.prune(now);
  }

  /** The report at `now`; null when nothing is known. */
  report(now: number): NetReport | null {
    const from = now - this.windowMs;
    const r: NetReport = {};
    if (this.routeIs) r.route = this.routeIs;
    const p = this.path;
    if (p?.iface) r.iface = p.iface;
    if (p?.expensive !== undefined) r.expensive = p.expensive;
    if (p?.constrained !== undefined) r.constrained = p.constrained;
    const ms = this.rtts.filter((s) => s.at > from).map((s) => s.ms);
    if (ms.length) r.inputRttMs = { p50: percentile(ms, 0.5)!, p90: percentile(ms, 0.9)!, n: ms.length };
    if (this.rxSince !== null) {
      const rxFrom = now - this.rxWindowMs;
      const span = Math.max(Math.min(this.rxWindowMs, now - this.rxSince), 500);
      const bytes = this.rx.filter((b) => b.at > rxFrom).reduce((n, b) => n + b.bytes, 0);
      r.rxKbps = (bytes * 8) / span;
    }
    r.failures = this.failures.filter((t) => t > from).length;
    return Object.keys(r).length === 1 && r.failures === 0 ? null : r;
  }

  private prune(now: number): void {
    const from = now - this.windowMs;
    while (this.rtts.length && this.rtts[0]!.at <= from) this.rtts.shift();
    while (this.failures.length && this.failures[0]! <= from) this.failures.shift();
    const rxFrom = now - this.rxWindowMs;
    while (this.rx.length && this.rx[0]!.at <= rxFrom) this.rx.shift();
  }
}

/** The network path as the report names it. A browser has no radio information. */
export interface NetPath {
  iface?: "wifi" | "cellular" | "wired" | "other";
  expensive?: boolean;
  constrained?: boolean;
}

/** The parts of the Network Information API (`navigator.connection`) read here; absent on Safari and Firefox. */
export interface ConnectionLike {
  type?: string;
  saveData?: boolean;
}

/** The path from `navigator.connection` when the browser has one (Chromium): `type` → iface (`ethernet` → wired,
 *  `wifi`, `cellular`, `none` → no path, anything else other), `saveData` → constrained; cellular is expensive. Null
 *  without the API or without a `type`. */
export function browserNetPath(connection: ConnectionLike | null | undefined = (globalThis.navigator as { connection?: ConnectionLike } | undefined)?.connection): NetPath | null {
  const type = connection?.type;
  if (!type) return null;
  if (type === "none") return {};
  const iface = type === "ethernet" ? "wired" : type === "wifi" ? "wifi" : type === "cellular" ? "cellular" : "other";
  const p: NetPath = { iface };
  if (iface === "cellular") p.expensive = true;
  if (typeof connection.saveData === "boolean") p.constrained = connection.saveData;
  return p;
}

/** Statuses a proxy or CDN in front of the computer answers when it couldn't reach it (the default `isWayDown`). */
export function isUnreachableStatus(status: number): boolean {
  return status === 502 || status === 504 || (status >= 520 && status <= 527) || status === 530;
}

/**
 * A request that failed on the way counts as a network failure: a fetch that threw (a `TypeError`, a timeout) or an
 * answer saying the way to the computer is broken (`isWayDown`, default `isUnreachableStatus`). An answer from the
 * computer's server (409, 400, 404, its own 503) and an abort don't.
 */
export function isNetworkFailure(error: unknown, isWayDown: (status: number, message: string | null) => boolean = (s) => isUnreachableStatus(s)): boolean {
  if (error instanceof RequestError) return isWayDown(error.status, error.message);
  if (error instanceof DOMException && error.name === "AbortError") return false;
  if (error && typeof error === "object" && "status" in error && typeof (error as { status: unknown }).status === "number") {
    return isWayDown((error as { status: number }).status, error instanceof Error ? error.message : null);
  }
  return error instanceof Error;
}

/** The server's grade from an ack answer's `net` (or a link's own), leniently: null when it isn't an object; an unknown
 *  grade is `unknown`, negative or non-finite numbers are dropped, at most 8 reasons of ≤ 32 characters. */
export function parseNetQuality(net: unknown): NetQuality | null {
  if (!net || typeof net !== "object") return null;
  const o = net as Record<string, unknown>;
  const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) && v >= 0 ? v : undefined);
  const grade = typeof o.grade === "string" && ["good", "fair", "poor", "unknown"].includes(o.grade) ? o.grade : "unknown";
  const q: NetQuality = { grade, reasons: [] };
  if (o.rttMs && typeof o.rttMs === "object") {
    const r = o.rttMs as Record<string, unknown>;
    const min = num(r.min), p50 = num(r.p50), p90 = num(r.p90);
    if (min !== undefined && p50 !== undefined && p90 !== undefined) q.rttMs = { min, p50, p90 };
  }
  const j = num(o.jitterMs);
  if (j !== undefined) q.jitterMs = j;
  if (Array.isArray(o.reasons)) q.reasons = o.reasons.filter((r): r is string => typeof r === "string" && r.length > 0 && r.length <= 32).slice(0, 8);
  return q;
}

/** The stats line's part: `net fair (rtt, jitter) · rtt 165/210 · jitter 73` (codes and numbers only). */
export function netQualityLine(q: NetQuality): string {
  let head = `net ${q.grade}`;
  if (q.reasons.length) head += ` (${q.reasons.join(", ")})`;
  const parts = [head];
  if (q.rttMs) parts.push(`rtt ${Math.round(q.rttMs.p50)}/${Math.round(q.rttMs.p90)}`);
  if (q.jitterMs !== undefined) parts.push(`jitter ${Math.round(q.jitterMs)}`);
  return parts.join(" · ");
}

/**
 * `send` (InputQueue's `SendInput`, HTTP) that reports each input's round trip to `net` on the route it went (`route()`
 * when it was sent), and a network failure (`isNetworkFailure`) as one. Over a link input isn't answered one by one;
 * the link's own input round trips are in its stats line.
 */
export function withNetSampler(send: SendInput, net: NetSampler, route: () => NetReport["route"], now: () => number = () => performance.now()): SendInput {
  return async (input) => {
    const way = route();
    const t0 = now();
    try {
      await send(input);
      const t = now();
      net.inputAnswered(way, t - t0, t);
    } catch (e) {
      if (isNetworkFailure(e)) net.failed(now());
      throw e;
    }
  };
}
