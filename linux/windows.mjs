// The windows of the X display (README.md「窗口」; the Mac's Windows.swift): GET /windows, GET /hit, and /frame's
// `visible=` / `hide=` (covering, the Mac's mask fallback) and `crop=` — over a one-shot `yoyo-x11windows` per request
// (x11windows.c: the root's viewable children in stacking order, each with its client's WM_CLASS, _NET_WM_PID,
// window type and state). Linux apps have no bundle id: an app is its WM_CLASS class (`bundleId` and `name` both;
// matched case-insensitively), one per (pid, class). Never a window title.
import { spawn } from "node:child_process";
import { InputError } from "./input.mjs";

export const WINDOWS = Object.freeze({
  /** How long the helper may take before the route answers 503. */
  timeoutMs: 2000,
  /** `hide=` entries at most (the Mac's HiddenApps.maxPatterns). */
  maxPatterns: 64,
  /** The covering's colour (the Mac's FrameFilter.maskColor), as ffmpeg's drawbox takes it. */
  maskColor: "0x3a3a3a",
  /** More boxes than this after keeping allowed windows in front visible: the plain covered rectangles instead. */
  maxBoxes: 400,
});

/** `/windows` `layer`: the desktop under everything, panels and keep-above windows over normal ones, popups on top. */
export const LAYER = Object.freeze({ desktop: -1, normal: 0, above: 1, popup: 2 });
const POPUP_TYPES = new Set(["dropdown_menu", "popup_menu", "menu", "tooltip", "notification", "combo", "dnd"]);

const round6 = (v) => Math.round(v * 1e6) / 1e6;

/**
 * Runs the helper once → its JSON (x11windows.c). A helper that can't run (missing, no display, too slow, odd output)
 * is a 503 InputError; `onSpawn(ok)` says whether it could be started at all (`/status.features.windows`).
 */
export function readWindows({ path, env, spawnFn = spawn, timeoutMs = WINDOWS.timeoutMs, onSpawn = () => {} }) {
  return new Promise((resolve, reject) => {
    let p;
    try {
      p = spawnFn(path, [], { stdio: ["ignore", "pipe", "pipe"], env });
    } catch (err) {
      onSpawn(false);
      return reject(new InputError(`the windows helper: ${err.message}`, 503));
    }
    const out = [];
    let err = "";
    let done = false;
    const finish = (fn) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      fn();
    };
    const timer = setTimeout(() => {
      p.kill("SIGKILL");
      finish(() => reject(new InputError(`the windows helper did not answer in ${timeoutMs} ms`, 503)));
    }, timeoutMs);
    p.stdout.on("data", (d) => out.push(d));
    p.stderr.on("data", (d) => (err += d));
    p.on("error", (e) => {
      if (e.code === "ENOENT" || e.code === "EACCES") onSpawn(false);
      finish(() => reject(new InputError(`the windows helper: ${e.message}`, 503)));
    });
    p.on("close", (code) => {
      if (code === 0) onSpawn(true);
      finish(() => {
        if (code !== 0) return reject(new InputError(`the windows helper: ${err.trim().slice(0, 300) || `exit ${code}`}`, 503));
        try {
          const raw = JSON.parse(Buffer.concat(out).toString("utf8"));
          if (!Array.isArray(raw?.windows) || !Array.isArray(raw?.screen)) throw new Error("no windows");
          resolve(raw);
        } catch {
          reject(new InputError("the windows helper: bad output", 503));
        }
      });
    });
  });
}

/** One helper window's kind: the desktop, a panel (dock), or a window. */
function kindOf(w) {
  return w.type === "desktop" ? "desktop" : w.type === "dock" ? "dock" : "window";
}

function layerOf(w) {
  if (w.type === "desktop") return LAYER.desktop;
  if (w.or || POPUP_TYPES.has(w.type)) return LAYER.popup;
  if (w.type === "dock" || w.above) return LAYER.above;
  return LAYER.normal;
}

/** A helper window's app: `{ pid, bundleId, name }` (no class: bundleId null, name the instance or "pid N"). */
function appOf(w) {
  const pid = Number.isSafeInteger(w.pid) && w.pid > 0 ? w.pid : 0;
  const cls = typeof w.class === "string" && w.class ? w.class : null;
  return { pid, bundleId: cls, name: cls ?? (typeof w.instance === "string" && w.instance ? w.instance : `pid ${pid}`) };
}

