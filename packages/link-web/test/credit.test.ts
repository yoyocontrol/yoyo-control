// The credit window (docs/LINK.md「信用窗口」) against a scripted server that speaks it: grants as text messages, the
// same units on both sides (each non-empty binary message's length + 64), a pool per session.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import {
  CREDIT_INITIAL,
  CREDIT_POOL,
  CREDIT_WINDOW,
  dialRtc,
  DuplexReader,
  encodeDuplexMessage,
  encodeFrame,
  LinkError,
  messageBytes,
  messageCost,
  type DialRtcOptions,
  type LinkSession,
} from "../src/index.js";
import { FakeChannel, FakePeerConnection, Identity, ScriptedServer } from "./fake.js";

const WASM = readFileSync(fileURLToPath(new URL("../src/wasm/uu_link_wasm_bg.wasm", import.meta.url)));
const WELCOME = { t: "welcome", v: 1, server: { id: "srv", name: "Test Mac", platform: "macos" }, principal: null, features: ["link", "duplex", "credit"], maxDatagram: 1200 };
const tick = (ms = 5) => new Promise((r) => setTimeout(r, ms));

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

/** The server end of one channel under the window: what it allowed the client and what came (any excess is a
 *  violation, counted), what the client allowed it and what it sent. */
class ServerCredit {
  granted = CREDIT_INITIAL;
  received = 0;
  peerGranted = CREDIT_INITIAL;
  sent = 0;
  violations = 0;
  private waiters: (() => void)[] = [];

  constructor(readonly ch: FakeChannel) {
    ch.addEventListener("message", (ev) => {
      const d = (ev as MessageEvent).data;
      if (typeof d === "string") {
        this.peerGranted = Math.max(this.peerGranted, (JSON.parse(d) as { credit: number }).credit);
        for (const w of this.waiters.splice(0)) w();
        return;
      }
      const n = messageBytes(d).length;
      this.received += messageCost(n);
      if (this.received > this.granted) this.violations++;
    });
  }

  /** Lets the client send `more` beyond what it sent so far. */
  grant(more: number): void {
    this.granted = this.received + more;
    this.ch.send(JSON.stringify({ credit: this.granted }));
  }

  /** Sends `bytes` once the client's window has room (as a server that takes the window does). */
  async send(bytes: Uint8Array): Promise<void> {
    while (this.sent + messageCost(bytes.length) > this.peerGranted) await new Promise<void>((r) => this.waiters.push(r));
    this.ch.send(bytes);
    this.sent += messageCost(bytes.length);
  }

  /** Until the client's window has room for `n` more, at most `ms`; false if it didn't come. */
  async waitRoom(n: number, ms: number): Promise<boolean> {
    const until = performance.now() + ms;
    while (this.sent + messageCost(n) > this.peerGranted) {
      if (performance.now() > until) return false;
      await tick(2);
    }
    return true;
  }
}

test("both sides say credit: an upload waits for the server's grants and never goes past them (head and body, len + 64 each)", async () => {
  const server = new ScriptedServer();
  server.onHello = (h, send) => {
    assert.ok((h.features as string[]).includes("credit"), "the hello offers it");
    send(WELCOME);
  };
  let sc: ServerCredit | null = null;
  const origChannel = server.channel.bind(server);
  server.channel = (ch) => {
    sc = new ServerCredit(ch);
    origChannel(ch);
  };
  const { session, pc } = await dial(server);
  const size = 3 * 1024 * 1024;
  const pending = session.request({ method: "POST", path: "/up" }, new Uint8Array(size).fill(5));
  await tick(20);
  const ch = pc.channels.at(-1)!;
  const sentBytes = () => ch.sent.reduce((n, m) => n + messageCost(m.length), 0);
  assert.ok(sentBytes() <= CREDIT_INITIAL, `held to the initial window: ${sentBytes()}`);
  assert.ok(sentBytes() > CREDIT_INITIAL - 17 * 1024, "and used it");
  // the server reads and grants 256 KiB at a time
  let done = false;
  void pending.then(() => (done = true));
  for (let i = 0; i < 100 && !done; i++) {
    sc!.grant(256 * 1024);
    await tick(2);
    assert.ok(sentBytes() <= sc!.granted, "never past the grant");
  }
  const r = await pending;
  assert.deepEqual(await r.json(), { m: "POST", p: "/up", n: size });
  assert.equal(sc!.violations, 0);
  assert.ok(ch.sent.every((m) => m.length <= 16 * 1024), "the head too in ≤ 16 KiB pieces");
  await session.close();
});

