import type { ControlDevice, Controller, Display, DisplayState, Features, StreamStatusPart } from "./types.js";

/**
 * The page's reading of a screen's status and the connection codes (docs/PROTOCOL.md「连接状态」), as the iOS
 * ScreenHost / ScreenConnectionModel / ScreenControlModel. Pure. No words of its own beyond `englishStrings`: a host
 * page passes its own `ScreenStrings`.
 */

export type Host = "mac" | "linux" | "windows";

/** What the screen runs on: "linux" / "windows" when the server says so, any other `platform` is a Mac; none → `fallback`. */
export function hostOf(status: { platform?: string | null } | null | undefined, fallback: Host = "mac"): Host {
  const p = status?.platform;
  if (p === "linux" || p === "windows") return p;
  if (p !== undefined && p !== null) return "mac";
  return fallback;
}

/** The computer's clipboard: `features.clipboard` when the server says, else `fallback`. */
export function clipboardOn(status: { features?: Features | null } | null | undefined, fallback: boolean): boolean {
  return status?.features?.clipboard ?? fallback;
}

/** The speaker: hidden at once when the server says there is no sound; otherwise found out by asking (404 / 503). */
export function audioOn(status: { features?: Features | null } | null | undefined): boolean {
  return status?.features?.audio !== false;
}

/** The display `id` (when it is still there), else the main one, else the first. */
export function mainDisplay<D extends Display>(s: { displays: D[] }, id?: number | null): D | null {
  return (id != null ? s.displays.find((d) => d.id === id) : undefined) ?? s.displays.find((d) => d.main) ?? s.displays[0] ?? null;
}

// ---------------------------------------------------------------- who controls

export type ControlRole = { t: "free" } | { t: "agent" } | { t: "me" } | { t: "other"; name: string | null };

/** Who holds the screen as this browser sees it (`me`: its device id). A holder that names no device: as before (mine). */
export function controlRole(controller: Controller, device: ControlDevice | undefined | null, me: string): ControlRole {
  if (controller === "agent") return { t: "agent" };
  if (controller !== "user") return { t: "free" };
  if (device && device.id !== me) return { t: "other", name: device.name ?? null };
  return { t: "me" };
}

// ---------------------------------------------------------------- connection

export type Phase = { t: "live" } | { t: "reconnecting"; reason: string | null } | { t: "unavailable"; reason: string | null; retryAt: number | null };

/** An unexplained gap (the stream ended, no picture since) shows "Reconnecting" after this long. */
export const GAP_GRACE_MS = 700;

/** A status part's JSON, leniently: null when it isn't one. */
export function parseStatusPart(body: Uint8Array | string): StreamStatusPart | null {
  try {
    const v = JSON.parse(typeof body === "string" ? body : new TextDecoder().decode(body)) as Partial<StreamStatusPart>;
    if (!v || typeof v !== "object" || typeof v.phase !== "string") return null;
    return { display: typeof v.display === "number" ? v.display : 0, phase: v.phase, since: typeof v.since === "number" ? v.since : 0, ...(v.main ? { main: true } : {}), ...(typeof v.reason === "string" ? { reason: v.reason } : {}), ...(typeof v.retryAt === "number" ? { retryAt: v.retryAt } : {}), ...(v.console !== undefined ? { console: v.console } : {}) };
  } catch {
    return null;
  }
}

/**
 * What the page says about its picture (the iOS ScreenConnectionModel, without the reopen hold): the open stream's status
 * part counts first, then the display's state entry; a state that isn't `ready` shows at once until a NEW PICTURE
 * arrives after it; without states, a stream that ended and brought no picture for GAP_GRACE_MS reads "Reconnecting".
 */
export class ConnectionModel {
  private stateAt = -Infinity;
  private state: DisplayState | null = null;
  private lastPicture = -Infinity;
  private gapSince: number | null = null;
  private retried: number | null = null;
  private open = false;
  locked = false;

  streamOpened(): void {
    this.open = true;
  }
  streamEnded(now: number): void {
    this.open = false;
    if (this.gapSince === null) this.gapSince = now;
  }
  picture(now: number): void {
    this.lastPicture = now;
    this.gapSince = null;
    this.retried = null;
  }
  /** A status part of the open stream, or the display's entry of the screen's status / a state event. */
  status(s: DisplayState & { console?: { locked: boolean } | null }, now: number): void {
    const same = this.state && this.state.phase === s.phase && this.state.reason === s.reason;
    this.state = s;
    if (!same) this.stateAt = now;
    if (s.console) this.locked = s.console.locked;
  }
  retry(now: number): void {
    this.retried = now;
    if (this.gapSince === null) this.gapSince = now;
  }

  phase(now: number): Phase {
    const s = this.state;
    const fresh = s !== null && this.stateAt > Math.max(this.lastPicture, this.retried ?? -Infinity);
    if (s && fresh && s.phase === "unavailable") return { t: "unavailable", reason: s.reason ?? null, retryAt: s.retryAt ?? null };
    if (s && fresh && s.phase !== "ready") return { t: "reconnecting", reason: s.reason ?? null };
    if (this.retried !== null) return { t: "reconnecting", reason: null };
    if (!this.open && this.gapSince !== null && now - this.gapSince >= GAP_GRACE_MS) return { t: "reconnecting", reason: null };
    return { t: "live" };
  }

