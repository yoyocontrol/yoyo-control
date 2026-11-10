import type { Input, Modifier, ScrollPhase } from "./types.js";

/**
 * The screen page's input to the computer (`POST /input`, docs/PROTOCOL.md「输入」): what browser events
 * become, and the queue that sends them in order (ported from the iOS InputQueue, simplified). Pure: the page
 * wires DOM events to these functions.
 */

// ---------------------------------------------------------------- the queue

export type SendInput = (input: Input) => Promise<void>;

/** Pointer moves on their way at once (each with its `seq`; the server drops a stale one). */
export const MAX_MOVES_IN_FLIGHT = 3;
/** Less than this (points, on both axes) waits for more. */
export const MIN_SCROLL = 0.5;
/** A failed move this soon after a reported failure isn't reported (a dead path fails several at once: one toast). */
export const MOVE_FAILURE_QUIET_MS = 1000;

interface Merge {
  kind: "scroll" | "move";
  /** Move: the button held (a live drag). */
  button?: "left";
  dx: number;
  dy: number;
  x: number;
  y: number;
  display?: number;
  hasMove: boolean;
  phase?: ScrollPhase;
  vx: number;
  vy: number;
  /** Takes no more (an `ended`): what comes next starts its own. */
  closed: boolean;
}

type Entry = { t: "input"; input: Input } | { t: "merge"; m: Merge };

const worth = (m: Merge) =>
  m.kind === "move" ? m.hasMove : m.phase === "began" || m.phase === "ended" || Math.abs(m.dx) >= MIN_SCROLL || Math.abs(m.dy) >= MIN_SCROLL;

function mergeInput(m: Merge): Input {
  const base = m.display === undefined ? {} : { display: m.display };
  if (m.kind === "move") return { type: "move", ...base, x: m.x, y: m.y, ...(m.button ? { button: m.button } : {}) };
  const input: Input = { type: "scroll", ...base, x: m.x, y: m.y, dx: m.dx, dy: m.dy };
  if (m.phase) input.phase = m.phase;
  if (m.phase === "ended") {
    input.vx = m.vx;
    input.vy = m.vy;
  }
  return input;
}

export interface InputQueueOptions {
  /** The way in use's link sender (null: HTTP requests, one at a time). Asked for each input. */
  link?: () => ((input: Input) => void) | null;
}

/** `next` folded into `last` when both are of one move or one scroll gesture (null: they go as two). */
export function mergeLinkInput(last: Input, next: Input): Input | null {
  if (last.display !== next.display || last.type !== next.type) return null;
  if (next.type === "move") {
    const mods = (i: Input) => (i.modifiers ?? []).join(",");
    return last.button === next.button && mods(last) === mods(next) ? next : null;
  }
  if (next.type !== "scroll") return null;
  const m: Input = { ...last };
  const a = last.phase, b = next.phase;
  if ((a === undefined && b === undefined) || (a === "began" && b === "changed") || (a === "changed" && b === "changed")) {
    /* adds up */
  } else if (a === "changed" && b === "ended") {
    m.phase = "ended";
    if (next.vx !== undefined) m.vx = next.vx;
    if (next.vy !== undefined) m.vy = next.vy;
  } else {
    return null;
  }
  m.dx = (last.dx ?? 0) + (next.dx ?? 0);
  m.dy = (last.dy ?? 0) + (next.dy ?? 0);
  if (next.x !== undefined) m.x = next.x;
  if (next.y !== undefined) m.y = next.y;
  return m;
}

