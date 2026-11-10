import assert from "node:assert/strict";
import { test } from "node:test";
import { Drag, FingerSmoother, FingerSpeed, GestureHints, HoldToDrag, pageLayout, pointerGrow, Spring, TapSpotter, TapToDrag, Trackpad, TwoFingerScroll, Zoom, MIN_PAD_HEIGHT } from "../src/gestures.js";

// Ported from the iOS kit's ScreenGestureTests.
const a = { x: 0.3, y: 0.3 };
const close = (x: number, y: number, eps = 1e-9) => Math.abs(x - y) < eps;

function lockedDrag(at: { x: number; y: number }, now: number): Drag {
  const d = new Drag();
  d.began(a);
  d.moved(at);
  d.ended(at, now);
  return d;
}

test("three fingers drag from where the pointer is, and lock", () => {
  const d = new Drag();
  const b = { x: 0.31, y: 0.32 }, c = { x: 0.35, y: 0.35 };
  assert.deepEqual(d.began(a), [{ t: "down", at: a }]);
  assert.ok(d.isPressed && d.isDragging);
  assert.deepEqual(d.moved(b), [{ t: "move", at: b }]);
  assert.deepEqual(d.moved(c), [{ t: "move", at: c }]);
  assert.deepEqual(d.ended(c, 10), []);
  assert.deepEqual(d.phase, { t: "locked", at: c, until: 10 + Drag.LOCK_WINDOW });
  assert.deepEqual(d.ended(c, 10.1), []);
  assert.deepEqual(d.expire(10.5), []);
  assert.deepEqual(d.expire(10 + Drag.LOCK_WINDOW), [{ t: "up", at: c }]);
  assert.deepEqual(d.expire(20), [], "let go once");
  assert.deepEqual(d.moved(a), []);
});

test("a tap then a touch that moves drags", () => {
  const t = new TapToDrag();
  t.touched(1);
  assert.equal(t.take(), false);
  t.tapped(2);
  t.touched(2 + TapToDrag.WINDOW - 0.01);
  assert.ok(t.armed);
  assert.equal(t.take(), true);
  assert.equal(t.take(), false);
  t.tapped(5);
  t.touched(5 + TapToDrag.WINDOW + 0.01);
  assert.equal(t.armed, false);
  t.tapped(6, { x: 100, y: 100 });
  t.touched(6.1, { x: 100 + TapToDrag.REACH + 1, y: 100 });
  assert.equal(t.armed, false, "far from the tap");
  t.tapped(9);
  t.touched(9.1);
  t.disarm();
  assert.equal(t.take(), false);
  t.tapped(11);
  t.touched(10);
  assert.equal(t.armed, false, "a clock running backwards");
});

test("a touch held still arms a drag; moving first doesn't", () => {
  const h = new HoldToDrag();
  h.touched(1);
  assert.equal(h.check(1 + HoldToDrag.DELAY - 0.01), false);
  h.moved({ x: 1, y: 0 }, 1.1);
  h.moved({ x: 0, y: 1 }, 1.2);
  assert.equal(h.check(1 + HoldToDrag.DELAY), true);
  assert.equal(h.check(2), false);
  h.moved({ x: 80, y: 0 }, 2.1);
  assert.equal(h.take(), true);
  assert.equal(h.take(), false);
  h.touched(10);
  h.moved({ x: HoldToDrag.STILLNESS + 1, y: 0 }, 10.1);
  assert.equal(h.check(11), false);
  assert.equal(h.due, null);
  h.touched(40);
  h.moved({ x: NaN, y: 0 }, 40.1);
  assert.equal(h.check(41), false, "nonsense offsets don't arm it");
  assert.equal(TapSpotter.MAX_DURATION, HoldToDrag.DELAY);
});

test("a finger creeping slowly never arms a hold", () => {
  const h = new HoldToDrag();
  h.touched(0);
  let armed = false;
  for (let i = 1; i <= 60; i++) {
    const t = i * 0.01;
    h.moved({ x: t * 8, y: 0 }, t);
    armed = armed || h.check(t);
  }
  assert.equal(armed, false);
  const due = h.due!;
  assert.ok(due > 0.6 && due <= 0.6 + HoldToDrag.REST_TIME);
  assert.equal(h.check(due - 0.01), false);
  assert.equal(h.check(due), true);
});

