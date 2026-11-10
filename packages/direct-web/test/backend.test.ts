import assert from "node:assert/strict";
import { test } from "node:test";
import type { ScreenEvent } from "@yoyocontrol/screen-ui";
import { RequestError } from "@yoyocontrol/screen-web";
import { DirectBackend } from "../src/backend.js";
import { MacConnection } from "../src/connection.js";
import { DirectError } from "../src/errors.js";
import { FakeDialer, FakeMediaLink, FakeSession, flush, IDENTITY, json, MAC, type Route } from "./fakes.js";

const MAC_STATUS = {
  ok: true,
  screenRecording: true,
  accessibility: false,
  displays: [{ id: 1, width: 1512, height: 982, scale: 2, main: true }],
  states: [{ display: 1, phase: "ready" }],
  console: { locked: false },
  control: { controller: "remote", since: 5, device: { id: "phone-9", name: "iPhone" } },
  automation: { active: false },
};

function setup(route: Route, onUnpaired?: () => void) {
  const session = new FakeSession(route);
  const media = new FakeMediaLink();
  const dialer = new FakeDialer(() => session);
  const connection = new MacConnection(MAC, { identity: IDENTITY, deviceName: "Chrome on Mac", app: { name: "t", version: "1" }, iceServers: [], turn: false, dial: dialer.dial });
  const backend = new DirectBackend(MAC, connection, { screenLink: () => media, ...(onUnpaired ? { onUnpaired } : {}) });
  return { session, media, dialer, connection, backend };
}

test("the Mac's /status over RPC as the page's status", async () => {
  const { backend, session } = setup((p) => (p === "/status" ? json(200, MAC_STATUS) : json(404, {})));
  const s = await backend.status();
  assert.equal(session.requests[0]!.path, "/status");
  assert.equal(s.available, true);
  assert.equal(s.accessibility, false);
  assert.equal(s.controller, "user");
  assert.deepEqual(s.controllerDevice, { id: "phone-9", name: "iPhone" });
  assert.equal(s.controllerSince, 5);
  assert.deepEqual(s.console, { locked: false });
  assert.equal(backend.cacheScope, "yoyocontrol:mac-1");

  const agent = setup(() => json(200, { ...MAC_STATUS, control: { controller: "none" }, automation: { active: true } }));
  assert.equal((await agent.backend.status()).controller, "agent");
});

test("control rides the link; a release while going away doesn't dial", async () => {
  const { backend, media, dialer } = setup(() => json(200, MAC_STATUS));
  const route = backend.route;
  assert.equal(await backend.setControl("none", route, { id: "browser-1" }, true), null);
  assert.equal(dialer.dials.length, 0, "no session for a keepalive release");
  const s = await backend.setControl("user", route, { id: "browser-1" }, false);
  assert.deepEqual(media.controls, [true]);
  assert.equal(s?.available, true);
  media.holder = { id: "phone-9", name: "iPhone" };
  await assert.rejects(backend.setControl("user", route, { id: "browser-1" }, false), (e: unknown) => {
    const body = (e as RequestError).body as { code?: string; controllerDevice?: { id: string } };
    return e instanceof RequestError && e.status === 409 && body.code === "controlled-elsewhere" && body.controllerDevice?.id === "phone-9";
  });
  await backend.input({ type: "move", x: 1, y: 2 });
  assert.deepEqual(media.inputs, [[JSON.stringify({ type: "move", x: 1, y: 2 }), true]]);
});

test("clipboard: the item, a 503 as unavailable, text in, files refused, a file's name", async () => {
  const { backend, session } = setup((p, init) => {
    if (p === "/clipboard" && init.method === "POST") return json(200, { ok: true, changeCount: 8, kind: "text", text: JSON.parse(String(init.body)).text });
    if (p === "/clipboard") return json(200, { ok: true, changeCount: 7, kind: "text", text: "hi", preview: "hi" });
    if (p === "/clipboard/file?index=0")
      return new Response("bytes", { headers: { "content-disposition": "attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf", "content-type": "application/pdf" } });
    return json(404, {});
  });
  const c = await backend.clipboard();
  assert.equal(c.available, true);
  assert.equal(c.item?.text, "hi");
  assert.equal((c.item as unknown as Record<string, unknown>).ok, undefined);
  const put = await backend.putClipboard({ text: "yo" }, () => {});
  assert.equal(put.item?.text, "yo");
  assert.deepEqual(JSON.parse(session.requests.at(-1)!.body!), { text: "yo" });
  await assert.rejects(backend.putClipboard({ files: [] }, () => {}), (e: unknown) => e instanceof RequestError && e.status === 501);
  const f = await backend.clipboardFile(0, 7, () => {});
  assert.equal(f.name, "résumé.pdf");
  assert.equal(f.mime, "application/pdf");

  await assert.rejects(backend.requestPermissions(), (e: unknown) => e instanceof RequestError && e.status === 403 && /menu on the Mac/.test(e.message));
  const off = setup(() => json(503, { error: "no GUI session" }));
  assert.deepEqual(await off.backend.clipboard(), { available: false, reason: "no GUI session" });
});

test("events: /events lines as the pages' events, agent asked from /status, reconnects; 401 = unpaired", async () => {
  let opened = 0;
  const lines = [
    { type: "state", states: [{ display: 1, phase: "ready" }] },
    { type: "control", control: { controller: "none" } },
    { type: "clipboard", changeCount: 3, kind: "image" },
    { type: "something-else" },
  ];
  const { backend } = setup((p) => {
    if (p === "/status") return json(200, { ...MAC_STATUS, control: { controller: "none" }, automation: { active: true } });
    if (p === "/events") {
      opened++;
      const body = new ReadableStream<Uint8Array>({
        start(c) {
          const enc = new TextEncoder();
          const text = lines.map((l) => JSON.stringify(l)).join("\n") + "\n";
          c.enqueue(enc.encode(text.slice(0, 10)));
          c.enqueue(enc.encode(text.slice(10)));
          c.close();
        },
      });
      return new Response(body, { headers: { "content-type": "application/x-ndjson" } });
    }
    return json(404, {});
  });
  const got: ScreenEvent[] = [];
  const it = backend.events()[Symbol.asyncIterator]();
  for (let i = 0; i < 3; i++) got.push((await it.next()).value as ScreenEvent);
  await it.return!();
  assert.deepEqual(got[0], { type: "screen.state", states: [{ display: 1, phase: "ready" }] });
  assert.equal(got[1]!.type, "screen.control");
  assert.equal((got[1] as { controller: string }).controller, "agent");
  assert.deepEqual(got[2], { type: "clipboard.changed", available: true, item: { changeCount: 3, kind: "image" } });
  assert.equal(opened, 1);

  let unpaired = 0;
  const gone = setup(() => json(401, { error: "unauthorized" }), () => unpaired++);
  const it2 = gone.backend.events()[Symbol.asyncIterator]();
  await flush();
  assert.equal(unpaired, 1);
  await it2.return!();
});

test("a Mac that can't be reached is a DirectError the page reads as the way being down", async () => {
  const connection = new MacConnection(MAC, {
    identity: IDENTITY,
    deviceName: "x",
    app: { name: "t", version: "1" },
    iceServers: [],
    turn: false,
    dial: new FakeDialer(() => new DirectError("offline", "the Mac is not online")).dial,
  });
  const backend = new DirectBackend(MAC, connection);
  await assert.rejects(backend.status(), (e: unknown) => e instanceof DirectError && e.status === 523);
});
