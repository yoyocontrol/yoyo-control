import { test } from "node:test";
import assert from "node:assert/strict";
import { AudioPolicy, ConnectionModel, GAP_GRACE_MS, ReopenPolicy, audioOn, clipboardOn, controlRole, englishStrings, hostOf, mainDisplay, parseStatusPart, phaseText, retryDelay, type ScreenStrings } from "../src/status.js";

test("host: platform first (unknown = Mac); none: the caller's fallback", () => {
  assert.equal(hostOf({ platform: "linux" }, "mac"), "linux");
  assert.equal(hostOf({ platform: "windows" }, "mac"), "windows");
  assert.equal(hostOf({ platform: "mac" }, "linux"), "mac");
  assert.equal(hostOf({ platform: "beos" }, "linux"), "mac");
  assert.equal(hostOf({}, "linux"), "linux");
  assert.equal(hostOf(undefined), "mac");
});

test("clipboard: features.clipboard when said, else the fallback; sound hidden only on features.audio false", () => {
  assert.equal(clipboardOn({ features: { clipboard: true } }, false), true);
  assert.equal(clipboardOn({ features: { clipboard: false } }, true), false);
  assert.equal(clipboardOn({}, true), true);
  assert.equal(clipboardOn({ features: { audio: true } }, false), false);
  assert.equal(clipboardOn(undefined, false), false);
  assert.equal(audioOn({ features: { audio: false } }), false);
  assert.equal(audioOn({ features: {} }), true);
  assert.equal(audioOn(undefined), true);
});

test("who controls, as this browser sees it", () => {
  assert.deepEqual(controlRole("none", undefined, "me"), { t: "free" });
  assert.deepEqual(controlRole("agent", undefined, "me"), { t: "agent" });
  assert.deepEqual(controlRole("user", undefined, "me"), { t: "me" });
  assert.deepEqual(controlRole("user", { id: "me" }, "me"), { t: "me" });
  assert.deepEqual(controlRole("user", { id: "phone", name: "Mia's iPhone" }, "me"), { t: "other", name: "Mia's iPhone" });
  assert.deepEqual(controlRole("user", { id: "phone" }, "me"), { t: "other", name: null });
  assert.deepEqual(controlRole("weird", undefined, "me"), { t: "free" });
});

test("mainDisplay: by id, else the main one", () => {
  const s = { displays: [{ id: 3, width: 1, height: 1, scale: 1, main: false }, { id: 1, width: 2, height: 2, scale: 1, main: true }] };
  assert.equal(mainDisplay(s)!.id, 1);
  assert.equal(mainDisplay(s, 3)!.id, 3);
  assert.equal(mainDisplay(s, 9)!.id, 1);
  assert.equal(mainDisplay({ displays: [] }), null);
});

test("status parts: lenient", () => {
  assert.deepEqual(parseStatusPart('{"display":1,"main":true,"phase":"ready","since":5,"console":{"locked":false}}'), { display: 1, main: true, phase: "ready", since: 5, console: { locked: false } });
  assert.deepEqual(parseStatusPart(new TextEncoder().encode('{"phase":"unavailable","reason":"helper-down","retryAt":9}')), { display: 0, phase: "unavailable", since: 0, reason: "helper-down", retryAt: 9 });
  assert.equal(parseStatusPart("{}"), null);
  assert.equal(parseStatusPart("nope"), null);
});

test("connection: a state that isn't ready shows until a new picture; a gap reads reconnecting after the grace", () => {
  const c = new ConnectionModel();
  c.streamOpened();
  c.picture(0);
  assert.deepEqual(c.phase(1), { t: "live" });
  c.status({ display: 1, phase: "reconnecting", reason: "helper-restart", since: 0 }, 10);
  assert.deepEqual(c.phase(11), { t: "reconnecting", reason: "helper-restart" });
  c.status({ display: 1, phase: "ready", since: 0 }, 20);
  assert.deepEqual(c.phase(21), { t: "live" }, "ready, nothing to say");
  c.status({ display: 1, phase: "unavailable", reason: "no-session", since: 0, retryAt: 99 }, 30);
  assert.deepEqual(c.phase(31), { t: "unavailable", reason: "no-session", retryAt: 99 });
  c.picture(40);
  assert.deepEqual(c.phase(41), { t: "live" });
  c.streamEnded(100);
  assert.deepEqual(c.phase(100 + GAP_GRACE_MS - 1), { t: "live" });
  assert.deepEqual(c.phase(100 + GAP_GRACE_MS), { t: "reconnecting", reason: null });
  assert.equal(c.deadline(), 100 + GAP_GRACE_MS);
  c.status({ display: 1, phase: "ready", since: 0, console: { locked: true } }, 900);
  assert.equal(c.locked, true);
  c.retry(1000);
  assert.deepEqual(c.phase(1001), { t: "reconnecting", reason: null });
});

test("words: English by default, a host page's own strings when given", () => {
  assert.deepEqual(phaseText({ t: "reconnecting", reason: "starting" }, "mac"), { title: "Connecting…", detail: null });
  assert.deepEqual(phaseText({ t: "reconnecting", reason: "helper-restart" }, "linux"), { title: "Reconnecting…", detail: "The desktop is restarting" });
  assert.deepEqual(phaseText({ t: "unavailable", reason: "no-session", retryAt: null }, "linux"), { title: "Can't show the desktop", detail: "The desktop can't be shown right now." });
  assert.deepEqual(phaseText({ t: "unavailable", reason: "no-session", retryAt: null }, "mac"), { title: "Can't show the screen", detail: "This account isn't logged in on the Mac" });
  assert.equal(phaseText({ t: "live" }, "mac"), null);
  assert.equal(englishStrings.reason("something-new", "mac"), null);
  const own: ScreenStrings = { connecting: "c", reconnecting: "r", unavailable: (h) => `u-${h}`, unavailableDetail: () => "d", reason: (r) => (r === "x" ? "X" : null) };
  assert.deepEqual(phaseText({ t: "reconnecting", reason: "x" }, "mac", own), { title: "r", detail: "X" });
  assert.deepEqual(phaseText({ t: "unavailable", reason: "y", retryAt: 1 }, "linux", own), { title: "u-linux", detail: "d" });
});

test("retry and reopen policies", () => {
  assert.equal(retryDelay(undefined), 5000);
  assert.equal(retryDelay(1000, 0), 2000);
  assert.equal(retryDelay(8000, 0), 8000);
  assert.equal(retryDelay(99_000, 0), 15000);
  const r = new ReopenPolicy();
  assert.equal(r.ended(true, false, 60_000), 0, "a clean end after a while: at once");
  for (let i = 0; i < 3; i++) assert.equal(r.ended(true, false, 500), 0);
  assert.equal(r.ended(true, false, 500), 1000, "quick ends in a row: back off");
  assert.equal(r.ended(false, true, 10), 3000);
  assert.equal(r.ended(false, false, 10), 5000);
  const a = new AudioPolicy();
  assert.equal(a.ended(404, 0), null);
  assert.equal(a.ended(403, 0), null);
  assert.equal(a.ended(501, 0), null);
  assert.equal(a.ended(503, 0), 30_000);
  assert.equal(a.ended(null, 60_000), 0);
  assert.equal(a.ended(null, 100), 0);
  assert.equal(a.ended(null, 100), 5000);
});
