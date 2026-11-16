import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { dialRtc, DUPLEX_RECV_MAX, DuplexReader, encodeDuplexMessage, encodeFrame, LinkError, MAX_DUPLEX_MESSAGE, messageBytes, type DialRtcOptions, type DuplexMessage, type LinkSession } from "../src/index.js";
import { FakeChannel, FakePeerConnection, Identity, ScriptedServer } from "./fake.js";

const WASM = readFileSync(fileURLToPath(new URL("../src/wasm/uu_link_wasm_bg.wasm", import.meta.url)));

const WELCOME = { t: "welcome", v: 1, server: { id: "srv", name: "Test Mac", platform: "macos" }, principal: null, features: ["link", "duplex"], maxDatagram: 1200 };

async function dial(server: ScriptedServer, over: Partial<DialRtcOptions> = {}): Promise<{ session: LinkSession; pc: FakePeerConnection }> {
  const identity = await Identity.create();
  let pc: FakePeerConnection | null = null;
  const session = await dialRtc({
    signal: async (offer) => identity.answer(offer.offer),
    pinnedFingerprint: identity.fingerprint,
    credential: "Bearer t0ken",
    device: { id: "dev-1", name: "Test Browser" },
    app: { name: "test", version: "1" },
    wasm: WASM,
    iface: "wifi",
    createPeerConnection: (c) => (pc = new FakePeerConnection(server, c)) as unknown as RTCPeerConnection,
    ...over,
  });
  return { session, pc: pc! };
}

/** A server whose `/ws` echoes every message (as the Rust core's tests' does): a close is echoed, then it finishes;
 *  the client's FIN gets its FIN. What it saw is kept. */
function echoServer(): { server: ScriptedServer; heads: Record<string, unknown>[]; seen: DuplexMessage[]; finIn: () => boolean } {
  const server = new ScriptedServer();
  server.onHello = (_h, send) => send(WELCOME);
  const heads: Record<string, unknown>[] = [];
  const seen: DuplexMessage[] = [];
  let fin = false;
  server.duplex = (head, ch, early) => {
    heads.push(head);
    if (head.p !== "/ws") {
      ch.send(encodeFrame({ s: 403, h: { "content-type": "application/json" } }));
      ch.send(new TextEncoder().encode('{"error":"no"}'));
      ch.send(new Uint8Array(0));
      return;
    }
    ch.send(encodeFrame({ s: 101, h: { "x-ws": "yes" } }));
    const reader = new DuplexReader();
    let finished = false;
    const take = (b: Uint8Array) => {
      if (b.length === 0) {
        fin = true;
        if (!finished) ch.send(new Uint8Array(0));
        finished = true;
        return;
      }
      for (const m of reader.push(b)) {
        seen.push(m);
        if (finished) continue;
        const bytes = encodeDuplexMessage(m);
        for (let i = 0; i < bytes.length; i += 16 * 1024) ch.send(bytes.slice(i, i + 16 * 1024));
        if (m.type === "close") {
          ch.send(new Uint8Array(0));
          finished = true;
        }
      }
    };
    if (early.length) take(early);
    ch.addEventListener("message", (ev) => take(messageBytes((ev as MessageEvent).data)));
  };
  return { server, heads, seen, finIn: () => fin };
}

const tick = () => new Promise((r) => setTimeout(r, 5));

test("the message format: u8 type + u32 BE length + payload; a close's u16 code; split and joined across channel messages", () => {
  const msgs: DuplexMessage[] = [{ type: "text", text: "hé" }, { type: "binary", data: new Uint8Array([1, 2, 3]) }, { type: "close", code: 4001, reason: "bye" }];
  const enc = msgs.map(encodeDuplexMessage);
  assert.deepEqual([...enc[0]!], [1, 0, 0, 0, 3, 0x68, 0xc3, 0xa9]);
  assert.deepEqual([...enc[2]!], [8, 0, 0, 0, 5, 0x0f, 0xa1, 0x62, 0x79, 0x65]);
  const all = new Uint8Array(enc.reduce((n, e) => n + e.length, 0));
  let at = 0;
  for (const e of enc) {
    all.set(e, at);
    at += e.length;
  }
  // one byte at a time, then all in one
  const r1 = new DuplexReader();
  const got: DuplexMessage[] = [];
  for (const b of all) got.push(...r1.push(new Uint8Array([b])));
  assert.deepEqual(got, msgs);
  assert.deepEqual(new DuplexReader().push(all), msgs);
  // limits: 1 MiB is the largest message; one over is refused both ways
  assert.equal(encodeDuplexMessage({ type: "binary", data: new Uint8Array(MAX_DUPLEX_MESSAGE) }).length, MAX_DUPLEX_MESSAGE + 5);
  assert.throws(() => encodeDuplexMessage({ type: "binary", data: new Uint8Array(MAX_DUPLEX_MESSAGE + 1) }), (e: unknown) => e instanceof LinkError && e.kind === "protocol");
  const over = new Uint8Array(5);
  new DataView(over.buffer).setUint32(1, MAX_DUPLEX_MESSAGE + 1);
  over[0] = 2;
  assert.throws(() => new DuplexReader().push(over), (e: unknown) => e instanceof LinkError && e.kind === "protocol");
  assert.throws(() => new DuplexReader().push(new Uint8Array([9, 0, 0, 0, 0])), /type 9/);
  assert.throws(() => new DuplexReader().push(new Uint8Array([8, 0, 0, 0, 1, 0])), /without a code/);
  assert.throws(() => new DuplexReader().push(new Uint8Array([1, 0, 0, 0, 1, 0xff])), /not UTF-8/);
});

