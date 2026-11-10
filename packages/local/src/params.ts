// Request parameters checked before they reach the server (a proxy validates what its own clients send), and the
// server's answers read leniently. Every refusal is a 400 LocalError; an answer that isn't one at all is a 502.
import { LocalError } from "./errors.js";
import {
  INPUT_TYPES,
  MODIFIERS,
  POINTER_BUTTONS,
  SCROLL_PHASES,
  type Features,
  type Focus,
  type Input,
  type Modifier,
  type PlayoutReport,
  type PointerButton,
  type ScrollPhase,
  type StreamAck,
} from "./types.js";

const clamp01 = (n: number) => Math.min(1, Math.max(0, n));
const isNum = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);

/** A POST /input body, validated (400 LocalError otherwise). Coordinates are clamped to the display. */
export function parseInput(raw: unknown): Input {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new LocalError("body must be a JSON object", 400);
  const b = raw as Record<string, unknown>;
  const type = b.type;
  if (typeof type !== "string" || !(INPUT_TYPES as readonly string[]).includes(type)) {
    throw new LocalError(`type must be one of ${INPUT_TYPES.join(", ")}`, 400);
  }
  const out: Input = { type: type as Input["type"] };
  if (b.display !== undefined && b.display !== null) {
    if (!isNum(b.display) || !Number.isInteger(b.display) || b.display < 0) throw new LocalError("display must be a display id", 400);
    out.display = b.display;
  }
  for (const k of ["x", "y", "dx", "dy"] as const) {
    if (b[k] === undefined || b[k] === null) continue;
    if (!isNum(b[k])) throw new LocalError(`${k} must be a number`, 400);
    out[k] = k === "x" || k === "y" ? clamp01(b[k] as number) : (b[k] as number);
  }
  const pointer = out.type === "click" || out.type === "doubleClick" || out.type === "rightClick" || out.type === "move" || out.type === "drag" ||
    out.type === "down" || out.type === "up";
  if (pointer && (out.x === undefined || out.y === undefined)) throw new LocalError(`${out.type} needs x and y (0…1)`, 400);
  // a live drag: `move` with the left button held (between `down` and `up`); no other button, and only on `move`
  if (b.button !== undefined && b.button !== null) {
    if (typeof b.button !== "string" || !(POINTER_BUTTONS as readonly string[]).includes(b.button)) {
      throw new LocalError(`button must be ${POINTER_BUTTONS.map((x) => `"${x}"`).join(" or ")}`, 400);
    }
    if (out.type === "move") out.button = b.button as PointerButton;
  }
  // a pipelined move's counter (the server answers an overtaken one `stale`): a non-negative integer, only on a move
  if (b.seq !== undefined && b.seq !== null) {
    if (!isNum(b.seq) || !Number.isSafeInteger(b.seq) || b.seq < 0) throw new LocalError("seq must be a non-negative integer", 400);
    if (out.type === "move") out.seq = b.seq;
  }
  if (out.type === "drag" && out.dx === undefined && out.dy === undefined) throw new LocalError("drag needs dx and/or dy", 400);
  if (out.type === "scroll" && out.dx === undefined && out.dy === undefined) throw new LocalError("scroll needs dx and/or dy", 400);
  // a two-finger gesture's phase and, on `ended`, the velocity at lift (the server's momentum); only on a scroll
  if (b.phase !== undefined && b.phase !== null) {
    if (typeof b.phase !== "string" || !(SCROLL_PHASES as readonly string[]).includes(b.phase)) {
      throw new LocalError(`phase must be one of ${SCROLL_PHASES.join(", ")}`, 400);
    }
    if (out.type === "scroll") out.phase = b.phase as ScrollPhase;
  }
  for (const k of ["vx", "vy"] as const) {
    if (b[k] === undefined || b[k] === null) continue;
    if (!isNum(b[k])) throw new LocalError(`${k} must be a number`, 400);
    if (out.type === "scroll") out[k] = b[k] as number;
  }
  if (out.type === "type") {
    if (typeof b.text !== "string" || !b.text) throw new LocalError("type needs a non-empty text", 400);
    if (b.text.length > 4000) throw new LocalError("text is too long (max 4000 characters)", 400);
    out.text = b.text;
  }
  if (out.type === "key") {
    if (typeof b.key !== "string" || !b.key.trim() || b.key.length > 32) throw new LocalError("key needs a key name", 400);
    out.key = b.key.trim();
  }
  if (b.modifiers !== undefined && b.modifiers !== null) {
    if (!Array.isArray(b.modifiers) || !b.modifiers.every((m) => (MODIFIERS as readonly unknown[]).includes(m))) {
      throw new LocalError(`modifiers must be a list of ${MODIFIERS.join(", ")}`, 400);
    }
    // held with the button: they count on `down`, not on what moves or lifts it
    const heldMove = out.type === "up" || (out.type === "move" && out.button !== undefined);
    if (b.modifiers.length && !heldMove) out.modifiers = [...new Set(b.modifiers as Modifier[])];
  }
  return out;
}