test("an answer's body: grants only as the app reads it; what waits in the page is the window, not the body", async () => {
  const server = new ScriptedServer();
  server.onHello = (_h, send) => send(WELCOME);
  const total = 8 * 1024 * 1024;
  let sc: ServerCredit | null = null;
  let wrote = 0;
  const origChannel = server.channel.bind(server);
  server.channel = (ch) => {
    sc = new ServerCredit(ch);
    origChannel(ch);
  };
  server.rpc = (_head, _body, ch) => {
    void (async () => {
      await sc!.send(encodeFrame({ s: 200, h: {} }));
      for (let at = 0; at < total; at += 16 * 1024) {
        await sc!.send(new Uint8Array(16 * 1024).fill(9));
        wrote += 16 * 1024;
      }
      ch.send(new Uint8Array(0));
    })();
  };
  const { session } = await dial(server);
  const r = await session.request({ method: "GET", path: "/big" });
  await tick(50);
  assert.ok(wrote <= CREDIT_WINDOW, `the server is held to the window while nobody reads: ${wrote}`);
  // a slow reader: a piece every so often, the server follows
  let got = 0;
  for (let i = 0; i < 20; i++) {
    const c = await r.chunk();
    got += c!.length;
  }
  await tick(10);
  assert.ok(wrote <= got + CREDIT_WINDOW, `ahead of the reader by at most the window: wrote ${wrote}, read ${got}`);
  for (let c = await r.chunk(); c; c = await r.chunk()) got += c.length;
  assert.equal(got, total);
  assert.equal(sc!.violations, 0);
  await session.close();
});

test("duplex both ways: a slow reader on either side holds the writer back, no reset; a server past its credit is a protocol error", async () => {
  const server = new ScriptedServer();
  server.onHello = (_h, send) => send(WELCOME);
  const ends: { ch: FakeChannel; sc: ServerCredit; seen: number }[] = [];
  server.duplex = (head, ch) => {
    const sc = new ServerCredit(ch);
    const end = { ch, sc, seen: 0 };
    ends.push(end);
    // (the head's pieces were read: the server would grant for them)
    sc.received = messageCost(encodeFrame({ m: "GET", p: head.p, h: {}, duplex: true }).length);
    void sc.send(encodeFrame({ s: 101, h: {} }));
    const reader = new DuplexReader();
    ch.addEventListener("message", (ev) => {
      const d = (ev as MessageEvent).data;
      if (typeof d === "string") return;
      end.seen += reader.push(messageBytes(d)).length;
    });
  };
  const { session } = await dial(server);
  const d = (await session.requestDuplex({ method: "GET", path: "/ws" })).duplex!;
  const e = ends[0]!;
  // this side writes 2 MiB; the server grants nothing past the initial window
  let sent = 0;
  const writer = (async () => {
    for (let i = 0; i < 32; i++) {
      await d.sendBinary(new Uint8Array(64 * 1024));
      sent++;
    }
  })();
  await tick(30);
  assert.ok(sent <= 1, `held back by the server's window: ${sent} sent`);
  for (let i = 0; i < 200 && sent < 32; i++) {
    e.sc.grant(128 * 1024);
    await tick(2);
  }
  await writer;
  await tick(5);
  assert.equal(e.seen, 32);
  assert.equal(e.sc.violations, 0);

  // the server writes 4 MiB to a slow reader here: within this side's grants, no reset
  const msg = encodeDuplexMessage({ type: "binary", data: new Uint8Array(60 * 1024).fill(1) });
  let wrote = 0;
  const serverWriter = (async () => {
    for (let i = 0; i < 70; i++) {
      for (let at = 0; at < msg.length; at += 16 * 1024) await e.sc.send(msg.slice(at, at + 16 * 1024));
      wrote++;
    }
  })();
  await tick(30);
  assert.ok(wrote * msg.length <= CREDIT_WINDOW, `the server is held to this side's window: ${wrote} messages`);
  for (let i = 0; i < 70; i++) {
    const m = await d.recv();
    assert.equal(m?.type, "binary");
    if (i % 10 === 0) await tick(3);
  }
  await serverWriter;

  // the largest message (1 MiB: more than the window with its overhead) still gets through, reading or not
  const largest = encodeDuplexMessage({ type: "binary", data: new Uint8Array(1024 * 1024).fill(4) });
  for (let at = 0; at < largest.length; at += 16 * 1024) await e.sc.send(largest.slice(at, at + 16 * 1024));
  const l = (await d.recv()) as { type: "binary"; data: Uint8Array };
  assert.equal(l.data.length, 1024 * 1024);

  // past the window: the server broke the protocol
  const room = e.sc.peerGranted - e.sc.sent;
  const over = encodeDuplexMessage({ type: "binary", data: new Uint8Array(1000) });
  for (let at = 0; at <= room + 16 * 1024; at += over.length) e.ch.send(over);
  await assert.rejects(
    (async () => {
      for (;;) await d.recv();
    })(),
    (err: unknown) => err instanceof LinkError && err.kind === "protocol" && /credit/.test(err.message),
  );
  await session.close();
});

