// Who takes the screen, in a real browser: <yoyo-screen> on the demo's in-memory computer (demo/), in headless Chrome
// over the DevTools protocol. Checks:
//
//   1. opening never takes control (nobody holds it, the agent, another device);
//   2. while not in control the pill shows with its button — "Take Control" (nobody), "Take Over" (the agent, another
//      device) — and a click on it takes the screen with exactly one control("user"), after which the pill goes;
//   3. in full screen (a phone) the pill shows too and its button leaves full screen into control;
//   4. the first real input still takes control (a key on a desktop), but not another device's.
//
//   npm -w packages/screen-ui run e2e:control -- [--chrome <path>] [--shots <dir>]
//
// Needs the built dist of screen-ui and screen-web (the script builds both). `--shots` saves a PNG of each pill.

import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const arg = (name, fallback) => {
  const i = process.argv.indexOf(name);
  return i > 0 ? process.argv[i + 1] : fallback;
};
const chromePath = arg("--chrome", process.platform === "darwin" ? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" : "google-chrome");
const shots = arg("--shots", null);
const port = 8700 + Math.floor(Math.random() * 90);
const devtools = port + 1000;

const profile = mkdtempSync(join(tmpdir(), "screen-ui-control-"));
const children = [];
const cleanup = () => {
  for (const c of children) c.kill("SIGKILL");
  rmSync(profile, { recursive: true, force: true });
};
process.on("exit", cleanup);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

children.push(spawn(process.execPath, [join(here, "..", "..", "demo", "serve.mjs")], { env: { ...process.env, PORT: String(port) }, stdio: "ignore" }));
children.push(spawn(chromePath, ["--headless=new", `--remote-debugging-port=${devtools}`, `--user-data-dir=${profile}`, "--no-first-run", "about:blank"], { stdio: "ignore" }));

let ws;
for (let i = 0; i < 100 && !ws; i++) {
  try {
    const page = (await (await fetch(`http://127.0.0.1:${devtools}/json/list`)).json()).find((t) => t.type === "page");
    if (page) ws = new WebSocket(page.webSocketDebuggerUrl);
  } catch {
    /* not up yet */
  }
  if (!ws) await sleep(100);
}
if (!ws) throw new Error("Chrome didn't come up");
await new Promise((r) => ws.addEventListener("open", r));
let nextId = 0;
const pending = new Map();
ws.addEventListener("message", (m) => {
  const d = JSON.parse(m.data);
  if (d.id && pending.has(d.id)) {
    pending.get(d.id)(d);
    pending.delete(d.id);
  }
});
const send = (method, params = {}) =>
  new Promise((r) => {
    const id = ++nextId;
    pending.set(id, r);
    ws.send(JSON.stringify({ id, method, params }));
  });
const evaluate = async (expression) => (await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true })).result?.result?.value;

const failures = [];
const check = (name, ok, detail) => {
  console.log(`${ok ? "ok  " : "FAIL"} ${name}${ok ? "" : ` ${JSON.stringify(detail)}`}`);
  if (!ok) failures.push(name);
};

/** The page on `state` (none / agent / viewer), its control requests counted. */
async function open(state, phone) {
  await send("Emulation.setTouchEmulationEnabled", { enabled: phone, maxTouchPoints: phone ? 5 : 0 });
  await send("Emulation.setDeviceMetricsOverride", phone ? { width: 390, height: 844, deviceScaleFactor: 3, mobile: true } : { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false });
  await send("Page.navigate", { url: `http://localhost:${port}/?state=${state}` });
  for (let i = 0; i < 50; i++) {
    if (await evaluate("!!window.demo?.screen?.backend")) break;
    await sleep(100);
  }
  await evaluate(`(() => {
    const b = demo.screen.backend;
    const set = b.setControl.bind(b);
    window.controls = [];
    b.setControl = (controller, ...rest) => (window.controls.push(controller), set(controller, ...rest));
  })()`);
  await sleep(1500);
  return state;
}
const pill = () =>
  evaluate(`(() => {
    const p = demo.screen.shadowRoot.querySelector(".vpill");
    const b = p?.querySelector("button");
    const r = b?.getBoundingClientRect();
    return { shown: !!p && !p.hidden, text: p?.querySelector(".name")?.textContent ?? null, button: b?.textContent ?? null,
             x: r ? r.x + r.width / 2 : 0, y: r ? r.y + r.height / 2 : 0 };
  })()`);
