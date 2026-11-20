// Windows' console lock (console.mjs): the session watcher, POST /console/lock, POST /console/unlock through an input
// helper (the broker's, faked here), and the routes on the server (Windows only, never for a paired phone).
import assert from "node:assert/strict";
import { request } from "node:http";
import { test } from "node:test";
import { checkPassword, passwordLine, WindowsConsole } from "../console.mjs";
import { PLATFORMS } from "../platform.mjs";
import { YoyoLinux } from "../server.mjs";
import { fakeProcess, fakeSpawn } from "./fakes.mjs";

const until = async (cond, ms = 2000) => {
  const t0 = Date.now();
  while (!cond()) {
    if (Date.now() - t0 > ms) throw new Error("timed out");
    await new Promise((r) => setTimeout(r, 10));
  }
};

/** An input helper that answers `unlock <answer>` after the password line (kept in `got`). */
function fakeInput(answer, got = {}) {
  let want = false;
  const p = fakeProcess((line, proc) => {
    if (line === "unlock") return (want = true);
    if (want) {
      got.password = line;
      want = false;
      if (answer) proc.stdout.write(`unlock ${answer}\n`);
      else proc.exit(1);
    }
  });
  return p;
}

function setup({ input = () => null, lockWaitMs = 300 } = {}) {
  const { spawn, state } = fakeSpawn();
  const changes = [];
  const c = new WindowsConsole({ windowsHelper: "C:\\yoyo\\yoyo-winwindows.exe", spawnFn: spawn, inputHelper: async () => input(), onChange: () => changes.push(c.locked), lockWaitMs, retryMs: 20 });
  return { c, state, changes };
}

test("checkPassword and passwordLine: a non-empty string without control characters, as U<hex> words", () => {
  assert.equal(checkPassword({ password: "1234" }), null);
  assert.match(checkPassword({}), /password/);
  assert.match(checkPassword({ password: "" }), /password/);
  assert.match(checkPassword({ password: 1234 }), /password/);
  assert.match(checkPassword({ password: "a\nb" }), /control/);
  assert.match(checkPassword({ password: "x".repeat(1025) }), /too long/);
  assert.equal(passwordLine("12a中"), "U31 U32 U61 U4e2d\n");
});

test("the watcher reports the session's lock, and starts again when it ends", async () => {
  const { c, state, changes } = setup();
  assert.equal(c.locked, null);
  c.start();
  await until(() => c.locked === false);
  state.setSession("locked");
  await until(() => c.locked === true);
  state.sessionWatches[0].exit(1);
  await until(() => c.locked === null);
  await until(() => state.sessionWatches.length === 2 && c.locked === true);
  assert.deepEqual(changes, [false, true, null, true]);
  c.stop();
});

test("lock: LockWorkStation, then the watcher sees it; already locked does nothing; no lock is a timeout", async () => {
  const { c, state } = setup();
  c.start();
  await until(() => c.locked === false);
  assert.deepEqual(await c.lock(), { ok: true, locked: true });
  assert.equal(state.locks, 1);
  assert.deepEqual(await c.lock(), { ok: true, locked: true, already: true });
  assert.equal(state.locks, 1);
  state.setSession("unlocked");
  await until(() => c.locked === false);
  state.lockIgnored = true;
  assert.deepEqual(await c.lock(), { ok: false, locked: false, reason: "timeout" });
  c.stop();
});

test("unlock: the password on the helper's stdin, its answer back; never typed when not locked or no broker", async () => {
  const got = {};
  let helpers = 0;
  let answer = "ok";
  const { c, state } = setup({ input: () => (helpers++, fakeInput(answer, got)) });
  c.start();
  await until(() => c.locked === false);
  assert.deepEqual(await c.unlock("1234"), { ok: true, unlocked: true, already: true });
  assert.equal(helpers, 0, "not locked: no helper, nothing typed");
  state.setSession("locked");
  await until(() => c.locked === true);
  assert.deepEqual(await c.unlock("1234"), { ok: true, unlocked: true });
  assert.equal(got.password, "U31 U32 U33 U34");
  assert.equal(c.locked, false, "the answer counts at once");
  state.setSession("locked");
  await until(() => c.locked === true);
  answer = "wrong-password";
  assert.deepEqual(await c.unlock("0000"), { ok: false, unlocked: false, reason: "wrong-password" });
  answer = null;
  assert.deepEqual(await c.unlock("0000"), { ok: false, unlocked: false, reason: "failed" }, "the helper died");
  c.stop();
  const none = setup();
  none.c.locked = true;
  assert.deepEqual(await none.c.unlock("1234"), { ok: false, unlocked: false, reason: "no-secure-desktop" });
});

test("two unlocks at once: one after the other, the second sees the first's result", async () => {
  let helpers = 0;
  const { c, state } = setup({ input: () => (helpers++, fakeInput("ok")) });
  state.session = "locked";
  c.start();
  await until(() => c.locked === true);
  const [a, b] = await Promise.all([c.unlock("1"), c.unlock("1")]);
  assert.deepEqual(a, { ok: true, unlocked: true });
  assert.deepEqual(b, { ok: true, unlocked: true, already: true });
  assert.equal(helpers, 1);
  c.stop();
});

function post(port, path, body) {
  return new Promise((resolve, reject) => {
    const data = body === undefined ? "" : JSON.stringify(body);
    const r = request({ host: "127.0.0.1", port, path, method: "POST", headers: { Authorization: "Bearer t".padEnd(23, "t"), "Content-Type": "application/json", "Content-Length": Buffer.byteLength(data) } }, (res) => {
      let s = "";
      res.on("data", (d) => (s += d));
      res.on("end", () => resolve({ status: res.statusCode, json: JSON.parse(s) }));
    });
    r.on("error", reject);
    r.end(data);
  });
}

test("the routes: Windows only; a bad body is 400; /status.console.locked follows the session", async () => {
  const token = "t".repeat(16);
  const linux = new YoyoLinux({ token, platform: PLATFORMS.linux, spawnFn: fakeSpawn().spawn, logLine: () => {} });
  const lp = (await linux.listen(0, "127.0.0.1")).port;
  assert.equal((await post(lp, "/console/lock")).status, 404);
  linux.close();

  const { spawn, state } = fakeSpawn();
  const win = new YoyoLinux({ token, platform: PLATFORMS.windows, env: { ...process.env, YOYO_BROKER: "off" }, spawnFn: spawn, logLine: () => {} });
  const wp = (await win.listen(0, "127.0.0.1")).port;
  await until(() => win.winConsole.locked === false);
  assert.equal((await post(wp, "/console/unlock", { password: "" })).status, 400);
  assert.deepEqual((await post(wp, "/console/lock")).json, { ok: true, locked: true });
  await win.screenSize(0).catch(() => {});
  assert.equal(win.console()?.locked ?? true, true);
  assert.deepEqual((await post(wp, "/console/unlock", { password: "1234" })).json, { ok: false, unlocked: false, reason: "no-secure-desktop" }, "no broker: nothing to type with");
  state.setSession("unlocked");
  await until(() => win.winConsole.locked === false);
  win.close();
});
