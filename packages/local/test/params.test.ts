import assert from "node:assert/strict";
import { test } from "node:test";
import {
  LocalError,
  parseAppAx,
  parseAppWindows,
  parseFeatures,
  parseFocus,
  parseFrameParams,
  parseHit,
  parseInput,
  parseStreamAck,
  parseStreamParams,
  parseWindows,
  regionHeader,
  remoteFailure,
} from "../src/index.js";

const bad = (fn: () => unknown, status = 400) =>
  assert.throws(fn, (e: unknown) => e instanceof LocalError && e.status === status && e.body.error === e.message);

test("parseInput: types, clamped coordinates, pointer types need x and y", () => {
  assert.deepEqual(parseInput({ type: "click", x: 1.5, y: -0.2 }), { type: "click", x: 1, y: 0 });
  bad(() => parseInput({ type: "tap", x: 0, y: 0 }));
  bad(() => parseInput({ type: "click", x: 0.5 }));
  bad(() => parseInput([]));
  bad(() => parseInput({ type: "click", x: "a", y: 0 }));
  bad(() => parseInput({ type: "click", x: 0, y: 0, display: -1 }));
  assert.deepEqual(parseInput({ type: "click", x: 0, y: 0, display: 2 }), { type: "click", x: 0, y: 0, display: 2 });
});

test("parseInput: a live drag's button and seq only on move; modifiers held with the button count on down only", () => {
  assert.deepEqual(parseInput({ type: "move", x: 0.1, y: 0.2, button: "left", seq: 7, modifiers: ["cmd"] }), { type: "move", x: 0.1, y: 0.2, button: "left", seq: 7 });
  assert.deepEqual(parseInput({ type: "down", x: 0.1, y: 0.2, button: "left", seq: 7, modifiers: ["cmd", "cmd", "shift"] }), { type: "down", x: 0.1, y: 0.2, modifiers: ["cmd", "shift"] });
  assert.deepEqual(parseInput({ type: "up", x: 0.1, y: 0.2, modifiers: ["cmd"] }), { type: "up", x: 0.1, y: 0.2 });
  bad(() => parseInput({ type: "move", x: 0, y: 0, button: "right" }));
  bad(() => parseInput({ type: "move", x: 0, y: 0, seq: -1 }));
  bad(() => parseInput({ type: "key", key: "a", modifiers: ["hyper"] }));
});

test("parseInput: scroll needs a delta; phase and velocity only on scroll; type and key", () => {
  assert.deepEqual(parseInput({ type: "scroll", x: 0.5, y: 0.5, dy: 3, phase: "ended", vx: 1, vy: 2 }), { type: "scroll", x: 0.5, y: 0.5, dy: 3, phase: "ended", vx: 1, vy: 2 });
  assert.deepEqual(parseInput({ type: "click", x: 0.5, y: 0.5, phase: "began", vx: 1 }), { type: "click", x: 0.5, y: 0.5 });
  bad(() => parseInput({ type: "scroll", x: 0.5, y: 0.5 }));
  bad(() => parseInput({ type: "scroll", dy: 1, phase: "wobble" }));
  bad(() => parseInput({ type: "drag", x: 0, y: 0 }));
  assert.deepEqual(parseInput({ type: "type", text: "hi" }), { type: "type", text: "hi" });
  bad(() => parseInput({ type: "type", text: "" }));
  bad(() => parseInput({ type: "type", text: "x".repeat(4001) }));
  assert.deepEqual(parseInput({ type: "key", key: " return " }), { type: "key", key: "return" });
  bad(() => parseInput({ type: "key", key: "x".repeat(33) }));
});

test("parseFrameParams / parseStreamParams clamp, filter codecs, check ids and flags", () => {
  const q = (o: Record<string, unknown>) => (n: string) => o[n];
  assert.deepEqual(parseFrameParams(q({ display: "2.7", maxWidth: 99_999, quality: 1, fps: 500 })), { display: 2, maxWidth: 3840, quality: 10, fps: 60 });
  bad(() => parseFrameParams(q({ maxWidth: "wide" })));
  assert.deepEqual(parseStreamParams(q({ codecs: "AV1, h264,hevc,h264", stream: "abcdefgh", ack: "1", cursor: "client", status: true, maxKbps: "500" })), {
    codecs: "h264,hevc",
    stream: "abcdefgh",
    ack: 1,
    cursor: "client",
    status: 1,
    maxKbps: 500,
  });
  assert.deepEqual(parseStreamParams(q({ codecs: "av1", ack: "0", status: "" })), {});
  bad(() => parseStreamParams(q({ stream: "short" })));
  bad(() => parseStreamParams(q({ ack: "yes" })));
  bad(() => parseStreamParams(q({ cursor: "server" })));
  bad(() => parseStreamParams(q({ maxKbps: 50 })));
  bad(() => parseStreamParams(q({ maxKbps: "1e3" })));
});