const state = () => evaluate(`({ controls: window.controls, controller: demo.pc.controller, device: demo.pc.controllerDevice?.id ?? null, full: demo.screen.hasAttribute("fullscreen") })`);
/** A tap (a phone: a real tap gesture, so a button gets its click) or a mouse click. */
const click = async (x, y, phone) => {
  if (phone) await send("Input.synthesizeTapGesture", { x, y, gestureSourceType: "touch" });
  else for (const type of ["mousePressed", "mouseReleased"]) await send("Input.dispatchMouseEvent", { type, x, y, button: "left", clickCount: 1 });
};
/** A finger down and up (no tap gesture): what the trackpad sees. */
const touch = async (x, y) => {
  await send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x, y }] });
  await send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
};
const shot = async (name) => {
  if (!shots) return;
  const r = await send("Page.captureScreenshot", { format: "png" });
  writeFileSync(join(shots, `web-${name}.png`), Buffer.from(r.result.data, "base64"));
};

await send("Page.enable");
await send("Runtime.enable");

// the first real input still takes it (a key on a desktop)
await open("none", false);
await send("Input.dispatchKeyEvent", { type: "keyDown", key: "Escape", code: "Escape", windowsVirtualKeyCode: 27 });
await send("Input.dispatchKeyEvent", { type: "keyUp", key: "Escape", code: "Escape", windowsVirtualKeyCode: 27 });
await sleep(500);
let st = await state();
check("desktop/none: a key takes the screen", st.controls.length === 1 && st.controller === "user", st);
// the desktop first (Chrome's touch emulation leaves a page's pointer coarse afterwards)
for (const [s, phone, button] of [["agent", false, "Take Over"], ["none", true, "Take Control"], ["agent", true, "Take Over"], ["viewer", true, "Take Over"]]) {
  const where = `${phone ? "phone" : "desktop"}/${s}`;
  await open(s, phone);
  let st = await state();
  check(`${where}: opening takes nothing`, st.controls.length === 0, st);
  const p = await pill();
  check(`${where}: the pill says ${button}`, p.shown && p.button === button, p);
  await shot(where.replace("/", "-"));
  await click(p.x, p.y, phone);
  await sleep(600);
  st = await state();
  check(`${where}: its button takes the screen once`, st.controls.length === 1 && st.controls[0] === "user" && st.controller === "user" && st.device !== "someone-else", st);
  const after = await pill();
  check(`${where}: in control, no pill`, !after.shown, after);
  if (phone && s === "none") await shot("phone-in-control");
}

// full screen on a phone: the pill shows, its button leaves full screen into control
await open("agent", true);
await evaluate(`demo.screen.shadowRoot.querySelector(".fs").click()`);
await sleep(400);
st = await state();
const p = await pill();
check("phone/full screen: the pill shows", st.full && p.shown && p.button === "Take Over", { st, p });
await shot("phone-fullscreen");
await click(p.x, p.y, true);
await sleep(600);
st = await state();
check("phone/full screen: its button leaves full screen into control", !st.full && st.controls.length === 1 && st.controller === "user", st);

// not another device's control by a touch
await open("viewer", true);
const pad = await evaluate(`(() => { const r = demo.screen.shadowRoot.querySelector(".pad").getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()`);
await touch(pad.x, pad.y);
await sleep(500);
st = await state();
check("phone/viewer: a touch on the pad doesn't take another device's control", st.controls.length === 0 && st.device === "someone-else", st);

console.log(failures.length ? `${failures.length} failed` : "all passed");
process.exit(failures.length ? 1 : 0);
