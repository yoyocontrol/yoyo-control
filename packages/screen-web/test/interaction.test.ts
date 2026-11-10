import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { INTERACTIVE_TAIL_MS, Interactivity, withInteraction, type InteractivityClock } from "../src/interaction.js";
import type { ScreenTransport } from "../src/transport.js";
import type { Input } from "../src/types.js";
import { VideoStream } from "../src/video.js";

/** A clock whose timers run when the test moves it on. */
function manualClock(): InteractivityClock & { advance(ms: number): void } {
  let now = 0;
  let timers: { at: number; fn: () => void; id: number }[] = [];
  let id = 0;
  return {
    now: () => now,
    setTimeout: (fn, ms) => {
      timers.push({ at: now + ms, fn, id: ++id });
      return id;
    },
    clearTimeout: (h) => {
      timers = timers.filter((t) => t.id !== h);
    },
    advance(ms) {
      const end = now + ms;
      for (;;) {
        const due = timers.filter((t) => t.at <= end).sort((a, b) => a.at - b.at)[0];
        if (!due) break;
        timers = timers.filter((t) => t !== due);
        now = due.at;
        due.fn();
      }
      now = end;
    },
  };
}

test("interactivity: on from the first contact, off a tail after the last lifts; a contact back within it keeps it on", () => {
  assert.equal(INTERACTIVE_TAIL_MS, 600);
  const clock = manualClock();
  const i = new Interactivity(INTERACTIVE_TAIL_MS, clock);
  const changes: boolean[] = [];
  i.subscribe((on) => changes.push(on));
  assert.equal(i.on, false);
  i.down();
  i.down();
  assert.deepEqual(changes, [true], "one change for two fingers");
  i.up();
  clock.advance(5000);
  assert.equal(i.on, true, "a finger is still down");
  i.up();
  clock.advance(599);
  assert.equal(i.on, true);
  i.down();
  clock.advance(5000);
  assert.equal(i.on, true);
  i.up();
  clock.advance(600);
  assert.equal(i.on, false);
  assert.deepEqual(changes, [true, false]);
  i.up();
  assert.equal(i.on, false, "an extra up does nothing");
});

test("interactivity: inputs keep it on for the tail; reset turns it off at once", () => {
  const clock = manualClock();
  const i = new Interactivity(INTERACTIVE_TAIL_MS, clock);
  const sent: Input[] = [];
  const send = withInteraction(async (input) => void sent.push(input), i);
  void send({ type: "key", key: "a" });
  assert.equal(i.on, true);
  clock.advance(500);
  void send({ type: "type", text: "b" });
  clock.advance(500);
  assert.equal(i.on, true, "the tail runs from the last input");
  clock.advance(100);
  assert.equal(i.on, false);
  assert.equal(sent.length, 2);
  i.down();
  i.pulse();
  clock.advance(10_000);
  assert.equal(i.on, true, "a finger down keeps it on whatever the keys do");
  i.reset();
  assert.equal(i.on, false);
});

// ---- the stream's playout follows it

const FIXTURE = new Uint8Array(readFileSync(resolve(import.meta.dirname, "fixtures/screen-stream.bin")));

function transport(): ScreenTransport {
  return {
    fetch: async (path, init) => {
      if (path === "/stream/ack") return new Response('{"ok":true}', { status: 200, headers: { "content-type": "application/json" } });
      const signal = init.signal;
      const body = new ReadableStream<Uint8Array>({
        start(c) {
          c.enqueue(FIXTURE);
          signal?.addEventListener("abort", () => c.error(new DOMException("aborted", "AbortError")));
        },
      });
      return new Response(body, { status: 200, headers: { "content-type": "application/vnd.yoyo-control.stream; boundary=frame", "x-stream-codec": "h264" } });
    },
  };
}

