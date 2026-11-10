import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import type { ScreenLink, ScreenLinkAudioEvent, ScreenLinkVideoEvent } from "@yoyocontrol/screen-web";
import { dialRtc, LinkError, LinkRequestError, linkScreen } from "../src/index.js";
import { FakePeerConnection, Identity, ScriptedServer } from "./fake.js";

const WASM = readFileSync(fileURLToPath(new URL("../src/wasm/uu_link_wasm_bg.wasm", import.meta.url)));
const FIXTURE = readFileSync(fileURLToPath(new URL("../../../link/wasm/tests/fixtures/fec-frame.bin", import.meta.url)));

function fixtureDatagrams(): Uint8Array[] {
  let at = 5;
  const out: Uint8Array[] = [];
  for (let n = FIXTURE.readUInt32BE(at), i = ((at += 4), 0); i < n; i++) {
    const len = FIXTURE.readUInt16BE(at);
    out.push(new Uint8Array(FIXTURE.subarray(at + 2, at + 2 + len)));
    at += 2 + len;
  }
  return out;
}

async function setup() {
  const id = await Identity.create();
  const server = new ScriptedServer();
  const session = await dialRtc({
    signal: async (o) => id.answer(o.offer),
    pinnedFingerprint: id.fingerprint,
    credential: "Bearer x",
    device: { id: "dev", name: "B" },
    app: { name: "t", version: "1" },
    wasm: WASM,
    createPeerConnection: (c) => new FakePeerConnection(server, c) as unknown as RTCPeerConnection,
  });
  // the type check that link-web's object is screen-web's ScreenLink
  const link: ScreenLink = linkScreen(session);
  return { server, session, link };
}

const until = async (cond: () => boolean, ms = 1000) => {
  const t0 = Date.now();
  while (!cond()) {
    if (Date.now() - t0 > ms) throw new Error("timed out");
    await new Promise((r) => setTimeout(r, 5));
  }
};

test("a video stream: video.open with the query, frames from the media layer, decoder answers", async () => {
  const { server, session, link } = await setup();
  const events: ScreenLinkVideoEvent[] = [];
  const video = link.openVideo("maxWidth=1920&fps=60&codecs=h264&cursor=client&status=1", (e) => events.push(e));
  await until(() => server.received.some((m) => m.t === "video.open"));
  const open = server.received.find((m) => m.t === "video.open")!;
  assert.deepEqual(open, { t: "video.open", id: 1, query: "maxWidth=1920&fps=60&codecs=h264&cursor=client&status=1" });
  server.send({ t: "video.opened", id: 1, codec: "h264", width: 640, height: 360, headers: { "X-Stream-Codec": "h264", "X-Display": 1 } });
  server.send({ t: "video.status", id: 1, json: { display: 1, phase: "ready", since: 0 } });
  server.send({ t: "cursor.shape", id: 1, shapeId: 3, shape: { id: 3, png: "", hotX: 0, hotY: 0, width: 1, height: 1 } });
  for (const d of fixtureDatagrams()) server.dgram!.send(d);
  await until(() => events.some((e) => e.type === "frame"));
  assert.deepEqual(events[0], { type: "opened", codec: "h264", width: 640, height: 360, headers: { "X-Stream-Codec": "h264", "X-Display": "1" } });
  assert.deepEqual(events[1], { type: "status", json: '{"display":1,"phase":"ready","since":0}' });
  assert.deepEqual(events[2], { type: "cursor", json: '{"shapeId":3,"shape":{"id":3,"png":"","hotX":0,"hotY":0,"width":1,"height":1}}' });
  const f = events.find((e) => e.type === "frame");
  assert.ok(f?.type === "frame");
  assert.deepEqual({ ...f.frame, au: f.frame.au.length }, { number: 1, codec: "h264", kind: "key", width: 640, height: 360, captureMs: 1_700_000_000_000, au: 30_005 });
  video.decoded(1, true);
  video.report({ mode: "smooth", fps: 30, frames: [] });
  await until(() => server.received.some((m) => m.t === "report"));
  const report = server.received.find((m) => m.t === "report") as { id: number; report: Record<string, unknown> };
  assert.equal(report.id, 1);
  assert.equal(report.report.mode, "smooth");
  assert.equal((report.report.rx as { fate: string }[])[0]?.fate, "delivered");
  assert.ok(typeof (report.report.clock as { mediaUs: number }).mediaUs === "number");
  // the media layer's feedback reached the server on channel 4
  await until(() => server.datagrams.some((d) => d[0] === ((4 << 4) | 1)));
  video.close();
  await until(() => server.received.some((m) => m.t === "video.close"));
  await session.close();
});