test("three fingers back within the window carry on the same drag", () => {
  const b = { x: 0.5, y: 0.4 }, c = { x: 0.7, y: 0.45 };
  const d = lockedDrag(b, 10);
  assert.deepEqual(d.touched(10.5), []);
  assert.equal(d.lockedUntil, null);
  assert.deepEqual(d.expire(15), [], "resting fingers hold it open");
  assert.deepEqual(d.began(a), []);
  assert.deepEqual(d.phase, { t: "dragging", at: b });
  assert.deepEqual(d.moved(c), [{ t: "move", at: c }]);
  d.ended(c, 16);
  assert.equal(d.lockedUntil, 16 + Drag.LOCK_WINDOW);
});

test("anything else on a locked drag lets go; a late touch lets go first; an interrupted drag lifts", () => {
  const b = { x: 0.5, y: 0.4 };
  let d = lockedDrag(b, 10);
  d.touched(10.2);
  assert.deepEqual(d.released(), [{ t: "up", at: b }]);
  assert.deepEqual(d.released(), []);
  d = lockedDrag(b, 10);
  assert.deepEqual(d.touched(11), [{ t: "up", at: b }]);
  assert.deepEqual(d.began(a), [{ t: "down", at: a }]);
  d = new Drag();
  assert.deepEqual(d.cancelled(), []);
  d.began(a);
  d.moved(b);
  assert.deepEqual(d.began(a), [{ t: "up", at: b }, { t: "down", at: a }]);
});

test("the trackpad's curve: precise slow, one at a normal speed, far fast, never falling", () => {
  assert.equal(Trackpad.curve(0), Trackpad.PRECISE_GAIN);
  assert.ok(close(Trackpad.curve(Trackpad.NORMAL_SPEED), 1));
  assert.ok(close(Trackpad.curve(Trackpad.FAST_SPEED), Trackpad.FAST_GAIN));
  assert.equal(Trackpad.curve(NaN), Trackpad.PRECISE_GAIN);
  assert.equal(Trackpad.curve(Infinity), Trackpad.PRECISE_GAIN);
  let last = Trackpad.curve(25);
  for (let s = 26; s < 1400; s++) {
    const g = Trackpad.curve(s);
    assert.ok(g > last && g - last < 0.01);
    last = g;
  }
  const display = { width: 1500, height: 1000 };
  const p = Trackpad.moved({ x: 0.5, y: 0.5 }, { x: 100, y: -40 }, display, 1.5);
  assert.ok(close(p.x, 0.6) && close(p.y, 0.44));
  assert.deepEqual(Trackpad.moved({ x: 0.95, y: 0.02 }, { x: 500, y: -500 }, display, 1.5), { x: 1, y: 0 });
  // a swipe across the trackpad crosses the display
  const d2 = { width: 1728, height: 1117 };
  assert.ok(900 * Trackpad.gain(300, d2, { width: 870, height: 562 }) >= d2.width);
  assert.equal(Trackpad.gain(300, d2, { width: 870, height: 562 }, -1), Trackpad.gain(300, d2, { width: 870, height: 562 }));
});

test("the finger's speed is its path over the last moment; the smoother takes out a slow finger's tremor", () => {
  const f = new FingerSpeed();
  f.reset({ x: 100, y: 100 }, 1);
  for (let i = 1; i <= 12; i++) f.add({ x: 100 + 2.5 * i, y: 100 }, 1 + i / 120);
  assert.ok(Math.abs(f.speed - 300) < 1);
  assert.ok(f.samples.length <= 7);
  const g = new FingerSpeed();
  g.reset({ x: 0, y: 0 }, 0);
  g.add({ x: 2, y: 0 }, 0.002);
  assert.ok(g.speed <= 2 / FingerSpeed.MIN_SPAN + 1e-6);
  const s = new FingerSmoother();
  s.reset({ x: 100, y: 100 }, 0);
  let worst = 0;
  for (let i = 1; i <= 240; i++) {
    const t = i / 120;
    const p = s.add({ x: 100 + 10 * t, y: 100 + (i % 2 === 0 ? 1 : -1) }, t, 10);
    if (i > 60) worst = Math.max(worst, Math.abs(p.y - 100));
  }
  assert.ok(worst < 0.2, `wobble ${worst}`);
  const lag = 120 - s.location!.x;
  assert.ok(lag > 0 && lag < 1);
});

