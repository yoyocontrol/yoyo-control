// End-to-end in a real browser: uu-link-probe's rtc listener (Rust, str0m) ↔ headless Chrome running link-web
// (WebRTC + the wasm media layer). Prints the measurements as JSON.
//
//   npm -w packages/link-web run e2e -- [--probe <uu-link-probe>] [--seconds 10] [--netem <profile>] [--chrome <path>]
//   npm -w packages/link-web run e2e -- --netem handover --netem-args "--handover-every 12 --blackout 6000"   # path lost 6 s: ICE restarts
//   npm -w packages/link-web run e2e -- --page screen [--seconds 10] [--delay 40 --jitter 15] [--codec hevc]
//   npm -w packages/link-web run e2e -- --signal-url <https://…/v1/rtc/<hex>> --fingerprint sha256:<hex> --credential "Pair <code>"
//
// `--signal-url` dials a real server (a Mac, a Linux server) through a real signaling server or relay instead of the
// probe: the time to welcome, the path and `GET /status` round trips only (the rest needs the probe's test routes).
//
// `--page screen` needs no probe: screen-web's VideoStream / ScreenAudio over an in-page ScreenLink fed by the
// browser's own encoders (test/e2e/screen.ts), for the decode, playout and A/V sync path in a real browser.
//
// The probe defaults to link/target/release/uu-link-probe (cargo build --release -p uu-link-probe). It is started as
// `serve-rtc` on free ports; the page is served from 127.0.0.1 (a secure context: WebCrypto works) and signals through
// the probe's localhost endpoint. With --netem the browser reaches the probe's rtc port only through
// uu-link-netem (the probe advertises the proxy's address, docs/LINK.md「测试工具」). Chrome runs headless with its
// own temporary profile; it needs to run outside a sandbox that forbids its own. `--devtools <ws://…>` drives a browser
// that runs already (its DevTools endpoint) instead of starting one. `--speed-test <ms>`: only the speed test
// (docs/LINK.md「测速」), its report (also with `--signal-url`).

import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, copyFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { networkInterfaces, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { build } from "esbuild";

const here = dirname(fileURLToPath(import.meta.url));
const pkg = join(here, "..", "..");
const repo = join(pkg, "..", "..");
const arg = (name, fallback) => {
  const i = process.argv.indexOf(name);
  return i > 0 ? process.argv[i + 1] : fallback;
};
const seconds = Number(arg("--seconds", "10"));
const probe = arg("--probe", join(repo, "link", "target", "release", "uu-link-probe"));
const netem = arg("--netem", null);
const netemBin = arg("--netem-bin", join(dirname(probe), "uu-link-netem"));
const page = arg("--page", "link");
const realSignal = arg("--signal-url", null);
const chrome = arg("--chrome", process.platform === "darwin" ? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" : "google-chrome");

const out = mkdtempSync(join(tmpdir(), "link-web-e2e-"));
const children = [];
const cleanup = () => {
  for (const c of children) c.kill("SIGKILL");
  try {
    rmSync(out, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
  } catch {
    /* Chrome still writing its profile: the OS cleans the temp dir */
  }
};
process.on("exit", cleanup);
process.on("SIGINT", () => process.exit(130));

/** Starts `cmd`, resolves with its stdout lines as they come (and the child). */
function start(cmd, args, onLine) {
  const c = spawn(cmd, args, { stdio: ["ignore", "pipe", "pipe"] });
  children.push(c);
  let buf = "";
  const feed = (d) => {
    buf += d;
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      onLine(buf.slice(0, i));
      buf = buf.slice(i + 1);
    }
  };
  c.stdout.on("data", feed);
  c.stderr.on("data", feed);
  return c;
}

const free = () =>
  new Promise((resolve) => {
    const s = createServer().listen(0, "127.0.0.1", () => {
      const p = s.address().port;
      s.close(() => resolve(p));
    });
  });

// 1. the page
await build({ entryPoints: [join(here, page === "screen" ? "screen.ts" : "page.ts")], bundle: true, format: "esm", target: "es2022", outfile: join(out, "page.js"), logLevel: "warning",
  // the workspace's sources, not a stale dist/
  alias: { "@yoyocontrol/screen-web": join(repo, "packages", "screen-web", "src", "index.ts") } });
mkdirSync(join(out, "wasm"));
copyFileSync(join(pkg, "src", "wasm", "uu_link_wasm_bg.wasm"), join(out, "wasm", "uu_link_wasm_bg.wasm"));
const html = `<!doctype html><meta charset="utf-8"><title>link-web e2e</title><script type="module" src="/page.js"></script>`;
const types = { ".js": "text/javascript", ".wasm": "application/wasm" };
// set once the probe runs: its signaling URL
let signalUrl = realSignal ?? "";
const web = createServer(async (req, res) => {
  const path = (req.url ?? "/").split("?")[0];
  if (path === "/") return res.writeHead(200, { "content-type": "text/html" }).end(html);
  if (path === "/signal" && req.method === "POST") {
    // the probe's signaling, passed through unchanged (same origin for the page)
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const r = await fetch(signalUrl, { method: "POST", headers: { "content-type": "application/json" }, body: Buffer.concat(chunks) });
    return res.writeHead(r.status, { "content-type": "application/json" }).end(await r.text());
  }
  try {
    const body = readFileSync(join(out, path));
    res.writeHead(200, { "content-type": types[path.slice(path.lastIndexOf("."))] ?? "application/octet-stream" }).end(body);
  } catch {
    res.writeHead(404).end();
  }
});
const webPort = await free();
await new Promise((r) => web.listen(webPort, "127.0.0.1", r));

// 2. the probe (and the impairment proxy)
const probeLog = [];
const info = page === "screen" ? null : realSignal ? { fingerprint: arg("--fingerprint"), credential: arg("--credential") } : await startProbe();

async function startProbe() {
  const [linkPort, rtcPort, signalPort, netemPort] = [await free(), await free(), await free(), await free()];
  const lan = Object.values(networkInterfaces()).flat().find((i) => i && i.family === "IPv4" && !i.internal)?.address ?? "127.0.0.1";
  const args = ["serve-rtc", "--port", String(linkPort), "--rtc-port", String(rtcPort), "--signal", String(signalPort)];
  // through the proxy only: the probe binds loopback and its answer offers only the proxy's address
  if (netem) args.push("--bind", "127.0.0.1", "--advertise", `${lan}:${netemPort}`, "--advertise-only");
  const seen = await new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(`the probe didn't start:\n${probeLog.join("\n")}`)), 20_000);
    const got = {};
    start(probe, args, (line) => {
      probeLog.push(line);
      const m = /^(fingerprint|token|signal) (\S+)/.exec(line);
      if (m) got[m[1]] = m[2];
      if (got.fingerprint && got.token && got.signal) {
        clearTimeout(t);
        resolve(got);
      }
    });
  });
  signalUrl = seen.signal;
  if (netem) {
    const extra = (arg("--netem-args", "") ?? "").split(/\s+/).filter(Boolean);
    start(netemBin, ["--listen", `${lan}:${netemPort}`, "--to", `127.0.0.1:${rtcPort}`, "--profile", netem, ...extra], (l) => probeLog.push(`netem: ${l}`));
  }
  return seen;
}

