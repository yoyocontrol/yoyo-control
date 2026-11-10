// The window list (windows.mjs) and automation (automation.mjs): the pure parts, then GET /windows, GET /hit,
// /frame?visible=&hide=&crop= and POST /automation over a faked yoyo-x11windows (test/fakes.mjs).
import assert from "node:assert/strict";
import { request } from "node:http";
import { after, before, test } from "node:test";
import { parseAutomation } from "../automation.mjs";
import { YoyoLinux } from "../server.mjs";
import { hitAnswer, maskBoxes, parseCrop, parseHide, parseVisible, pixelRect, subtract, windowCatalog, windowsAnswer } from "../windows.mjs";
import { fakeProcess, fakeSpawn } from "./fakes.mjs";

// what yoyo-x11windows prints for an Xfce desktop of 1280 × 832, bottom → top
const win = (o) => ({ or: false, instance: null, pid: 0, type: "normal", hidden: false, above: false, ...o });
const DESKTOP = {
  screen: [1280, 832],
  active: 4,
  windows: [
    win({ id: 1, class: "Xfdesktop", instance: "xfdesktop", pid: 100, type: "desktop", x: 0, y: 0, w: 1280, h: 832 }),
    win({ id: 2, class: "Xfce4-panel", instance: "xfce4-panel", pid: 101, type: "dock", x: 0, y: 0, w: 1280, h: 32 }),
    win({ id: 3, class: "Thunar", instance: "thunar", pid: 200, x: 100, y: 100, w: 600, h: 400 }),
    win({ id: 4, class: "Xfce4-terminal", instance: "xfce4-terminal", pid: 300, x: 400, y: 300, w: 600, h: 400 }),
    win({ id: 5, class: "Thunar", instance: "thunar", pid: 200, hidden: true, x: 0, y: 0, w: 300, h: 300 }),
    win({ id: 6, or: true, class: "firefox-esr", instance: "Popup", pid: 400, type: "popup_menu", x: 1200, y: 700, w: 200, h: 200 }),
    win({ id: 7, class: "Gimp", pid: 450, x: 2000, y: 2000, w: 300, h: 300 }),
    win({ id: 8, class: null, pid: 500, type: null, x: 0, y: 800, w: 10, h: 10 }),
  ],
};

test("windows: the helper's list → front → back, minimized and off-screen windows out, clipped, identity = WM_CLASS class", () => {
  const cat = windowCatalog(DESKTOP);
  const a = windowsAnswer(cat, 1);
  assert.deepEqual(a.windows, [
    { pid: 500, display: 1, x: 0, y: 0.961538, w: 0.007813, h: 0.012019, layer: 0 },
    { pid: 400, display: 1, x: 0.9375, y: 0.841346, w: 0.0625, h: 0.158654, layer: 2 },
    { pid: 300, display: 1, x: 0.3125, y: 0.360577, w: 0.46875, h: 0.480769, layer: 0 },
    { pid: 200, display: 1, x: 0.078125, y: 0.120192, w: 0.46875, h: 0.480769, layer: 0 },
    { pid: 101, display: 1, x: 0, y: 0, w: 1, h: 0.038462, layer: 1 },
    { pid: 100, display: 1, x: 0, y: 0, w: 1, h: 1, layer: -1 },
  ]);
  assert.deepEqual(a.apps, [
    { pid: 500, bundleId: null, name: "pid 500", windows: 1 },
    { pid: 400, bundleId: "firefox-esr", name: "firefox-esr", windows: 1 },
    { pid: 300, bundleId: "Xfce4-terminal", name: "Xfce4-terminal", windows: 1 },
    { pid: 200, bundleId: "Thunar", name: "Thunar", windows: 1 },
    { pid: 101, bundleId: "Xfce4-panel", name: "Xfce4-panel", windows: 1 },
    { pid: 100, bundleId: "Xfdesktop", name: "Xfdesktop", windows: 1 },
  ]);
  assert.deepEqual(a.focused, { pid: 300, bundleId: "Xfce4-terminal", name: "Xfce4-terminal" });
  assert.equal(windowCatalog({ ...DESKTOP, active: 0 }).focused, null);
  // two windows of one app: one entry, counted
  const two = windowsAnswer(windowCatalog({ ...DESKTOP, windows: [...DESKTOP.windows, win({ id: 9, class: "Thunar", pid: 200, x: 0, y: 0, w: 50, h: 50 })] }), 1);
  assert.deepEqual(two.apps.find((x) => x.bundleId === "Thunar"), { pid: 200, bundleId: "Thunar", name: "Thunar", windows: 2 });
});