/** Query of /frame and /stream, clamped: display id, max width (px), JPEG quality, frames per second. */
export interface FrameParams {
  display?: number;
  maxWidth?: number;
  quality?: number;
  fps?: number;
}

/** FrameParams from a parameter lookup (a URL query's `get`, a JSON body's fields): clamped; not a number → 400. */
export function parseFrameParams(get: (name: string) => unknown): FrameParams {
  const num = (name: string) => {
    const v = get(name);
    if (v === undefined || v === null || v === "") return undefined;
    const n = typeof v === "number" ? v : Number(v);
    if (!Number.isFinite(n)) throw new LocalError(`${name} must be a number`, 400);
    return n;
  };
  const p: FrameParams = {};
  const display = num("display");
  if (display !== undefined) p.display = Math.trunc(display);
  const maxWidth = num("maxWidth");
  if (maxWidth !== undefined) p.maxWidth = Math.min(3840, Math.max(160, Math.round(maxWidth)));
  const quality = num("quality");
  if (quality !== undefined) p.quality = Math.min(95, Math.max(10, Math.round(quality)));
  const fps = num("fps");
  // up to 60 fps: video streams only encode a frame when it changes, so a high cap is cheap
  if (fps !== undefined) p.fps = Math.min(60, Math.max(1, fps));
  return p;
}

/** /stream's parameters (docs/PROTOCOL.md「视频流、确认与客户端指针」): FrameParams plus the video-stream ones. */
export interface StreamParams extends FrameParams {
  /** Known tokens of the client's list, in its order (left out when it listed only unknown ones: the server serves h264). */
  codecs?: string;
  stream?: string;
  ack?: 1;
  cursor?: "client";
  /** Status parts (「连接状态」); a server without them ignores it. */
  status?: 1;
  /** The video bit rate's ceiling (kbit/s, an integer 100…100000; testing only); a server without it ignores it. */
  maxKbps?: number;
}

/** An on/off flag parameter: 1 / "1" / true / "true" → true; absent / "" / 0 / "0" / false / "false" → false; else 400. */
function flagParam(v: unknown, name: string): boolean {
  if (v === 1 || v === "1" || v === true || v === "true") return true;
  if (v === undefined || v === null || v === "" || v === 0 || v === "0" || v === false || v === "false") return false;
  throw new LocalError(`${name} must be 1`, 400);
}

export const STREAM_CODEC_TOKENS: readonly string[] = ["hevc", "h264"];
/** A client-chosen stream id. */
export const STREAM_ID = /^[A-Za-z0-9_-]{8,64}$/;

export function parseStreamParams(get: (name: string) => unknown): StreamParams {
  const p: StreamParams = parseFrameParams(get);
  const codecs = get("codecs");
  if (codecs !== undefined && codecs !== null && codecs !== "") {
    const raw = Array.isArray(codecs) ? codecs.join(",") : typeof codecs === "string" ? codecs : null;
    if (raw === null) throw new LocalError("codecs must be a comma-separated list", 400);
    const known = [...new Set(raw.split(",").map((t) => t.trim().toLowerCase()))].filter((t) => STREAM_CODEC_TOKENS.includes(t));
    if (known.length) p.codecs = known.join(",");
  }
  const stream = get("stream");
  if (stream !== undefined && stream !== null && stream !== "") {
    if (typeof stream !== "string" || !STREAM_ID.test(stream)) throw new LocalError("stream must be 8–64 characters of A-Z a-z 0-9 _ -", 400);
    p.stream = stream;
  }
  if (flagParam(get("ack"), "ack")) p.ack = 1;
  const cursor = get("cursor");
  if (cursor === "client") p.cursor = "client";
  else if (!(cursor === undefined || cursor === null || cursor === "")) throw new LocalError('cursor must be "client"', 400);
  if (flagParam(get("status"), "status")) p.status = 1;
  const maxKbps = get("maxKbps");
  if (maxKbps !== undefined && maxKbps !== null && maxKbps !== "") {
    const n = typeof maxKbps === "number" ? maxKbps : typeof maxKbps === "string" && /^\d+$/.test(maxKbps) ? Number(maxKbps) : NaN;
    if (!Number.isInteger(n) || n < 100 || n > 100_000) throw new LocalError("maxKbps must be an integer 100…100000", 400);
    p.maxKbps = n;
  }
  return p;
}

/** The largest stream ack body worth reading (bytes); a proxy answers 413 above it. */
export const ACK_BODY_MAX = 16 * 1024;