/**
 * Input in order, one request at a time, except pointer moves: up to MAX_MOVES_IN_FLIGHT of those go at once, each
 * with the next `seq` (from the wall clock in ms, one up per move). Scrolls and moves never queue up: while one is on
 * its way, two-finger / wheel deltas add up and moves keep only the latest position, and what waited goes as one
 * when it returns. Anything else (clicks, keys, text, a drag's down / up) waits for every earlier request, moves
 * included, to return. Scroll phases keep their order: `began` starts a merge of its own, `changed` adds up into the
 * open one, `ended` goes with what waited (or after a `began` not sent yet, on its own).
 *
 * **Link mode** (`options.link` gives a sender: the way in use is a uu Link session): nothing waits for an answer — the
 * link orders, repeats and acknowledges input itself (discrete events exactly once, the newest move wins). What comes in
 * one turn of the event loop goes out at the end of it (a microtask), in order: pointer moves merge into the latest
 * (same display, button and modifiers), and so do scroll deltas of one gesture (`mergeLinkInput`). Moves still take the
 * next `seq`. A refusal comes back later (the link's input error handler); a send that throws (too many unacknowledged
 * events: 429) goes to `failed` at once. A way that stopped being a link before the flush gets them as requests.
 */
export class InputQueue {
  private line: Entry[] = [];
  private busy = false;
  private movesInFlight = 0;
  private nextSeq: number;
  private generation = 0;
  private reportedAt = -Infinity;
  private outbox: Input[] = [];
  private flushScheduled = false;

  constructor(
    private readonly send: SendInput,
    private readonly failed: (e: unknown) => void,
    firstSeq: number = Date.now(),
    private readonly now: () => number = () => performance.now(),
    private readonly options: InputQueueOptions = {},
  ) {
    this.nextSeq = firstSeq;
  }

  /** Link mode: inputs waiting for the end of this turn. */
  get queuedForLink(): number {
    return this.outbox.length;
  }

  /** Requests waiting in line (not sent yet). */
  get waiting(): number {
    return this.line.length;
  }
  get inFlight(): number {
    return this.movesInFlight + (this.busy ? 1 : 0);
  }

  /** A click, a key, text, a drag's down / up: in order, after what came before. */
  input(input: Input): void {
    if (this.options.link?.()) return this.linkEnqueue(input);
    this.closeOpen();
    this.line.push({ t: "input", input });
    this.pump();
  }

  /** The pointer to (x, y) (0…1); `button`: held (a live drag). Only the latest position waits. */
  move(x: number, y: number, display?: number, button?: "left"): void {
    if (this.options.link?.()) return this.linkEnqueue({ type: "move", ...(display === undefined ? {} : { display }), x, y, ...(button ? { button } : {}) });
    const m = this.open("move", button);
    m.x = x;
    m.y = y;
    m.display = display;
    m.hasMove = true;
    this.pump();
  }

  /** A scroll by (dx, dy) display points at (x, y), in a gesture's `phase` (none: a wheel); velocity at lift for `ended`. */
  scroll(dx: number, dy: number, x: number, y: number, display?: number, phase?: ScrollPhase, vx = 0, vy = 0): void {
    if (this.options.link?.()) {
      const s: Input = { type: "scroll", ...(display === undefined ? {} : { display }), x, y, dx, dy, ...(phase ? { phase } : {}) };
      if (phase === "ended") {
        s.vx = vx;
        s.vy = vy;
      }
      return this.linkEnqueue(s);
    }
    let m = this.open("scroll");
    if (phase === "began") {
      // an earlier gesture's leftovers go first, as their own request; this one starts its own
      if (worth(m)) {
        m.closed = true;
        m = this.open("scroll");
      }
      m.phase = "began";
    } else if (phase === "changed") {
      if (!m.phase) m.phase = "changed";
    }
    m.dx += dx;
    m.dy += dy;
    m.x = x;
    m.y = y;
    m.display = display;
    if (phase === "ended") {
      if (m.phase === "began") {
        // its start hasn't gone: it goes as it is, then the end on its own
        m.closed = true;
        this.line.push({ t: "input", input: { type: "scroll", ...(display === undefined ? {} : { display }), x, y, dx: 0, dy: 0, phase: "ended", vx, vy } });
      } else {
        m.phase = "ended";
        m.vx = vx;
        m.vy = vy;
        m.closed = true;
      }
    }
    this.pump();
  }

