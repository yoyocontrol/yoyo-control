// One link video stream's loop (link.mjs LinkVideo) over a pretend session and the pretend video helper: what the
// encoder is told (the rate per picture, the buffer that bounds one picture) and what a lost picture costs — a
// picture that references the newest one the phone confirmed (`recovery`), a key frame only when that can't be.
import assert from "node:assert/strict";
import { test } from "node:test";
import { TUNING, linkBufferKbit } from "../flow.mjs";
import { LinkVideo, keyTransit } from "../link.mjs";
import { PLATFORMS, maxFpsFor } from "../platform.mjs";
import { YoyoLinux } from "../server.mjs";
import { fakeSpawn } from "./fakes.mjs";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(f, ms = 3000) {
  const t0 = Date.now();
  for (;;) {
    const v = await f();
    if (v) return v;
    if (Date.now() - t0 > ms) throw new Error("timed out");
    await sleep(5);
  }
}

/** A stream on a pretend session: `sent` what went to the link (`{ frame, kind, recoveryBase }`), `fake` the helper's side. */
function stream({ refs = true, cap = 30, fps = 60 } = {}) {
  const fake = fakeSpawn();
  fake.state.refs = refs;
  const svc = new YoyoLinux({ token: null, spawnFn: fake.spawn, logLine: () => {}, maxFps: 60 });
  const sent = [];
  const session = {
    isClosed: false,
    targetBitrate: 3.5e6,
    refuse: 0,
    openVideo() {},
    closeVideo() {},
    frameRateCap: () => cap,
    canSendFrame: () => true,
    sendCursor() {},
    sendFrame(_id, meta, au) {
      if (session.refuse > 0) {
        session.refuse--;
        throw new Error("the queue is full");
      }
      sent.push({ frame: sent.length + 1, kind: meta.kind, recoveryBase: meta.recoveryBase ?? null, bytes: au.length });
      return sent.length;
    },
  };
  const peer = { svc, session, encoderBps: 3_000_000, report: null, server: { clock: () => performance.now() / 1000 }, send() {}, log() {} };
  const v = new LinkVideo({ peer, id: 1, o: { id: null, fps, maxKbps: null, cursor: false, status: false } });
  const done = v.run();
  /** The next picture sent that is no refine of a still screen (those come by the clock). */
  const next = async (ms = 4000) => {
    const n = sent.length;
    return until(() => sent.slice(n).find((f) => f.kind !== "refine" && f.kind !== "keepalive"), ms);
  };
  const change = async () => {
    const p = next();
    fake.state.screenChanges();
    return p;
  };
  return { v, sent, fake, session, next, change, close: () => (v.close("test"), done) };
}

test("the encoder's buffer: eight pictures' shares of the real rate, half of it for a key frame", async () => {
  const s = stream();
  try {
    await until(() => s.sent.length === 1);
    assert.equal(s.sent[0].kind, "key");
    await s.change();
    const [key, delta] = s.fake.state.encodes;
    // 3000 kbit/s at the link's 30 pictures a second, x264 started at 60: twice the rate per picture
    assert.equal(delta.kbps, 6000);
    assert.equal(delta.buf, linkBufferKbit(TUNING, 3000, 30));
    assert.equal(delta.buf, 800);
    assert.equal(key.buf, 400);
  } finally {
    await s.close();
  }
});

test("a lost picture: the next one references the newest confirmed one, no key frame", async () => {
  const s = stream();
  try {
    await until(() => s.sent.length === 1);
    for (let i = 0; i < 4; i++) await s.change();
    // the phone confirmed frame 3 (the helper's picture 2), then lost one
    let p = s.next();
    s.v.delivered(3);
    s.v.recoveryNeeded(3);
    let mend = await p;
    assert.deepEqual(s.fake.state.forgets, [3], "the pictures after number 2 are forgotten");
    assert.deepEqual([mend.kind, mend.recoveryBase], ["recovery", 3]);
    assert.equal(s.fake.state.encodes.filter((e) => e.key).length, 1);
    // the link's own count of the newest delivered frame is used when it is ahead of what this stream heard
    p = s.next();
    s.v.recoveryNeeded(mend.frame);
    const again = await p;
    assert.deepEqual([again.kind, again.recoveryBase], ["recovery", mend.frame]);
    // pictures go on from there
    assert.equal((await s.change()).kind, "delta");
    assert.equal(s.v.mended, 2);
  } finally {
    await s.close();
  }
});

test("a key frame instead: nothing confirmed yet, a confirmed picture older than the helper keeps, a helper that keeps none", async () => {
  const s = stream();
  try {
    await until(() => s.sent.length === 1);
    // nothing confirmed: only a key frame mends it — after the first one has had its time on the way
    let p = s.next();
    s.v.recoveryNeeded(null);
    const key = await p;
    assert.equal(key.kind, "key");
    assert.deepEqual(s.fake.state.forgets, []);
    // the first key frame was never confirmed: the second gets half its buffer
    assert.deepEqual(s.fake.state.encodes.filter((e) => e.key).map((e) => e.buf), [400, 200]);
    // that key frame confirmed, then 20 pictures the phone never confirmed: the helper keeps 16
    s.v.delivered(key.frame);
    let last;
    for (let i = 0; i < 20; i++) last = await s.change();
    p = s.next();
    s.v.recoveryNeeded(key.frame);
    assert.equal((await p).kind, "key", "the helper answered with a key frame by itself");
    // a frame from before that key frame can be no reference any more
    p = s.next();
    s.v.recoveryNeeded(last.frame);
    assert.equal((await p).kind, "key");
  } finally {
    await s.close();
  }
  const plain = stream({ refs: false });
  try {
    await until(() => plain.sent.length === 1);
    const d = await plain.change();
    const p = plain.next();
    plain.v.delivered(d.frame);
    plain.v.recoveryNeeded(d.frame);
    assert.equal((await p).kind, "key");
  } finally {
    await plain.close();
  }
});

test("a picture the link refused: the next one skips it, no key frame", async () => {
  const s = stream();
  try {
    await until(() => s.sent.length === 1);
    await s.change();
    s.session.refuse = 1;
    s.fake.state.screenChanges();
    await until(() => s.fake.state.forgets.length === 1);
    // the refused picture was the helper's number 2
    assert.deepEqual(s.fake.state.forgets, [2]);
    const next = await s.change();
    assert.equal(next.kind, "delta");
    assert.equal(s.fake.state.encodes.filter((e) => e.key).length, 1);
  } finally {
    await s.close();
  }
});

test("no key frames by the clock; a key frame's time on the way", () => {
  // a small key frame: the fewest 0.5 s; a heavy one at a low rate: twice its time through the link and 0.2 s
  assert.equal(keyTransit(10_000, 3000), 0.5);
  assert.ok(Math.abs(keyTransit(30_000, 300) - 1.8) < 1e-9);
});

test("60 pictures a second where there are 8 processors, else 30; Windows as before", () => {
  assert.equal(maxFpsFor(PLATFORMS.linux, 4), 30);
  assert.equal(maxFpsFor(PLATFORMS.linux, 8), 60);
  assert.equal(maxFpsFor(PLATFORMS.windows, 2), 60);
});