/** A decoder that outputs a frame for each chunk; animation frames the test runs by hand; a canvas that counts. */
function fakes() {
  const g = globalThis as Record<string, unknown>;
  const before = { VideoDecoder: g.VideoDecoder, EncodedVideoChunk: g.EncodedVideoChunk, requestAnimationFrame: g.requestAnimationFrame, cancelAnimationFrame: g.cancelAnimationFrame };
  const state = { frames: 0, closed: 0, drawn: 0, rafs: [] as ((t: number) => void)[] };
  g.VideoDecoder = class {
    state = "unconfigured";
    decodeQueueSize = 0;
    constructor(private readonly init: { output: (f: unknown) => void }) {}
    configure() {
      this.state = "configured";
    }
    decode(chunk: { init: { timestamp: number } }) {
      state.frames++;
      const frame = { timestamp: chunk.init.timestamp, displayWidth: 8, displayHeight: 6, close: () => void state.closed++ };
      queueMicrotask(() => this.init.output(frame));
    }
    reset() {}
    close() {
      this.state = "closed";
    }
  };
  g.EncodedVideoChunk = class {
    constructor(public init: unknown) {}
  };
  g.requestAnimationFrame = (cb: (t: number) => void) => state.rafs.push(cb);
  g.cancelAnimationFrame = () => {};
  const canvas = { width: 0, height: 0, getContext: () => ({ drawImage: () => void state.drawn++ }) } as unknown as HTMLCanvasElement;
  const runRaf = (t: number) => {
    const cbs = state.rafs;
    state.rafs = [];
    for (const cb of cbs) cb(t);
  };
  return { state, canvas, runRaf, undo: () => Object.assign(g, before) };
}

const settle = () => new Promise((r) => setTimeout(r, 30));

test("VideoStream: smooth pictures wait; a finger down draws the newest at once and closes the ones it passed", async () => {
  const f = fakes();
  const interactivity = new Interactivity(INTERACTIVE_TAIL_MS, manualClock());
  const s = new VideoStream({ transport: transport(), canvas: f.canvas, interactivity, route: "tunnel" }, { onPicture: () => {}, onCursor: () => {}, onStatus: () => {}, onEnd: () => {} });
  try {
    void s.run();
    await settle();
    assert.ok(f.state.frames >= 2, `decoded ${f.state.frames}`);
    assert.equal(s.playoutState().mode, "smooth");
    // the pictures wait for their time (the 25 ms start depth + a refresh): an animation frame right now draws none
    // of the ones not due yet
    const waiting = s.playoutState().queued;
    assert.ok(waiting >= 1);
    interactivity.down();
    assert.equal(s.playoutState().mode, "responsive");
    // far enough on that the interactive rule has them all due: the newest is drawn, the rest closed undrawn
    f.runRaf(performance.now() + 1000);
    assert.equal(s.playoutState().queued, 0);
    assert.equal(f.state.closed, f.state.frames, "every frame was let go (drawn or not)");
    assert.ok(f.state.drawn >= 1);
  } finally {
    s.close();
    f.undo();
  }
});

test("VideoStream: on the LAN while interacting (no touch budget) and with playout \"arrival\", each picture is drawn on the next frame", async () => {
  for (const opts of [{ route: "lan" as const, on: true }, { route: "tunnel" as const, arrival: true }]) {
    const f = fakes();
    const interactivity = new Interactivity(INTERACTIVE_TAIL_MS, manualClock());
    if (opts.on) interactivity.down();
    const s = new VideoStream(
      { transport: transport(), canvas: f.canvas, interactivity, route: opts.route, ...(opts.arrival ? { playout: "arrival" as const } : {}) },
      { onPicture: () => {}, onCursor: () => {}, onStatus: () => {}, onEnd: () => {} },
    );
    try {
      void s.run();
      await settle();
      assert.equal(s.playoutState().queued, 0, "nothing waits");
      assert.equal(s.playoutState().mode, "responsive");
      f.runRaf(performance.now());
      assert.equal(f.state.drawn, 1, "the newest");
      assert.equal(f.state.closed, f.state.frames);
    } finally {
      s.close();
      f.undo();
    }
  }
});
