// POST /input (README.md「输入」, the protocol's「输入」): the body checked like the reference server (Input.swift), then
// turned into xdotool commands — one long-lived `xdotool -` reads them from a pipe, line by line, so nothing typed is
// ever in a process's argv (other users of the machine can read argv). The X server here has core events only: a
// scroll becomes wheel clicks (buttons 4–7), paced and given momentum like the reference server's ScrollSynth.

export class InputError extends Error {
  constructor(message, status = 400) {
    super(message);
    this.status = status;
  }
}

const TYPES = ["click", "doubleClick", "rightClick", "move", "drag", "scroll", "type", "key", "down", "up"];
const POINTER = new Set(["click", "doubleClick", "rightClick", "move", "drag", "down", "up"]);
const MODIFIERS = { cmd: "ctrl", ctrl: "ctrl", alt: "alt", shift: "shift" };
const PHASES = ["began", "changed", "ended"];

/**
 * The protocol's key names (case-insensitive) → X keysyms. ⌘ is Ctrl here (the shortcuts a Linux app knows). `insert`
 * is a Linux extension: a client's paste key sends Shift+Insert to a Linux desktop (README.md「剪贴板」).
 */
export const KEYS = (() => {
  const k = {
    return: "Return",
    enter: "KP_Enter",
    escape: "Escape",
    esc: "Escape",
    tab: "Tab",
    space: "space",
    delete: "BackSpace",
    backspace: "BackSpace",
    forwarddelete: "Delete",
    up: "Up",
    down: "Down",
    left: "Left",
    right: "Right",
    home: "Home",
    end: "End",
    pageup: "Prior",
    pagedown: "Next",
    // a Linux extension (proposed upstream): Shift+Insert pastes in X terminals and GTK alike
    insert: "Insert",
    "-": "minus",
    "=": "equal",
    "[": "bracketleft",
    "]": "bracketright",
    ";": "semicolon",
    "'": "apostrophe",
    ",": "comma",
    ".": "period",
    "/": "slash",
    "\\": "backslash",
    "`": "grave",
  };
  for (let c = 97; c <= 122; c++) k[String.fromCharCode(c)] = String.fromCharCode(c);
  for (let d = 0; d <= 9; d++) k[String(d)] = String(d);
  for (let f = 1; f <= 12; f++) k[`f${f}`] = `F${f}`;
  return k;
})();

const finite = (v) => typeof v === "number" && Number.isFinite(v);
const clamp01 = (v) => Math.min(1, Math.max(0, v));

/** The body of POST /input, checked (400 InputError otherwise); x / y clamped to the display. */
export function parseInput(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new InputError("body must be a JSON object");
  const type = raw.type;
  if (!TYPES.includes(type)) throw new InputError(`type must be one of ${TYPES.join(", ")}`);
  const e = { type };
  if (raw.display != null) {
    if (!finite(raw.display) || !Number.isInteger(raw.display) || raw.display < 0) throw new InputError("display must be a display id");
    e.display = raw.display;
  }
  for (const k of ["x", "y", "dx", "dy"]) {
    if (raw[k] == null) continue;
    if (!finite(raw[k])) throw new InputError(`${k} must be a number`);
    e[k] = k === "x" || k === "y" ? clamp01(raw[k]) : raw[k];
  }
  if (POINTER.has(type) && (e.x === undefined || e.y === undefined)) throw new InputError(`${type} needs x and y (0…1)`);
  if (raw.button != null) {
    if (raw.button !== "left") throw new InputError('button must be "left"');
    if (type === "move") e.button = "left";
  }
  if (raw.seq != null) {
    if (!finite(raw.seq) || !Number.isSafeInteger(raw.seq) || raw.seq < 0) throw new InputError("seq must be a non-negative integer");
    if (type === "move") e.seq = raw.seq;
  }
  if (type === "drag" && e.dx === undefined && e.dy === undefined) throw new InputError("drag needs dx and/or dy");
  if (type === "scroll" && e.dx === undefined && e.dy === undefined) throw new InputError("scroll needs dx and/or dy");
  if (raw.phase != null) {
    if (!PHASES.includes(raw.phase)) throw new InputError(`phase must be one of ${PHASES.join(", ")}`);
    if (type === "scroll") e.phase = raw.phase;
  }
  for (const k of ["vx", "vy"]) {
    if (raw[k] == null) continue;
    if (!finite(raw[k])) throw new InputError(`${k} must be a number`);
    if (type === "scroll") e[k] = raw[k];
  }
  if (type === "type") {
    if (typeof raw.text !== "string" || !raw.text) throw new InputError("type needs a non-empty text");
    if (raw.text.length > 4000) throw new InputError("text is too long (max 4000 characters)");
    e.text = raw.text;
  }
  if (type === "key") {
    if (typeof raw.key !== "string" || !raw.key.trim()) throw new InputError("key needs a key name");
    const name = raw.key.trim().toLowerCase();
    if (!KEYS[name]) throw new InputError(`unknown key "${raw.key.trim()}"`);
    e.key = name;
  }
  if (raw.modifiers != null) {
    if (!Array.isArray(raw.modifiers) || !raw.modifiers.every((m) => Object.hasOwn(MODIFIERS, m))) {
      throw new InputError(`modifiers must be a list of ${Object.keys(MODIFIERS).join(", ")}`);
    }
    const held = type === "up" || (type === "move" && e.button);
    if (raw.modifiers.length && !held) e.modifiers = [...new Set(raw.modifiers)];
  }
  return e;
}