  /** Drops everything not sent yet (the page stopped); what is on its way is let go. */
  cancel(): void {
    this.generation++;
    this.line = [];
    this.outbox = [];
    this.flushScheduled = false;
    this.busy = false;
    this.movesInFlight = 0;
  }

  /** Link mode: into the outbox (merged with the last one when it can be), sent at the end of this turn. */
  private linkEnqueue(input: Input): void {
    // what the request lane still holds goes first
    for (const e of this.line) {
      if (e.t === "input") this.outbox.push(e.input);
      else if (worth(e.m)) this.outbox.push(mergeInput(e.m));
    }
    this.line = [];
    const last = this.outbox[this.outbox.length - 1];
    const merged = last ? mergeLinkInput(last, input) : null;
    if (merged) this.outbox[this.outbox.length - 1] = merged;
    else this.outbox.push(input);
    if (this.flushScheduled) return;
    this.flushScheduled = true;
    const gen = this.generation;
    queueMicrotask(() => {
      if (gen === this.generation) this.flushLink();
    });
  }

  private flushLink(): void {
    this.flushScheduled = false;
    const items = this.outbox;
    this.outbox = [];
    const sendNow = this.options.link?.() ?? null;
    if (!sendNow) {
      for (const input of items) this.line.push({ t: "input", input });
      this.pump();
      return;
    }
    for (let input of items) {
      const move = input.type === "move";
      if (move) input = { ...input, seq: this.nextSeq++ };
      try {
        sendNow(input);
      } catch (err) {
        this.report(err ?? new Error("failed"), move);
      }
    }
  }

  private report(err: unknown, move: boolean): void {
    const t = this.now();
    if (move && t - this.reportedAt < MOVE_FAILURE_QUIET_MS) return;
    this.reportedAt = t;
    this.failed(err);
  }

  /** The last entry if it is an open merge of this kind, else a new one. */
  private open(kind: "scroll" | "move", button?: "left"): Merge {
    const last = this.line[this.line.length - 1];
    if (last?.t === "merge" && !last.m.closed && last.m.kind === kind && last.m.button === button) return last.m;
    this.closeOpen();
    const m: Merge = { kind, dx: 0, dy: 0, x: 0.5, y: 0.5, hasMove: false, vx: 0, vy: 0, closed: false, ...(button ? { button } : {}) };
    this.line.push({ t: "merge", m });
    return m;
  }

  private closeOpen(): void {
    const last = this.line[this.line.length - 1];
    if (last?.t === "merge") last.m.closed = true;
  }

  private pump(): void {
    while (this.line.length > 0) {
      const e = this.line[0]!;
      if (e.t === "merge" && !worth(e.m)) {
        // nothing to send yet: an open one waits for more, a closed one is dropped
        if (!e.m.closed) return;
        this.line.shift();
        continue;
      }
      const isMove = e.t === "merge" && e.m.kind === "move";
      if (this.busy || (isMove ? this.movesInFlight >= MAX_MOVES_IN_FLIGHT : this.movesInFlight > 0)) return;
      this.line.shift();
      let input = e.t === "input" ? e.input : mergeInput(e.m);
      if (isMove) {
        input = { ...input, seq: this.nextSeq++ };
        this.movesInFlight++;
      } else {
        this.busy = true;
      }
      const gen = this.generation;
      this.send(input).then(
        () => this.done(gen, isMove, null),
        (err: unknown) => this.done(gen, isMove, err ?? new Error("failed")),
      );
    }
  }

  private done(gen: number, move: boolean, err: unknown): void {
    if (gen !== this.generation) return;
    if (move) this.movesInFlight--;
    else this.busy = false;
    if (err !== null) this.report(err, move);
    this.pump();
  }
}

// ---------------------------------------------------------------- keys