test("hit: the topmost listed window at the point; none there → app null", () => {
  const cat = windowCatalog(DESKTOP);
  const at = (x, y) => hitAnswer(cat, x / 1280, y / 832);
  assert.deepEqual(at(450, 350), { app: { pid: 300, bundleId: "Xfce4-terminal", name: "Xfce4-terminal" }, layer: 0 });
  assert.equal(at(150, 150).app.bundleId, "Thunar");
  assert.deepEqual(at(10, 10), { app: { pid: 101, bundleId: "Xfce4-panel", name: "Xfce4-panel" }, layer: 1 });
  assert.equal(at(640, 800).app.bundleId, "Xfdesktop");
  assert.equal(at(1279, 831).app.bundleId, "firefox-esr");
  assert.equal(hitAnswer(cat, 1, 1).app.bundleId, "firefox-esr", "the last pixel row / column belongs to the window touching it");
  const bare = windowCatalog({ screen: [1280, 832], active: 0, windows: [DESKTOP.windows[2]] });
  assert.deepEqual(hitAnswer(bare, 0.9, 0.9), { app: null, layer: null });
});

test("frame filter: hide= patterns, visible= set, crop= region, pixel rounding, rectangle subtraction", () => {
  const h = parseHide("Thunar, xfce4-*");
  assert.ok(h.hides("thunar") && h.hides("Xfce4-Terminal") && h.hides("xfce4-panel") && !h.hides("Xfdesktop") && !h.hides(null));
  assert.throws(() => parseHide("bad/id"), /not an app id/);
  assert.throws(() => parseHide(Array.from({ length: 65 }, (_, i) => `a${i}`).join(",")), /more than 64/);
  assert.ok(parseHide("VirtualBox Machine").hides("virtualbox machine"));
  assert.deepEqual([...parseVisible(" Thunar,,XFCE4-terminal ")], ["thunar", "xfce4-terminal"]);
  assert.deepEqual(parseCrop("0.5,0.5,1,1"), { x: 0.5, y: 0.5, w: 0.5, h: 0.5 });
  assert.throws(() => parseCrop("0.1,0.2,0.3"), /x,y,w,h/);
  assert.throws(() => parseCrop("2,2,1,1"), /empty/);
  assert.deepEqual(pixelRect({ x: 0.1, y: 0.1, w: 0.5, h: 0.5 }, 1280, 832), { x: 128, y: 83, w: 640, h: 417 });
  assert.deepEqual(subtract({ x: 0, y: 0, w: 10, h: 10 }, { x: 20, y: 20, w: 5, h: 5 }), [{ x: 0, y: 0, w: 10, h: 10 }]);
  assert.deepEqual(subtract({ x: 0, y: 0, w: 10, h: 10 }, { x: 0, y: 0, w: 10, h: 10 }), []);
  assert.deepEqual(subtract({ x: 0, y: 0, w: 10, h: 10 }, { x: 3, y: 3, w: 4, h: 4 }).length, 4);
});

test("mask: other apps' windows covered back → front, an allowed window in front stays; desktop and panel only when hidden", () => {
  const cat = windowCatalog(DESKTOP);
  const boxes = (visible, hide = "") => maskBoxes(cat, parseVisible(visible), parseHide(hide), 1280, 832);
  // the terminal allowed: Thunar behind it covered except where the terminal is; the popup and the classless window covered
  assert.deepEqual(boxes("xfce4-terminal"), [
    { x: 0, y: 800, w: 10, h: 10 },
    { x: 1200, y: 700, w: 80, h: 132 },
    { x: 100, y: 100, w: 600, h: 200 },
    { x: 100, y: 300, w: 300, h: 200 },
  ]);
  // Thunar allowed: the terminal in front of it is covered whole (it is painted after)
  assert.deepEqual(boxes("thunar").slice(2), [{ x: 400, y: 300, w: 600, h: 400 }]);
  // nothing allowed: every window, but not the desktop or the panel
  assert.equal(boxes("").length, 4);
  // hidden: out of visible, and the panel too when named
  assert.deepEqual(boxes("thunar,xfce4-terminal,firefox-esr", "Thunar,xfce4-panel").slice(1), [
    { x: 100, y: 100, w: 600, h: 200 },
    { x: 100, y: 300, w: 300, h: 200 },
    { x: 0, y: 0, w: 1280, h: 32 },
  ]);
  // the boxes in the picture's own pixels (a capture of another size)
  assert.deepEqual(maskBoxes(cat, parseVisible("thunar,firefox-esr,xfce4-terminal"), parseHide(""), 640, 416), [{ x: 0, y: 400, w: 5, h: 5 }]);
});

