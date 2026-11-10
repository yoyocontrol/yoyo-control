import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { CONTROLLED_ELSEWHERE, linkInputSender, linkSetControl } from "../src/control.js";
import { InputQueue, mergeLinkInput } from "../src/input.js";
import { linkStreamQuery, type ScreenLink, type ScreenLinkAudioEvent, type ScreenLinkControlAnswer, type ScreenLinkVideoEvent } from "../src/link.js";
import { PartParser } from "../src/parts.js";
import { RequestError } from "../src/transport.js";
import type { Input } from "../src/types.js";
import { VideoStream, type VideoCallbacks } from "../src/video.js";

// The screen over a link (ScreenLink): the query, the stream on a fake link with a fake decoder, input in link mode, control.

test("linkStreamQuery: /stream's body as a query, without ack", () => {
  assert.equal(linkStreamQuery({ display: 2, maxWidth: 3840, fps: 60, codecs: "h264", stream: "w1", ack: 1, cursor: "client", status: 1, x: undefined }), "display=2&maxWidth=3840&fps=60&codecs=h264&stream=w1&cursor=client&status=1");
});

/** A ScreenLink that records what is sent and lets the test drive the video stream's events. */
class FakeLink implements ScreenLink {
  pathLabel = "link lan";
  isLocalNetwork = true;
  rttMinMs: number | null = 4;
  statsLine: string | null = "lan wifi rtt 1/2/3 ms";
  isClosed = false;
  closed = new Promise<string>(() => {});
  queries: string[] = [];
  decoded: [number, boolean][] = [];
  keyRequests = 0;
  reports: Record<string, unknown>[] = [];
  videoClosed = 0;
  inputs: { json: string; move: boolean }[] = [];
  emit: (e: ScreenLinkVideoEvent) => void = () => {};
  answer: ScreenLinkControlAnswer = { granted: true, holder: { id: "me", name: "Me" } };
  sendThrows: unknown = null;

  openVideo(query: string, onEvent: (e: ScreenLinkVideoEvent) => void) {
    this.queries.push(query);
    this.emit = onEvent;
    return {
      decoded: (frame: number, ok: boolean) => void this.decoded.push([frame, ok]),
      requestKeyframe: () => void this.keyRequests++,
      report: (r: Record<string, unknown>) => void this.reports.push(r),
      close: () => void this.videoClosed++,
    };
  }
  openAudio(_query: string, _onEvent: (e: ScreenLinkAudioEvent) => void) {
    return { close() {} };
  }
  sendInput(json: string, move: boolean): void {
    if (this.sendThrows) throw this.sendThrows;
    this.inputs.push({ json, move });
  }
  setInputErrorHandler(): void {}
  async control(): Promise<ScreenLinkControlAnswer> {
    return this.answer;
  }
}

/** A decoder that outputs a picture for each chunk (node has no WebCodecs), and animation frames on timers. */
function fakeBrowser(): () => void {
  const g = globalThis as Record<string, unknown>;
  const before = { VideoDecoder: g.VideoDecoder, EncodedVideoChunk: g.EncodedVideoChunk, requestAnimationFrame: g.requestAnimationFrame, cancelAnimationFrame: g.cancelAnimationFrame };
  g.VideoDecoder = class {
    state = "unconfigured";
    decodeQueueSize = 0;
    constructor(private readonly init: { output: (f: unknown) => void }) {}
    configure() {
      this.state = "configured";
    }
    decode(chunk: { init: { timestamp: number } }) {
      setTimeout(() => this.init.output({ timestamp: chunk.init.timestamp, displayWidth: 8, displayHeight: 6, close() {} }), 1);
    }
    reset() {}
    close() {
      this.state = "closed";
    }
  };
  g.EncodedVideoChunk = class {
    constructor(public init: unknown) {}
  };
  g.requestAnimationFrame = (cb: (t: number) => void) => setTimeout(() => cb(performance.now()), 4) as unknown as number;
  g.cancelAnimationFrame = (id: number) => clearTimeout(id);
  return () => Object.assign(g, before);
}

const FIXTURE = new Uint8Array(readFileSync(resolve(import.meta.dirname, "fixtures/screen-stream.bin")));
const pictures = () => new PartParser("frame").feed(FIXTURE).filter((p) => p.kind === "h264");
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const canvas = () => ({ width: 0, height: 0, getContext: () => ({ drawImage() {} }) }) as unknown as HTMLCanvasElement;

