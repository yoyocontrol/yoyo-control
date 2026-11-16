// The browser half of the end-to-end test (run.mjs bundles it): dials uu-link-probe's rtc listener through its
// localhost signaling, then measures what docs/LINK.md's probe table measures for QUIC — time to welcome, RPC and
// control round trips, an 8 MiB RPC download, a 50 Hz datagram ping (channel 14), the synthetic video through the
// wasm media layer, input acks — and returns it as JSON.

import { clientCertificate, clientKeyOf, dialRtc, indexedDbCertificateStore, type LinkSession, type MediaEvent } from "../../src/index.js";

interface Config {
  signal: string;
  fingerprint: string;
  credential: string;
  seconds: number;
  /** A real server (`--signal-url`): welcome, path and control round trips only. */
  real?: boolean;
  /** `--speed-test <ms>`: only the speed test (docs/LINK.md「测速」), its report. */
  speedTestMs?: number;
}

const pct = (v: number[], p: number) => {
  if (!v.length) return null;
  const s = [...v].sort((a, b) => a - b);
  return Math.round(s[Math.min(s.length - 1, Math.floor(p * s.length))]! * 100) / 100;
};
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** The page's JS heap in use after a GC (the runner measures it over CDP: `e2eHeapAsk`); null when it can't. */
function heapUsed(): Promise<number | null> {
  const g = globalThis as { e2eHeapAsk?: (s: string) => void; __e2eHeap?: (n: number) => void };
  if (typeof g.e2eHeapAsk !== "function") return Promise.resolve(null);
  return new Promise((r) => {
    g.__e2eHeap = r;
    g.e2eHeapAsk!("");
  });
}

async function controlRtt(session: LinkSession, n: number): Promise<number[]> {
  const out: number[] = [];
  for (let i = 0; i < n; i++) {
    const t0 = performance.now();
    const pong = new Promise<void>((resolve) => {
      const off = session.onControl((m) => {
        if (m.t === "pong" && m.n === i) {
          off();
          resolve();
        }
      });
    });
    session.sendControl({ t: "ping", n: i });
    await pong;
    out.push(performance.now() - t0);
  }
  return out;
}

const dial = (cfg: Config, credit = true) =>
  dialRtc({
    credit,
    signal: async (offer) => {
      const res = await fetch(cfg.signal, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(offer) });
      if (!res.ok) throw new Error(`signal: HTTP ${res.status} ${await res.text()}`);
      return res.text();
    },
    pinnedFingerprint: cfg.fingerprint,
    credential: cfg.credential,
    device: { id: "e2e-browser", name: "Headless Chrome" },
    app: { name: "link-web-e2e", version: "1" },
  });

/** The probe puts the client key it saw (`AuthRequest.client_key`) into `welcome.principal.client`. */
const clientKeyOfSession = (s: LinkSession) => (s.welcome.principal as { client?: string } | null)?.client;