test("automation: the body's checks; the label one line of ≤ 40 characters", () => {
  assert.deepEqual(parseAutomation({ active: true, label: "  Robot\n\tArm  " }), { active: true, label: "Robot Arm" });
  assert.equal(parseAutomation({ active: true, label: "é".repeat(50) }).label.length, 40);
  assert.deepEqual(parseAutomation({ active: false, title: "anything" }), { active: false, label: "" });
  assert.throws(() => parseAutomation({ active: "yes" }), /active must be a boolean/);
  assert.throws(() => parseAutomation({ active: true, label: 5 }), /label must be a string/);
  assert.throws(() => parseAutomation({ active: true, title: 5 }), /title must be a string/);
  assert.throws(() => parseAutomation([]), /JSON object/);
});

// the routes
const TOKEN = "w".repeat(64);
const fake = fakeSpawn();
fake.state.windows = DESKTOP;
const svc = new YoyoLinux({ token: TOKEN, spawnFn: fake.spawn, logLine: () => {} });
let port;
before(async () => {
  port = (await svc.listen(0, "127.0.0.1")).port;
});
after(() => svc.close());

function call(method, path, { body, stream } = {}) {
  return new Promise((resolve, reject) => {
    const b = body === undefined ? undefined : Buffer.from(JSON.stringify(body));
    const req = request({ host: "127.0.0.1", port, method, path, headers: { authorization: `Bearer ${TOKEN}`, ...(b ? { "content-type": "application/json", "content-length": b.length } : {}) } }, (res) => {
      if (stream) return resolve({ res, req });
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const buf = Buffer.concat(chunks);
        let json;
        try {
          json = JSON.parse(buf.toString());
        } catch {}
        resolve({ status: res.statusCode, headers: res.headers, json });
      });
    });
    req.on("error", reject);
    req.end(b);
  });
}

const until = async (pred, what) => {
  for (let i = 0; i < 200; i++) {
    if (pred()) return;
    await new Promise((r) => setTimeout(r, 5));
  }
  throw new Error(`timed out waiting for ${what}`);
};

test("GET /windows and GET /hit: the helper's list; 400 / 404 for bad points and other displays; 503 without X", async () => {
  const r = await call("GET", "/windows");
  assert.equal(r.status, 200);
  assert.deepEqual(r.json, windowsAnswer(windowCatalog(DESKTOP), 1));
  assert.equal((await call("GET", "/windows?display=1")).status, 200);
  assert.equal((await call("GET", "/windows?display=2")).status, 404);
  assert.deepEqual((await call("GET", `/hit?display=1&x=${450 / 1280}&y=${350 / 832}`)).json, { app: { pid: 300, bundleId: "Xfce4-terminal", name: "Xfce4-terminal" }, layer: 0 });
  for (const q of ["x=0.5", "y=0.5", "x=1.5&y=0.5", "x=0.5&y=-0.1", "x=a&y=0.5"]) assert.equal((await call("GET", `/hit?${q}`)).status, 400, q);
  assert.equal((await call("GET", "/hit?display=3&x=0.5&y=0.5")).status, 404);
  fake.state.windowsFail = true;
  try {
    const f = await call("GET", "/windows");
    assert.equal(f.status, 503);
    assert.match(f.json.error, /cannot open the display/);
    assert.equal((await call("GET", "/hit?x=0.5&y=0.5")).status, 503);
    assert.equal((await call("GET", "/frame?visible=thunar")).status, 503);
    assert.equal((await call("GET", "/status")).json.features.windows, true, "the helper runs: it is the display that is missing");
  } finally {
    fake.state.windowsFail = false;
  }
});

test("GET /frame?visible=: drawbox per covered region before the scale, X-Frame-Filter: mask; crop= after covering, X-Crop", async () => {
  const runs = fake.state.windowsRuns;
  const plain = await call("GET", "/frame?maxWidth=640");
  assert.equal(plain.headers["x-frame-filter"], undefined);
  assert.equal(fake.state.windowsRuns, runs, "no window list for a plain frame");
  assert.equal(fake.state.ffmpegArgs.at(-1).at(fake.state.ffmpegArgs.at(-1).indexOf("-vf") + 1), "scale=640:416:flags=area");

  const r = await call("GET", "/frame?maxWidth=640&visible=Xfce4-Terminal");
  assert.equal(r.status, 200);
  assert.equal(r.headers["x-frame-filter"], "mask");
  assert.equal(r.headers["x-crop"], undefined);
  const vf = fake.state.ffmpegArgs.at(-1).at(fake.state.ffmpegArgs.at(-1).indexOf("-vf") + 1);
  assert.equal(
    vf,
    [
      "drawbox=x=0:y=800:w=10:h=10:color=0x3a3a3a:t=fill",
      "drawbox=x=1200:y=700:w=80:h=132:color=0x3a3a3a:t=fill",
      "drawbox=x=100:y=100:w=600:h=200:color=0x3a3a3a:t=fill",
      "drawbox=x=100:y=300:w=300:h=200:color=0x3a3a3a:t=fill",
      "scale=640:416:flags=area",
    ].join(","),
  );

  const c = await call("GET", "/frame?maxWidth=320&visible=thunar,xfce4-terminal,firefox-esr&hide=thunar&crop=0.5,0.5,0.5,0.5");
  assert.equal(c.status, 200);
  assert.deepEqual([c.headers["x-frame-width"], c.headers["x-frame-height"], c.headers["x-crop"], c.headers["x-frame-filter"]], ["320", "208", "0.5000,0.5000,0.5000,0.5000", "mask"]);
  const cvf = fake.state.ffmpegArgs.at(-1).at(fake.state.ffmpegArgs.at(-1).indexOf("-vf") + 1).split(",");
  assert.deepEqual(cvf.slice(-2), ["crop=640:416:640:416", "scale=320:208:flags=area"]);
  assert.ok(cvf.includes("drawbox=x=100:y=100:w=600:h=200:color=0x3a3a3a:t=fill"), "hidden Thunar covered though visible names it");

  // crop alone: no window list, no mask header; a small crop is not scaled up
  const runs2 = fake.state.windowsRuns;
  const z = await call("GET", "/frame?crop=0,0,0.1,0.1");
  assert.deepEqual([z.headers["x-frame-width"], z.headers["x-frame-height"], z.headers["x-frame-filter"]], ["128", "84", undefined]);
  assert.equal(fake.state.windowsRuns, runs2);
  for (const q of ["crop=1,1,1,1", "crop=a,b,c,d", "hide=no/such", "visible=a&hide=x%2Fy"]) assert.equal((await call("GET", `/frame?${q}`)).status, 400, q);
});

