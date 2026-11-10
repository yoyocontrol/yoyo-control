// End-to-end in a real browser: <yoyo-screen> in headless Chrome with a backend of two ways chosen by screen-ui's
// Connector — the demo's in-memory computer over "HTTP" (the way that always works) and a uu Link session dialed with
// @yoyocontrol/link-web against `uu-link-probe serve-rtc --screen-clip` (real H.264 from this Chrome's encoder, looped
// by the probe, decoded by screen-web's VideoStream on the link route). Checks, in order:
//
//   1. the page goes on the link and its pictures decode (the decoder's verdicts go back as frameDecoded);
//   2. the probe is killed: the page falls back to the HTTP way and its stream plays there;
//   3. the probe comes back (same identity, ports and token): the connector's retry moves the page back to the link.
//
//   npm -w packages/screen-ui run e2e -- [--probe <uu-link-probe>] [--chrome <path>] [--retry-ms 3000]
//
// The probe defaults to link/target/release/uu-link-probe (cargo build --release -p uu-link-probe). Chrome runs
// headless with its own temporary profile (outside a sandbox that forbids its own). Prints the timings as JSON.

import { spawn } from "node:child_process";
import { generateKeyPairSync } from "node:crypto";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
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
const probeBin = arg("--probe", join(repo, "link", "target", "release", "uu-link-probe"));
const chrome = arg("--chrome", process.platform === "darwin" ? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" : "google-chrome");
const retryIntervalMs = Number(arg("--retry-ms", "3000"));

const out = mkdtempSync(join(tmpdir(), "screen-ui-e2e-"));
const children = new Set();
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

function start(cmd, args, onLine) {
  const c = spawn(cmd, args, { stdio: ["ignore", "pipe", "pipe"] });
  children.add(c);
  c.on("exit", () => children.delete(c));
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
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// 1. the page: screen-ui, screen-web and link-web from their sources
const src = (p) => join(repo, "packages", p, "src", "index.ts");
await build({
  entryPoints: [join(here, "page.ts")],
  bundle: true,
  format: "esm",
  target: "es2022",
  outfile: join(out, "page.js"),
  logLevel: "warning",
  alias: { "@yoyocontrol/screen-web": src("screen-web"), "@yoyocontrol/link-web": src("link-web"), "@yoyocontrol/screen-ui": src("screen-ui") },
});
mkdirSync(join(out, "wasm"));
copyFileSync(join(repo, "packages", "link-web", "src", "wasm", "uu_link_wasm_bg.wasm"), join(out, "wasm", "uu_link_wasm_bg.wasm"));
const html = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>screen-ui e2e</title><script type="module" src="/page.js"></script>`;
const types = { ".js": "text/javascript", ".wasm": "application/wasm" };
let signalUrl = "";
const web = createServer(async (req, res) => {
  const path = (req.url ?? "/").split("?")[0];
  if (path === "/") return res.writeHead(200, { "content-type": "text/html" }).end(html);
  if (path === "/signal" && req.method === "POST") {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    try {
      const r = await fetch(signalUrl, { method: "POST", headers: { "content-type": "application/json" }, body: Buffer.concat(chunks) });
      return res.writeHead(r.status, { "content-type": "application/json" }).end(await r.text());
    } catch {
      return res.writeHead(502).end("the probe is down");
    }
  }
  let body;
  try {
    body = readFileSync(join(out, path));
  } catch {
    return res.writeHead(404).end();
  }
  res.writeHead(200, { "content-type": types[path.slice(path.lastIndexOf("."))] ?? "application/octet-stream" }).end(body);
});
const webPort = await free();
await new Promise((r) => web.listen(webPort, "127.0.0.1", r));

// 2. Chrome over CDP
const devtools = await new Promise((resolve, reject) => {
  const t = setTimeout(() => reject(new Error("Chrome didn't start")), 20_000);
  start(chrome, ["--headless=new", `--user-data-dir=${join(out, "chrome")}`, "--remote-debugging-port=0", "--no-first-run", "--no-default-browser-check", "--disable-background-networking", "--autoplay-policy=no-user-gesture-required", "about:blank"], (line) => {
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
  } else if (m.method === "Runtime.consoleAPICalled" && (m.params.type === "error" || m.params.type === "warning")) {
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
const evaluate = async (expression, timeoutMs = 30_000) => {
  const r = await cdp("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true, timeout: timeoutMs }, sessionId);
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
  return r.result.value;
};
for (let i = 0; i < 100 && (await evaluate("typeof e2e")) !== "object"; i++) await sleep(100);

// 3. the probe's screen clip (this Chrome's encoder), its identity (kept across the restart), the probe
writeFileSync(join(out, "clip.bin"), Buffer.from(await evaluate("e2e.makeClip()"), "base64"));
const jwk = generateKeyPairSync("ec", { namedCurve: "P-256" }).privateKey.export({ format: "jwk" });
const b64 = (s) => Buffer.from(s, "base64url");
writeFileSync(join(out, "identity"), Buffer.concat([Buffer.from([4]), b64(jwk.x), b64(jwk.y), b64(jwk.d)]));
const [linkPort, rtcPort, signalPort] = [await free(), await free(), await free()];
const probeLog = [];
let probe = null;
async function startProbe() {
  const args = ["serve-rtc", "--port", String(linkPort), "--rtc-port", String(rtcPort), "--signal", String(signalPort), "--identity", join(out, "identity"), "--screen-clip", join(out, "clip.bin")];
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(`the probe didn't start:\n${probeLog.join("\n")}`)), 20_000);
    const got = {};
    probe = start(probeBin, args, (line) => {
      probeLog.push(line);
      const m = /^(fingerprint|token|signal) (\S+)/.exec(line);
      if (m) got[m[1]] = m[2];
      if (got.fingerprint && got.token && got.signal) {
        clearTimeout(t);
        resolve(got);
      }
    });
  });
}
const info = await startProbe();
signalUrl = info.signal;

