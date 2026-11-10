import { test } from "node:test";
import assert from "node:assert/strict";
import type { Input } from "../src/types.js";
import { DOUBLE_TAP_MS, InputQueue, LONG_PRESS_MS, MAX_MOVES_IN_FLIGHT, PASTE_KEY, TouchGestures, deviceName, keyInput, modifiersOf, normalizedPoint, textInput, wheelDelta, type KeyLike } from "../src/input.js";

const key = (k: Partial<KeyLike>): KeyLike => ({ key: "", code: "", metaKey: false, ctrlKey: false, altKey: false, shiftKey: false, ...k });

test("keys: named keys, shortcuts by code (⌘ and Ctrl both = cmd), characters left to the text field", () => {
  assert.deepEqual(keyInput(key({ key: "Enter", code: "Enter" })), { type: "key", key: "return" });
  assert.deepEqual(keyInput(key({ key: "Backspace", code: "Backspace" })), { type: "key", key: "delete" });
  assert.deepEqual(keyInput(key({ key: "Delete", code: "Delete" })), { type: "key", key: "forwardDelete" });
  assert.deepEqual(keyInput(key({ key: "ArrowLeft", code: "ArrowLeft", shiftKey: true })), { type: "key", key: "left", modifiers: ["shift"] });
  assert.deepEqual(keyInput(key({ key: "F5", code: "F5" })), { type: "key", key: "f5" });
  assert.deepEqual(keyInput(key({ key: "PageDown", code: "PageDown" })), { type: "key", key: "pageDown" });
  assert.deepEqual(keyInput(key({ key: "c", code: "KeyC", metaKey: true })), { type: "key", key: "c", modifiers: ["cmd"] });
  assert.deepEqual(keyInput(key({ key: "c", code: "KeyC", ctrlKey: true })), { type: "key", key: "c", modifiers: ["cmd"] });
  // a non-Latin layout: the code decides
  assert.deepEqual(keyInput(key({ key: "с", code: "KeyC", metaKey: true, shiftKey: true })), { type: "key", key: "c", modifiers: ["cmd", "shift"] });
  assert.deepEqual(keyInput(key({ key: "[", code: "BracketLeft", metaKey: true })), { type: "key", key: "[", modifiers: ["cmd"] });
  assert.deepEqual(keyInput(key({ key: "Tab", code: "Tab", altKey: true })), { type: "key", key: "tab", modifiers: ["alt"] });
  // characters (with Shift / Option too) go through the text field
  assert.equal(keyInput(key({ key: "a", code: "KeyA" })), null);
  assert.equal(keyInput(key({ key: "A", code: "KeyA", shiftKey: true })), null);
  assert.equal(keyInput(key({ key: "™", code: "Digit2", altKey: true })), null);
  // a composition, the IME's 229, lone modifiers
  assert.equal(keyInput(key({ key: "Enter", code: "Enter", isComposing: true })), null);
  assert.equal(keyInput(key({ key: "Process", code: "KeyA", keyCode: 229 })), null);
  assert.equal(keyInput(key({ key: "Meta", code: "MetaLeft", metaKey: true })), null);
  // Insert only where it has a name (Linux)
  assert.equal(keyInput(key({ key: "Insert", code: "Insert", shiftKey: true })), null);
  assert.deepEqual(keyInput(key({ key: "Insert", code: "Insert", shiftKey: true }), true), { type: "key", key: "insert", modifiers: ["shift"] });
  assert.deepEqual(modifiersOf({ metaKey: true, ctrlKey: true, altKey: true, shiftKey: true }), ["cmd", "shift", "alt"]);
});

test("the paste key: ⌘V on the Mac, Shift+Insert on Linux", () => {
  assert.deepEqual(PASTE_KEY.mac, { type: "key", key: "v", modifiers: ["cmd"] });
  assert.deepEqual(PASTE_KEY.linux, { type: "key", key: "insert", modifiers: ["shift"] });
});

test("text field input: typed text, line breaks, deletes; nothing while composing", () => {
  assert.deepEqual(textInput("insertText", "你好", false), { type: "type", text: "你好" });
  assert.deepEqual(textInput("insertFromPaste", "x", false), { type: "type", text: "x" });
  assert.equal(textInput("insertText", "ni", true), null);
  assert.equal(textInput("insertCompositionText", "ni", false), null);
  assert.deepEqual(textInput("insertLineBreak", null, false), { type: "key", key: "return" });
  assert.deepEqual(textInput("deleteContentBackward", null, false), { type: "key", key: "delete" });
  assert.equal(textInput("historyUndo", null, false), null);
});

