// The client-drawn pointer of `cursor=client` streams (README.md「指针」; the protocol's「客户端指针」, the reference
// server's DisplayPointer.swift / StreamCursor.swift): where the pointer is and what it looks like, for one stream,
// from its video helper's 'P' records (polled moves, XFixes shapes) and from `/input` (the position an input leaves it
// at, the moment it is handled).
//
// Shape ids: `base + the X cursor serial`, `base` a random multiple of 2^20 in [2^20, 2^40) chosen once per process,
// so an id always means the same image within this process and never one a previous process (a phone's cache) used;
// 0 is the built-in arrow. A serial whose pixels change (a new X server under this process) moves to a new base.
import { crc32 } from "node:zlib";
import { builtinArrow, cursorPNG } from "./png.mjs";

/** Cursor parts at most this often per stream (StreamTuning.cursorMinInterval): 120 a second, the helpers' poll rate. */
export const CURSOR_MIN_INTERVAL = 1 / 120;
/** A stream resends a shape it sent once this many others came after it (ScreenCursorShapes.maxRemembered). */
export const SENT_SHAPES_MAX = 32;
/** Shapes (PNGs) kept, process-wide. */
export const SHAPES_MAX = 64;
/** A polled position this close (px) to where the pointer is (our own input, read back) is no news. */
export const SAME_POSITION_PX = 1.5;

const randomBase = (not) => {
  for (;;) {
    const b = (1 + Math.floor(Math.random() * (2 ** 20 - 1))) * 2 ** 20;
    if (b !== not) return b;
  }
};

/** The process's cursor images by X cursor serial: their PNG (made once) and id. */
export class CursorShapes {
  constructor({ log = () => {}, base = randomBase() } = {}) {
    this.log = log;
    this.base = base;
    /** serial → { id, key, png (base64), xhot, yhot, w, h }, and the same by id */
    this.bySerial = new Map();
    this.byId = new Map();
  }

  /** A 'P' record with pixels: its shape remembered (the PNG made the first time) → its id. */
  add(r) {
    const key = `${crc32(r.pixels)}:${r.w}x${r.h}:${r.xhot},${r.yhot}`;
    const known = this.bySerial.get(r.serial);
    if (known && known.key === key) return known.id;
    if (known) {
      // the same serial for another image: a new X server under this process; ids from the old one mean other images
      this.base = randomBase(this.base);
      this.bySerial.clear();
      this.byId.clear();
      this.log("pointer: a cursor serial came back with another image (a new X server?); new shape ids");
    }
    if (this.bySerial.size >= SHAPES_MAX) {
      const [oldest, old] = this.bySerial.entries().next().value;
      this.bySerial.delete(oldest);
      this.byId.delete(old.id);
    }
    let png;
    try {
      png = cursorPNG(r.w, r.h, r.pixels).toString("base64");
    } catch (err) {
      this.log(`pointer: no PNG for cursor ${r.serial} (${err.message}); the built-in arrow stands in`);
      return 0;
    }
    const s = { id: this.base + r.serial, key, png, xhot: r.xhot, yhot: r.yhot, w: r.w, h: r.h };
    this.bySerial.set(r.serial, s);
    this.byId.set(s.id, s);
    return s.id;
  }

  /** The id of a serial seen before (null: never seen, or forgotten). */
  idOf(serial) {
    return this.bySerial.get(serial)?.id ?? null;
  }

  /** The shape of `id` as a part's `shape`, normalized to a `width` × `height` display; null when unknown. */
  shape(id, width, height) {
    if (id === 0) return builtinArrow(width, height);
    const s = this.byId.get(id);
    return s ? { id, png: s.png, hotX: s.xhot / width, hotY: s.yhot / height, width: s.w / width, height: s.h / height } : null;
  }
}

/** One stream's pointer: `current()` for its cursor parts; `onChange` whenever that changed. */
export class CursorFeed {
  constructor({ width, height, shapes, onChange = () => {} }) {
    this.width = width;
    this.height = height;
    this.shapes = shapes;
    this.onChange = onChange;
    this.cursor = { x: 0, y: 0, visible: false, shapeId: 0 };
    /** Whether a 'P' came yet (the first one is the stream's first cursor part). */
    this.known = false;
    this.lastLocation = null;
  }

  /** A 'P' record of the stream's helper. */
  fromHelper(r) {
    const c = { ...this.cursor };
    if (r.none) c.shapeId = 0;
    else if (r.pixels) c.shapeId = this.shapes.add(r);
    else c.shapeId = this.shapes.idOf(r.serial) ?? c.shapeId;
    c.visible = r.visible;
    // only a change of the location moves the pointer, and not one within 1.5 px of where it is (our input, read back)
    if (!this.lastLocation || this.lastLocation[0] !== r.x || this.lastLocation[1] !== r.y) {
      this.lastLocation = [r.x, r.y];
      const nx = clamp01(r.x / this.width);
      const ny = clamp01(r.y / this.height);
      const same = this.known && Math.abs(nx - c.x) * this.width < SAME_POSITION_PX && Math.abs(ny - c.y) * this.height < SAME_POSITION_PX;
      if (!same) {
        c.x = nx;
        c.y = ny;
      }
    }
    this.known = true;
    this.set(c);
  }

  /** `/input` left the pointer at (x, y) (normalized). */
  noteInput(x, y) {
    this.set({ ...this.cursor, x, y });
  }

  set(c) {
    const b = this.cursor;
    if (c.x === b.x && c.y === b.y && c.visible === b.visible && c.shapeId === b.shapeId) return;
    this.cursor = c;
    this.onChange();
  }

  /** The pointer now and its shape (null: none to send). */
  current() {
    return { cursor: this.cursor, shape: this.shapes.shape(this.cursor.shapeId, this.width, this.height) };
  }
}

const clamp01 = (v) => Math.min(1, Math.max(0, v));

/** The JSON body of a cursor part (StreamCursorPart.body): `shape` only when given. */
export function cursorBody(c, shape) {
  const o = { shapeId: c.shapeId, visible: c.visible, x: c.x, y: c.y };
  if (shape) o.shape = shape;
  return Buffer.from(JSON.stringify(o));
}