test("tiny messages cost what they take (len + 64 on both sides): a compliant flood is never over the server's window", async () => {
  const server = new ScriptedServer();
  server.onHello = (_h, send) => send(WELCOME);
  let sc: ServerCredit | null = null;
  server.duplex = (head, ch) => {
    sc = new ServerCredit(ch);
    sc.received = messageCost(encodeFrame({ m: "GET", p: head.p, h: {}, duplex: true }).length);
    void sc.send(encodeFrame({ s: 101, h: {} }));
  };
  const { session } = await dial(server);
  const d = (await session.requestDuplex({ method: "GET", path: "/ws" })).duplex!;
  let n = 0;
  const writer = (async () => {
    for (; n < 5000; n++) await d.sendBinary(new Uint8Array([1]));
  })();
  await tick(30);
  // 6 bytes each: 64 KiB of credit is ~935 of them, not ~10 900
  assert.ok(n <= Math.floor(CREDIT_INITIAL / messageCost(6)) + 1, `${n} tiny messages in the initial window`);
  for (let i = 0; i < 400 && n < 5000; i++) {
    sc!.grant(64 * 1024);
    await tick(2);
  }
  await writer;
  assert.equal(sc!.violations, 0);
  await session.close();
});

test("the session's pool: streams that read a little and stop can't each hold a whole window", async () => {
  const server = new ScriptedServer();
  server.onHello = (_h, send) => send(WELCOME);
  const ends: ServerCredit[] = [];
  server.duplex = (head, ch) => {
    const sc = new ServerCredit(ch);
    sc.received = messageCost(encodeFrame({ m: "GET", p: head.p, h: {}, duplex: true }).length);
    ends.push(sc);
    void (async () => {
      await sc.send(encodeFrame({ s: 101, h: {} }));
      // as much as this side lets it
      const piece = encodeDuplexMessage({ type: "binary", data: new Uint8Array(16 * 1024 - 5) });
      while (await sc.waitRoom(piece.length, 100)) await sc.send(piece);
    })();
  };
  const { session } = await dial(server);
  const streams = 12;
  const ds = [];
  for (let i = 0; i < streams; i++) {
    const d = (await session.requestDuplex({ method: "GET", path: "/ws" })).duplex!;
    await d.recv(); // reads one, then stops
    ds.push(d);
    await tick(20);
  }
  await tick(150);
  const out = ends.reduce((n, sc) => n + sc.sent, 0);
  assert.ok(out <= CREDIT_POOL + streams * 2 * CREDIT_INITIAL, `${out} granted over ${streams} streams`);
  assert.ok(out >= CREDIT_POOL / 2, `the pool was used: ${out}`);
  await session.close();
});

test("credit: false, or a server that doesn't say it: no grants, today's behaviour", async () => {
  const server = new ScriptedServer();
  let offered: unknown;
  server.onHello = (h, send) => {
    offered = h.features;
    send(WELCOME);
  };
  const { session, pc } = await dial(server, { credit: false });
  assert.ok(!(offered as string[]).includes("credit"));
  const r = await session.request({ method: "POST", path: "/x" }, new Uint8Array(256 * 1024));
  assert.equal(r.status, 200);
  await r.readAll();
  assert.equal(pc.channels.at(-1)!.sentText.length, 0, "no grants");
  await session.close();
});

/** A server that, per duplex stream, sends `burst` bytes at once (within this side's credit) and then `more` when the
 *  test asks (`go`). */