/**
 * Where a checked input leaves the pointer (normalized), null when it doesn't move it (`type`, `key`, a scroll without
 * x / y): the reference server's DisplayPointerGeometry.position(after:). A drag ends at (x + dx, y + dy).
 */
export function positionAfter(e) {
  if (e.x === undefined || e.y === undefined) return null;
  switch (e.type) {
    case "click":
    case "doubleClick":
    case "rightClick":
    case "move":
    case "scroll":
    case "down":
    case "up":
      return { x: e.x, y: e.y };
    case "drag":
      return { x: clamp01(e.x + (e.dx ?? 0)), y: clamp01(e.y + (e.dy ?? 0)) };
    default:
      return null;
  }
}

/** X keysyms of the modifiers (⌘ and ⌃ are both Ctrl), each once. */
export const modifierKeys = (mods = []) => [...new Set(mods.map((m) => `${MODIFIERS[m]}`))];

/** One character as an xdotool key name: its Unicode keysym (xdotool maps a spare key code to it when needed). */
export function charKey(ch) {
  if (ch === "\n" || ch === "\r") return "Return";
  if (ch === "\t") return "Tab";
  if (ch === " ") return "space";
  const cp = ch.codePointAt(0);
  if (cp < 0x20 || cp === 0x7f) return null;
  return `U${cp.toString(16).toUpperCase().padStart(4, "0")}`;
}

/**
 * `type`'s text as xdotool lines. Characters on the keyboard map (ASCII) go a batch per line; any other (CJK, emoji,
 * accents) gets a spare key code mapped to it for its press, and the app reads the map when the press arrives — a
 * second remap before then turns the first character into the second (measured: "你好，世界" typed as "你好界界"),
 * so each such character is a line of its own followed by a pause.
 */
export function typeLines(text) {
  const lines = [];
  let batch = [];
  const flush = () => {
    if (batch.length) lines.push(`key --delay 8 ${batch.join(" ")}`);
    batch = [];
  };
  for (const ch of text) {
    const k = charKey(ch);
    if (!k) continue;
    const cp = ch.codePointAt(0);
    if (cp < 0x7f) {
      batch.push(k);
      if (batch.length >= 32) flush();
    } else {
      flush();
      lines.push(`key ${k}`, "sleep 0.04");
    }
  }
  flush();
  return lines;
}

/** Moves that overtook each other (`seq`): the reference server's PointerMoveGate. */
export class MoveGate {
  constructor() {
    this.last = null;
  }

  admit(seq, now) {
    const l = this.last;
    if (l && now - l.at < 2 && seq < l.seq && l.seq - seq < 1000) return false;
    this.last = { seq, at: now };
    return true;
  }
}

/** The scroll pacing and momentum of the reference server's ScrollMotion, in pixels; wheel clicks come out of it. */
export const SCROLL = Object.freeze({
  tick: 1 / 120,
  idleAfter: 0.5,
  fastWindow: 0.03,
  windowShare: 0.9,
  maxWindow: 0.14,
  intervalWeight: 0.3,
  momentumMin: 120,
  momentumMax: 8000,
  momentumStop: 20,
  deceleration: 0.998,
  /** Pixels per wheel click (a GTK app scrolls about this much per click at 120 dpi). */
  notch: 50,
});

