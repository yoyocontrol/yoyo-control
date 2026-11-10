import assert from "node:assert/strict";
import { test } from "node:test";
import { Drop, DropMotion, shapeRho, shapeSource } from "../src/drop.js";
import { Loupe } from "../src/gestures.js";

test("the loupe magnifies towards the computer's own size", () => {
  assert.equal(Loupe.magnification(0.05), Loupe.MAX_MAGNIFICATION);
  assert.equal(Loupe.magnification(1), Loupe.MIN_MAGNIFICATION);
  assert.ok(Math.abs(Loupe.magnification(0.2) - 2.25) < 1e-9);
  assert.equal(Loupe.diameter({ width: 1000, height: 1000 }), 150);
});

test("the drop magnifies its middle evenly and its bevel refracts what is around it", () => {
  const m = new DropMotion();
  m.aim({ x: 200, y: 150 }, true);
  m.setVisible(true, false);
  const s = m.shape(70, 2);
  // the middle: magnified evenly around the pointer
  const src = shapeSource(s, { x: 220, y: 150 });
  assert.ok(Math.abs(src.x - 210) < 1e-6);
  // the rim: pushed out past the drop's edge
  const rim = shapeSource(s, { x: 200 + 69.5, y: 150 });
  assert.ok(rim.x > 200 + 70, `${rim.x}`);
  assert.ok(shapeRho(s, { x: 300, y: 150 }) > 1);
  assert.equal(Drop.profile(0), 0);
  assert.ok(Math.abs(Drop.profile(1) - 1) < 1e-9);
});

test("at the picture's edge the drop merges with the edge", () => {
  const m = new DropMotion();
  m.aim({ x: 10, y: 100 }, true);
  m.setVisible(true, false);
  const s = m.shape(60, 2, { x: 0, y: 0, width: 400, height: 300 });
  // between the drop and the edge it reaches out (inside the merged outline)
  assert.ok(shapeRho(s, { x: 1, y: 100 + 55 }) < 1);
});

test("the drop stretches along a fast move, swells in and shrinks away", () => {
  const d = Drop.deformation({ x: 2400, y: 0 });
  assert.ok(d.xx > 0 && Math.abs(d.xy) < 1e-9 && d.tail.x < 0);
  const m = new DropMotion();
  m.aim({ x: 0, y: 0 });
  m.setVisible(true);
  for (let i = 0; i < 120; i++) m.step(1 / 120, false);
  assert.ok(m.presence.value > 0.9);
  m.setVisible(false);
  for (let i = 0; i < 240; i++) m.step(1 / 120, false);
  assert.ok(m.settled && m.presence.value < 0.01);
  // Reduce Motion: no deformation at all
  const r = new DropMotion();
  r.aim({ x: 0, y: 0 });
  r.setVisible(true, true, true);
  r.aim({ x: 500, y: 0 });
  r.step(1 / 60, true);
  assert.equal(r.xx.value, 0);
});