test("requestDuplex: head with duplex: true and no body; 101; messages both ways; the largest; a close; FINs; the channel closed after both", async () => {
  const { server, heads, seen, finIn } = echoServer();
  const { session, pc } = await dial(server);
  const r = await session.requestDuplex({ method: "get", path: "/ws", headers: { "Sec-WebSocket-Protocol": "nest", Host: "x" } });
  assert.equal(r.status, 101);
  assert.equal(r.headers["x-ws"], "yes");
  assert.deepEqual(heads[0], { m: "GET", p: "/ws", h: { "sec-websocket-protocol": "nest" }, duplex: true });
  const d = r.duplex!;
  assert.ok(d);
  const ch = pc.channels.at(-1)!;
  assert.equal(ch.label, "rpc");
  const big = new Uint8Array(MAX_DUPLEX_MESSAGE).fill(7);
  const writer = (async () => {
    for (let i = 0; i < 50; i++) await (i % 2 ? d.sendBinary(new Uint8Array([i])) : d.sendText(`m${i}`));
    await d.sendBinary(big);
    await d.send({ type: "close", code: 4001, reason: "bye" });
  })();
  for (let i = 0; i < 50; i++) assert.deepEqual(await d.recv(), i % 2 ? { type: "binary", data: new Uint8Array([i]) } : { type: "text", text: `m${i}` });
  const b = (await d.recv()) as { type: "binary"; data: Uint8Array };
  assert.equal(b.data.length, MAX_DUPLEX_MESSAGE);
  assert.ok(ch.sent.every((m) => m.length <= 16 * 1024), "every channel message ≤ 16 KiB");
  assert.deepEqual(await d.recv(), { type: "close", code: 4001, reason: "bye" });
  assert.equal(await d.recv(), null, "the server finished");
  await writer;
  assert.equal(seen.length, 52);
  assert.equal(ch.readyState, "open", "not closed while this side's direction is open");
  await d.finish();
  await tick();
  assert.ok(finIn(), "this side's FIN");
  assert.equal(ch.readyState, "closed", "both directions done: the client closes the channel");
  await assert.rejects(d.sendText("late"), (e: unknown) => e instanceof LinkError && e.kind === "closed");
  await session.close();
});

test("a refusal: its status and body, no stream; the server takes no duplex: refused without asking", async () => {
  const { server } = echoServer();
  const { session } = await dial(server);
  const r = await session.requestDuplex({ method: "GET", path: "/nope" });
  assert.equal(r.status, 403);
  assert.equal(r.duplex, null);
  assert.equal(new TextDecoder().decode(await r.readAll()), '{"error":"no"}');
  await session.close();

  const plain = new ScriptedServer();
  const { session: s2, pc } = await dial(plain);
  const before = pc.channels.length;
  await assert.rejects(s2.requestDuplex({ method: "GET", path: "/ws" }), (e: unknown) => e instanceof LinkError && e.kind === "unsupported");
  assert.equal(pc.channels.length, before, "no channel opened");
  await s2.close();
});

test("a reset (the channel closed without a FIN) is an error; stopped resolves; cancel: recv ends, the channel closes, sends fail", async () => {
  const server = new ScriptedServer();
  server.onHello = (_h, send) => send(WELCOME);
  let serverEnd: FakeChannel | null = null;
  server.duplex = (_head, ch) => {
    serverEnd = ch;
    ch.send(encodeFrame({ s: 101, h: {} }));
    ch.send(encodeDuplexMessage({ type: "text", text: "hi" }));
  };
  const { session } = await dial(server);
  const d = (await session.requestDuplex({ method: "GET", path: "/ws" })).duplex!;
  assert.deepEqual(await d.recv(), { type: "text", text: "hi" });
  const stopped = d.stopped();
  serverEnd!.close();
  await assert.rejects(d.recv(), (e: unknown) => e instanceof LinkError && e.kind === "closed");
  await stopped;

  const d2 = (await session.requestDuplex({ method: "GET", path: "/ws" })).duplex!;
  assert.deepEqual(await d2.recv(), { type: "text", text: "hi" });
  const waiting = d2.recv();
  d2.cancel();
  assert.equal(await waiting, null, "a waiting recv returns null");
  assert.equal(await d2.recv(), null);
  await tick();
  assert.equal(serverEnd!.readyState, "closed", "the server sees the channel close");
  await assert.rejects(d2.sendText("x"), (e: unknown) => e instanceof LinkError && e.kind === "closed");
  await session.close();
});

