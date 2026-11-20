// The secure-desktop broker's client (broker.mjs) and the Windows server over it: a fake broker on a local socket
// stands in for yoyo-broker's pipe (windows/broker.c, docs/BROKER.md) — its answers, the install of our version, the
// video helper's records relayed as frames, input lines as the helper's stdin, refusals falling back to the user's
// helpers, and what /status says.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { request } from "node:http";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";
import { Broker } from "../broker.mjs";
import { PLATFORMS } from "../platform.mjs";
import { VERSION, YoyoLinux } from "../server.mjs";
import { fakeSpawn, frameRecord, record } from "./fakes.mjs";

const dir = mkdtempSync(join(tmpdir(), "yoyo-broker-"));
const PIPE = join(dir, "broker.sock");

function frame(kind, body = Buffer.alloc(0)) {
  const head = Buffer.alloc(5);
  head[0] = kind;
  head.writeUInt32BE(body.length, 1);
  return Buffer.concat([head, body]);
}

/** The fake broker: `state.answer` (null: serve), `state.installed` versions, the requests and input lines it saw. */
const state = { answer: null, installed: new Set(), requests: [], inputLines: [], videoArgs: [] };
const broker = createServer((sock) => {
  let buf = "";
  let line = null;
  sock.on("error", () => {});
  sock.on("data", (d) => {
    if (line === null) {
      buf += d.toString("latin1");
      const i = buf.indexOf("\n");
      if (i < 0) return;
      line = buf.slice(0, i);
      const rest = Buffer.from(buf.slice(i + 1), "latin1");
      state.requests.push(line);
      start(sock, line);
      if (rest.length) sock.emit("stdin", rest);
      return;
    }
    sock.emit("stdin", d);
  });
});

function start(sock, line) {
  const [proto, version, role, ...args] = line.split(" ");
  const answer = (s) => sock.write(frame(0, Buffer.from(s)));
  if (proto !== "yoyo-broker/1") return answer("err bad-request"), sock.end();
  if (state.answer) return answer(state.answer), sock.end();
  if (role === "status") return answer(`ok broker 1 floor - installed ${state.installed.has(version) ? "yes" : "no"}`), sock.end();
  if (role === "install") {
    state.installed.add(version);
    return answer(`ok ${version}`), sock.end();
  }
  if (!state.installed.has(version)) return answer("err no-version"), sock.end();
  answer("ok");
  if (role === "input") {
    let pending = "";
    sock.on("stdin", (d) => {
      pending += d.toString();
      for (let i; (i = pending.indexOf("\n")) >= 0; pending = pending.slice(i + 1)) state.inputLines.push(pending.slice(0, i));
    });
    return;
  }
  // video: the records of a helper on UAC's prompt (seen: the broker's), a frame per E
  state.videoArgs.push(args);
  const hello = Buffer.alloc(5);
  hello.writeUInt16BE(1280, 0);
  hello.writeUInt16BE(832, 2);
  hello[4] = 0;
  sock.write(frame(1, Buffer.concat([record("D", Buffer.from([1])), record("H", hello), record("C")])));
  // stderr cut anywhere, as the relay does
  sock.write(frame(2, Buffer.from("y")));
  sock.write(frame(2, Buffer.from("oyo-winvideo: an administrator prompt (UAC) is showing\nyoyo-winvi")));
  sock.write(frame(2, Buffer.from("deo: second line\n")));
  let pending = "";
  sock.on("stdin", (d) => {
    pending += d.toString();
    for (let i; (i = pending.indexOf("\n")) >= 0; pending = pending.slice(i + 1)) {
      const l = pending.slice(0, i);
      if (l === "Q") {
        const code = Buffer.alloc(4);
        sock.write(frame(3, code));
        return sock.end();
      }
      const m = /^E (\d)/.exec(l);
      if (m) sock.write(frame(1, frameRecord({ key: m[1] === "1", changed: true })));
    }
  });
}

const fake = fakeSpawn();
const localSpawns = [];
const spawn = (path, args, opts) => {
  const file = path.split(/[\\/]/).pop();
  localSpawns.push(file);
  const as = { "yoyo-winvideo.exe": "/x/yoyo-x11video", "yoyo-wininput.exe": "xdotool", "yoyo-winclip.exe": "/x/yoyo-x11clip", "yoyo-winaudio.exe": "/x/yoyo-pa-opus", "yoyo-winwindows.exe": "/x/yoyo-x11windows" }[file];
  return fake.spawn(as ?? path, args, opts);
};
const TOKEN = "b".repeat(64);
const logs = [];
const svc = new YoyoLinux({ token: TOKEN, platform: PLATFORMS.windows, env: { ...process.env, YOYO_BROKER_PIPE: PIPE }, spawnFn: spawn, logLine: (l) => logs.push(l), brokerDir: "C:\\pkg dir\\broker" });
let port;

