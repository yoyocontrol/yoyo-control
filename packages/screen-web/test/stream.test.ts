import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import type { Input } from "../src/types.js";
import { ackOutcome } from "../src/acks.js";
import { ClickGate, DOUBLE_TAP_MS, FIELD_SENTINEL, LONG_PRESS_MS, TouchGestures, resetField, textInput, withoutSentinel } from "../src/input.js";
import { RequestError, type ScreenTransport } from "../src/transport.js";
import { sendInput, setControl } from "../src/control.js";
import { VideoStream, fetchFrame, pruneOlder, type VideoCallbacks } from "../src/video.js";

// ---- clicks and taps

test("touch: a long press right after a tap sends the tap's click first, and nothing after the right-click", () => {
  const g = new TouchGestures((x, y) => ({ x: x / 100, y: y / 100 }), () => 1);
  g.down(10, 10, 0);
  g.up(10, 10, 50);
  g.down(40, 40, 150);
  assert.deepEqual(g.tick(150 + LONG_PRESS_MS), [{ t: "click", x: 0.1, y: 0.1 }, { t: "rightClick", x: 0.4, y: 0.4 }]);
  assert.deepEqual(g.tick(2000), [], "no stale click afterwards");
  assert.deepEqual(g.up(40, 40, 900), []);
});

function gate() {
  const out: Input[] = [];
  return { g: new ClickGate((i) => out.push(i)), out };
}

test("mouse: a double click is one doubleClick (the first click waits for it)", () => {
  const { g, out } = gate();
  g.click(0.2, 0.3, 1, [], 0);
  assert.deepEqual(out, [], "the first click waits");
  assert.equal(g.deadline, DOUBLE_TAP_MS);
  g.click(0.2, 0.3, 2, [], 180);
  assert.deepEqual(out, [{ type: "doubleClick", x: 0.2, y: 0.3 }]);
  g.click(0.2, 0.3, 3, [], 250);
  assert.equal(out.length, 1, "a triple click adds nothing");
  g.tick(1000);
  assert.equal(out.length, 1);
});

test("mouse: a single click goes at its deadline; a late second click is a click; flush keeps the order; cancel drops", () => {
  const { g, out } = gate();
  g.click(0.5, 0.5, 1, ["cmd"], 0);
  g.tick(DOUBLE_TAP_MS - 1);
  assert.equal(out.length, 0);
  g.tick(DOUBLE_TAP_MS);
  assert.deepEqual(out, [{ type: "click", x: 0.5, y: 0.5, modifiers: ["cmd"] }]);
  // the browser still counts it as a double click (its own interval is longer): a plain click, not a doubleClick
  g.click(0.5, 0.5, 2, [], 450);
  assert.deepEqual(out.at(-1), { type: "click", x: 0.5, y: 0.5 });
  // a key right after a click: the page flushes first, so the click goes before it
  g.click(0.1, 0.1, 1, [], 2000);
  g.flush();
  out.push({ type: "key", key: "a" });
  assert.deepEqual(out.slice(-2).map((i) => i.type), ["click", "key"]);
  g.click(0.1, 0.1, 1, [], 3000);
  g.cancel();
  g.tick(9999);
  assert.equal(out.at(-1)!.type, "key", "a cancelled click never goes");
});

// ---- the keyboard field

test("the keyboard field keeps a sentinel: a phone's backspace deletes it and becomes Delete", () => {
  const field = { value: "x", sel: [-1, -1], setSelectionRange(a: number, b: number) { this.sel = [a, b]; } };
  resetField(field);
  assert.equal(field.value, FIELD_SENTINEL);
  assert.deepEqual(field.sel, [FIELD_SENTINEL.length, FIELD_SENTINEL.length]);
  assert.deepEqual(textInput("deleteContentBackward", null, false), { type: "key", key: "delete" });
  // a keyboard that hands over the whole field: the sentinel isn't typed
  assert.deepEqual(textInput("insertText", `${FIELD_SENTINEL}ok`, false), { type: "type", text: "ok" });
  assert.equal(textInput("insertText", FIELD_SENTINEL, false), null);
  assert.equal(withoutSentinel(`a${FIELD_SENTINEL}b`), "ab");
});

// ---- acks, decode bookkeeping, host

test("ack statuses: 404 stops acking; other 4xx stop and end the stream; 5xx / timeouts are tried again", () => {
  assert.deepEqual(ackOutcome(200), { outcome: "ok", ends: false });
  assert.deepEqual(ackOutcome(404), { outcome: "gone", ends: false });
  assert.deepEqual(ackOutcome(401), { outcome: "gone", ends: true });
  assert.deepEqual(ackOutcome(403), { outcome: "gone", ends: true });
  assert.deepEqual(ackOutcome(400), { outcome: "gone", ends: true });
  assert.deepEqual(ackOutcome(429), { outcome: "failed", ends: false });
  assert.deepEqual(ackOutcome(502), { outcome: "failed", ends: false });
});

test("decode start times of pictures that never came out are pruned", () => {
  const m = new Map([[1, 0], [2, 1500], [3, 2900]]);
  pruneOlder(m, 3000, 2000);
  assert.deepEqual([...m.keys()], [2, 3]);
});

// ---- the stream: watchdog and a refused ack

const FIXTURE = new Uint8Array(readFileSync(resolve(import.meta.dirname, "fixtures/screen-stream.bin")));