// 4. the steps
const state = () => evaluate("e2e.state()");
async function waitFor(what, ok, timeoutMs) {
  const t = performance.now();
  for (;;) {
    const s = await state();
    if (ok(s)) return { ms: Math.round(performance.now() - t), state: s };
    if (performance.now() - t > timeoutMs) throw new Error(`timed out waiting for ${what}: ${JSON.stringify(s, null, 2)}`);
    await sleep(100);
  }
}
const result = { retryIntervalMs };
let failure = null;
try {
  await evaluate(`e2e.mount(${JSON.stringify({ signal: `http://127.0.0.1:${webPort}/signal`, fingerprint: info.fingerprint, credential: `Bearer ${info.token}`, retryIntervalMs })})`);
  // 1. on the link, its pictures decoding
  const onLink = await waitFor("the link's pictures", (s) => s.route === "link" && s.linkDecodedOk >= 30, 20_000);
  result.toLinkPicturesMs = onLink.ms;
  await sleep(2000);
  const a = await state();
  result.linkSteady = { decodedOk: a.linkDecodedOk - onLink.state.linkDecodedOk, decodedFailed: a.linkDecodedFailed, fps: Math.round(((a.linkDecodedOk - onLink.state.linkDecodedOk) / 2) * 10) / 10 };
  if (result.linkSteady.decodedOk < 40 || a.linkDecodedFailed > 0) throw new Error(`the link's video didn't play: ${JSON.stringify(result.linkSteady)}`);
  // the stats line: screen-web's (decode ms, playout, the link's own line)
  result.linkStats = a.stats;
  if (!/h264 · \d+ fps · \d+ KB\/s · [\d.]+ ms · link lan/.test(a.stats ?? "") || !/smooth · /.test(a.stats) || !/\blan \w+ rtt /.test(a.stats)) throw new Error(`the stats line on the link: ${a.stats}`);
  // 2. the probe dies: back to HTTP
  probe.kill("SIGKILL");
  const acks0 = a.tunnelAcks;
  const back = await waitFor("the fallback's pictures", (s) => s.route === "tunnel" && s.tunnelAcks >= acks0 + 30, 40_000);
  result.fallbackMs = back.ms;
  await sleep(2500);
  result.tunnelStats = (await state()).stats;
  if (!/ · tunnel · /.test(result.tunnelStats ?? "") || !/net good/.test(result.tunnelStats)) throw new Error(`the stats line on HTTP: ${result.tunnelStats}`);
  // 3. the probe is back: the retry finds the link again
  await startProbe();
  const ok0 = back.state.linkDecodedOk;
  const again = await waitFor("the link again", (s) => s.route === "link" && s.linkDecodedOk >= ok0 + 30, retryIntervalMs + 20_000);
  result.backToLinkMs = again.ms;
  result.final = { ...again.state, log: undefined, stats: undefined };
  result.log = again.state.log;
} catch (e) {
  failure = e instanceof Error ? e.message : String(e);
}
console.log(JSON.stringify({ ...result, ...(failure ? { error: failure } : {}) }, null, 2));
if (failure) console.log(`probe:\n  ${probeLog.filter((l) => /session|rtc|error/i.test(l)).join("\n  ")}`);
browser.close();
web.close();
process.exit(failure ? 1 : 0);