  /** The stats line's part (codes, not words): `live ready`, `reconnecting helper-restart`, `unavailable no-session`,
   *  `· locked` when the console is. */
  statsText(now: number): string {
    const p = this.phase(now);
    const parts = [p.t === "live" ? (this.state ? `live ${this.state.phase}` : "live") : p.reason ? `${p.t} ${p.reason}` : p.t];
    if (this.locked) parts.push("locked");
    return parts.join(" · ");
  }

  /** When the phase changes by itself (a gap turning into "Reconnecting"), or null. */
  deadline(): number | null {
    return this.gapSince === null ? null : this.gapSince + GAP_GRACE_MS;
  }
}

/** The words of the connection phases (a host page passes its own: its language, its names for the computer). */
export interface ScreenStrings {
  /** The headline while a stream first connects (reason "starting"). */
  connecting: string;
  reconnecting: string;
  /** The headline when the screen can't be shown. */
  unavailable(host: Host): string;
  /** The line under it when no reason has words. */
  unavailableDetail(host: Host): string;
  /** A reason code's words, null for codes it has none for. */
  reason(reason: string, host: Host): string | null;
}

export const englishStrings: ScreenStrings = {
  connecting: "Connecting…",
  reconnecting: "Reconnecting…",
  unavailable: (host) => (host === "mac" ? "Can't show the screen" : "Can't show the desktop"),
  unavailableDetail: (host) => (host === "mac" ? "The Mac's screen can't be shown right now." : "The desktop can't be shown right now."),
  reason: (reason, host) => {
    if (host !== "mac") {
      switch (reason) {
        case "helper-restart": return "The desktop is restarting";
        case "timeout": return "The desktop isn't responding";
        case "helper-down": return "The desktop can't start";
        default: return null;
      }
    }
    switch (reason) {
      case "helper-restart": return "The screen helper is restarting";
      case "timeout": return "The Mac's screen isn't responding";
      case "no-session": return "This account isn't logged in on the Mac";
      case "no-permission": return "Yoyo Control is missing a permission on the Mac";
      case "helper-down": return "The screen helper can't start";
      default: return null;
    }
  },
};

/** The overlay's headline and the line under it (null: live, nothing to say). */
export function phaseText(p: Phase, host: Host, strings: ScreenStrings = englishStrings): { title: string; detail: string | null } | null {
  switch (p.t) {
    case "live":
      return null;
    case "reconnecting":
      return { title: p.reason === "starting" ? strings.connecting : strings.reconnecting, detail: p.reason ? strings.reason(p.reason, host) : null };
    case "unavailable":
      return { title: strings.unavailable(host), detail: (p.reason ? strings.reason(p.reason, host) : null) ?? strings.unavailableDetail(host) };
  }
}

/** How long to wait before asking again for a display the server called unavailable: until its `retryAt`, 2…15 s; 5 s without one. */
export function retryDelay(retryAt: number | null | undefined, nowMs = Date.now()): number {
  if (retryAt == null || !Number.isFinite(retryAt)) return 5000;
  return Math.min(Math.max(retryAt - nowMs, 2000), 15000);
}

// ---------------------------------------------------------------- reopen / sound policies

export const QUICK_LIFETIME_MS = 3000;
export const QUICK_ENDS_ALLOWED = 3;
export const REOPEN_BACKOFF_MS = 1000;
export const RETRY_FAILED_MS = 3000;
export const RETRY_EMPTY_MS = 5000;

/** What to do when the video stream ends (iOS ScreenStreamReopenPolicy; its 15 s retry is shorter here: a page has no
 *  background state to save power for). */
export class ReopenPolicy {
  quickEnds = 0;
  /** ms to wait before opening again. */
  ended(delivered: boolean, failed: boolean, lifetimeMs: number): number {
    if (!delivered || failed) {
      this.quickEnds = 0;
      return failed ? RETRY_FAILED_MS : RETRY_EMPTY_MS;
    }
    this.quickEnds = lifetimeMs < QUICK_LIFETIME_MS ? this.quickEnds + 1 : 0;
    return this.quickEnds > QUICK_ENDS_ALLOWED ? REOPEN_BACKOFF_MS : 0;
  }
  reset(): void {
    this.quickEnds = 0;
  }
}

/** When the sound opens again after its stream ended (iOS ScreenAudioPolicy): null = not again this visit. */
export class AudioPolicy {
  static readonly unavailableRetryMs = 30_000;
  static readonly failedRetryMs = 5000;
  static readonly quickLifetimeMs = 5000;
  quickEnds = 0;
  ended(status: number | null, lifetimeMs: number): number | null {
    if (status === 404 || status === 403 || status === 501 || status === 415) return null;
    if (status === 503) {
      this.quickEnds = 0;
      return AudioPolicy.unavailableRetryMs;
    }
    this.quickEnds = lifetimeMs < AudioPolicy.quickLifetimeMs ? this.quickEnds + 1 : 0;
    return this.quickEnds > 1 ? AudioPolicy.failedRetryMs : 0;
  }
  reset(): void {
    this.quickEnds = 0;
  }
}