/**
 * A POST /stream/ack body (400 LocalError otherwise): `stream`, `seq` and `keyframe` checked; `report` passed on as it
 * came when it is a JSON object (else dropped) — the server decodes it leniently.
 */
export function parseStreamAck(raw: unknown): StreamAck {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new LocalError("body must be a JSON object", 400);
  const b = raw as Record<string, unknown>;
  if (typeof b.stream !== "string" || !STREAM_ID.test(b.stream)) throw new LocalError("stream must be a stream id", 400);
  if (!isNum(b.seq) || !Number.isSafeInteger(b.seq) || b.seq < 0) throw new LocalError("seq must be a non-negative integer", 400);
  const out: StreamAck = { stream: b.stream, seq: b.seq };
  if (b.keyframe !== undefined && b.keyframe !== null) {
    if (typeof b.keyframe !== "boolean") throw new LocalError("keyframe must be a boolean", 400);
    if (b.keyframe) out.keyframe = true;
  }
  if (b.report && typeof b.report === "object" && !Array.isArray(b.report)) out.report = b.report as PlayoutReport;
  return out;
}

/** The /focus answer (anything odd = not editable; a role of at most 64 characters). */
export function parseFocus(raw: unknown): Focus {
  const r = raw && typeof raw === "object" && !Array.isArray(raw) ? (raw as Record<string, unknown>) : {};
  const role = typeof r.role === "string" && r.role.length > 0 && r.role.length <= 64 ? r.role : null;
  return { editable: r.editable === true, role };
}

/** `/status.features`: its boolean entries (an open set), null when it has none. */
export function parseFeatures(raw: unknown): Features | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const out: Features = {};
  for (const [k, v] of Object.entries(raw as Record<string, unknown>)) if (typeof v === "boolean") out[k] = v;
  return Object.keys(out).length ? out : null;
}

// ----------------------------------------------------------------------------- apps and windows

/** An app as the server names it (GET /windows, GET /hit). */
export interface AppRef {
  pid: number;
  bundleId: string | null;
  /** As the system shows it (localized). */
  name: string;
  /** The app's English name, when the server knows one that differs from `name` ("Notification Center" for "Notification Centre"). */
  englishName?: string;
}
/** An app with on-screen windows (the desktop, Dock and menu bar fold into Finder), front to back. */
export interface AppInfo extends AppRef {
  windows: number;
}
/** An on-screen window, front to back; x / y / w / h normalized 0…1 on its display. No title (it leaks content). */
export interface WindowInfo {
  pid: number;
  display: number;
  x: number;
  y: number;
  w: number;
  h: number;
  layer: number;
}
/** GET /windows: the apps, the windows (of `display` when asked), the app taking keyboard input (null: unknown). */
export interface Windows {
  apps: AppInfo[];
  windows: WindowInfo[];
  focused: AppRef | null;
}
/** Which part of the menu bar a /hit point is (newer services; absent outside the menu bar). */
export type MenuBarArea = "appleMenu" | "appMenu" | "statusItem" | "bar";
const MENU_BAR_AREAS: readonly string[] = ["appleMenu", "appMenu", "statusItem", "bar"];

/** GET /hit: the app owning the frontmost window at a point, null = none. */
export interface Hit {
  app: AppRef | null;
  layer: number | null;
  /** In the menu bar: which part (the app is that part's: a status item's app, the Apple menu, an app's menu, the frontmost app). */
  menuBar?: MenuBarArea;
}
/** A normalized region (0…1) of a display. */
export interface Region {
  x: number;
  y: number;
  w: number;
  h: number;
}

const rec = (raw: unknown): Record<string, unknown> | null => (raw && typeof raw === "object" && !Array.isArray(raw) ? (raw as Record<string, unknown>) : null);
const finite = (v: unknown): number | null => (typeof v === "number" && Number.isFinite(v) ? v : null);

/** One AppRef of an answer, or null when it is not one (no pid / name). */
export function parseAppRef(raw: unknown): AppRef | null {
  const r = rec(raw);
  const pid = finite(r?.pid);
  if (!r || pid === null || typeof r.name !== "string") return null;
  const englishName = typeof r.englishName === "string" && r.englishName && r.englishName !== r.name ? r.englishName : undefined;
  return { pid, bundleId: typeof r.bundleId === "string" && r.bundleId ? r.bundleId : null, name: r.name, ...(englishName ? { englishName } : {}) };
}