// 3. Chrome over CDP
const profile = join(out, "chrome");
const chromeArgs = [
  "--headless=new",
  `--user-data-dir=${profile}`,
  "--remote-debugging-port=0",
  "--no-first-run",
  "--no-default-browser-check",
  "--disable-background-networking",
  "--autoplay-policy=no-user-gesture-required",
  "about:blank",
];
const devtools = arg("--devtools", null) ?? await new Promise((resolve, reject) => {
  const t = setTimeout(() => reject(new Error("Chrome didn't start")), 20_000);
  start(chrome, chromeArgs, (line) => {
    const m = /DevTools listening on (ws:\/\/\S+)/.exec(line);
    if (m) {
      clearTimeout(t);
      resolve(m[1]);
    }
  });
});
const browser = new WebSocket(devtools);
await new Promise((r) => browser.addEventListener("open", r, { once: true }));
let id = 0;
const pending = new Map();
browser.addEventListener("message", (ev) => {
  const m = JSON.parse(ev.data);
  if (m.id && pending.has(m.id)) {
    pending.get(m.id)(m);
    pending.delete(m.id);
  } else if (m.method === "Runtime.consoleAPICalled") {
    console.error("page:", m.params.args.map((a) => a.value ?? a.description).join(" "));
  } else if (m.method === "Runtime.exceptionThrown") {
    console.error("page exception:", m.params.exceptionDetails.exception?.description ?? m.params.exceptionDetails.text);
  }
});
const cdp = (method, params = {}, sessionId) =>
  new Promise((resolve, reject) => {
    const i = ++id;
    pending.set(i, (m) => (m.error ? reject(new Error(`${method}: ${m.error.message}`)) : resolve(m.result)));
    browser.send(JSON.stringify({ id: i, method, params, ...(sessionId ? { sessionId } : {}) }));
  });
const { targetId } = await cdp("Target.createTarget", { url: `http://127.0.0.1:${webPort}/` });
const { sessionId } = await cdp("Target.attachToTarget", { targetId, flatten: true });
await cdp("Runtime.enable", {}, sessionId);
for (let i = 0; i < 100; i++) {
  const r = await cdp("Runtime.evaluate", { expression: "typeof e2e", returnByValue: true }, sessionId);
  if (r.result.value === "function") break;
  await new Promise((r) => setTimeout(r, 100));
}
const config =
  page === "screen"
    ? { seconds, delayMs: Number(arg("--delay", "40")), jitterMs: Number(arg("--jitter", "15")), codec: arg("--codec", "h264") }
    : { signal: `http://127.0.0.1:${webPort}/signal`, fingerprint: info.fingerprint, credential: info.credential ?? `Bearer ${info.token}`, seconds, real: !!realSignal, ...(arg("--speed-test", null) ? { speedTestMs: Number(arg("--speed-test", "8000")) } : {}) };
const r = await cdp("Runtime.evaluate", { expression: `e2e(${JSON.stringify(config)})`, awaitPromise: true, returnByValue: true, timeout: (seconds + 60) * 1000 }, sessionId);
const result = r.result.value ?? { error: r.exceptionDetails?.text };
console.log(JSON.stringify({ netem: netem ?? "none", ...result }, null, 2));
const serverLines = probeLog.filter((l) => /link\[(server|phone)\]:|session (opened|closed)|rtc/.test(l));
if (serverLines.length) console.log(`probe:\n  ${serverLines.join("\n  ")}`);
if (arg("--devtools", null)) await cdp("Target.closeTarget", { targetId }).catch(() => {});
browser.close();
web.close();
process.exit(result.error ? 1 : 0);
