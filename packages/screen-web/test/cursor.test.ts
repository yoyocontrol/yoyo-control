import { test } from "node:test";
import assert from "node:assert/strict";
import { CursorModel, parseCursorPart } from "../src/cursor.js";

const shape = (id: number) => ({ id, png: "iVBORw0KGgo=", hotX: 0.001, hotY: 0.002, width: 0.01, height: 0.02 });

test("cursor parts: lenient; big shape ids kept as they are (no coordinate range)", () => {
  const big = 3 * 2 ** 20 + 17;
  const p = parseCursorPart(JSON.stringify({ x: 0.5, y: 0.25, visible: true, shapeId: big, shape: shape(big) }));
  assert.equal(p?.shapeId, big);
  assert.equal(p?.shape?.id, big);
  assert.equal(parseCursorPart('{"x":"a"}'), null);
  assert.equal(parseCursorPart("nope"), null);
  // a bad shape is dropped, the position stays
  assert.deepEqual(parseCursorPart('{"x":0.1,"y":0.2,"visible":false,"shapeId":0,"shape":{"id":0}}'), { x: 0.1, y: 0.2, visible: false, shapeId: 0 });
});

test("the shape is drawn with its hot spot at the position; known ids are reused without a shape", () => {
  const m = new CursorModel();
  m.streamOpened();
  m.cursor({ x: 0.5, y: 0.5, visible: true, shapeId: 1_000_001, shape: shape(1_000_001) });
  assert.equal(m.picture(), false, "a cursor part came first: the page draws it");
  const v = m.view()!;
  assert.ok(Math.abs(v.left - 0.499) < 1e-9 && Math.abs(v.top - 0.498) < 1e-9);
  assert.match(v.url!, /^data:image\/png;base64,/);
  m.cursor({ x: 0.6, y: 0.6, visible: true, shapeId: 1_000_001 });
  assert.equal(m.view()!.url, v.url);
  // an id never seen: the page's own arrow
  m.cursor({ x: 0.6, y: 0.6, visible: true, shapeId: 42 });
  assert.equal(m.view()!.url, null);
  m.cursor({ x: 0.6, y: 0.6, visible: false, shapeId: 1_000_001 });
  assert.equal(m.view(), null);
});

test("a stream whose first picture comes without a cursor part draws the pointer itself: nothing here", () => {
  const m = new CursorModel();
  m.streamOpened();
  m.cursor({ x: 0.5, y: 0.5, visible: true, shapeId: 0, shape: shape(0) });
  m.picture();
  m.streamOpened();
  assert.equal(m.picture(), true);
  assert.equal(m.view(), null);
});

test("the page's own move shows at once; the server's next word takes over", () => {
  const m = new CursorModel();
  m.streamOpened();
  m.cursor({ x: 0.5, y: 0.5, visible: true, shapeId: 0, shape: shape(0) });
  m.moved(0.2, 0.3);
  assert.ok(Math.abs(m.view()!.left - 0.199) < 1e-9);
  m.cursor({ x: 0.21, y: 0.3, visible: true, shapeId: 0 });
  assert.ok(Math.abs(m.view()!.left - 0.209) < 1e-9);
});