test("parseStreamAck checks stream / seq / keyframe and passes an object report on", () => {
  assert.deepEqual(parseStreamAck({ stream: "abcdefgh", seq: 3, keyframe: false, report: { mode: "smooth", fps: 30 } }), { stream: "abcdefgh", seq: 3, report: { mode: "smooth", fps: 30 } });
  assert.deepEqual(parseStreamAck({ stream: "abcdefgh", seq: 3, keyframe: true, report: [1] }), { stream: "abcdefgh", seq: 3, keyframe: true });
  bad(() => parseStreamAck({ stream: "abcdefgh", seq: 1.5 }));
  bad(() => parseStreamAck({ stream: "a", seq: 1 }));
  bad(() => parseStreamAck({ stream: "abcdefgh", seq: 1, keyframe: "yes" }));
});

test("answers read leniently: focus, features, windows, hit, app windows, ax, regions", () => {
  assert.deepEqual(parseFocus({ editable: true, role: "AXTextField" }), { editable: true, role: "AXTextField" });
  assert.deepEqual(parseFocus("nonsense"), { editable: false, role: null });
  assert.deepEqual(parseFeatures({ audio: false, clipboard: true, odd: "yes" }), { audio: false, clipboard: true });
  assert.equal(parseFeatures({}), null);
  assert.equal(parseFeatures([true]), null);
  const w = parseWindows({ apps: [{ pid: 1, name: "Finder", bundleId: "", windows: 2.9 }, { name: "no pid" }], windows: [{ pid: 1, display: 1, x: 0, y: 0, w: 1, h: 1 }, { pid: 1 }], focused: { pid: 1, name: "Finder" } });
  assert.deepEqual(w, { apps: [{ pid: 1, bundleId: null, name: "Finder", windows: 2 }], windows: [{ pid: 1, display: 1, x: 0, y: 0, w: 1, h: 1, layer: 0 }], focused: { pid: 1, bundleId: null, name: "Finder" } });
  bad(() => parseWindows({}), 502);
  assert.deepEqual(parseHit({ app: null, layer: 3 }), { app: null, layer: 3 });
  assert.deepEqual(parseAppWindows({ windows: [{ id: 4, display: 1, x: 0, y: 0, w: 0.5, h: 0.5, onScreen: false }, { id: "x" }] }), [{ id: 4, display: 1, x: 0, y: 0, w: 0.5, h: 0.5, onScreen: false, minimized: false }]);
  bad(() => parseAppWindows(null), 502);
  const ax = parseAppAx({ app: { pid: 2, name: "TextEdit" }, focused: 1.2, truncated: true, elements: [{ i: 1, role: "AXButton", title: "Save", x: 0, y: 0, w: 1, h: 1, enabled: false }, { i: 2, x: 0, y: 0, w: 1, h: 1 }] });
  assert.deepEqual(ax, { app: { pid: 2, bundleId: null, name: "TextEdit" }, focused: 1, truncated: true, elements: [{ i: 1, role: "AXButton", title: "Save", x: 0, y: 0, w: 1, h: 1, enabled: false, focused: false }] });
  assert.deepEqual(regionHeader("0.1,0.2,0.3,0.4"), { x: 0.1, y: 0.2, w: 0.3, h: 0.4 });
  assert.equal(regionHeader("1,2,3"), null);
});

test("remoteFailure: refused / gone → restart, 401 → rekey, anything else (a timeout) → busy", () => {
  assert.equal(remoteFailure(Object.assign(new Error("x"), { code: "ECONNREFUSED" })), "restart");
  assert.equal(remoteFailure({ cause: { code: "EHOSTUNREACH" } }), "restart");
  assert.equal(remoteFailure({ httpStatus: 401 }), "rekey");
  assert.equal(remoteFailure(new DOMException("timed out", "TimeoutError")), "busy");
  assert.equal(remoteFailure(null), "busy");
});

test("an app's English name is kept when it differs from the localized one", () => {
  const w = parseWindows({
    apps: [
      { pid: 9, bundleId: "com.apple.notificationcenterui", name: "Notification Centre", englishName: "Notification Center", windows: 1 },
      { pid: 2, bundleId: "com.apple.finder", name: "Finder", englishName: "Finder", windows: 3 },
      { pid: 3, bundleId: "com.example.x", name: "X", englishName: 7, windows: 1 },
    ],
    windows: [],
    focused: null,
  });
  assert.equal(w.apps[0]!.englishName, "Notification Center");
  assert.equal("englishName" in w.apps[1]!, false);
  assert.equal("englishName" in w.apps[2]!, false);
  assert.deepEqual(parseHit({ app: { pid: 9, bundleId: null, name: "Notification Centre", englishName: "Notification Center" }, layer: 21 }), {
    app: { pid: 9, bundleId: null, name: "Notification Centre", englishName: "Notification Center" },
    layer: 21,
  });
  assert.deepEqual(parseHit({ app: { pid: 4, bundleId: "com.apple.controlcenter", name: "Control Centre" }, layer: 24, menuBar: "statusItem" }).menuBar, "statusItem");
  assert.equal("menuBar" in parseHit({ app: null, layer: null, menuBar: "elsewhere" }), false);
});