function burstServer(burst: number): { server: ScriptedServer; ends: ServerCredit[]; go: (i: number, more: number) => Promise<void> } {
  const server = new ScriptedServer();
  server.onHello = (_h, send) => send(WELCOME);
  const ends: ServerCredit[] = [];
  const piece = encodeDuplexMessage({ type: "binary", data: new Uint8Array(16 * 1024 - 5) });
  const go = async (i: number, more: number) => {
    for (let n = 0; n < more; n += piece.length) await ends[i]!.send(piece);
  };
  server.duplex = (head, ch) => {
    const sc = new ServerCredit(ch);
    sc.received = messageCost(encodeFrame({ m: "GET", p: head.p, h: {}, duplex: true }).length);
    const i = ends.push(sc) - 1;
    void (async () => {
      await sc.send(encodeFrame({ s: 101, h: {} }));
      await go(i, burst);
    })();
  };
  return { server, ends, go };
}

test("streams that had a burst (read) and went quiet hold none of the pool: a new stream gets a whole window", async () => {
  const { server, ends, go } = burstServer(512 * 1024);
  const { session } = await dial(server);
  const ds = [];
  for (let i = 0; i < 12; i++) {
    const d = (await session.requestDuplex({ method: "GET", path: "/ws" })).duplex!;
    for (let k = 0; k < (512 * 1024) / (16 * 1024); k++) await d.recv(); // the server's 16 KiB messages
    ds.push(d);
  }
  // each idle stream keeps ~1 MiB of credit it doesn't use; the new one isn't held to the initial window
  const fresh = (await session.requestDuplex({ method: "GET", path: "/ws" })).duplex!;
  for (let k = 0; k < (512 * 1024) / (16 * 1024); k++) await fresh.recv();
  const sc = ends.at(-1)!;
  assert.ok(sc.peerGranted - sc.sent > CREDIT_WINDOW / 2, `a whole window: ${sc.peerGranted - sc.sent} left`);
  const more = go(12, 2 * 1024 * 1024);
  for (let k = 0; k < (2 * 1024 * 1024) / (16 * 1024); k++) await fresh.recv();
  await more;
  await session.close();
});

test("a full pool: a stream whose sender has less left than a message still gets a grant (no stall)", async () => {
  const { server, ends, go } = burstServer(0);
  const { session } = await dial(server);
  // the pool full of unread bytes: streams that took a window's worth and stopped reading
  const held = [];
  for (let i = 0; i < 10; i++) {
    const d = (await session.requestDuplex({ method: "GET", path: "/ws" })).duplex!;
    await tick(5);
    const sc = ends[i]!;
    while (await sc.waitRoom(16 * 1024, 30)) await go(i, 1);
    held.push(d);
  }
  // a new stream, read as it comes: it moves on the initial window, 2 MiB of it
  const d = (await session.requestDuplex({ method: "GET", path: "/ws" })).duplex!;
  const sending = go(10, 2 * 1024 * 1024);
  let got = 0;
  const reading = (async () => {
    while (got < Math.floor((2 * 1024 * 1024) / (16 * 1024 - 5))) {
      await d.recv();
      got++;
    }
  })();
  await Promise.race([Promise.all([sending, reading]), tick(5000).then(() => assert.fail(`stalled after ${got} messages`))]);
  assert.equal(ends[10]!.violations, 0);
  await session.close();
});

test("a grant the browser refuses to send is not counted as given: it goes again (bufferedamountlow, the next read)", async () => {
  const { server, ends, go } = burstServer(0);
  const { session, pc } = await dial(server);
  const d = (await session.requestDuplex({ method: "GET", path: "/ws" })).duplex!;
  const ch = pc.channels.at(-1)!;
  ch.refuseText = 3;
  const total = 2 * 1024 * 1024;
  const sending = go(0, total);
  let got = 0;
  const reading = (async () => {
    while (got < Math.floor(total / (16 * 1024 - 5))) {
      await d.recv();
      got++;
    }
  })();
  for (let i = 0; i < 50 && ch.refuseText > 0; i++) await tick(5);
  assert.equal(ch.refuseText, 0, "grants were refused");
  // what a browser does once its queue drains
  for (let i = 0; i < 20; i++) {
    ch.dispatchEvent(new Event("bufferedamountlow"));
    await tick(5);
  }
  await Promise.race([Promise.all([sending, reading]), tick(5000).then(() => assert.fail(`stuck after ${got}`))]);
  assert.equal(ends[0]!.violations, 0);
  await session.close();
});