before(async () => {
  await new Promise((r) => broker.listen(PIPE, r));
  port = (await svc.listen(0, "127.0.0.1")).port;
  await svc.broker.probe(true);
});
after(() => {
  svc.close();
  broker.close();
  rmSync(dir, { recursive: true, force: true });
});

function call(method, path, body) {
  return new Promise((resolve, reject) => {
    const b = body === undefined ? undefined : Buffer.from(JSON.stringify(body));
    const req = request({ host: "127.0.0.1", port, method, path, headers: { authorization: `Bearer ${TOKEN}`, ...(b ? { "content-type": "application/json", "content-length": b.length } : {}) } }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const buf = Buffer.concat(chunks);
        let json;
        try {
          json = JSON.parse(buf.toString());
        } catch {}
        resolve({ status: res.statusCode, json, buf });
      });
    });
    req.on("error", reject);
    req.end(b);
  });
}

const until = async (pred, what) => {
  for (let i = 0; i < 200; i++) {
    if (pred()) return;
    await new Promise((r) => setTimeout(r, 10));
  }
  assert.fail(`timed out: ${what}`);
};

test("not there: not-installed, and the server's own helpers", async () => {
  const b = new Broker({ version: "9.9.9", packageDir: null, pipe: join(dir, "nobody.sock") });
  assert.equal(await b.probe(true), false);
  assert.deepEqual(b.json(), { ok: false, reason: "not-installed" });
});

test("our version missing: installed from the package's folder, then ready", () => {
  assert.ok(state.requests.includes(`yoyo-broker/1 ${VERSION} install C:\\pkg dir\\broker`), state.requests.join(" | "));
  assert.equal(svc.broker.ready, true);
  assert.deepEqual(svc.broker.json(), { ok: true, version: VERSION });
});

test("/status: features.secureDesktop and secureDesktopHelper; the size and the secure desktop through the broker", async () => {
  const st = (await call("GET", "/status")).json;
  assert.equal(st.features.secureDesktop, true);
  assert.deepEqual(st.secureDesktopHelper, { ok: true, version: VERSION });
  assert.equal(st.ok, true);
  assert.deepEqual([st.displays[0].width, st.displays[0].height], [1280, 832]);
  assert.deepEqual(st.console, { locked: false, secureDesktop: "admin-prompt" });
  assert.ok(state.videoArgs.some((a) => a.join(" ") === "--fps 1"), "the size probe went through the broker");
  // the user's windows aren't on the screen while it shows
  assert.deepEqual((await call("GET", "/windows")).json.windows, []);
  assert.ok(!localSpawns.includes("yoyo-winvideo.exe"), "no video helper of the user");
  // its stderr as whole lines
  await until(() => logs.some((l) => l.includes("second line")), "the helper's lines");
  assert.ok(logs.includes("video helper: yoyo-winvideo: an administrator prompt (UAC) is showing"), logs.join(" | "));
  assert.ok(!logs.includes("video helper: y"));
});

test("input: the xdotool lines are the broker's input helper's stdin", async () => {
  assert.deepEqual((await call("POST", "/input", { type: "click", x: 0.5, y: 0.5 })).json, { ok: true });
  await until(() => state.inputLines.some((l) => l.startsWith("mousemove 640 416")), "the move");
  assert.ok(state.requests.some((r) => r === `yoyo-broker/1 ${VERSION} input`));
  assert.ok(!localSpawns.includes("yoyo-wininput.exe"));
});

test("a refusal: that helper fails, the next ones are the user's, the reason is on /status", async () => {
  state.answer = "err not-console";
  svc.sizeAt = 0;
  const st = (await call("GET", "/status")).json;
  // the probe's helper was refused; the display is asked again on the next status
  assert.deepEqual(st.secureDesktopHelper, { ok: false, reason: "not-console" });
  assert.equal(st.features.secureDesktop, false);
  svc.sizeAt = 0;
  const again = (await call("GET", "/status")).json;
  assert.equal(again.ok, true);
  assert.ok(localSpawns.includes("yoyo-winvideo.exe"), "the user's video helper");
  // the broker answers again (after its 10 s): ready, and the input helper is started anew through it
  state.answer = null;
  assert.equal(await svc.broker.probe(true), true);
  assert.deepEqual((await call("GET", "/status")).json.secureDesktopHelper, { ok: true, version: VERSION });
});