test("a link stream: video.open's query, pictures straight to the decoder, each verdict back, LAN caps, stats", async () => {
  const undo = fakeBrowser();
  const link = new FakeLink();
  try {
    let ended = null as Parameters<VideoCallbacks["onEnd"]>[0] | null;
    let drawn = 0;
    const statuses: string[] = [];
    const s = new VideoStream({ link, canvas: canvas(), display: 1 }, { onPicture: () => drawn++, onCursor: () => {}, onStatus: (p) => statuses.push(p.phase), onEnd: (e) => (ended = e) });
    const done = s.run();
    assert.equal(link.queries.length, 1);
    const q = new URLSearchParams(link.queries[0]);
    assert.equal(q.get("display"), "1");
    assert.equal(q.get("cursor"), "client");
    assert.equal(q.has("ack"), false, "no acks on a link");
    link.emit({ type: "opened", codec: "h264", width: 8, height: 6, headers: { "X-Display": "1" } });
    link.emit({ type: "status", json: JSON.stringify({ display: 1, phase: "ready", since: 1 }) });
    const ps = pictures();
    assert.ok(ps.length >= 1);
    ps.forEach((p, i) => {
      link.emit({ type: "frame", frame: { number: i + 1, codec: "h264", kind: (p.headers.kind ?? "delta") as "key", width: 8, height: 6, captureMs: Date.now(), au: p.body } });
    });
    await sleep(60);
    assert.deepEqual(statuses, ["ready"]);
    assert.deepEqual(link.decoded, ps.map((_, i) => [i + 1, true] as [number, boolean]), "every picture's verdict goes back, in order");
    assert.ok(drawn >= 1);
    assert.equal(s.playoutState().capMs, 100, "a local link gets the LAN cap");
    const st = s.stats();
    assert.equal(st.codec, "h264");
    assert.equal(st.rttMinMs, 4, "the link's round trip is the touch budget's source");
    assert.equal(st.net, null);
    // the server ends the stream
    link.emit({ type: "error", status: 503, message: "no screen" });
    await done;
    assert.deepEqual(ended && { failed: ended.failed, status: ended.status, error: ended.error }, { failed: true, status: 503, error: "no screen" });
    assert.equal(link.videoClosed, 1);
  } finally {
    undo();
  }
});

test("a link stream: a delta before any key picture asks the link for one and says it wasn't decoded", async () => {
  const undo = fakeBrowser();
  const link = new FakeLink();
  try {
    const s = new VideoStream({ link, canvas: canvas() }, { onPicture: () => {}, onCursor: () => {}, onStatus: () => {}, onEnd: () => {} });
    void s.run();
    // a non-IDR slice (NAL type 1) and no SPS / PPS: no decoder yet
    link.emit({ type: "frame", frame: { number: 7, codec: "h264", kind: "delta", width: 0, height: 0, captureMs: null, au: Uint8Array.of(0, 0, 0, 1, 0x41, 0x9a, 0x02) } });
    await sleep(5);
    s.close();
    assert.deepEqual(link.decoded, [[7, false]]);
    assert.equal(link.keyRequests, 1);
    // an hevc frame ends the stream as an unexpected codec
    const link2 = new FakeLink();
    let error: string | null = null;
    const s2 = new VideoStream({ link: link2, canvas: canvas() }, { onPicture: () => {}, onCursor: () => {}, onStatus: () => {}, onEnd: (e) => (error = e.error) });
    const done = s2.run();
    link2.emit({ type: "frame", frame: { number: 1, codec: "hevc", kind: "key", width: 0, height: 0, captureMs: null, au: new Uint8Array(4) } });
    await done;
    assert.match(error ?? "", /unexpected codec hevc/);
  } finally {
    undo();
  }
});

test("a link stream: the session's end ends it as failed; close() closes the link stream without onEnd", async () => {
  const link = new FakeLink();
  let end = null as Parameters<VideoCallbacks["onEnd"]>[0] | null;
  const s = new VideoStream({ link, canvas: canvas() }, { onPicture: () => {}, onCursor: () => {}, onStatus: () => {}, onEnd: (e) => (end = e) });
  const done = s.run();
  link.emit({ type: "failed", reason: "connection lost" });
  await done;
  assert.deepEqual(end && { failed: end.failed, error: end.error, status: end.status }, { failed: true, error: "connection lost", status: null });
  const link2 = new FakeLink();
  let ended = false;
  const s2 = new VideoStream({ link: link2, canvas: canvas() }, { onPicture: () => {}, onCursor: () => {}, onStatus: () => {}, onEnd: () => (ended = true) });
  const done2 = s2.run();
  s2.close();
  await done2;
  assert.equal(ended, false);
  assert.equal(link2.videoClosed, 1);
});