test("geometry: client point → 0…1 clamped; wheel deltas in display points", () => {
  const box = { left: 100, top: 50, width: 400, height: 250 };
  assert.deepEqual(normalizedPoint(300, 175, box), { x: 0.5, y: 0.5 });
  assert.deepEqual(normalizedPoint(0, 1000, box), { x: 0, y: 1 });
  assert.deepEqual(wheelDelta(0, 10, 0, 2.5, 800), { dx: 0, dy: 25 });
  assert.deepEqual(wheelDelta(0, 3, 1, 2.5, 800), { dx: 0, dy: 120 });
  assert.deepEqual(wheelDelta(0, -1, 2, 2.5, 800), { dx: 0, dy: -800 });
});

test("this browser: a readable name", () => {
  assert.equal(deviceName("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"), "Chrome on Mac");
  assert.equal(deviceName("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"), "Safari on iPhone");
  assert.equal(deviceName("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36 Edg/130.0"), "Edge on Windows");
});

// ---- the queue

function queueHarness(firstSeq = 1000) {
  const sent: { input: Input; done: (err?: unknown) => void }[] = [];
  const errors: unknown[] = [];
  let now = 0;
  const q = new InputQueue(
    (input) => new Promise<void>((resolve, reject) => sent.push({ input, done: (err) => (err ? reject(err) : resolve()) })),
    (e) => errors.push(e),
    firstSeq,
    () => now,
  );
  const flush = () => new Promise((r) => setImmediate(r));
  return { q, sent, errors, flush, tick: (ms: number) => (now += ms) };
}

test("queue: discrete input in order, one at a time", async () => {
  const { q, sent, flush } = queueHarness();
  q.input({ type: "click", x: 0.1, y: 0.1 });
  q.input({ type: "key", key: "a" });
  assert.equal(sent.length, 1);
  sent[0]!.done();
  await flush();
  assert.deepEqual(sent.map((s) => s.input.type), ["click", "key"]);
});

test("queue: up to 3 moves in flight with rising seq; meanwhile only the latest position waits", async () => {
  const { q, sent, flush } = queueHarness(500);
  for (let i = 1; i <= 6; i++) q.move(i / 10, i / 10);
  assert.deepEqual(sent.map((s) => [s.input.x, s.input.seq]), [[0.1, 500], [0.2, 501], [0.3, 502]]);
  assert.equal(MAX_MOVES_IN_FLIGHT, 3);
  sent[0]!.done();
  await flush();
  assert.deepEqual(sent.slice(3).map((s) => [s.input.x, s.input.seq]), [[0.6, 503]]);
});

test("queue: a click after moves waits for them all to return", async () => {
  const { q, sent, flush } = queueHarness();
  q.move(0.2, 0.2);
  q.move(0.3, 0.3);
  q.input({ type: "click", x: 0.3, y: 0.3 });
  assert.deepEqual(sent.map((s) => s.input.type), ["move", "move"]);
  sent[0]!.done();
  await flush();
  assert.equal(sent.length, 2);
  sent[1]!.done();
  await flush();
  assert.deepEqual(sent.map((s) => s.input.type), ["move", "move", "click"]);
});

test("queue: wheel scrolls add up while one is on its way", async () => {
  const { q, sent, flush } = queueHarness();
  q.scroll(0, 10, 0.5, 0.5);
  q.scroll(0, 5, 0.5, 0.5);
  q.scroll(2, 7, 0.6, 0.5);
  assert.deepEqual(sent.map((s) => [s.input.dx, s.input.dy]), [[0, 10]]);
  sent[0]!.done();
  await flush();
  assert.deepEqual(sent.map((s) => [s.input.dx, s.input.dy, s.input.x]), [[0, 10, 0.5], [2, 12, 0.6]]);
  assert.equal(sent[1]!.input.phase, undefined);
});

test("queue: scroll phases keep their order; ended carries what waited and the velocity", async () => {
  const { q, sent, flush } = queueHarness();
  q.scroll(0, 4, 0.5, 0.5, undefined, "began");
  q.scroll(0, 3, 0.5, 0.5, undefined, "changed");
  q.scroll(0, 2, 0.5, 0.5, undefined, "changed");
  q.scroll(0, 1, 0.5, 0.5, undefined, "ended", 0, 900);
  assert.deepEqual(sent.map((s) => [s.input.phase, s.input.dy]), [["began", 4]]);
  sent[0]!.done();
  await flush();
  assert.deepEqual(sent.slice(1).map((s) => [s.input.phase, s.input.dy, s.input.vy]), [["ended", 6, 900]]);
});