/**
 * The helper's answer → the listed windows front → back: `{ app, kind, layer, x, y, w, h }` (root pixels, clipped to
 * the screen; normalized `nx ny nw nh`), and the focused app (the owner of _NET_ACTIVE_WINDOW, null without one).
 * Left out: minimized (_NET_WM_STATE_HIDDEN) windows and windows wholly off the screen.
 */
export function windowCatalog(raw) {
  const [W, H] = raw.screen;
  const entries = [];
  for (const w of [...raw.windows].reverse()) {
    if (!w || typeof w !== "object" || w.hidden) continue;
    const x0 = Math.max(0, w.x), y0 = Math.max(0, w.y);
    const x1 = Math.min(W, w.x + w.w), y1 = Math.min(H, w.y + w.h);
    if (!(x1 > x0 && y1 > y0)) continue;
    entries.push({
      id: w.id,
      app: appOf(w),
      kind: kindOf(w),
      layer: layerOf(w),
      x: x0,
      y: y0,
      w: x1 - x0,
      h: y1 - y0,
      nx: round6(x0 / W),
      ny: round6(y0 / H),
      nw: round6((x1 - x0) / W),
      nh: round6((y1 - y0) / H),
    });
  }
  const active = raw.active ? raw.windows.find((w) => w?.id === raw.active) : null;
  return { width: W, height: H, entries, focused: active ? appOf(active) : null };
}

/** GET /windows's answer (`display` 1: the one display; the route 404s any other). */
export function windowsAnswer(cat, displayId) {
  const apps = new Map();
  for (const e of cat.entries) {
    const k = `${e.app.pid}\0${e.app.bundleId ?? ""}\0${e.app.name}`;
    const a = apps.get(k);
    if (a) a.windows++;
    else apps.set(k, { ...e.app, windows: 1 });
  }
  return {
    apps: [...apps.values()],
    windows: cat.entries.map((e) => ({ pid: e.app.pid, display: displayId, x: e.nx, y: e.ny, w: e.nw, h: e.nh, layer: e.layer })),
    focused: cat.focused,
  };
}

/** GET /hit's answer: the topmost listed window containing the normalized point. */
export function hitAnswer(cat, x, y) {
  const px = x * cat.width, py = y * cat.height;
  const e = cat.entries.find((e) => px >= e.x && px < e.x + e.w && py >= e.y && py < e.y + e.h)
    // the screen's last row / column (x or y = 1) belongs to the window touching it
    ?? cat.entries.find((e) => px >= e.x && px <= e.x + e.w && py >= e.y && py <= e.y + e.h);
  return e ? { app: e.app, layer: e.layer } : { app: null, layer: null };
}

/** A 0…1 query parameter (400 when missing or outside). */
export function unitParameter(url, name) {
  const raw = url.searchParams.get(name);
  if (raw === null || raw === "") throw new InputError(`${name} is required`);
  const v = Number(raw);
  if (!Number.isFinite(v) || v < 0 || v > 1) throw new InputError(`${name} must be a number in 0…1`);
  return v;
}

const APP_ID = /^[A-Za-z0-9._-](?:[A-Za-z0-9._ -]*[A-Za-z0-9._-])?$/;

/**
 * `hide=` (comma-separated, case-insensitive, a trailing `*` matches a prefix, ≤ 64; 400 for an entry that is not a
 * WM_CLASS-like name: letters, digits, `.`, `-`, `_`, inner spaces) → `{ hides(id) }`.
 */