/** The fields of a KeyboardEvent the mapping reads. */
export interface KeyLike {
  key: string;
  code: string;
  metaKey: boolean;
  ctrlKey: boolean;
  altKey: boolean;
  shiftKey: boolean;
  isComposing?: boolean;
  keyCode?: number;
}

const NAMED: Record<string, string> = {
  Enter: "return",
  NumpadEnter: "return",
  Escape: "escape",
  Tab: "tab",
  Backspace: "delete",
  Delete: "forwardDelete",
  ArrowUp: "up",
  ArrowDown: "down",
  ArrowLeft: "left",
  ArrowRight: "right",
  Home: "home",
  End: "end",
  PageUp: "pageUp",
  PageDown: "pageDown",
};
for (let i = 1; i <= 12; i++) NAMED[`F${i}`] = `f${i}`;

/** `code` → the protocol's name for letters, digits and punctuation (layout independent: ⌘C is ⌘C on any layout). */
function codeName(code: string): string | null {
  let m = /^Key([A-Z])$/.exec(code);
  if (m) return m[1]!.toLowerCase();
  m = /^(?:Digit|Numpad)(\d)$/.exec(code);
  if (m) return m[1]!;
  const punct: Record<string, string> = {
    Minus: "-", Equal: "=", BracketLeft: "[", BracketRight: "]", Semicolon: ";", Quote: "'", Comma: ",", Period: ".",
    Slash: "/", Backslash: "\\", Backquote: "`", Space: "space", NumpadSubtract: "-", NumpadAdd: "=", NumpadDecimal: ".",
    NumpadDivide: "/",
  };
  return punct[code] ?? null;
}

/** ⌘ and Ctrl both send `cmd` (a Mac takes ⌘, the Linux desktop maps it to Ctrl); Shift and Option / Alt as they are. */
export function modifiersOf(e: Pick<KeyLike, "metaKey" | "ctrlKey" | "altKey" | "shiftKey">): Modifier[] {
  const m: Modifier[] = [];
  if (e.metaKey || e.ctrlKey) m.push("cmd");
  if (e.shiftKey) m.push("shift");
  if (e.altKey) m.push("alt");
  return m;
}

/**
 * A keydown as a `key` input, or null when it isn't one: a plain character (with or without Shift / Option) is typed
 * through the hidden text field (`input` / `compositionend` → `type`, so the browser's IME composes Chinese first),
 * and so is anything while a composition is on. Keys with names (Return, arrows, F-keys…) and shortcuts (⌘ / Ctrl +
 * a letter, digit or punctuation) are keys. `linux`: Insert has a name there (the paste key, Shift+Insert).
 */
export function keyInput(e: KeyLike, linux = false): Input | null {
  if (e.isComposing || e.keyCode === 229) return null;
  if (e.key === "Meta" || e.key === "Control" || e.key === "Shift" || e.key === "Alt" || e.key === "CapsLock") return null;
  const modifiers = modifiersOf(e);
  let name: string | null = NAMED[e.key] ?? NAMED[e.code] ?? null;
  if (!name && e.key === "Insert" && linux) name = "insert";
  const shortcut = e.metaKey || e.ctrlKey;
  if (!name && shortcut) name = codeName(e.code) ?? (e.key.length === 1 ? e.key.toLowerCase() : null);
  if (!name) return null;
  return modifiers.length ? { type: "key", key: name, modifiers } : { type: "key", key: name };
}

/**
 * What the hidden text field's `input` event sends (`beforeinput` types from a phone's keyboard included): typed
 * text → `type`, a line break → Return, a backspace → Delete. Null while composing (the text comes with
 * `compositionend`) or for anything else.
 */