test("link input: one turn's moves merge into the latest and take a seq; scroll phases fold; discrete ones keep their order", async () => {
  const link = new FakeLink();
  const failures: unknown[] = [];
  const q = new InputQueue(() => Promise.reject(new Error("no HTTP here")), (e) => failures.push(e), 100, () => 0, { link: () => linkInputSender(link) });
  q.move(0.1, 0.1);
  q.move(0.2, 0.2);
  q.input({ type: "click", x: 0.2, y: 0.2 });
  q.scroll(0, 2, 0.5, 0.5, undefined, "began");
  q.scroll(0, 3, 0.5, 0.5, undefined, "changed");
  q.scroll(0, 1, 0.5, 0.5, undefined, "changed");
  q.scroll(0, 0, 0.5, 0.5, undefined, "ended", 0, 40);
  assert.equal(link.inputs.length, 0, "nothing before the turn ends");
  assert.equal(q.queuedForLink, 4);
  await Promise.resolve();
  const sent = link.inputs.map((i) => ({ ...(JSON.parse(i.json) as Input), move: i.move }));
  assert.deepEqual(sent, [
    { type: "move", x: 0.2, y: 0.2, seq: 100, move: true },
    { type: "click", x: 0.2, y: 0.2, move: false },
    { type: "scroll", x: 0.5, y: 0.5, dx: 0, dy: 6, phase: "began", move: false },
    { type: "scroll", x: 0.5, y: 0.5, dx: 0, dy: 0, phase: "ended", vx: 0, vy: 40, move: false },
  ]);
  // a 429 from the link goes to failed at once, as a RequestError
  link.sendThrows = Object.assign(new Error("too many input events waiting"), { status: 429 });
  q.input({ type: "key", key: "a" });
  await Promise.resolve();
  assert.equal(failures.length, 1);
  assert.ok(failures[0] instanceof RequestError && failures[0].status === 429);
});

test("link input: a way that stops being a link before the flush sends them as requests", async () => {
  const sent: Input[] = [];
  let link: ((i: Input) => void) | null = () => assert.fail("not on the link");
  const q = new InputQueue(async (i) => void sent.push(i), () => {}, 1, () => 0, { link: () => link });
  q.input({ type: "click", x: 0.5, y: 0.5 });
  link = null;
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(sent, [{ type: "click", x: 0.5, y: 0.5 }]);
});

test("mergeLinkInput: moves of one button merge; another button, display or a scroll after an end don't", () => {
  assert.deepEqual(mergeLinkInput({ type: "move", x: 0, y: 0 }, { type: "move", x: 1, y: 1 }), { type: "move", x: 1, y: 1 });
  assert.equal(mergeLinkInput({ type: "move", x: 0, y: 0 }, { type: "move", x: 1, y: 1, button: "left" }), null);
  assert.equal(mergeLinkInput({ type: "move", x: 0, y: 0, display: 1 }, { type: "move", x: 1, y: 1, display: 2 }), null);
  assert.deepEqual(mergeLinkInput({ type: "scroll", dx: 1, dy: 1, x: 0, y: 0 }, { type: "scroll", dx: 2, dy: 3, x: 1, y: 1 }), { type: "scroll", dx: 3, dy: 4, x: 1, y: 1 });
  assert.equal(mergeLinkInput({ type: "scroll", dx: 1, dy: 1, phase: "ended" }, { type: "scroll", dx: 2, dy: 3, phase: "began" }), null);
  assert.equal(mergeLinkInput({ type: "click" }, { type: "click" }), null);
});

test("linkSetControl: granted; another device holding it is controlled-elsewhere (409); nobody holding it is 409", async () => {
  const link = new FakeLink();
  assert.deepEqual(await linkSetControl(link, true), { controller: "user", device: { id: "me", name: "Me" } });
  link.answer = { granted: false, holder: { id: "ipad", name: "iPad" } };
  await assert.rejects(linkSetControl(link, true), (e: unknown) => e instanceof RequestError && e.status === 409 && (e.body as { code: string; controllerDevice: { id: string } }).code === CONTROLLED_ELSEWHERE && (e.body as { controllerDevice: { id: string } }).controllerDevice.id === "ipad");
  link.answer = { granted: false, holder: null };
  await assert.rejects(linkSetControl(link, true), (e: unknown) => e instanceof RequestError && e.status === 409);
  assert.deepEqual(await linkSetControl(link, false), { controller: "none", device: null });
});