/** A transport for VideoStream: the stream request answers with `chunks` then stays open (until aborted); acks get `ackStatus`. */
function fakeTransport(chunks: Uint8Array[], ackStatus = 200): { transport: ScreenTransport; acks: number[]; requests: { path: string; init: RequestInit }[] } {
  const acks: number[] = [];
  const requests: { path: string; init: RequestInit }[] = [];
  const transport: ScreenTransport = {
    fetch: async (path, init) => {
      requests.push({ path, init });
      if (path === "/stream/ack") {
        acks.push(JSON.parse(String(init.body)).seq);
        return new Response(ackStatus === 200 ? '{"ok":true}' : '{"error":"x"}', { status: ackStatus, headers: { "content-type": "application/json" } });
      }
      const signal = init.signal;
      const body = new ReadableStream<Uint8Array>({
        start(c) {
          for (const ch of chunks) c.enqueue(ch);
          signal?.addEventListener("abort", () => c.error(new DOMException("aborted", "AbortError")));
        },
      });
      return new Response(body, { status: 200, headers: { "content-type": "application/vnd.yoyo-control.stream; boundary=frame", "x-stream-codec": "h264" } });
    },
  };
  return { transport, acks, requests };
}

/** A VideoDecoder that takes everything and outputs nothing (node has none). */
function fakeDecoder(): () => void {
  const g = globalThis as Record<string, unknown>;
  const before = { VideoDecoder: g.VideoDecoder, EncodedVideoChunk: g.EncodedVideoChunk };
  g.VideoDecoder = class {
    state = "unconfigured";
    decodeQueueSize = 0;
    configure() { this.state = "configured"; }
    decode() {}
    reset() {}
    close() { this.state = "closed"; }
  };
  g.EncodedVideoChunk = class { constructor(public init: unknown) {} };
  return () => Object.assign(g, before);
}

function run(transport: ScreenTransport, stallMs: number): Promise<Parameters<VideoCallbacks["onEnd"]>[0]> {
  return new Promise((done) => {
    const s = new VideoStream(
      { transport, canvas: {} as HTMLCanvasElement, stallMs },
      { onPicture: () => {}, onCursor: () => {}, onStatus: () => {}, onEnd: done },
    );
    void s.run();
  });
}

test("a stream that stops sending (half open) ends as failed after the stall time", async () => {
  const f = fakeTransport([FIXTURE.subarray(0, 200)]);
  const t0 = performance.now();
  const end = await run(f.transport, 120);
  assert.equal(end.failed, true);
  assert.match(end.error ?? "", /no data/);
  assert.equal(end.status, null);
  assert.ok(performance.now() - t0 >= 100);
  // the stream request: POST /stream with its parameters as JSON, asking for both sets of media type names
  const open = f.requests[0]!;
  assert.equal(open.path, "/stream");
  assert.equal(open.init.method, "POST");
  assert.equal((open.init.headers as Record<string, string>).accept, "application/vnd.yoyo-control.stream");
  const body = JSON.parse(String(open.init.body));
  assert.deepEqual({ ...body, stream: "id" }, { maxWidth: 3840, fps: 60, codecs: "h264", stream: "id", ack: 1, cursor: "client", status: 1 });
});

test("an ack refused with 401 ends the stream with that status (no endless retries)", async () => {
  const undo = fakeDecoder();
  const f = fakeTransport([FIXTURE], 401);
  try {
    const end = await run(f.transport, 5000);
    assert.equal(end.failed, true);
    assert.equal(end.status, 401);
    // the fixture's three pictures were acked at once (up to 4 in flight); after the 401 nothing more goes
    const asked = f.acks.length;
    assert.ok(asked >= 1 && asked <= 3);
    await new Promise((r) => setTimeout(r, 400));
    assert.equal(f.acks.length, asked, "no retry every 100 ms");
  } finally {
    undo();
  }
});

// ---- the other requests go through the transport too

test("fetchFrame: GET /frame with the size, quality and display; a failure is null", async () => {
  const paths: string[] = [];
  const ok: ScreenTransport = {
    fetch: async (path) => {
      paths.push(path);
      return new Response(new Uint8Array([1, 2, 3]), { status: 200, headers: { "x-frame-width": "800", "x-frame-height": "500" } });
    },
  };
  const g = globalThis as { URL: typeof URL };
  const before = g.URL.createObjectURL;
  g.URL.createObjectURL = () => "blob:x";
  try {
    assert.deepEqual(await fetchFrame(ok, 7, 160), { url: "blob:x", width: 800, height: 500 });
    assert.deepEqual(paths, ["/frame?maxWidth=160&quality=70&display=7"]);
    const down: ScreenTransport = { fetch: async () => new Response("", { status: 503 }) };
    assert.equal(await fetchFrame(down, undefined, 160), null);
  } finally {
    g.URL.createObjectURL = before;
  }
});

test("input and control: POST /input, POST /control; a refusal carries its status and body", async () => {
  const seen: { path: string; body: unknown; keepalive?: boolean }[] = [];
  const t: ScreenTransport = {
    fetch: async (path, init) => {
      seen.push({ path, body: JSON.parse(String(init.body)), keepalive: init.keepalive });
      if (path === "/input") return new Response(JSON.stringify({ error: "another device controls the screen", code: "controlled-elsewhere" }), { status: 409 });
      return new Response(JSON.stringify({ controller: "user" }), { status: 200 });
    },
  };
  await assert.rejects(sendInput(t, { type: "click", x: 0.5, y: 0.5 }), (e: unknown) => e instanceof RequestError && e.status === 409 && (e.body as { code: string }).code === "controlled-elsewhere" && e.message === "another device controls the screen");
  assert.deepEqual(await setControl(t, "user", { id: "web-1", name: "Chrome on Mac" }), { controller: "user" });
  assert.equal(await setControl(t, "none", undefined, true), null);
  assert.deepEqual(seen.slice(1), [
    { path: "/control", body: { controller: "user", device: { id: "web-1", name: "Chrome on Mac" } }, keepalive: false },
    { path: "/control", body: { controller: "none" }, keepalive: true },
  ]);
});
