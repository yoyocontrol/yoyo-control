// The client-drawn pointer's pure parts: the PNG, the built-in arrow, shape ids, a stream's feed, where input leaves
// the pointer, the 'P' record.
import assert from "node:assert/strict";
import { test } from "node:test";
import { crc32, inflateSync } from "node:zlib";
import { CursorFeed, CursorShapes, SHAPES_MAX, cursorBody } from "../cursor.mjs";
import { parseInput, positionAfter } from "../input.mjs";
import { builtinArrow, cursorPNG, encodePNG, unpremultiply } from "../png.mjs";
import { RecordReader } from "../wire.mjs";
import { pointerRecord, solidCursor } from "./fakes.mjs";

/** A PNG's chunks (CRCs checked) and its pixels (filter 0 rows only, as png.mjs writes them). */
function decodePNG(buf) {
  assert.deepEqual(buf.subarray(0, 8), Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
  const chunks = {};
  for (let i = 8; i < buf.length; ) {
    const len = buf.readUInt32BE(i);
    const type = buf.subarray(i + 4, i + 8).toString("latin1");
    const data = buf.subarray(i + 8, i + 8 + len);
    assert.equal(buf.readUInt32BE(i + 8 + len), crc32(buf.subarray(i + 4, i + 8 + len)) >>> 0, `${type} CRC`);
    chunks[type] = Buffer.concat([chunks[type] ?? Buffer.alloc(0), data]);
    i += 12 + len;
  }
  const width = chunks.IHDR.readUInt32BE(0);
  const height = chunks.IHDR.readUInt32BE(4);
  assert.deepEqual([chunks.IHDR[8], chunks.IHDR[9]], [8, 6], "8-bit RGBA");
  const raw = inflateSync(chunks.IDAT);
  assert.equal(raw.length, (width * 4 + 1) * height);
  const rgba = Buffer.alloc(width * height * 4);
  for (let y = 0; y < height; y++) {
    assert.equal(raw[y * (width * 4 + 1)], 0, "filter none");
    raw.copy(rgba, y * width * 4, y * (width * 4 + 1) + 1, (y + 1) * (width * 4 + 1));
  }
  assert.ok("IEND" in chunks);
  return { width, height, rgba };
}

test("png: straight RGBA from premultiplied, a PNG that decodes back with valid CRCs", () => {
  assert.deepEqual([...unpremultiply(Buffer.from([50, 25, 0, 128, 9, 9, 9, 0, 255, 255, 255, 255]))], [100, 50, 0, 128, 0, 0, 0, 0, 255, 255, 255, 255]);
  const px = solidCursor(3, 2, [100, 50, 0, 200]);
  const png = decodePNG(cursorPNG(3, 2, px));
  assert.deepEqual([png.width, png.height], [3, 2]);
  assert.deepEqual([...png.rgba.subarray(0, 4)], [128, 64, 0, 200]);
  assert.throws(() => encodePNG(2, 2, Buffer.alloc(3)), /bytes/);
});

test("png: the built-in arrow is shapeId 0, 26 px per 1600 px of width (52 px PNG), normalized to the display", () => {
  const a = builtinArrow(1600, 1000);
  assert.equal(a.id, 0);
  const img = decodePNG(Buffer.from(a.png, "base64"));
  // its visible rows ≈ 52 px; the shape's height in display units: rows × (26/1600)/52 × aspect
  let top = -1;
  let bottom = -1;
  for (let y = 0; y < img.height; y++) {
    for (let x = 0; x < img.width; x++) {
      if (img.rgba[(y * img.width + x) * 4 + 3]) {
        if (top < 0) top = y;
        bottom = y;
        break;
      }
    }
  }
  const visible = bottom - top + 1;
  assert.ok(Math.abs(visible - 52) <= 1, `visible rows ${visible}`);
  const k = 26 / 1600 / visible;
  assert.ok(Math.abs(a.width - img.width * k) < 1e-9);
  assert.ok(Math.abs(a.height - img.height * k * 1.6) < 1e-9);
  assert.ok(a.hotX > 0 && a.hotY > 0 && a.hotX < a.width);
  // the tip pixel is painted (black body)
  assert.ok(img.rgba[(Math.round(a.hotY / (k * 1.6)) * img.width + Math.round(a.hotX / k)) * 4 + 3] > 0);
});

test("cursor: shape ids are base + serial (base a multiple of 2^20, ≥ 1e6); the PNG made once; another image under a serial moves the base", () => {
  const lines = [];
  const shapes = new CursorShapes({ log: (l) => lines.push(l) });
  assert.equal(shapes.base % 2 ** 20, 0);
  assert.ok(shapes.base >= 2 ** 20 && shapes.base < 2 ** 40);
  const r = { serial: 5, xhot: 1, yhot: 2, w: 2, h: 2, pixels: solidCursor(2, 2, [0, 0, 0, 255]) };
  const id = shapes.add(r);
  assert.equal(id, shapes.base + 5);
  assert.ok(id >= 1e6);
  assert.equal(shapes.add({ ...r }), id, "same image: same id");
  assert.equal(shapes.idOf(5), id);
  const s = shapes.shape(id, 1280, 832);
  assert.deepEqual([s.id, s.hotX, s.hotY, s.width, s.height], [id, 1 / 1280, 2 / 832, 2 / 1280, 2 / 832]);
  assert.equal(decodePNG(Buffer.from(s.png, "base64")).width, 2);
  const old = shapes.base;
  const moved = shapes.add({ ...r, pixels: solidCursor(2, 2, [255, 255, 255, 255]) });
  assert.notEqual(shapes.base, old);
  assert.equal(moved, shapes.base + 5);
  assert.equal(shapes.shape(id, 1280, 832), null, "the old id is gone");
  assert.match(lines.join("\n"), /new shape ids/);
  // at most SHAPES_MAX kept
  for (let i = 0; i < SHAPES_MAX + 5; i++) shapes.add({ ...r, serial: 100 + i });
  assert.equal(shapes.bySerial.size, SHAPES_MAX);
  assert.equal(shapes.idOf(100), null);
  assert.equal(shapes.shape(0, 1280, 832).id, 0, "0 is the arrow");
});

test("cursor: a stream's feed — polled moves, a change only beyond 1.5 px of our input, shapes by serial, the arrow when none", () => {
  const shapes = new CursorShapes();
  let changes = 0;
  const f = new CursorFeed({ width: 1000, height: 500, shapes, onChange: () => changes++ });
  const px = solidCursor(4, 4, [0, 0, 0, 255]);
  f.fromHelper({ x: 100, y: 50, serial: 3, xhot: 0, yhot: 0, w: 4, h: 4, visible: true, none: false, pixels: px });
  assert.deepEqual(f.cursor, { x: 0.1, y: 0.1, visible: true, shapeId: shapes.base + 3 });
  assert.equal(f.current().shape.id, shapes.base + 3);
  // our input put it at 0.5, 0.5; the poll reads back 500.4 → 500 px: no news
  f.noteInput(0.5004, 0.5);
  const after = changes;
  f.fromHelper({ x: 500, y: 250, serial: 3, xhot: 0, yhot: 0, w: 4, h: 4, visible: true, none: false });
  assert.equal(f.cursor.x, 0.5004);
  assert.equal(changes, after, "no change");
  // someone at the desktop moved it
  f.fromHelper({ x: 700, y: 400, serial: 3, xhot: 0, yhot: 0, w: 4, h: 4, visible: true, none: false });
  assert.deepEqual([f.cursor.x, f.cursor.y], [0.7, 0.8]);
  // a shape change at the same place: the shape only; a hidden (all transparent) cursor: visible false
  f.fromHelper({ x: 700, y: 400, serial: 9, xhot: 0, yhot: 0, w: 4, h: 4, visible: false, none: false, pixels: solidCursor(4, 4, [0, 0, 0, 0]) });
  assert.deepEqual(f.cursor, { x: 0.7, y: 0.8, visible: false, shapeId: shapes.base + 9 });
  // no image: the built-in arrow
  f.fromHelper({ x: 700, y: 400, serial: 0, xhot: 0, yhot: 0, w: 0, h: 0, visible: true, none: true });
  assert.equal(f.cursor.shapeId, 0);
  assert.equal(f.current().shape.id, 0);
  const body = JSON.parse(cursorBody(f.cursor, null));
  assert.deepEqual(Object.keys(body).sort(), ["shapeId", "visible", "x", "y"]);
});

test("cursor: where an input leaves the pointer (DisplayPointerGeometry.position(after:))", () => {
  const at = (raw) => positionAfter(parseInput(raw));
  assert.deepEqual(at({ type: "click", x: 0.2, y: 0.3 }), { x: 0.2, y: 0.3 });
  assert.deepEqual(at({ type: "move", x: 0.2, y: 0.3, button: "left", seq: 4 }), { x: 0.2, y: 0.3 });
  for (const type of ["doubleClick", "rightClick", "down", "up"]) assert.deepEqual(at({ type, x: 1.5, y: -1 }), { x: 1, y: 0 });
  assert.deepEqual(at({ type: "drag", x: 0.5, y: 0.5, dx: 0.7, dy: -0.25 }), { x: 1, y: 0.25 });
  assert.deepEqual(at({ type: "scroll", x: 0.1, y: 0.9, dy: 40 }), { x: 0.1, y: 0.9 });
  assert.equal(at({ type: "scroll", dy: 40 }), null);
  assert.equal(at({ type: "type", text: "hi" }), null);
  assert.equal(at({ type: "key", key: "a" }), null);
});

test("wire: a 'P' record — position (signed), serial, hotspot, size, flags, the pixels with flag 2", () => {
  const r = new RecordReader();
  const px = solidCursor(2, 3, [1, 2, 3, 4]);
  const [a, b, c] = r.feed(Buffer.concat([pointerRecord({ x: -3, y: 900, serial: 70000, xhot: 1, yhot: 2, w: 2, h: 3, pixels: px }), pointerRecord({ x: 5, y: 6, visible: false }), pointerRecord({ none: true, w: 0, h: 0 })]));
  assert.deepEqual({ ...a, pixels: undefined }, { type: "P", x: -3, y: 900, serial: 70000, xhot: 1, yhot: 2, w: 2, h: 3, visible: true, none: false, pixels: undefined });
  assert.deepEqual(a.pixels, px);
  assert.deepEqual([b.x, b.y, b.visible, b.pixels], [5, 6, false, undefined]);
  assert.equal(c.none, true);
});
