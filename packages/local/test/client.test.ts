import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { test } from "node:test";
import { LocalClient, LocalError, readAll, type ChildHandle, type DisplayState, type LocalClientOptions, type RemoteMode } from "../src/index.js";
import { deadPort, push, quiet, startStandIn, waitFor } from "./stand-in.js";

const URL_ = "https://example.com/get";

async function appClient(extra: Partial<LocalClientOptions> = {}, status: Record<string, unknown> = {}) {
  const s = await startStandIn(status);
  const states: DisplayState[][] = [];
  const client = new LocalClient({
    socketPath: "/nonexistent/child.sock",
    platform: "darwin",
    childPath: null,
    app: { socketPath: "/nonexistent/app.sock", endpoint: s.endpoint, downloadUrl: URL_, find: () => null },
    log: quiet,
    eventsRetryMs: 20,
    onState: (st) => states.push(st),
    ...extra,
  });
  return { s, client, states };
}

test("app: a socket answering as YoyoControl with api in range is used; its /events state is forwarded once per change", async () => {
  const { s, client, states } = await appClient();
  s.eventLines.push({ type: "state", states: [{ display: 1, main: true, phase: "ready", since: 1 }], console: { locked: false } });
  try {
    const st = await client.status();
    assert.equal(st.app, "YoyoControl");
    assert.deepEqual(client.identity, { mode: "app", version: "1.0.5", build: "105", api: 1 });
    assert.equal(client.connected, true);
    assert.equal(client.attached, true);
    await waitFor(() => states.length === 1, "the first state");
    push(s, { type: "state", states: [{ display: 1, main: true, phase: "ready", since: 99 }], console: { locked: false } });
    push(s, { type: "ping" });
    push(s, { type: "state", states: [{ display: 1, main: true, phase: "reconnecting", reason: "timeout", since: 100 }], console: { locked: true } });
    await waitFor(() => states.length === 2, "the changed state");
    assert.equal(states[1]![0]!.phase, "reconnecting");
    assert.deepEqual(client.console, { locked: true });
  } finally {
    client.stop();
    await s.close();
  }
});

test("app: too old → 503 with an install hint (outdated, its version); too new → 503; messages can be the caller's", async () => {
  const { s, client } = await appClient({ messages: { outdated: (v, api, url, r) => `old ${v} ${api} ${url} ${r.min}-${r.max}` } }, { api: 0, version: "0.9" });
  try {
    await assert.rejects(client.ensure(), (e: unknown) => {
      assert.ok(e instanceof LocalError);
      assert.equal(e.status, 503);
      assert.equal(e.message, `old 0.9 0 ${URL_} 1-1`);
      assert.deepEqual(e.body.install, { reason: "outdated", url: URL_, version: "0.9" });
      return true;
    });
    s.status.api = 2;
    await assert.rejects(client.ensure(), /speaks API 2, newer than this program knows \(1…1\)/);
  } finally {
    client.stop();
    await s.close();
  }
});

test("app: nothing (or something else) answering and nothing installed → not-installed with the download URL", async () => {
  const port = await deadPort();
  const client = new LocalClient({ socketPath: "/nonexistent/c.sock", platform: "darwin", childPath: null, log: quiet, app: { socketPath: "/nonexistent/a.sock", endpoint: { host: "127.0.0.1", port }, downloadUrl: URL_, find: () => null } });
  await assert.rejects(client.ensure(), (e: unknown) => e instanceof LocalError && e.status === 503 && (e.body.install as { reason: string }).reason === "not-installed" && e.message.includes(URL_));
  const { s, client: c2 } = await appClient({}, { app: "SomethingElse" });
  try {
    await assert.rejects(c2.ensure(), /not installed/);
  } finally {
    c2.stop();
    await s.close();
  }
});

test("app: an installed app is opened and used once it answers; one that never answers is not opened again until it changes", async () => {
  const port = await deadPort();
  let launches = 0;
  let stamp = "a";
  let live: Awaited<ReturnType<typeof startStandIn>> | null = null;
  const client = new LocalClient({
    socketPath: "/nonexistent/c.sock",
    platform: "darwin",
    childPath: null,
    log: quiet,
    app: {
      socketPath: "/nonexistent/a.sock",
      endpoint: { host: "127.0.0.1", port },
      downloadUrl: URL_,
      find: () => "/Applications/Yoyo Control.app",
      stamp: () => stamp,
      launchTimeoutMs: 300,
      launch: async () => {
        launches++;
        // the second time it is a build that answers
        if (launches === 2) live = await startStandIn({}, port);
      },
    },
  });
  try {
    await assert.rejects(client.ensure(), (e: unknown) => e instanceof LocalError && (e.body.install as { reason: string }).reason === "outdated" && /did not answer/.test(e.message));
    assert.equal(launches, 1);
    await assert.rejects(client.ensure(), /did not answer/);
    assert.equal(launches, 1, "a silent app is not opened again");
    stamp = "b";
    await client.ensure();
    assert.equal(launches, 2);
    assert.equal(client.identity?.version, "1.0.5");
  } finally {
    client.stop();
    await (live as Awaited<ReturnType<typeof startStandIn>> | null)?.close();
  }
});

