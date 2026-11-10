import assert from "node:assert/strict";
import { test } from "node:test";
import type { ScreenLink, ScreenLinkControlAnswer } from "@yoyocontrol/screen-web";
import { DIRECT_ROUTE, type ScreenBackend, type ScreenStatus } from "../src/contracts.js";
import { ScreenSession } from "../src/session.js";

const status: ScreenStatus = { available: true, screenRecording: true, accessibility: true, displays: [], controller: "none" };

/** A ScreenLink that records what the page sends on it. */
function fakeLink(answer: ScreenLinkControlAnswer) {
  const sent: { json: string; move: boolean }[] = [];
  const controls: boolean[] = [];
  let onError: ((e: unknown) => void) | null = null;
  const link: ScreenLink = {
    pathLabel: "link lan",
    isLocalNetwork: true,
    rttMinMs: 1,
    statsLine: "lan wifi rtt 1.0/1.0/1.0 ms",
    isClosed: false,
    closed: new Promise(() => {}),
    openVideo: () => ({ decoded() {}, requestKeyframe() {}, report() {}, close() {} }),
    openAudio: () => ({ close() {} }),
    sendInput: (json, move) => void sent.push({ json, move }),
    setInputErrorHandler: (h) => void (onError = h),
    control: async (take) => (controls.push(take), answer),
  };
  return { link, sent, controls, error: (e: unknown) => onError?.(e) };
}

function session(backend: Partial<ScreenBackend>): ScreenSession {
  const b: ScreenBackend = { cacheScope: "t", status: async () => status, transport: () => ({ fetch: async () => new Response(null, { status: 500 }) }), ...backend };
  const s = new ScreenSession(b, { canvas: {} as HTMLCanvasElement, audioKey: null }, { picture() {}, cursor() {}, streamOpened() {}, connection() {}, audio() {}, refreshStatus() {}, handleError: () => false });
  s.statusChanged(status);
  return s;
}

test("over a link, control is control.take and the status follows the holder", async () => {
  const me = { id: "me", name: "Browser" };
  const f = fakeLink({ granted: true, holder: me });
  const s = session({ screenLink: () => f.link });
  const st = await s.control("user", me);
  assert.deepEqual(f.controls, [true]);
  assert.equal(st?.controller, "user");
  assert.deepEqual(st?.controllerDevice, me);
  assert.equal(await s.control("none", me, true), null, "a keepalive release answers nothing");
  assert.deepEqual(f.controls, [true, false]);
});

test("over a link, another holder is a 409 controlled-elsewhere as POST /control would give", async () => {
  const f = fakeLink({ granted: false, holder: { id: "other", name: "Mia's iPhone" } });
  const s = session({ screenLink: () => f.link });
  await assert.rejects(s.control("user", { id: "me", name: "B" }), (e: { status?: number; body?: { code?: string } }) => e.status === 409 && e.body?.code === "controlled-elsewhere");
});

test("input goes on the link at once (moves marked), its refusals to the page's handler; HTTP has no link sender", async () => {
  const f = fakeLink({ granted: true, holder: null });
  const errors: unknown[] = [];
  const s = session({ screenLink: () => f.link });
  const send = s.linkInput((e) => errors.push(e));
  assert.ok(send);
  send({ type: "move", x: 0.5, y: 0.5 });
  send({ type: "click", x: 0.5, y: 0.5 });
  assert.deepEqual(
    f.sent.map((x) => x.move),
    [true, false],
  );
  f.error(new Error("refused"));
  assert.equal(errors.length, 1);
  assert.equal(session({}).linkInput(() => {}), null);
});

test("HTTP input goes through the backend on the way in use", async () => {
  const got: unknown[] = [];
  const s = session({ input: async (i, r) => void got.push([i.type, r.id]) });
  await s.deliver({ type: "click", x: 0.1, y: 0.2 });
  assert.deepEqual(got, [["click", DIRECT_ROUTE.id]]);
});

test("the stats line without a stream says the way and the connection", () => {
  const f = fakeLink({ granted: true, holder: null });
  assert.match(session({ screenLink: () => f.link }).statsText(), /^link lan · /);
  assert.match(session({}).statsText(), /^direct · /);
});
