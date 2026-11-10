// PNG for the client-drawn pointer (README.md「指针」): a cursor's premultiplied RGBA → straight RGBA → an 8-bit RGBA PNG
// (zlib from node), and the built-in arrow the protocol sends as shapeId 0 when the cursor's image can't be had — the
// same drawing as the reference server's StreamCursor.swift (`CursorImage.makeArrow`): a black arrow with a white
// border, 26 px tall per 1600 px of picture width, its PNG at 2× that.
import { crc32, deflateSync } from "node:zlib";

const SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

function chunk(type, data) {
  const head = Buffer.alloc(8);
  head.writeUInt32BE(data.length, 0);
  head.write(type, 4, "latin1");
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), data])) >>> 0, 0);
  return Buffer.concat([head, data, crc]);
}

/** An 8-bit RGBA PNG of `width` × `height` straight-alpha pixels (`rgba`: width × height × 4 bytes, row-major). */
export function encodePNG(width, height, rgba) {
  if (rgba.length !== width * height * 4) throw new Error(`png: ${rgba.length} bytes for ${width} x ${height}`);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA
  // compression, filter, interlace: 0
  const raw = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y++) {
    // filter type 0 (none) per row: a cursor is small, the compression barely cares
    rgba.copy(raw, y * (width * 4 + 1) + 1, y * width * 4, (y + 1) * width * 4);
  }
  return Buffer.concat([SIGNATURE, chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]);
}

/** Premultiplied RGBA → straight RGBA (a new buffer). */
export function unpremultiply(rgba) {
  const out = Buffer.alloc(rgba.length);
  for (let i = 0; i < rgba.length; i += 4) {
    const a = rgba[i + 3];
    out[i + 3] = a;
    if (!a) continue;
    for (let k = 0; k < 3; k++) out[i + k] = Math.min(255, Math.round((rgba[i + k] * 255) / a));
  }
  return out;
}

/** The PNG of a premultiplied-RGBA cursor image. */
export const cursorPNG = (width, height, premultiplied) => encodePNG(width, height, unpremultiply(premultiplied));

/**
 * The arrow (StreamCursor.swift `CursorImage.makeArrow`) at `unit` pixels per arrow unit, 4 × 4 supersampled:
 * `{ width, height, hotX, hotY, rgba }` (premultiplied) and the height of its visible rows.
 */
export function makeArrow(unit) {
  const body = [[0, 0], [0, 15.5], [3.7, 12.0], [6.3, 17.8], [8.6, 16.8], [6.0, 11.2], [11.0, 11.0]];
  const outline = 1.3 * unit;
  const pad = Math.ceil(outline) + 1;
  const pts = body.map(([x, y]) => [pad + x * unit, pad + y * unit]);
  const w = Math.ceil(11.0 * unit + 2 * pad);
  const h = Math.ceil(17.8 * unit + 2 * pad);
  const inside = (px, py) => {
    let c = false;
    for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
      const [xi, yi] = pts[i];
      const [xj, yj] = pts[j];
      if (yi > py !== yj > py && px < ((xj - xi) * (py - yi)) / (yj - yi) + xi) c = !c;
    }
    return c;
  };
  const edgeDistance = (px, py) => {
    let best = Infinity;
    for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
      const [ax, ay] = pts[j];
      const [bx, by] = pts[i];
      const dx = bx - ax;
      const dy = by - ay;
      const t = Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)));
      best = Math.min(best, Math.hypot(ax + t * dx - px, ay + t * dy - py));
    }
    return best;
  };
  const ss = 4;
  const rgba = Buffer.alloc(w * h * 4);
  let top = -1;
  let bottom = -1;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let alpha = 0;
      let white = 0;
      for (let sy = 0; sy < ss; sy++) {
        for (let sx = 0; sx < ss; sx++) {
          const px = x + (sx + 0.5) / ss;
          const py = y + (sy + 0.5) / ss;
          if (inside(px, py)) alpha++;
          else if (edgeDistance(px, py) <= outline) {
            alpha++;
            white++;
          }
        }
      }
      const n = ss * ss;
      const a = Math.round((alpha / n) * 255);
      const v = Math.round((white / n) * 255);
      const d = (y * w + x) * 4;
      rgba[d] = v;
      rgba[d + 1] = v;
      rgba[d + 2] = v;
      rgba[d + 3] = a;
      if (a) {
        if (top < 0) top = y;
        bottom = y;
      }
    }
  }
  return { width: w, height: h, hotX: pad, hotY: pad, rgba, visibleHeight: top < 0 ? 0 : bottom - top + 1 };
}

/** The arrow whose visible rows are as close to `target` px as the unit allows (CursorImage.arrow). */
export function arrowImage(target) {
  const t = Math.max(8, target);
  let unit = t / 20.4;
  let best = makeArrow(unit);
  for (let i = 0; i < 3 && best.visibleHeight !== t; i++) {
    unit *= t / Math.max(best.visibleHeight, 1);
    const next = makeArrow(unit);
    if (Math.abs(next.visibleHeight - t) < Math.abs(best.visibleHeight - t)) best = next;
  }
  return best;
}

/** The built-in arrow's visible height as a fraction of the picture WIDTH (26 px per 1600), and its PNG's scale. */
export const ARROW = Object.freeze({ widthFraction: 26 / 1600, renderScale: 2 });

let arrowCache = null;

/**
 * The built-in arrow (shapeId 0) as a cursor part's shape for a `width` × `height` display (StreamCursor.swift
 * `builtinArrow`): normalized to the display, its PNG made once per process.
 */
export function builtinArrow(width, height) {
  if (!arrowCache) {
    const img = arrowImage(Math.round(26 * ARROW.renderScale));
    arrowCache = { img, png: cursorPNG(img.width, img.height, img.rgba).toString("base64") };
  }
  const { img, png } = arrowCache;
  const k = ARROW.widthFraction / img.visibleHeight;
  const aspect = width / height;
  return { id: 0, png, hotX: img.hotX * k, hotY: img.hotY * k * aspect, width: img.width * k, height: img.height * k * aspect };
}