export function parseHide(raw) {
  const entries = (raw ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  if (entries.length > WINDOWS.maxPatterns) throw new InputError(`hide names more than ${WINDOWS.maxPatterns} apps`);
  for (const e of entries) {
    const id = e.endsWith("*") ? e.slice(0, -1) : e;
    if (!APP_ID.test(id)) throw new InputError(`hide: ${e.slice(0, 80)} is not an app id (a WM_CLASS class; a trailing * matches a prefix)`);
  }
  const patterns = entries.map((e) => e.toLowerCase());
  return {
    patterns,
    hides(id) {
      if (typeof id !== "string") return false;
      const l = id.toLowerCase();
      return patterns.some((p) => (p.endsWith("*") ? l.startsWith(p.slice(0, -1)) : l === p));
    },
  };
}

/** `visible=` → the lowercased set (empty entries dropped). */
export function parseVisible(raw) {
  return new Set(raw.split(",").map((s) => s.trim().toLowerCase()).filter(Boolean));
}

/** `crop=x,y,w,h` (normalized) → the region inside 0…1; 400 when malformed or empty after clipping. */
export function parseCrop(raw) {
  const parts = raw.split(",").map((s) => (s.trim() === "" ? NaN : Number(s)));
  if (parts.length !== 4 || !parts.every(Number.isFinite)) throw new InputError("crop must be x,y,w,h (normalized 0…1)");
  const [x, y, w, h] = parts;
  const c = (v) => Math.min(Math.max(v, 0), 1);
  const x0 = c(x), y0 = c(y), x1 = c(x + w), y1 = c(y + h);
  if (!(x1 > x0 && y1 > y0)) throw new InputError("crop is empty inside the picture");
  return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
}

/** A normalized region → whole pixels of a W × H picture, rounded outward (a hair of float error is not a pixel). */
export function pixelRect(r, W, H) {
  const down = (v) => Math.floor(v + 1e-6);
  const up = (v) => Math.ceil(v - 1e-6);
  const x0 = Math.max(0, down(r.x * W)), y0 = Math.max(0, down(r.y * H));
  const x1 = Math.min(W, up((r.x + r.w) * W)), y1 = Math.min(H, up((r.y + r.h) * H));
  return { x: x0, y: y0, w: Math.max(0, x1 - x0), h: Math.max(0, y1 - y0) };
}

/** `a` less `b`: up to four rectangles. */
export function subtract(a, b) {
  const ix0 = Math.max(a.x, b.x), iy0 = Math.max(a.y, b.y);
  const ix1 = Math.min(a.x + a.w, b.x + b.w), iy1 = Math.min(a.y + a.h, b.y + b.h);
  if (ix1 <= ix0 || iy1 <= iy0) return [a];
  const out = [];
  if (iy0 > a.y) out.push({ x: a.x, y: a.y, w: a.w, h: iy0 - a.y });
  if (iy1 < a.y + a.h) out.push({ x: a.x, y: iy1, w: a.w, h: a.y + a.h - iy1 });
  if (ix0 > a.x) out.push({ x: a.x, y: iy0, w: ix0 - a.x, h: iy1 - iy0 });
  if (ix1 < a.x + a.w) out.push({ x: ix1, y: iy0, w: a.x + a.w - ix1, h: iy1 - iy0 });
  return out;
}

/** Whether `/frame?visible=` covers this window: not an allowed app's (or a hidden one's); the desktop and panels only when hidden. */
export function covered(e, visible, hidden) {
  if (hidden.hides(e.app.bundleId)) return true;
  if (e.kind !== "window") return false;
  return !(e.app.bundleId && visible.has(e.app.bundleId.toLowerCase()));
}

/**
 * The boxes covering a W × H picture of the catalog's screen, as painting every covered window back → front and every
 * allowed one over it would leave them: each covered window less the allowed windows in front of it. Whole pixels.
 */
export function maskBoxes(cat, visible, hidden, W, H) {
  const px = (e) => pixelRect({ x: e.x / cat.width, y: e.y / cat.height, w: e.w / cat.width, h: e.h / cat.height }, W, H);
  const rects = cat.entries.map(px);
  const cover = cat.entries.map((e) => covered(e, visible, hidden));
  const boxes = [];
  const plain = [];
  for (let i = 0; i < rects.length; i++) {
    if (!cover[i]) continue;
    plain.push(rects[i]);
    let frags = [rects[i]];
    for (let j = 0; j < i && frags.length; j++) if (!cover[j]) frags = frags.flatMap((f) => subtract(f, rects[j]));
    boxes.push(...frags);
  }
  return (boxes.length > WINDOWS.maxBoxes ? plain : boxes).filter((b) => b.w > 0 && b.h > 0);
}

/** ffmpeg's filters painting the boxes. */
export const drawboxes = (boxes) => boxes.map((b) => `drawbox=x=${b.x}:y=${b.y}:w=${b.w}:h=${b.h}:color=${WINDOWS.maskColor}:t=fill`);