export class ScrollMotion {
  constructor() {
    this.remaining = { x: 0, y: 0 };
    this.carry = { x: 0, y: 0 };
    this.deadline = 0;
    this.lastTick = null;
    this.lastArrival = null;
    this.interval = null;
    this.gesture = null;
    this.momentum = null;
  }

  get busy() {
    return this.lastTick !== null || this.remaining.x !== 0 || this.remaining.y !== 0 || this.momentum !== null || this.gesture !== null;
  }

  noteArrival(now, fresh) {
    const gap = this.lastArrival == null ? null : now - this.lastArrival;
    this.lastArrival = now;
    if (fresh || gap == null || gap > SCROLL.idleAfter) {
      this.interval = null;
      return;
    }
    this.interval = this.interval == null ? gap : this.interval * (1 - SCROLL.intervalWeight) + gap * SCROLL.intervalWeight;
  }

  pace(d, now) {
    this.remaining.x += d.x;
    this.remaining.y += d.y;
    const win = this.interval == null ? SCROLL.fastWindow : Math.min(SCROLL.maxWindow, Math.max(SCROLL.tick, this.interval * SCROLL.windowShare));
    this.deadline = now + win;
    if (this.lastTick == null) this.lastTick = now - SCROLL.tick;
  }

  submit({ dx = 0, dy = 0, phase, vx, vy }, now) {
    const d = { x: finite(dx) ? dx : 0, y: finite(dy) ? dy : 0 };
    const zero = d.x === 0 && d.y === 0;
    if (this.momentum && phase !== "ended" && (phase !== undefined || !zero)) this.momentum = null;
    if (phase === undefined) {
      if (zero) return;
      this.noteArrival(now, false);
      this.pace(d, now);
    } else if (phase === "began" || phase === "changed") {
      const fresh = !this.gesture || phase === "began";
      this.gesture = { ending: null };
      this.noteArrival(now, fresh);
      this.pace(d, now);
    } else {
      if (!this.gesture) {
        if (!zero) {
          this.noteArrival(now, false);
          this.pace(d, now);
        }
        return;
      }
      let v = { x: finite(vx) ? vx : 0, y: finite(vy) ? vy : 0 };
      const len = Math.hypot(v.x, v.y);
      if (len > SCROLL.momentumMax) v = { x: (v.x * SCROLL.momentumMax) / len, y: (v.y * SCROLL.momentumMax) / len };
      this.gesture.ending = v;
      this.pace(d, now);
    }
  }

  /** Other pointer input: what is left goes at once, the gesture ends without momentum, momentum stops. Pixels. */
  interrupt() {
    const out = { x: this.remaining.x + this.carry.x, y: this.remaining.y + this.carry.y };
    this.remaining = { x: 0, y: 0 };
    this.carry = { x: 0, y: 0 };
    this.gesture = null;
    this.momentum = null;
    this.lastTick = null;
    return out;
  }

  /** The pixels due at `now` (whole ones; the rest carries over). */
  tick(now) {
    const prev = this.lastTick ?? now - SCROLL.tick;
    const dt = Math.max(0, now - prev);
    this.lastTick = now;
    const out = { x: 0, y: 0 };
    if (this.momentum) {
      const m = this.momentum;
      const decay = Math.pow(SCROLL.deceleration, dt * 1000);
      const k = dt > 0 ? (1 - decay) / (-Math.log(SCROLL.deceleration) * 1000) : 0;
      this.carry.x += m.v.x * k;
      this.carry.y += m.v.y * k;
      m.v = { x: m.v.x * decay, y: m.v.y * decay };
      if (Math.hypot(m.v.x, m.v.y) < SCROLL.momentumStop) this.momentum = null;
    } else if (this.remaining.x !== 0 || this.remaining.y !== 0) {
      const left = Math.max(0, this.deadline - prev);
      const share = left <= dt ? 1 : dt / left;
      const step = { x: this.remaining.x * share, y: this.remaining.y * share };
      this.remaining.x -= step.x;
      this.remaining.y -= step.y;
      if (share >= 1) this.remaining = { x: 0, y: 0 };
      this.carry.x += step.x;
      this.carry.y += step.y;
    }
    // whole pixels, the sub-pixel rest carried (|rest| ≤ 0.5): what goes out adds up to what was asked
    out.x = Math.round(this.carry.x);
    out.y = Math.round(this.carry.y);
    this.carry.x -= out.x;
    this.carry.y -= out.y;
    // the paced part is out: an ending gesture turns into momentum (fast enough) or ends
    if (this.remaining.x === 0 && this.remaining.y === 0 && this.gesture?.ending) {
      const v = this.gesture.ending;
      this.gesture = null;
      if (Math.hypot(v.x, v.y) >= SCROLL.momentumMin) this.momentum = { v };
    }
    if (!this.momentum && this.remaining.x === 0 && this.remaining.y === 0 && !this.gesture) this.lastTick = null;
    return out;
  }
}