test("automation: ordered, with the label; an older build gets /agent-control; Esc on /events turns it off and calls onAbort", async () => {
  const aborts: string[] = [];
  const { s, client } = await appClient({ onAbort: (r) => aborts.push(r) });
  try {
    client.setAutomation(true, "Robot");
    assert.equal(client.automationActive, true);
    await client.automationSettled();
    assert.deepEqual(s.requests.find((r) => r.path === "/automation")?.body, { active: true, label: "Robot" });
    s.missing.add("/automation");
    client.setAutomation(false, "Robot");
    await client.automationSettled();
    assert.deepEqual(s.requests.filter((r) => r.path === "/agent-control").map((r) => r.body), [{ active: false }]);
    client.setAutomation(true);
    await client.automationSettled();
    await waitFor(() => s.events.length > 0, "the /events subscription");
    push(s, { type: "abort", reason: "esc" });
    await waitFor(() => aborts.length === 1, "the abort");
    assert.equal(client.automationActive, false);
  } finally {
    client.stop();
    await s.close();
  }
});

test("other /events lines reach onEvent; clipboard lines onClipboard", async () => {
  const lines: unknown[] = [];
  const clips: unknown[] = [];
  const { s, client } = await appClient({ onEvent: (l) => lines.push(l), onClipboard: (c) => clips.push(c) });
  try {
    await client.ensure();
    await waitFor(() => s.events.length > 0, "the /events subscription");
    push(s, { type: "control", control: { controller: "none" } });
    push(s, { type: "clipboard", changeCount: 3, kind: "text" });
    push(s, "not an object");
    await waitFor(() => lines.length === 1 && clips.length === 1, "the lines");
    assert.deepEqual(lines[0], { type: "control", control: { controller: "none" } });
  } finally {
    client.stop();
    await s.close();
  }
});

test("stream / audio pass the viewer's Accept on; ack keeps a 404; input's stale; frame reads its headers", async () => {
  const { s, client } = await appClient();
  s.routes.set("/stream", (_req, res) => {
    res.writeHead(200, { "content-type": "application/vnd.yoyo-control.stream; boundary=frame" });
    res.end("--frame\r\n");
  });
  s.routes.set("/audio", (_req, res) => {
    res.writeHead(503, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "audio is off" }));
  });
  s.routes.set("/stream/ack", (_req, res, body) => {
    const known = (body as { stream: string }).stream === "abcdefgh";
    res.writeHead(known ? 200 : 404, { "content-type": "application/json" });
    res.end(JSON.stringify(known ? { ok: true, net: { grade: "good", reasons: [] } } : { error: "no such stream" }));
  });
  s.routes.set("/frame", (_req, res) => {
    res.writeHead(200, { "content-type": "image/jpeg", "x-frame-width": "800", "x-frame-height": "500", "x-display": "1", "x-crop": "0,0,0.5,0.5" });
    res.end("JPEG");
  });
  try {
    const res = await client.stream({ stream: "abcdefgh", ack: 1, codecs: "h264" }, new AbortController().signal, "application/vnd.yoyo-control.stream");
    assert.equal(String(await readAll(res.body)), "--frame\r\n");
    const req = s.requests.find((r) => r.path.startsWith("/stream?"))!;
    assert.equal(req.path, "/stream?stream=abcdefgh&ack=1&codecs=h264");
    assert.equal(req.headers.accept, "application/vnd.yoyo-control.stream");
    await assert.rejects(client.audio(new AbortController().signal), (e: unknown) => e instanceof LocalError && e.status === 503 && e.message === "audio is off");
    assert.deepEqual(await client.ack({ stream: "abcdefgh", seq: 1 }), { status: 200, body: { ok: true, net: { grade: "good", reasons: [] } } });
    assert.deepEqual(await client.ack({ stream: "zzzzzzzz", seq: 1 }), { status: 404, body: { error: "no such stream" } });
    await assert.rejects(client.ack({ stream: "x", seq: 1 }), (e: unknown) => e instanceof LocalError && e.status === 400);
    assert.deepEqual(await client.input({ type: "move", x: 0, y: 0, seq: 1 }), { ok: true, stale: true });
    assert.deepEqual(await client.input({ type: "click", x: 0, y: 0 }), { ok: true });
    const f = await client.frame({ maxWidth: 800, visible: ["com.a"], hide: "com.me*", crop: { x: 0, y: 0, w: 0.5, h: 0.5 } });
    assert.deepEqual({ ...f, jpeg: String(f.jpeg) }, { jpeg: "JPEG", width: 800, height: 500, display: 1, crop: { x: 0, y: 0, w: 0.5, h: 0.5 } });
    assert.ok(s.requests.some((r) => r.path === "/frame?maxWidth=800&visible=com.a&hide=com.me*&crop=0%2C0%2C0.5%2C0.5"));
  } finally {
    client.stop();
    await s.close();
  }
});

