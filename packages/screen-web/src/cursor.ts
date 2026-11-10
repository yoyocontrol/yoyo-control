import type { CursorPart } from "./types.js";

/**
 * The pointer the page draws itself (`cursor=client`, docs/PROTOCOL.md「客户端指针」): the server leaves it out of the
 * pictures and sends cursor parts — one before the stream's first picture, then on change. Shapes are cached by
 * `shapeId` (the same id is always the same picture; a `shape` for a known id replaces it). Ids are big numbers
 * (≥ 1e6 on the Mac, a random 2^20 multiple on Linux): never range-checked like coordinates. A stream whose first
 * picture comes without a cursor part before it draws the pointer into its pictures: then nothing is drawn here.
 * Pure: the page renders `view()`.
 */

export interface CursorShape {
  /** A data: URL of the PNG. */
  url: string;
  hotX: number;
  hotY: number;
  width: number;
  height: number;
}

export interface CursorView {
  /** 0…1 of the display: where the shape's top-left goes, and its size. */
  left: number;
  top: number;
  width: number;
  height: number;
  /** null: draw the page's own arrow (shape missing or unknown). */
  url: string | null;
}

const MAX_SHAPES = 64;

/** A cursor part's JSON, leniently: null when it isn't one. */
export function parseCursorPart(body: Uint8Array | string): CursorPart | null {
  let v: unknown;
  try {
    v = JSON.parse(typeof body === "string" ? body : new TextDecoder().decode(body));
  } catch {
    return null;
  }
  if (!v || typeof v !== "object") return null;
  const o = v as Record<string, unknown>;
  const num = (k: unknown) => (typeof k === "number" && Number.isFinite(k) ? k : null);
  const x = num(o.x), y = num(o.y), id = num(o.shapeId);
  if (x === null || y === null) return null;
  const part: CursorPart = { x, y, visible: o.visible !== false, shapeId: id ?? 0 };
  const s = o.shape as Record<string, unknown> | undefined;
  if (s && typeof s === "object" && typeof s.png === "string") {
    const sid = num(s.id), hx = num(s.hotX), hy = num(s.hotY), w = num(s.width), h = num(s.height);
    if (sid !== null && hx !== null && hy !== null && w !== null && h !== null && w > 0 && h > 0)
      part.shape = { id: sid, png: s.png, hotX: hx, hotY: hy, width: w, height: h };
  }
  return part;
}

export class CursorModel {
  private shapes = new Map<number, CursorShape>();
  private part: CursorPart | null = null;
  private sawCursor = false;
  private sawPicture = false;
  /** The page moved the pointer itself (its own input) since the server's last word. */
  private local: { x: number; y: number } | null = null;

  /** A new stream: nothing seen yet (cached shapes stay: ids never change meaning). */
  streamOpened(): void {
    this.sawCursor = false;
    this.sawPicture = false;
  }

  /** A cursor part. */
  cursor(p: CursorPart): void {
    this.sawCursor = true;
    if (p.shape) {
      this.shapes.delete(p.shape.id);
      this.shapes.set(p.shape.id, { url: `data:image/png;base64,${p.shape.png}`, hotX: p.shape.hotX, hotY: p.shape.hotY, width: p.shape.width, height: p.shape.height });
      while (this.shapes.size > MAX_SHAPES) this.shapes.delete(this.shapes.keys().next().value!);
    }
    this.part = p;
    this.local = null;
  }

  /** A picture arrived. true when this stream draws the pointer into its pictures (no cursor part came first). */
  picture(): boolean {
    if (!this.sawPicture && !this.sawCursor) this.part = null;
    this.sawPicture = true;
    return !this.sawCursor;
  }

  /** The page's own input moved the pointer (shown at once; the server's echo takes over). */
  moved(x: number, y: number): void {
    if (this.part) this.local = { x, y };
  }

  /** Whether the page draws a pointer at all (cursor parts are coming). */
  get drawn(): boolean {
    return this.sawCursor && this.part !== null;
  }

  view(): CursorView | null {
    const p = this.part;
    if (!p || !this.sawCursor || !p.visible) return null;
    const at = this.local ?? p;
    const s = this.shapes.get(p.shapeId);
    if (!s) return { left: at.x, top: at.y, width: 0, height: 0, url: null };
    return { left: at.x - s.hotX, top: at.y - s.hotY, width: s.width, height: s.height, url: s.url };
  }
}