export function textInput(inputType: string, data: string | null, composing: boolean): Input | null {
  if (composing) return null;
  switch (inputType) {
    case "insertText":
    case "insertReplacementText":
    case "insertFromPaste":
    case "insertFromDrop":
    {
      const text = data ? withoutSentinel(data) : "";
      return text ? { type: "type", text } : null;
    }
    case "insertLineBreak":
    case "insertParagraph":
      return { type: "key", key: "return" };
    case "deleteContentBackward":
      return { type: "key", key: "delete" };
    case "deleteContentForward":
      return { type: "key", key: "forwardDelete" };
    default:
      return null;
  }
}

/**
 * The paste key after the phone / browser put text on the computer's clipboard: ⌘V on the Mac; Shift+Insert on the
 * Linux desktop (yoyo-linux's `insert`: GTK apps and xfce4-terminal both paste with it; Ctrl+V doesn't in a terminal);
 * Ctrl+V on Windows (yoyo-windows: every Windows app, the console included, pastes with it).
 */
export const PASTE_KEY: Record<"mac" | "linux" | "windows", Input> = {
  mac: { type: "key", key: "v", modifiers: ["cmd"] },
  linux: { type: "key", key: "insert", modifiers: ["shift"] },
  windows: { type: "key", key: "v", modifiers: ["ctrl"] },
};

// ---------------------------------------------------------------- pointer geometry

export interface Box {
  left: number;
  top: number;
  width: number;
  height: number;
}

/** A client point as the display's 0…1 (clamped), from the picture's box on the page. */
export function normalizedPoint(clientX: number, clientY: number, box: Box): { x: number; y: number } {
  const clamp = (v: number) => (Number.isFinite(v) ? Math.min(1, Math.max(0, v)) : 0.5);
  return { x: clamp((clientX - box.left) / box.width), y: clamp((clientY - box.top) / box.height) };
}

/**
 * A wheel event's scroll in display points (positive dy = see content further down, as the browser's deltaY). Pixel
 * deltas (trackpads) follow the fingers on the picture: × the display's points per picture pixel; line and page
 * deltas are wheel notches (40 points a line, a page = the display's height).
 */
export function wheelDelta(deltaX: number, deltaY: number, deltaMode: number, pointsPerPx: number, pageHeight: number): { dx: number; dy: number } {
  const k = deltaMode === 1 ? 40 : deltaMode === 2 ? pageHeight : pointsPerPx;
  return { dx: deltaX * k, dy: deltaY * k };
}

// ---------------------------------------------------------------- touch

/** What a finger on the picture does (a phone's browser): tap, double tap, long press, one-finger scroll. */
export type TouchAction =
  | { t: "click" | "doubleClick" | "rightClick"; x: number; y: number }
  | { t: "scroll"; phase: ScrollPhase; dx: number; dy: number; x: number; y: number; vx: number; vy: number };

export const TOUCH_SLOP_PX = 8;
export const LONG_PRESS_MS = 500;
export const DOUBLE_TAP_MS = 300;
export const DOUBLE_TAP_PX = 24;

/**
 * One-finger gestures over the picture, by time and position (client px), pure: `down` / `move` / `up` / `tick`
 * (timers: the page calls it at `deadline`) return what to send. A tap waits DOUBLE_TAP_MS for a second one (then
 * `doubleClick`, else `click`); a finger held LONG_PRESS_MS without moving right-clicks; one that moves past the slop
 * scrolls, the content following it (finger up = content further down), in display points (`pointsPerPx`), with the
 * gesture's phases and the velocity at lift. `at` maps a client point to the display's 0…1.
 */
export class TouchGestures {
  private start: { x: number; y: number; t: number } | null = null;
  private last: { x: number; y: number } | null = null;
  private scrolling = false;
  private pressed = false;
  private longFired = false;
  private pendingTap: { x: number; y: number; t: number } | null = null;
  /** Recent finger positions (for the velocity at lift). */
  private trail: { x: number; y: number; t: number }[] = [];

  constructor(
    private readonly at: (x: number, y: number) => { x: number; y: number },
    private readonly pointsPerPx: () => number,
  ) {}

