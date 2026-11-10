import assert from "node:assert/strict";
import { test } from "node:test";
import type { ScreenLinkVideoEvent } from "@yoyocontrol/screen-web";
import { MacConnection } from "../src/connection.js";
import { DirectScreenLink } from "../src/screen-link.js";
import { FakeDialer, FakeMediaLink, FakeSession, flush, IDENTITY, MAC } from "./fakes.js";

function setup(next: () => FakeSession | Error) {
  const medias: FakeMediaLink[] = [];
  const dialer = new FakeDialer(next);
  const connection = new MacConnection(MAC, { identity: IDENTITY, deviceName: "x", app: { name: "t", version: "1" }, iceServers: [], turn: false, dial: dialer.dial });
  const link = new DirectScreenLink(connection, () => {
    const m = new FakeMediaLink();
    medias.push(m);
    return m;
  });
  return { link, medias, dialer, connection };
}

test("a stream opened before the session exists opens on it; its events and the calls in between pass through", async () => {
  const { link, medias } = setup(() => new FakeSession());
  const events: ScreenLinkVideoEvent[] = [];
  const v = link.openVideo("display=1&maxWidth=1600", (e) => events.push(e));
  v.requestKeyframe();
  v.report({ fps: 60 });
  await flush();
  const m = medias[0]!;
  assert.equal(m.videos[0]!.query, "display=1&maxWidth=1600");
  assert.equal(m.videos[0]!.keyframes, 1);
  assert.deepEqual(m.videos[0]!.reports, [{ fps: 60 }]);
  m.videos[0]!.emit({ type: "opened", codec: "h264", width: 100, height: 50, headers: { "X-Display": "1" } });
  m.videos[0]!.emit({ type: "closed", reason: "done" });
  assert.deepEqual(events, [
    { type: "opened", codec: "h264", width: 100, height: 50, headers: { "X-Display": "1" } },
    { type: "closed", reason: "done" },
  ]);
  v.decoded(3, true);
  assert.deepEqual(m.videos[0]!.decoded, [[3, true]]);
  assert.equal(link.pathLabel, "link lan");
  assert.equal(link.isLocalNetwork, true);
  assert.equal(link.rttMinMs, 1.5);
});

test("a dial that fails is `failed` for the stream; input without a session is a 503", async () => {
  const { link } = setup(() => new Error("nope"));
  const events: ScreenLinkVideoEvent[] = [];
  link.openVideo("", (e) => events.push(e));
  await flush();
  assert.equal(events[0]?.type, "failed");
  assert.throws(() => link.sendInput("{}", false), (e: unknown) => (e as { status?: number }).status === 503);
  assert.equal(link.pathLabel, "link");
  assert.equal(link.isClosed, false);
  link.end("closed");
  assert.equal(link.isClosed, true);
  assert.equal(await link.closed, "closed");
});

test("a new session gets its own media; input and its error handler follow", async () => {
  const sessions: FakeSession[] = [];
  const { link, medias, connection } = setup(() => {
    const s = new FakeSession();
    sessions.push(s);
    return s;
  });
  const errors: unknown[] = [];
  link.setInputErrorHandler((e) => errors.push(e));
  await connection.session();
  link.openAudio("", () => {});
  await flush();
  link.sendInput('{"type":"click"}', false);
  assert.deepEqual(medias[0]!.inputs, [['{"type":"click"}', false]]);
  medias[0]!.inputError?.("refused");
  sessions[0]!.drop();
  await connection.session();
  link.sendInput('{"type":"move"}', true);
  assert.equal(medias.length, 2);
  assert.deepEqual(medias[1]!.inputs, [['{"type":"move"}', true]]);
  medias[1]!.inputError?.("again");
  assert.deepEqual(errors, ["refused", "again"]);
});