test("POST /automation: on (the Escape watch's hello: esc true), /status says so, Escape → off + abort on /events; off stops the watch", async () => {
  assert.equal((await call("POST", "/automation", { body: { active: "yes" } })).status, 400);
  const on = await call("POST", "/automation", { body: { active: true, label: "Robot\nArm" } });
  assert.deepEqual(on.json, { ok: true, active: true, esc: true, label: "Robot Arm" });
  assert.deepEqual((await call("GET", "/status")).json.automation, { active: true, esc: true, label: "Robot Arm" });
  const watch = fake.state.escWatches.at(-1);
  assert.deepEqual(watch.args, ["--esc"]);
  // the same value again: no second watch; a new label kept
  assert.deepEqual((await call("POST", "/automation", { body: { active: true, label: "Other" } })).json, { ok: true, active: true, esc: true, label: "Other" });
  assert.equal(fake.state.escWatches.length, 1);

  const { res, req } = await call("GET", "/events", { stream: true });
  let text = "";
  res.on("data", (d) => (text += d));
  await until(() => text.includes('"state"'), "the first /events line");
  fake.state.pressEscape();
  await until(() => text.includes('"abort"'), "the abort line");
  assert.ok(text.split("\n").includes(JSON.stringify({ type: "abort", reason: "esc" })));
  assert.deepEqual((await call("GET", "/status")).json.automation, { active: false, esc: false });
  assert.notEqual(watch.exitCode, null, "the watch stopped");
  req.destroy();

  // the older name; no XInput 2 → esc false, still active; off → its answer
  fake.state.escFails = true;
  try {
    assert.deepEqual((await call("POST", "/agent-control", { body: { active: true } })).json, { ok: true, active: true, esc: false });
  } finally {
    fake.state.escFails = false;
  }
  assert.deepEqual((await call("POST", "/automation", { body: { active: false } })).json, { ok: true, active: false, esc: false });
  assert.deepEqual((await call("POST", "/automation", { body: { active: true } })).json, { ok: true, active: true, esc: true });
  const last = fake.state.escWatches.at(-1);
  assert.deepEqual((await call("POST", "/automation", { body: { active: false } })).json, { ok: true, active: false, esc: false });
  await until(() => last.exitCode !== null, "the watch stopping");
  fake.state.pressEscape();
  await new Promise((r) => setTimeout(r, 20));
  assert.equal((await call("GET", "/status")).json.automation.active, false);
});

test("features.windows: false while the helper can't be started (missing), true again once it runs", async () => {
  const base = fakeSpawn();
  base.state.windows = DESKTOP;
  let missing = true;
  const spawnFn = (path, args, o) => {
    if (path.endsWith("yoyo-x11windows") && missing) {
      const p = fakeProcess();
      setImmediate(() => p.emit("error", Object.assign(new Error("spawn yoyo-x11windows ENOENT"), { code: "ENOENT" })));
      return p;
    }
    return base.spawn(path, args, o);
  };
  const s = new YoyoLinux({ token: TOKEN, spawnFn, logLine: () => {} });
  try {
    await assert.rejects(s.readWindows(), (e) => e.status === 503);
    assert.equal((await s.features()).windows, false);
    missing = false;
    await s.readWindows();
    assert.equal((await s.features()).windows, true);
  } finally {
    s.close();
  }
});