  /** When `tick` has something to do (a long press, a single tap's wait running out), or null. */
  get deadline(): number | null {
    if (this.pressed && !this.scrolling && !this.longFired && this.start) return this.start.t + LONG_PRESS_MS;
    if (this.pendingTap) return this.pendingTap.t + DOUBLE_TAP_MS;
    return null;
  }

  down(x: number, y: number, t: number): TouchAction[] {
    this.start = { x, y, t };
    this.last = { x, y };
    this.scrolling = false;
    this.pressed = true;
    this.longFired = false;
    this.trail = [{ x, y, t }];
    return [];
  }

  move(x: number, y: number, t: number): TouchAction[] {
    if (!this.pressed || !this.start || !this.last || this.longFired) return [];
    this.trail.push({ x, y, t });
    while (this.trail.length > 2 && t - this.trail[0]!.t > 100) this.trail.shift();
    if (!this.scrolling) {
      if (Math.hypot(x - this.start.x, y - this.start.y) < TOUCH_SLOP_PX) return [];
      this.scrolling = true;
      // a tap waiting for its second one is a click now (the finger went on to scroll)
      const out: TouchAction[] = this.flushTap();
      out.push(this.scrollAction("began", this.start.x - x, this.start.y - y, x, y, 0, 0));
      this.last = { x, y };
      return out;
    }
    const a = this.scrollAction("changed", this.last.x - x, this.last.y - y, x, y, 0, 0);
    this.last = { x, y };
    return [a];
  }

  up(x: number, y: number, t: number): TouchAction[] {
    if (!this.pressed || !this.start) return [];
    this.pressed = false;
    if (this.longFired) return [];
    if (this.scrolling) {
      this.scrolling = false;
      const first = this.trail[0]!;
      const dt = Math.max(1, t - first.t) / 1000;
      const k = this.pointsPerPx();
      const recent = t - first.t <= 150;
      const vx = recent ? ((first.x - x) / dt) * k : 0;
      const vy = recent ? ((first.y - y) / dt) * k : 0;
      const last = this.last ?? { x, y };
      return [this.scrollAction("ended", last.x - x, last.y - y, x, y, vx, vy)];
    }
    const p = this.pendingTap;
    if (p && t - p.t <= DOUBLE_TAP_MS && Math.hypot(x - p.x, y - p.y) <= DOUBLE_TAP_PX) {
      this.pendingTap = null;
      return [{ t: "doubleClick", ...this.at(p.x, p.y) }];
    }
    const out = this.flushTap();
    this.pendingTap = { x, y, t };
    return out;
  }

  cancel(): void {
    this.pressed = false;
    this.scrolling = false;
    this.pendingTap = null;
  }

  tick(t: number): TouchAction[] {
    if (this.pressed && !this.scrolling && !this.longFired && this.start && t - this.start.t >= LONG_PRESS_MS) {
      this.longFired = true;
      // a tap still waiting for its second one goes first, as the click it was (never after the right-click)
      return [...this.flushTap(), { t: "rightClick", ...this.at(this.start.x, this.start.y) }];
    }
    if (this.pendingTap && t - this.pendingTap.t >= DOUBLE_TAP_MS) return this.flushTap();
    return [];
  }

  private flushTap(): TouchAction[] {
    const p = this.pendingTap;
    this.pendingTap = null;
    return p ? [{ t: "click", ...this.at(p.x, p.y) }] : [];
  }

  private scrollAction(phase: ScrollPhase, dxPx: number, dyPx: number, x: number, y: number, vx: number, vy: number): TouchAction {
    const k = this.pointsPerPx();
    return { t: "scroll", phase, dx: dxPx * k, dy: dyPx * k, ...this.at(x, y), vx, vy };
  }
}

// ---------------------------------------------------------------- mouse clicks