test("sound: audio.opened as /audio's header names; errors end the stream", async () => {
  const { server, session, link } = await setup();
  const events: ScreenLinkAudioEvent[] = [];
  link.openAudio("", (e) => events.push(e));
  await until(() => server.received.some((m) => m.t === "audio.open"));
  server.send({ t: "audio.opened", id: 1, codec: "opus", rate: 48000, channels: 2, frames: 960, cookie: null, videoOffsetMs: 31 });
  server.send({ t: "audio.error", id: 1, status: 503, message: "no capture" });
  await until(() => events.length === 2);
  assert.deepEqual(events, [
    { type: "opened", format: { "X-Audio-Codec": "opus", "X-Audio-Rate": "48000", "X-Audio-Channels": "2", "X-Audio-Frames": "960", "X-Audio-Video-Offset": "31" } },
    { type: "error", status: 503, message: "no capture" },
  ]);
  await session.close();
});

test("control take / release, input rejections, the session's end", async () => {
  const { server, session, link } = await setup();
  server.onControl = (m, send) => {
    if (m.t === "control.take") send({ t: "control", rid: m.rid, granted: false, holder: { id: "phone", name: "iPhone" } });
    if (m.t === "control.release") send({ t: "control", rid: m.rid, granted: false, holder: null });
  };
  assert.deepEqual(await link.control(true), { granted: false, holder: { id: "phone", name: "iPhone" } });
  assert.deepEqual(await link.control(false), { granted: false, holder: null });
  const errors: unknown[] = [];
  link.setInputErrorHandler((e) => errors.push(e));
  link.sendInput('{"type":"click","x":0.1,"y":0.2}', false);
  await until(() => server.datagrams.some((d) => d[0] === ((3 << 4) | 1)));
  server.send({ t: "input.rejected", seq: 1, status: 409, code: "controlled-elsewhere", message: "controlled elsewhere", controllerDevice: { id: "phone", name: "iPhone" } });
  await until(() => errors.length === 1);
  const e = errors[0] as LinkRequestError;
  assert.ok(e instanceof LinkRequestError);
  assert.equal(e.status, 409);
  assert.deepEqual(e.body, { error: "controlled elsewhere", code: "controlled-elsewhere", controllerDevice: { id: "phone", name: "iPhone" } });
  assert.match(link.pathLabel, /^link /);
  const events: ScreenLinkVideoEvent[] = [];
  link.openVideo("fps=60", (ev) => events.push(ev));
  server.send({ t: "bye", code: 5, reason: "shutting down" });
  assert.match(await link.closed, /shutting down/);
  assert.equal(events.at(-1)?.type, "failed");
  assert.equal(link.isClosed, true);
  await assert.rejects(link.control(true), (err: unknown) => err instanceof LinkError && err.kind === "closed");
  assert.throws(() => link.sendInput("{}", false), LinkError);
});

test("with a video stream open, 3 s of silence ends the session (its streams fail); without one it doesn't", async () => {
  const { server, session, link } = await setup();
  // no stream: the idle limit is the long one
  await new Promise((r) => setTimeout(r, 3400));
  assert.equal(session.isClosed, false);
  server.send({ t: "pong" });
  const events: ScreenLinkVideoEvent[] = [];
  const t0 = Date.now();
  link.openVideo("fps=30", (e) => events.push(e));
  await until(() => session.isClosed, 5000);
  const ms = Date.now() - t0;
  assert.ok(ms >= 2900 && ms < 3600, `ended after ${ms} ms`);
  assert.match((await session.closed()).reason, /nothing from the server for 3 s/);
  await until(() => events.some((e) => e.type === "failed"));
});

test("ICE disconnected or failed ends the session at once", async () => {
  for (const state of ["disconnected", "failed"] as const) {
    const { session } = await setup();
    const pc = (session as unknown as { pc: FakePeerConnection }).pc;
    (pc as unknown as { iceConnectionState: string }).iceConnectionState = state;
    pc.dispatchEvent(new Event("iceconnectionstatechange"));
    assert.equal(session.isClosed, true);
    assert.equal((await session.closed()).reason, `ICE ${state}`);
  }
});
