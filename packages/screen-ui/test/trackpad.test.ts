import assert from "node:assert/strict";
import { test, mock } from "node:test";
import { TrackpadGestures, type TrackpadHost } from "../src/trackpad.js";

globalThis.requestAnimationFrame ??= ((fn: FrameRequestCallback) => setTimeout(() => fn(performance.now()), 16) as unknown as number) as typeof requestAnimationFrame;
globalThis.cancelAnimationFrame ??= ((h: number) => clearTimeout(h)) as typeof cancelAnimationFrame;

function host() {
  const sent: string[] = [];
  let pointer = { x: 0.5, y: 0.5 };
  const h: TrackpadHost = {
    controlling: true,
    padRect: () => ({ x: 0, y: 300, width: 390, height: 400 }),
    shownPicture: () => ({ width: 390, height: 250 }),
    display: () => ({ width: 1512, height: 982 }),
    drawnPointer: () => pointer,
    moveCursor: (p) => (pointer = p),
    click: (k) => sent.push(k),
    scroll: (s) => sent.push(`scroll ${s.phase}`),
    drag: (s) => sent.push(s.t),
    pointerMoved: () => sent.push("move"),
    touches: () => {},
    quietTap: () => sent.push("quiet"),
    tapFeedback: () => {},
    threeFingerTap: () => sent.push("stats"),
    leftPad: (out) => sent.push(out ? "off" : "on"),
    holdArmed: (on) => on && sent.push("armed"),
    pressed: () => {},
    scrolling: () => {},
    loupeChanged: () => {},
    gestureBegan: () => {},
    vibrate: () => {},
  };
  return { h, sent };
}

test("a tap clicks once its double-tap wait runs out; two taps double-click; two fingers right-click; three toggle the stats", () => {
  mock.timers.enable({ apis: ["setTimeout"] });
  try {
    const { h, sent } = host();
    const t = new TrackpadGestures(h, () => 0);
    t.down(1, { x: 100, y: 400 }, 1);
    t.up(1, { x: 100, y: 400 }, false, 1.1);
    assert.deepEqual(sent, []);
    mock.timers.tick(400);
    assert.deepEqual(sent, ["click"]);
    t.down(1, { x: 100, y: 400 }, 3);
    t.up(1, { x: 100, y: 400 }, false, 3.08);
    t.down(1, { x: 102, y: 401 }, 3.2);
    t.up(1, { x: 102, y: 401 }, false, 3.28);
    assert.deepEqual(sent.slice(1), ["doubleClick"]);
    t.down(1, { x: 100, y: 400 }, 5);
    t.down(2, { x: 160, y: 400 }, 5.02);
    t.up(1, { x: 100, y: 400 }, false, 5.1);
    t.up(2, { x: 160, y: 400 }, false, 5.12);
    assert.deepEqual(sent.slice(2), ["rightClick"]);
    for (const id of [1, 2, 3]) t.down(id, { x: 100 + id * 40, y: 400 }, 7);
    for (const id of [1, 2, 3]) t.up(id, { x: 100 + id * 40, y: 400 }, false, 7.1);
    assert.deepEqual(sent.slice(3), ["stats"]);
  } finally {
    mock.timers.reset();
  }
});

test("one finger moves the pointer; two scroll with their phases; a touch off the surface isn't the trackpad's", () => {
  mock.timers.enable({ apis: ["setTimeout"] });
  try {
    const { h, sent } = host();
    const t = new TrackpadGestures(h, () => 0);
    assert.equal(t.down(9, { x: 100, y: 100 }, 0), false, "off the surface");
    t.down(1, { x: 100, y: 400 }, 1);
    for (let i = 1; i <= 10; i++) t.move(1, { x: 100 + i * 5, y: 400 }, [], 1 + i * 0.016);
    t.up(1, { x: 150, y: 400 }, false, 1.2);
    assert.ok(sent.includes("move"));
    assert.ok(!sent.includes("down"), "a plain move doesn't drag");
    sent.length = 0;
    t.down(1, { x: 100, y: 400 }, 3);
    t.down(2, { x: 160, y: 400 }, 3.01);
    for (let i = 1; i <= 6; i++) {
      t.move(1, { x: 100, y: 400 - i * 6 }, [], 3 + i * 0.016);
      t.move(2, { x: 160, y: 400 - i * 6 }, [], 3 + i * 0.016);
    }
    t.up(1, { x: 100, y: 364 }, false, 3.2);
    t.up(2, { x: 160, y: 364 }, false, 3.21);
    assert.equal(sent[0], "scroll began");
    assert.ok(sent.includes("scroll changed"));
    assert.equal(sent.at(-1), "scroll ended");
  } finally {
    mock.timers.reset();
  }
});

test("a touch held still, then moved, drags; lifting locks it; the lock lets go when it runs out", () => {
  mock.timers.enable({ apis: ["setTimeout"] });
  let now = 0;
  try {
    const { h, sent } = host();
    const t = new TrackpadGestures(h, () => now);
    t.down(1, { x: 100, y: 400 }, 0);
    now = 0.6;
    mock.timers.tick(600);
    assert.ok(sent.includes("armed"));
    for (let i = 1; i <= 8; i++) {
      now = 0.6 + i * 0.016;
      t.move(1, { x: 100 + i * 4, y: 400 }, [], now);
    }
    assert.equal(sent.filter((s) => s === "down").length, 1);
    assert.ok(sent.includes("move"));
    now = 0.8;
    t.up(1, { x: 132, y: 400 }, false, now);
    assert.ok(t.drag.isLocked);
    assert.ok(!sent.includes("up"));
    now = 1.7;
    mock.timers.tick(1000);
    assert.equal(sent.at(-1), "up");
  } finally {
    mock.timers.reset();
  }
});