test("a malformed message from the server: recv says protocol, the stream ends", async () => {
  const server = new ScriptedServer();
  server.onHello = (_h, send) => send(WELCOME);
  server.duplex = (_head, ch) => {
    ch.send(encodeFrame({ s: 101, h: {} }));
    ch.send(new Uint8Array([7, 0, 0, 0, 0]));
  };
  const { session } = await dial(server);
  const d = (await session.requestDuplex({ method: "GET", path: "/ws" })).duplex!;
  await assert.rejects(d.recv(), (e: unknown) => e instanceof LinkError && e.kind === "protocol");
  await session.close();
});

test("sends wait while the channel's buffer is full; they go on once it drains", async () => {
  const { server } = echoServer();
  const { session, pc } = await dial(server);
  const d = (await session.requestDuplex({ method: "GET", path: "/ws" })).duplex!;
  const ch = pc.channels.at(-1)!;
  ch.bufferedAmount = 1024 * 1024;
  let sent = false;
  const p = d.sendText("later").then(() => (sent = true));
  await tick();
  assert.equal(sent, false, "held back");
  ch.bufferedAmount = 0;
  ch.dispatchEvent(new Event("bufferedamountlow"));
  await p;
  assert.deepEqual(await d.recv(), { type: "text", text: "later" });
  await session.close();
});

test("sends and finish not awaited one by one go out in order, each message whole, the FIN after them all", async () => {
  const { server, seen, finIn } = echoServer();
  const { session, pc } = await dial(server);
  const d = (await session.requestDuplex({ method: "GET", path: "/ws" })).duplex!;
  const ch = pc.channels.at(-1)!;
  // the buffer full: every write waits for room, so un-serialized ones would wake together and interleave
  ch.bufferedAmount = 1024 * 1024;
  const big = (n: number) => new Uint8Array(100 * 1024).fill(n);
  const sends = [d.sendBinary(big(1)), d.sendText("small"), d.sendBinary(big(2))];
  const fin = d.finish();
  const late = d.sendText("late");
  await tick();
  assert.equal(ch.sent.length, 1, "only the head went before the drain");
  ch.bufferedAmount = 0;
  ch.dispatchEvent(new Event("bufferedamountlow"));
  await Promise.all(sends);
  await fin;
  await assert.rejects(late, (e: unknown) => e instanceof LinkError && e.kind === "closed");
  await tick();
  assert.deepEqual(seen, [{ type: "binary", data: big(1) }, { type: "text", text: "small" }, { type: "binary", data: big(2) }]);
  assert.ok(finIn());
  assert.equal(ch.sent.at(-1)!.length, 0, "the FIN is the last message sent");
  assert.equal(ch.sent.filter((m) => m.length === 0).length, 1);
  await session.close();
});

test("two recvs waiting at once each get a message", async () => {
  const server = new ScriptedServer();
  server.onHello = (_h, send) => send(WELCOME);
  let serverEnd: FakeChannel | null = null;
  server.duplex = (_head, ch) => {
    serverEnd = ch;
    ch.send(encodeFrame({ s: 101, h: {} }));
  };
  const { session } = await dial(server);
  const d = (await session.requestDuplex({ method: "GET", path: "/ws" })).duplex!;
  const a = d.recv();
  const b = d.recv();
  await tick();
  serverEnd!.send(encodeDuplexMessage({ type: "text", text: "one" }));
  serverEnd!.send(encodeDuplexMessage({ type: "text", text: "two" }));
  assert.deepEqual(await Promise.all([a, b]), [
    { type: "text", text: "one" },
    { type: "text", text: "two" },
  ]);
  const c = d.recv();
  const e = d.recv();
  serverEnd!.send(new Uint8Array(0));
  assert.deepEqual(await Promise.all([c, e]), [null, null], "the FIN ends every waiting one");
  await session.close();
});

