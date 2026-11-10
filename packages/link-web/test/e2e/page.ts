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

const dial = (cfg: Config) =>
  dialRtc({
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
  const td = performance.now();
  const big = await (await session.request({ method: "GET", path: "/bytes?n=8388608" })).readAll(16 << 20);
  const secs = (performance.now() - td) / 1000;
  result.rpcDownload = { bytes: big.length, mbps: Math.round(((big.length * 8) / 1e6 / secs) * 10) / 10 };

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
  return result;
}

(globalThis as { e2e?: (c: Config) => Promise<unknown> }).e2e = (c) =>
  run(c).catch((e: unknown) => ({ error: e instanceof Error ? `${e.name}: ${e.message}` : String(e), kind: (e as { kind?: string }).kind }));