/**
 * About how long xdotool takes for `typeLines` / a `key` line (ms): a key on the keyboard map with `--delay 8` ~10, a
 * remapped one with its pause ~50.
 */
export function typingCostMs(lines) {
  let ms = 0;
  for (const l of lines) {
    if (l.startsWith("key --delay")) ms += 10 * (l.split(" ").length - 3);
    else if (l.startsWith("sleep ")) ms += Number(l.slice(6)) * 1000;
    else ms += 12;
  }
  return ms;
}

/** Typing queued on the keyboard's xdotool beyond this (ms): the next `type` / `key` is refused (429) until it drains. */
export const MAX_TYPING_BACKLOG_MS = 60_000;

/**
 * Turns checked input into xdotool lines on a `width` × `height` screen: pointer lines (moves, clicks, drags, the
 * wheel) through `send`, keyboard lines (`key`, `type`) through `sendKeys` — two xdotool processes, so a long text being
 * typed never holds a click or a scroll back (keys stay in order among themselves). Owns the scroll pacing (a 120 Hz
 * timer while it has work), the move gate, the stuck-button guard (10 s after a `down` without a move or `up`) and the
 * typing backlog (an estimate: MAX_TYPING_BACKLOG_MS at most queued).
 */
export class InputDriver {
  constructor({ send, sendKeys = send, width, height, now = () => performance.now() / 1000, log = () => {}, holdTimeoutMs = 10_000 }) {
    this.send = send;
    this.sendKeys = sendKeys;
    /** When the keyboard's queued lines will have been typed (seconds, `now`'s clock). */
    this.keysBusyUntil = 0;
    this.width = width;
    this.height = height;
    this.now = now;
    this.log = log;
    this.holdTimeoutMs = holdTimeoutMs;
    this.gate = new MoveGate();
    this.scroll = new ScrollMotion();
    this.notch = { x: 0, y: 0 };
    this.timer = null;
    this.held = null; // { mods, at, timer }
  }

  px(x, y) {
    return [Math.min(this.width - 1, Math.round(x * this.width)), Math.min(this.height - 1, Math.round(y * this.height))];
  }