test("app gone: its last states turn reconnecting/helper-restart; the next use looks again", async () => {
  const { s, client, states } = await appClient();
  s.eventLines.push({ type: "state", states: [{ display: 1, main: true, phase: "ready", since: 1, detail: "x" }], console: null });
  let gone = 0;
  try {
    (client as unknown as { opts: LocalClientOptions }).opts.onGone = () => gone++;
    await client.ensure();
    await waitFor(() => states.length === 1, "the first state");
    await s.close();
    await waitFor(() => states.length === 2, "the made-up state");
    assert.deepEqual({ ...states[1]![0]!, since: 0 }, { display: 1, main: true, phase: "reconnecting", reason: "helper-restart", since: 0 });
    assert.equal(gone, 1);
    assert.equal(client.connected, false);
  } finally {
    client.stop();
  }
});

class FakeChild extends EventEmitter implements ChildHandle {
  killed = false;
  kill(): boolean {
    this.killed = true;
    queueMicrotask(() => this.emit("exit", null, "SIGTERM"));
    return true;
  }
}

test("child: spawned with --socket / --exit-on-stdin-eof; exit 75 respawns at once, another exit backs off", async () => {
  const s = await startStandIn({ app: undefined });
  const spawned: { path: string; args: string[]; child: FakeChild }[] = [];
  let t = 1_000_000;
  const client = new LocalClient({
    socketPath: "/tmp/x/screen.sock",
    endpoint: s.endpoint,
    platform: "darwin",
    childPath: process.execPath,
    now: () => t,
    log: quiet,
    spawn: (path, args) => {
      const child = new FakeChild();
      spawned.push({ path, args, child });
      return child;
    },
  });
  try {
    await client.ensure();
    assert.deepEqual(spawned[0]!.args, ["--socket", "/tmp/x/screen.sock", "--exit-on-stdin-eof"]);
    assert.deepEqual(client.identity, { mode: "child", version: "1.0.5", build: "105", api: 1 });
    spawned[0]!.child.emit("exit", 75, null);
    await client.ensure();
    assert.equal(spawned.length, 2, "respawned at once");
    spawned[1]!.child.emit("exit", 1, null);
    await assert.rejects(client.ensure(), /the screen helper failed \(exit code 1\); retrying in 1 s/);
    t += 1500;
    await client.ensure();
    assert.equal(spawned.length, 3);
  } finally {
    client.stop();
    await s.close();
  }
});

test("unavailable without macOS, or with nothing to run (the caller's words)", async () => {
  const linux = new LocalClient({ socketPath: "/x", platform: "linux", log: quiet, messages: { unsupportedPlatform: "no mac here" } });
  assert.equal(linux.unavailableReason(), "no mac here");
  await assert.rejects(linux.ensure(), (e: unknown) => e instanceof LocalError && e.status === 503 && e.message === "no mac here");
  const none = new LocalClient({ socketPath: "/x", platform: "darwin", childPath: null, log: quiet });
  assert.match(none.unavailableReason() ?? "", /looked for nothing/);
  assert.equal(none.maybeThere(), false);
});

test("remote: the endpoint's token on every request; a refused token is rekeyed once; something else answering → rekey", async () => {
  const s = await startStandIn({ app: "yoyo-linux", platform: "linux" });
  const modes: RemoteMode[] = [];
  let token = "t1";
  let held = 0;
  s.routes.set("/windows", (req, res) => {
    const ok = req.headers.authorization === "Bearer t2";
    res.writeHead(ok ? 200 : 401, { "content-type": "application/json" });
    res.end(JSON.stringify(ok ? { apps: [] } : { error: "bad token" }));
  });
  s.routes.set("/stream", (_req, res) => {
    res.writeHead(200, { "content-type": "application/vnd.yoyo-control.stream; boundary=frame" });
    res.end("x");
  });
  const client = new LocalClient({
    socketPath: "/x",
    log: quiet,
    remote: {
      app: "yoyo-linux",
      connect: async (mode) => {
        modes.push(mode);
        if (mode === "rekey") token = "t2";
        return { ...s.endpoint, token };
      },
      hold: () => {
        held++;
        return () => held--;
      },
    },
  });
  try {
    assert.equal(client.unavailableReason(), null);
    assert.equal((await client.status()).platform, "linux");
    assert.equal(s.requests.at(-1)!.headers.authorization, "Bearer t1");
    assert.deepEqual(await client.windows(), { apps: [], windows: [], focused: null });
    assert.deepEqual(modes, ["known", "rekey"]);
    const res = await client.stream({}, new AbortController().signal);
    assert.equal(held, 1);
    await readAll(res.body);
    await waitFor(() => held === 0, "the hold let go");
    s.status.app = "other";
    client.release();
    await assert.rejects(client.ensure(), /answers as other api 1, not yoyo-linux api 1…1/);
    s.status.app = "yoyo-linux";
    await client.ensure();
    assert.equal(modes.at(-1), "rekey");
  } finally {
    client.stop();
    await s.close();
  }
});