test("queue: an end right after a began that hasn't gone goes on its own after it", async () => {
  const { q, sent, flush } = queueHarness();
  q.input({ type: "click", x: 0, y: 0 });
  q.scroll(0, 4, 0.5, 0.5, undefined, "began");
  q.scroll(0, 0, 0.5, 0.5, undefined, "ended", 0, 50);
  sent[0]!.done();
  await flush();
  sent[1]!.done();
  await flush();
  assert.deepEqual(sent.map((s) => [s.input.type, s.input.phase ?? null, s.input.dy ?? null]), [["click", null, null], ["scroll", "began", 4], ["scroll", "ended", 0]]);
});

test("queue: tiny scrolls wait for more; a failure is reported once per burst of moves; cancel drops what waits", async () => {
  const { q, sent, errors, flush, tick } = queueHarness();
  q.scroll(0, 0.2, 0.5, 0.5);
  assert.equal(sent.length, 0);
  q.scroll(0, 0.4, 0.5, 0.5);
  assert.equal(sent.length, 1);
  sent[0]!.done();
  await flush();
  q.move(0.1, 0.1);
  q.move(0.2, 0.2);
  sent[1]!.done(new Error("offline"));
  sent[2]!.done(new Error("offline"));
  await flush();
  assert.equal(errors.length, 1);
  tick(2000);
  q.input({ type: "click", x: 0, y: 0 });
  q.cancel();
  q.input({ type: "key", key: "a" });
  assert.equal(sent.at(-1)!.input.type, "key");
});

// ---- touch

function touch() {
  const g = new TouchGestures((x, y) => ({ x: x / 100, y: y / 100 }), () => 2);
  return g;
}

test("touch: a tap clicks once the double-tap wait runs out; two taps double-click", () => {
  const g = touch();
  assert.deepEqual(g.down(10, 10, 0), []);
  assert.deepEqual(g.up(10, 10, 80), []);
  assert.equal(g.deadline, 80 + DOUBLE_TAP_MS);
  assert.deepEqual(g.tick(80 + DOUBLE_TAP_MS), [{ t: "click", x: 0.1, y: 0.1 }]);
  g.down(20, 20, 1000);
  g.up(20, 20, 1050);
  g.down(22, 21, 1150);
  assert.deepEqual(g.up(22, 21, 1200), [{ t: "doubleClick", x: 0.2, y: 0.2 }]);
  assert.equal(g.deadline, null);
});

test("touch: a long press right-clicks (and the lift does nothing)", () => {
  const g = touch();
  g.down(50, 40, 0);
  assert.equal(g.deadline, LONG_PRESS_MS);
  assert.deepEqual(g.tick(LONG_PRESS_MS), [{ t: "rightClick", x: 0.5, y: 0.4 }]);
  assert.deepEqual(g.up(50, 40, 900), []);
});

test("touch: one finger scrolls the content with it — began / changed / ended with the velocity at lift", () => {
  const g = touch();
  g.down(50, 80, 0);
  assert.deepEqual(g.move(50, 78, 10), [], "within the slop");
  const began = g.move(50, 70, 20);
  assert.equal(began.length, 1);
  assert.deepEqual(began[0], { t: "scroll", phase: "began", dx: 0, dy: 20, x: 0.5, y: 0.7, vx: 0, vy: 0 });
  assert.deepEqual(g.move(50, 60, 40), [{ t: "scroll", phase: "changed", dx: 0, dy: 20, x: 0.5, y: 0.6, vx: 0, vy: 0 }]);
  const end = g.up(50, 60, 50)[0]!;
  assert.equal(end.t, "scroll");
  if (end.t === "scroll") {
    assert.equal(end.phase, "ended");
    assert.equal(end.dy, 0);
    assert.ok(end.vy > 0, "finger up = content further down");
  }
});

test("touch: a pending tap becomes a click when the next touch scrolls", () => {
  const g = touch();
  g.down(10, 10, 0);
  g.up(10, 10, 50);
  g.down(10, 50, 100);
  const out = g.move(10, 30, 120);
  assert.deepEqual(out.map((a) => a.t), ["click", "scroll"]);
});