/** GET /windows, leniently (odd entries dropped); not an object at all → a 502. */
export function parseWindows(raw: unknown): Windows {
  const r = rec(raw);
  if (!r || !Array.isArray(r.apps)) throw new LocalError("screen helper: bad answer to /windows", 502);
  const apps = r.apps.flatMap((a): AppInfo[] => {
    const ref = parseAppRef(a);
    return ref ? [{ ...ref, windows: Math.max(0, Math.trunc(finite(rec(a)?.windows) ?? 0)) }] : [];
  });
  const windows = (Array.isArray(r.windows) ? r.windows : []).flatMap((w): WindowInfo[] => {
    const o = rec(w);
    const v = ["pid", "display", "x", "y", "w", "h"].map((k) => finite(o?.[k]));
    if (v.some((n) => n === null)) return [];
    const [pid, display, x, y, ww, h] = v as number[];
    return [{ pid: pid!, display: display!, x: x!, y: y!, w: ww!, h: h!, layer: finite(o?.layer) ?? 0 }];
  });
  return { apps, windows, focused: parseAppRef(r.focused) };
}

/** GET /hit, leniently. */
export function parseHit(raw: unknown): Hit {
  const r = rec(raw);
  const menuBar = typeof r?.menuBar === "string" && MENU_BAR_AREAS.includes(r.menuBar) ? (r.menuBar as MenuBarArea) : undefined;
  return { app: parseAppRef(r?.app), layer: finite(r?.layer), ...(menuBar ? { menuBar } : {}) };
}

/** GET /app/windows: one window of an app, front to back; x / y / w / h normalized 0…1 on its display. */
export interface AppWindowInfo {
  /** The CGWindowID. */
  id: number;
  display: number;
  x: number;
  y: number;
  w: number;
  h: number;
  onScreen: boolean;
  minimized: boolean;
}
/** GET /app/screenshot: one window's picture, whatever covers it. */
export interface AppScreenshot {
  jpeg: Buffer;
  width: number | null;
  height: number | null;
  window: number | null;
  /** The window on its display, normalized (X-Window-Bounds); null when the server did not say. */
  bounds: Region | null;
}
/** One actionable element of GET /app/ax; x / y / w / h normalized 0…1 in the window's picture. Never a value. */
export interface AppAxElement {
  i: number;
  role: string;
  subrole?: string;
  title?: string;
  x: number;
  y: number;
  w: number;
  h: number;
  enabled: boolean;
  focused: boolean;
}
/** GET /app/ax: the window's actionable elements; `truncated`: the walk ran out of time. */
export interface AppAx {
  app: AppRef | null;
  focused: number | null;
  elements: AppAxElement[];
  truncated: boolean;
}

const str = (v: unknown, max = 500): string | undefined => (typeof v === "string" && v.length ? v.slice(0, max) : undefined);

/** GET /app/windows, leniently (odd entries dropped); not an object → a 502. */
export function parseAppWindows(raw: unknown): AppWindowInfo[] {
  const r = rec(raw);
  if (!r || !Array.isArray(r.windows)) throw new LocalError("screen helper: bad answer to /app/windows", 502);
  return r.windows.flatMap((w): AppWindowInfo[] => {
    const o = rec(w);
    const v = ["id", "display", "x", "y", "w", "h"].map((k) => finite(o?.[k]));
    if (!o || v.some((n) => n === null)) return [];
    const [id, display, x, y, ww, h] = v as number[];
    return [{ id: id!, display: display!, x: x!, y: y!, w: ww!, h: h!, onScreen: o.onScreen !== false, minimized: o.minimized === true }];
  });
}

/** GET /app/ax, leniently; not an object → a 502. */
export function parseAppAx(raw: unknown): AppAx {
  const r = rec(raw);
  if (!r || !Array.isArray(r.elements)) throw new LocalError("screen helper: bad answer to /app/ax", 502);
  const elements = r.elements.flatMap((e): AppAxElement[] => {
    const o = rec(e);
    const v = ["i", "x", "y", "w", "h"].map((k) => finite(o?.[k]));
    const role = str(o?.role, 64);
    if (!o || !role || v.some((n) => n === null)) return [];
    const [i, x, y, w, h] = v as number[];
    const subrole = str(o.subrole, 64);
    const title = str(o.title, 200);
    return [{ i: Math.trunc(i!), role, ...(subrole ? { subrole } : {}), ...(title ? { title } : {}), x: x!, y: y!, w: w!, h: h!, enabled: o.enabled !== false, focused: o.focused === true }];
  });
  const focused = finite(r.focused);
  return { app: parseAppRef(r.app), focused: focused === null ? null : Math.trunc(focused), elements, truncated: r.truncated === true };
}

/** A `x,y,w,h` header (X-Crop, X-Window-Bounds) as a Region, null when it isn't one. */
export function regionHeader(v: unknown): Region | null {
  const parts = typeof v === "string" ? v.split(",").map(Number) : [];
  return parts.length === 4 && parts.every(Number.isFinite) ? { x: parts[0]!, y: parts[1]!, w: parts[2]!, h: parts[3]! } : null;
}