test("a two-finger pan locks its axis, begins, changes and ends with the velocity at lift (capped)", () => {
  const sc = new TwoFingerScroll();
  const size = { width: 400, height: 250 };
  assert.equal(sc.began({ x: 0, y: -4 }, size, true), null, "not decided yet");
  const b = sc.changed({ x: 1, y: -20 }, size, true)!;
  assert.equal(b.phase, "began");
  assert.equal(sc.axis, "vertical");
  assert.ok(close(b.delta.x, 0) && close(b.delta.y, 20 / 250));
  assert.equal(sc.changed({ x: 2, y: -40 }, size, true)!.phase, "changed");
  const e = sc.ended({ x: 50, y: -500 }, size)!;
  assert.equal(e.phase, "ended");
  assert.ok(close(e.velocity.x, 0) && close(e.velocity.y, 2));
  assert.equal(sc.ended(null, size), null, "only a gesture that began ends");
  const c = TwoFingerScroll.capped({ x: 0, y: 12000 });
  assert.equal(c.y, TwoFingerScroll.MAX_LIFT_SPEED);
});

test("a tap is spotted the moment the fingers lift", () => {
  const s = new TapSpotter();
  s.down(1, 0);
  s.down(2, 0.05);
  assert.equal(s.allUp(0.2), 2);
  s.down(1, 1);
  s.moved(TapSpotter.SLOP + 1);
  assert.equal(s.allUp(1.1), null);
  s.down(1, 2);
  assert.equal(s.allUp(2 + TapSpotter.MAX_DURATION + 0.01), null);
});

test("the zoom fits, covers its frame zoomed in, keeps the spot under a pinch and follows the pointer", () => {
  const size = { width: 400, height: 250 };
  assert.deepEqual(new Zoom().frame(size), { x: 0, y: 0, width: 400, height: 250 });
  const z = new Zoom(2, { x: 0.1, y: 0.9 });
  z.clampCenter();
  const f = z.frame(size);
  assert.ok(f.x <= 0 && f.y <= 0 && f.x + f.width >= 400 && f.y + f.height >= 250);
  const p = new Zoom(2, { x: 0.5, y: 0.5 });
  const anchor = p.point({ x: 100, y: 100 }, size);
  p.place(anchor, { x: 120, y: 90 }, size);
  const back = p.point({ x: 120, y: 90 }, size);
  assert.ok(close(back.x, anchor.x, 1e-6) && close(back.y, anchor.y, 1e-6));
  assert.ok(Zoom.clampedScale(0.5, true) > 0.5 && Zoom.clampedScale(0.5, false) === 1);
  const fz = new Zoom(2.5, { x: 0.5, y: 0.5 });
  fz.follow({ x: 0.52, y: 0.5 });
  assert.deepEqual(fz.center, { x: 0.5, y: 0.5 }, "away from the edges: nothing moves");
  fz.follow({ x: 0.95, y: 0.5 });
  assert.ok(fz.center.x > 0.5);
});

test("the picture sits on top of a trackpad; without one it is fitted", () => {
  const area = { x: 0, y: 0, width: 390, height: 700 };
  const { picture, pad } = pageLayout(area, 1.54, 40);
  assert.equal(picture.width, 390);
  assert.ok(pad && pad.height >= MIN_PAD_HEIGHT);
  const full = pageLayout({ x: 0, y: 0, width: 844, height: 390 }, 1.54, 0, false);
  assert.equal(full.pad, null);
  assert.equal(full.picture.height, 390);
});

test("springs settle and keep their speed when retargeted; the card shows once; pointers grow", () => {
  const s = new Spring(0);
  s.target = 1;
  s.step(0.05, { response: 0.3, dampingRatio: 0.5 });
  const v = s.velocity;
  s.target = 2;
  assert.equal(s.velocity, v);
  for (let i = 0; i < 300; i++) s.step(1 / 60, { response: 0.3, dampingRatio: 0.5 });
  assert.ok(s.settled());
  const h = new GestureHints(false);
  assert.equal(h.take(), true);
  assert.equal(h.take(), false);
  assert.ok(close(pointerGrow(0.02, 284, 1117), 20 / ((40 / 1117) * 284)));
  assert.equal(pointerGrow(0.5, 1000, 1000), 1);
});