async function run(cfg: Config) {
  (globalThis as { __linkDebug?: boolean }).__linkDebug = true;
  const result: Record<string, unknown> = { userAgent: navigator.userAgent };
  const t0 = performance.now();
  const session = await dial(cfg);
  console.log("e2e: dialed");
  result.welcomeMs = Math.round((performance.now() - t0) * 10) / 10;
  result.timing = session.timing;
  result.server = session.server;
  await sleep(600);
  result.path = session.path();
  if (cfg.speedTestMs) {
    result.speedTest = await session.probe(cfg.speedTestMs);
    await session.close();
    return result;
  }
  if (cfg.real) {
    const rpc: number[] = [];
    for (let i = 0; i < 10; i++) {
      const t = performance.now();
      const r = await session.request({ method: "GET", path: "/status" });
      await r.text();
      rpc.push(performance.now() - t);
    }
    result.rpcStatusMs = { p50: pct(rpc, 0.5), p90: pct(rpc, 0.9) };
    result.principal = session.welcome.principal;
    result.peer = session.peerStats();
    await session.close();
    return result;
  }

  // RPC
  const rpc: number[] = [];
  for (let i = 0; i < 20; i++) {
    const t = performance.now();
    const r = await session.request({ method: "POST", path: "/echo" }, new TextEncoder().encode("0123456789"));
    const body = await r.text();
    if (body !== "0123456789") throw new Error(`echo: ${body}`);
    rpc.push(performance.now() - t);
  }
  result.rpcEchoMs = { p50: pct(rpc, 0.5), p90: pct(rpc, 0.9) };
  console.log("e2e: rpc echo");
  const td = performance.now();
  const big = await (await session.request({ method: "GET", path: "/bytes?n=8388608" })).readAll(16 << 20);
  const secs = (performance.now() - td) / 1000;
  result.rpcDownload = { bytes: big.length, mbps: Math.round(((big.length * 8) / 1e6 / secs) * 10) / 10 };
  console.log("e2e: download 8 MiB");
  // uploads, paced by the channel's buffer (and the server's credit): 7 MiB echoed
  const up = new Uint8Array(7 * 1024 * 1024);
  for (let i = 0; i < up.length; i += 4096) up[i] = (i / 4096) & 0xff;
  const tu = performance.now();
  const echoed = await (await session.request({ method: "POST", path: "/echo" }, up)).readAll(16 << 20);
  const usecs = (performance.now() - tu) / 1000;
  if (echoed.length !== up.length || echoed.some((b, i) => b !== up[i])) throw new Error(`upload echo: ${echoed.length} bytes`);
  // 30 MiB (twice Chrome's send queue; the probe takes bodies up to 64 MiB): it arrives whole
  const huge = new Uint8Array(30 * 1024 * 1024);
  for (let i = 0; i < huge.length; i += 997) huge[i] = i & 0xff;
  let sum = 0;
  for (let i = 0; i < huge.length; i += 997) sum = (sum + huge[i]!) >>> 0;
  const th = performance.now();
  const sunk = (await (await session.request({ method: "POST", path: "/sink" }, huge)).json()) as { n: number; sum: number };
  const hsecs = (performance.now() - th) / 1000;
  if (sunk.n !== huge.length || sunk.sum !== sum) throw new Error(`a 30 MiB upload: ${JSON.stringify(sunk)}`);
  result.rpcUpload = {
    bytes: up.length,
    mbps: Math.round(((up.length * 8) / 1e6 / usecs) * 10) / 10,
    upload30MiB: { ok: true, mbps: Math.round(((huge.length * 8) / 1e6 / hsecs) * 10) / 10 },
  };

  // the credit window (both sides say `credit`): an answer nobody reads waits in the server, not in this page
  result.credit = session.welcome.features.includes("credit");
  console.log("e2e: uploads");
  if (result.credit) {
    const n = 50 * 1024 * 1024;
    const before = await heapUsed();
    const t0 = performance.now();
    const r = await session.request({ method: "GET", path: `/bytes?n=${n}` });
    await new Promise((res) => setTimeout(res, 2000)); // nobody reads for 2 s
    const idle = await heapUsed();
    // then a slow reader: a pause every MiB
    let got = 0;
    let peak = idle;
    for (let c = await r.chunk(); c; c = await r.chunk()) {
      got += c.length;
      if (got % (1024 * 1024) < c.length) await new Promise((res) => setTimeout(res, 10));
      if (got % (10 * 1024 * 1024) < c.length) peak = Math.max(peak ?? 0, (await heapUsed()) ?? 0);
    }
    if (got !== n) throw new Error(`a 50 MiB download: ${got} bytes`);
    const mib = (x: number | null) => (x === null || before === null ? null : Math.round(((x - before) / 1048576) * 10) / 10);
    result.creditDownload = { bytes: got, ms: Math.round(performance.now() - t0), heapIdleMiB: mib(idle), heapPeakMiB: mib(peak) };
  console.log("e2e: credit download");
    if (before !== null && idle !== null && idle - before > 4 * 1024 * 1024) throw new Error(`the page held ${mib(idle)} MiB of an unread answer`);

    // a slow duplex reader (`/ws-slow`: a message every 20 ms) holds the writer back: 4 MiB, no reset
    const d = (await session.requestDuplex({ method: "GET", path: "/ws-slow" })).duplex!;
    const td = performance.now();
    const sends: Promise<void>[] = [];
    for (let i = 0; i < 64; i++) sends.push(d.sendBinary(new Uint8Array(64 * 1024).fill(i)));
    await Promise.all(sends);
    await d.finish();
    const count = await d.recv();
    if (!count || count.type !== "text" || count.text !== String(64 * 64 * 1024)) throw new Error(`slow duplex: ${JSON.stringify(count)}`);
    result.creditDuplex = { bytes: 64 * 64 * 1024, ms: Math.round(performance.now() - td) };
  console.log("e2e: credit duplex");
  }

  // a duplex request (a WebSocket over the link): `/ws` echoes; 20 messages, the largest, a close, both FINs
  if (session.welcome.features.includes("duplex")) {
    const t = performance.now();
    const r = await session.requestDuplex({ method: "GET", path: "/ws" });
    if (r.status !== 101 || !r.duplex) throw new Error(`duplex: ${r.status}`);
    const d = r.duplex;
    // not awaited one by one: they go in order, each whole
    const sends: Promise<void>[] = [];
    for (let i = 0; i < 20; i++) sends.push(d.sendText(`m${i}`));
    sends.push(d.sendBinary(new Uint8Array(1024 * 1024).fill(7)));
    sends.push(d.send({ type: "close", code: 4001, reason: "bye" }));
    const sending = Promise.all(sends);
    for (let i = 0; i < 20; i++) {
      const m = await d.recv();
      if (!m || m.type !== "text" || m.text !== `m${i}`) throw new Error(`duplex echo ${i}: ${JSON.stringify(m)}`);
    }
    const big = await d.recv();
    if (!big || big.type !== "binary" || big.data.length !== 1024 * 1024) throw new Error("duplex: the 1 MiB message");
    const close = await d.recv();
    if (!close || close.type !== "close" || close.code !== 4001 || close.reason !== "bye") throw new Error(`duplex close: ${JSON.stringify(close)}`);
    if ((await d.recv()) !== null) throw new Error("duplex: no FIN");
    await sending;
    await d.finish();
    result.duplex = { ok: true, ms: Math.round(performance.now() - t) };
  } else {
    result.duplex = { ok: false, reason: "the server takes no duplex requests" };
  }

  // control
  const ctl = await controlRtt(session, 20);
  result.controlRttMs = { p50: pct(ctl, 0.5), p90: pct(ctl, 0.9) };

  // datagram ping (channel 14, echoed) at 50 Hz, the synthetic video and 10 Hz input at the same time
  const sent = new Map<number, number>();
  const pings: number[] = [];
  session.onDatagram(14, (p) => {
    const n = new DataView(p.buffer, p.byteOffset, p.byteLength).getUint32(0);
    const at = sent.get(n);
    if (at !== undefined) {
      pings.push(performance.now() - at);
      sent.delete(n);
    }
  });
  const media = session.media!;
  const frames: { at: number; bytes: number; kind: string; captureUs: number }[] = [];
  let acked = 0;
  media.onEvent((e: MediaEvent) => {
    if (e.type === "frame") {
      frames.push({ at: performance.now(), bytes: e.au.length, kind: e.kind, captureUs: e.captureUs });
      media.frameDecoded(e.stream, e.frame, true);
    } else if (e.type === "inputAcked") acked++;
  });
  media.openVideo(1);
  session.sendControl({ t: "video.open", id: 1, query: "fps=60" });
  // as linkScreen does with a stream open: 3 s of silence is a lost path
  session.setActivityTimeout(3000);
  let n = 0;
  let inputs = 0;
  const ping = setInterval(() => {
    const b = new Uint8Array(64);
    new DataView(b.buffer).setUint32(0, n);
    sent.set(n++, performance.now());
    session.sendDatagram(14, b);
  }, 20);
  const input = setInterval(() => {
    try {
      media.sendInput(JSON.stringify({ type: "key", key: "a" }), false);
      inputs++;
    } catch {
      /* 429 */
    }
  }, 100);
  const tv = performance.now();
  // a lost path (netem's blackouts) and the ICE restarts that find it again
  const recovering: { at: number; lost: boolean }[] = [];
  session.onRecovering((lost) => recovering.push({ at: Math.round(performance.now() - tv), lost }));
  const lines: string[] = [];
  const statsTimer = setInterval(() => lines.push(session.stats().line), 2000);
  await sleep(cfg.seconds * 1000);
  clearInterval(ping);
  clearInterval(input);
  clearInterval(statsTimer);
  await sleep(300);
  const span = (performance.now() - tv) / 1000;
  result.datagramPing = { sent: n, received: pings.length, lostPct: Math.round((1 - pings.length / n) * 1000) / 10, p50: pct(pings, 0.5), p90: pct(pings, 0.9), p99: pct(pings, 0.99) };
  const gaps = frames.slice(1).map((f, i) => f.at - frames[i]!.at);
  const bytes = frames.reduce((s, f) => s + f.bytes, 0);
  result.video = {
    frames: frames.length,
    fps: Math.round((frames.length / span) * 10) / 10,
    mbps: Math.round(((bytes * 8) / 1e6 / span) * 10) / 10,
    keys: frames.filter((f) => f.kind === "key").length,
    gapP50Ms: pct(gaps, 0.5),
    gapP99Ms: pct(gaps, 0.99),
    gapMaxMs: gaps.length ? Math.round(Math.max(...gaps)) : null,
  };
  result.input = { sent: inputs, acked };
  result.media = media.counters();
  result.lines = lines;
  result.peer = session.peerStats();
  result.recovery = { recoveries: session.recoveries, events: recovering, endedEarly: session.isClosed };
  await session.close();
  result.closed = await session.closed();

  // the DTLS certificate (the client key) is kept in IndexedDB: a second dial is the same client to the server
  const again = await dial(cfg);
  const kept = clientKeyOf(await clientCertificate(indexedDbCertificateStore()));
  const keys = [clientKeyOfSession(session), clientKeyOfSession(again)];
  await again.close();
  if (!keys[0]?.startsWith("dtls-sha256:") || keys[0] !== keys[1] || keys[0] !== kept) throw new Error(`client keys differ: ${keys.join(", ")}, kept ${kept}`);
  result.clientKey = { stable: true, key: keys[0] };

  // the control: the same unread 50 MiB answer without the credit window piles up in the page (what the window saves)
  if (result.credit) {
    const old = await dial(cfg, false);
    const before = await heapUsed();
    const r = await old.request({ method: "GET", path: `/bytes?n=${50 * 1024 * 1024}` });
    await new Promise((res) => setTimeout(res, 2000));
    const idle = await heapUsed();
    r.cancel();
    await old.close();
    result.withoutCredit = { heapIdleMiB: before === null || idle === null ? null : Math.round(((idle - before) / 1048576) * 10) / 10 };
  }
  return result;
}

(globalThis as { e2e?: (c: Config) => Promise<unknown> }).e2e = (c) =>
  run(c).catch((e: unknown) => ({ error: e instanceof Error ? `${e.name}: ${e.message}` : String(e), kind: (e as { kind?: string }).kind }));