test("the session's end ends its streams though the closed connection fires no channel events: recv, stopped, a waiting send, a request waiting for its head", async () => {
  const server = new ScriptedServer();
  server.onHello = (_h, send) => send(WELCOME);
  server.duplex = (head, ch) => {
    if (head.p === "/silent") return; // never answers
    ch.send(encodeFrame({ s: 101, h: {} }));
  };
  const { session, pc } = await dial(server);
  pc.silentClose = true;
  const d = (await session.requestDuplex({ method: "GET", path: "/ws" })).duplex!;
  pc.channels.at(-1)!.bufferedAmount = 1024 * 1024;
  const recv = d.recv();
  const stopped = d.stopped();
  const send = d.sendText("held");
  const head = session.requestDuplex({ method: "GET", path: "/silent" });
  const rpcHeld = session.request({ method: "POST", path: "/x" }, new Uint8Array(4 * 1024 * 1024));
  // its upload waits for room that never comes
  pc.channels.at(-1)!.buffering = true;
  await tick();
  assert.ok(pc.channels.at(-1)!.bufferedAmount > 0);
  const t0 = performance.now();
  await session.close();
  const closed = (e: unknown) => e instanceof LinkError && e.kind === "closed";
  await assert.rejects(recv, closed);
  await stopped;
  await assert.rejects(send, closed);
  await assert.rejects(head, closed);
  await assert.rejects(rpcHeld, (e: unknown) => e instanceof LinkError && e.kind !== "timeout");
  assert.ok(performance.now() - t0 < 2000, "at once, not at a timeout");
});

test("what the server sends and nobody reads is bounded (big messages or a flood of tiny ones): the stream is reset, what came first is still read", async () => {
  const server = new ScriptedServer();
  server.onHello = (_h, send) => send(WELCOME);
  const ends: FakeChannel[] = [];
  server.duplex = (head, ch) => {
    ends.push(ch);
    ch.send(encodeFrame({ s: 101, h: {} }));
    if (head.p === "/big") {
      for (let i = 0; i < 3; i++) {
        const bytes = encodeDuplexMessage({ type: "binary", data: new Uint8Array(MAX_DUPLEX_MESSAGE).fill(i) });
        for (let at = 0; at < bytes.length; at += 16 * 1024) ch.send(bytes.slice(at, at + 16 * 1024));
      }
    } else {
      // 1-byte messages: their bytes alone would be far under the bound
      for (let i = 0; i < DUPLEX_RECV_MAX / 40; i++) ch.send(encodeDuplexMessage({ type: "binary", data: new Uint8Array([1]) }));
    }
  };
  const { session } = await dial(server);
  const d = (await session.requestDuplex({ method: "GET", path: "/big" })).duplex!;
  await tick();
  assert.equal(ends[0]!.readyState, "closed", "reset: the server sees its channel close");
  for (let i = 0; i < 2; i++) {
    const m = (await d.recv()) as { type: "binary"; data: Uint8Array };
    assert.equal(m.data.length, MAX_DUPLEX_MESSAGE);
    assert.equal(m.data[0], i);
  }
  await assert.rejects(d.recv(), (e: unknown) => e instanceof LinkError && e.kind === "closed" && /weren't read/.test(e.message));

  const t = (await session.requestDuplex({ method: "GET", path: "/tiny" })).duplex!;
  await tick();
  assert.equal(ends[1]!.readyState, "closed");
  let n = 0;
  await assert.rejects(
    (async () => {
      for (;;) if (await t.recv()) n++;
    })(),
    (e: unknown) => e instanceof LinkError && e.kind === "closed",
  );
  assert.ok(n > 0 && n * 6 < DUPLEX_RECV_MAX / 5, `the overhead counts: ${n} tiny messages queued`);
  await session.close();
});

test("a malformed message after good ones in the same channel message: the good ones are read, then protocol", async () => {
  const server = new ScriptedServer();
  server.onHello = (_h, send) => send(WELCOME);
  server.duplex = (_head, ch) => {
    ch.send(encodeFrame({ s: 101, h: {} }));
    const a = encodeDuplexMessage({ type: "text", text: "a" });
    const b = encodeDuplexMessage({ type: "text", text: "b" });
    const bad = new Uint8Array([7, 0, 0, 0, 0]);
    const all = new Uint8Array(a.length + b.length + bad.length);
    all.set(a);
    all.set(b, a.length);
    all.set(bad, a.length + b.length);
    ch.send(all);
  };
  const { session } = await dial(server);
  const d = (await session.requestDuplex({ method: "GET", path: "/ws" })).duplex!;
  assert.deepEqual(await d.recv(), { type: "text", text: "a" });
  assert.deepEqual(await d.recv(), { type: "text", text: "b" });
  await assert.rejects(d.recv(), (e: unknown) => e instanceof LinkError && e.kind === "protocol");
  await session.close();
});
