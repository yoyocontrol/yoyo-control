import assert from "node:assert/strict";
import { test } from "node:test";
import { ControlModel, controlAnswer, controlledElsewhere, controlPill } from "../src/viewer.js";
import { Words } from "../src/strings.js";

test("another device taking over from this one is said once; a stale poll is ignored", () => {
  const m = new ControlModel();
  assert.equal(m.took("user", { id: "me" }, 100, "me"), null);
  assert.deepEqual(m.role, { t: "me" });
  assert.equal(m.status("user", { id: "other", name: "Mia" }, 90, "me"), null, "from before this device took it");
  assert.deepEqual(m.status("user", { id: "other", name: "Mia" }, 110, "me"), { tookOver: "Mia" });
  assert.ok(m.isViewer);
  assert.equal(m.status("user", { id: "other" }, 120, "me"), null, "said once");
  assert.deepEqual(ControlModel.roleOf("user", undefined, "me"), { t: "me" }, "a holder that names no device");
  assert.deepEqual(ControlModel.roleOf("agent", null, "me"), { t: "agent" });
  const w = new Words({ language: "en" });
  assert.equal(ControlModel.displayName("iPhone", w), "Another iPhone");
  assert.equal(ControlModel.displayName(" ", w), "Another device");
  assert.deepEqual(controlledElsewhere({ body: { code: "controlled-elsewhere", controllerDevice: { id: "x", name: "Mia" } } }), { id: "x", name: "Mia" });
  assert.equal(controlledElsewhere({ body: { code: "other" } }), null);
});

test("the page opens watching: only a real input takes the screen, over the agent too; another device's only with Take Over", () => {
  // in control: the input goes
  assert.equal(controlAnswer(true, false, true), "go");
  // watching with nobody else's control in the way (free, or the agent's: the user wins): take, then the input goes
  assert.equal(controlAnswer(false, false, true), "take");
  // another device holds it: the Take Over pill is nudged
  assert.equal(controlAnswer(false, true, false), "nudge");
  // view only (full screen), no Accessibility: nothing
  assert.equal(controlAnswer(false, false, false), "ignore");
});

test("not in control (and able to be): the pill says who holds it, with Take Control / Take Over", () => {
  assert.deepEqual(controlPill(false, true, { t: "free" }), { t: "free" });
  assert.deepEqual(controlPill(false, true, { t: "agent" }), { t: "agent" });
  assert.deepEqual(controlPill(false, true, { t: "other", name: "Mia" }), { t: "other", name: "Mia" });
  // full screen after this device held it: not in control, the button takes it again
  assert.deepEqual(controlPill(false, true, { t: "me" }), { t: "free" });
  // in control: the badge ("You have control"), no pill
  assert.equal(controlPill(true, true, { t: "me" }), null);
  // no Accessibility, no picture, a phone turned to landscape: the badge alone
  assert.equal(controlPill(false, false, { t: "agent" }), null);
  const w = new Words({ language: "zh-Hans" });
  assert.equal(w.t("takeControl"), "开始控制");
  assert.equal(w.t("takeOver"), "接管");
});