/**
 * A mouse's clicks as the computer should get them: a double click is ONE `doubleClick` (not `click` + `doubleClick`,
 * which the Mac takes as three presses and the Linux desktop's xdotool as a triple click). A first click (`detail` 1)
 * waits DOUBLE_TAP_MS (as a tap does); a second one (`detail` 2) within it replaces it with a `doubleClick`; else it
 * goes as `click` at its deadline. `flush()` sends a waiting click at once: the page calls it before any other input
 * (keys, text, a drag's down, a right-click, a scroll) so the order stays. Pure: `now` and `tick` come from the page.
 */
export class ClickGate {
  private pending: { input: Input; t: number } | null = null;

  constructor(private readonly emit: (input: Input) => void) {}

  /** When `tick` sends the waiting click, or null. */
  get deadline(): number | null {
    return this.pending ? this.pending.t + DOUBLE_TAP_MS : null;
  }

  /** A browser click with its `detail` (the click count) at (x, y). */
  click(x: number, y: number, detail: number, modifiers: Modifier[], t: number): void {
    const mods = modifiers.length ? { modifiers } : {};
    if (detail === 2 && this.pending && t - this.pending.t <= DOUBLE_TAP_MS) {
      this.pending = null;
      this.emit({ type: "doubleClick", x, y, ...mods });
      return;
    }
    this.flush();
    // a triple click (or more): the double click already went
    if (detail > 2) return;
    if (detail === 2) {
      // the first one went out already (the browser's double-click time is longer than ours): one more click
      this.emit({ type: "click", x, y, ...mods });
      return;
    }
    this.pending = { input: { type: "click", x, y, ...mods }, t };
  }

  /** The waiting click goes now (before other input). */
  flush(): void {
    const p = this.pending;
    this.pending = null;
    if (p) this.emit(p.input);
  }

  tick(t: number): void {
    if (this.pending && t - this.pending.t >= DOUBLE_TAP_MS) this.flush();
  }

  /** The page stopped: a waiting click is dropped. */
  cancel(): void {
    this.pending = null;
  }
}

// ---------------------------------------------------------------- the keyboard's text field

/**
 * What the hidden text field holds between inputs: one character, so a phone's soft keyboard (Android in particular)
 * has something to delete and sends `deleteContentBackward` — mapped to the Delete key — instead of nothing. The field
 * goes back to it after every input (iOS keeps a sentinel the same way).
 */
export const FIELD_SENTINEL = "​";

/** Puts the field back to the sentinel, the caret after it. */
export function resetField(field: { value: string; setSelectionRange?: (start: number, end: number) => void }): void {
  field.value = FIELD_SENTINEL;
  try {
    field.setSelectionRange?.(FIELD_SENTINEL.length, FIELD_SENTINEL.length);
  } catch {
    /* not focusable right now */
  }
}

/** Composed text without the sentinel (a keyboard that replaced the field's whole text sends it along). */
export const withoutSentinel = (text: string) => text.split(FIELD_SENTINEL).join("");

// ---------------------------------------------------------------- this browser

/** A name for this browser to show on the other devices: "Chrome on Mac", "Safari on iPhone". */
export function deviceName(ua: string): string {
  const browser = /Edg\//.test(ua)
    ? "Edge"
    : /Firefox\//.test(ua)
      ? "Firefox"
      : /(?:Chrome|CriOS)\//.test(ua)
        ? "Chrome"
        : /Safari\//.test(ua)
          ? "Safari"
          : "Browser";
  const os = /iPhone/.test(ua)
    ? "iPhone"
    : /iPad/.test(ua)
      ? "iPad"
      : /Android/.test(ua)
        ? "Android"
        : /Mac OS X|Macintosh/.test(ua)
          ? "Mac"
          : /Windows/.test(ua)
            ? "Windows"
            : /Linux/.test(ua)
              ? "Linux"
              : null;
  return os ? `${browser} on ${os}` : browser;
}