  /** One checked input; `{ ok: true }` or `{ ok: true, stale: true }`. */
  apply(e) {
    if (e.type === "move" && e.seq !== undefined && !this.gate.admit(e.seq, this.now())) return { ok: true, stale: true };
    if (e.type === "scroll") {
      if (e.x !== undefined && e.y !== undefined) this.send([`mousemove ${this.px(e.x, e.y).join(" ")}`]);
      this.scroll.submit(e, this.now());
      this.arm();
      return { ok: true };
    }
    // other pointer input stops the scroll first (what is left goes now)
    if (POINTER.has(e.type)) this.flushScroll(this.scroll.interrupt());
    const mods = modifierKeys(e.modifiers);
    const down = mods.map((m) => `keydown ${m}`);
    const up = mods.map((m) => `keyup ${m}`).reverse();
    const at = e.x !== undefined && e.y !== undefined ? this.px(e.x, e.y) : null;
    switch (e.type) {
      case "move":
        this.send([`mousemove ${at.join(" ")}`]);
        if (e.button && this.held) this.armHold();
        break;
      case "click":
        this.send([`mousemove ${at.join(" ")}`, ...down, "click 1", ...up]);
        break;
      case "rightClick":
        this.send([`mousemove ${at.join(" ")}`, ...down, "click 3", ...up]);
        break;
      case "doubleClick":
        this.send([`mousemove ${at.join(" ")}`, ...down, "click --repeat 2 --delay 80 1", ...up]);
        break;
      case "drag": {
        const to = this.px(clamp01(e.x + (e.dx ?? 0)), clamp01(e.y + (e.dy ?? 0)));
        const steps = 8;
        const lines = [`mousemove ${at.join(" ")}`, ...down, "mousedown 1", "sleep 0.03"];
        for (let i = 1; i <= steps; i++) {
          lines.push(`mousemove ${Math.round(at[0] + ((to[0] - at[0]) * i) / steps)} ${Math.round(at[1] + ((to[1] - at[1]) * i) / steps)}`, "sleep 0.015");
        }
        this.send([...lines, "mouseup 1", ...up]);
        break;
      }
      case "down":
        if (this.held) this.release();
        // the first held move (or the up) waits 15 ms: a quicker one is taken for a click
        this.send([`mousemove ${at.join(" ")}`, ...down, "mousedown 1", "sleep 0.015"]);
        this.held = { mods, timer: null };
        this.armHold();
        break;
      case "up":
        this.send([`mousemove ${at.join(" ")}`, "mouseup 1", ...(this.held?.mods ?? []).map((m) => `keyup ${m}`).reverse()]);
        this.clearHold();
        break;
      case "key":
        this.queueKeys([`key --clearmodifiers ${[...mods, KEYS[e.key]].join("+")}`]);
        break;
      case "type":
        this.queueKeys(typeLines(e.text));
        break;
    }
    return { ok: true };
  }

  /** Keyboard lines onto the keyboard's queue, unless they'd take it past MAX_TYPING_BACKLOG_MS (413 alone, else 429). */
  queueKeys(lines) {
    const now = this.now();
    const cost = typingCostMs(lines) / 1000;
    const busy = Math.max(now, this.keysBusyUntil);
    if (cost > MAX_TYPING_BACKLOG_MS / 1000) throw new InputError(`this text would take about ${Math.ceil(cost)} s to type; send at most ${MAX_TYPING_BACKLOG_MS / 1000} s of it at a time`, 413);
    if (busy - now + cost > MAX_TYPING_BACKLOG_MS / 1000) throw new InputError(`still typing the earlier text (about ${Math.ceil(busy - now)} s left)`, 429);
    this.keysBusyUntil = busy + cost;
    this.sendKeys(lines);
  }

  /** The screen's size changed (a new X server, xrandr): coordinates map onto the new one. */
  resize(width, height) {
    this.width = width;
    this.height = height;
  }

  /** The left button left down (a stream closed, the guard fired): lift it where the pointer is. */
  release() {
    if (!this.held) return;
    this.send(["mouseup 1", ...this.held.mods.map((m) => `keyup ${m}`).reverse()]);
    this.clearHold();
  }

  armHold() {
    if (!this.held) return;
    clearTimeout(this.held.timer);
    this.held.timer = setTimeout(() => {
      this.log(`input: left button held for ${this.holdTimeoutMs / 1000} s without a move or up; releasing it`);
      this.release();
    }, this.holdTimeoutMs);
    this.held.timer.unref?.();
  }

  clearHold() {
    if (this.held) clearTimeout(this.held.timer);
    this.held = null;
  }

  arm() {
    if (this.timer) return;
    this.timer = setInterval(() => {
      this.flushScroll(this.scroll.tick(this.now()));
      if (!this.scroll.busy) {
        clearInterval(this.timer);
        this.timer = null;
      }
    }, SCROLL.tick * 1000);
  }

  /** Pixels → wheel clicks (4 / 5: up / down; 6 / 7: left / right), the remainder kept for the next ones. */
  flushScroll(d) {
    this.notch.x += d.x;
    this.notch.y += d.y;
    const lines = [];
    for (const [axis, neg, pos] of [["y", 4, 5], ["x", 6, 7]]) {
      const n = Math.trunc(this.notch[axis] / SCROLL.notch);
      if (!n) continue;
      this.notch[axis] -= n * SCROLL.notch;
      lines.push(`click --repeat ${Math.abs(n)} --delay 1 ${n > 0 ? pos : neg}`);
    }
    if (lines.length) this.send(lines);
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
    this.clearHold();
  }
}
