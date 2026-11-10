// The browser half of screen-ui's end-to-end test (run.mjs bundles it): a <yoyo-screen> whose backend has two ways —
// the demo's in-memory computer as the HTTP way that always works ("tunnel"), and a uu Link session dialed with
// link-web against `uu-link-probe serve-rtc --screen-clip` ("link", the demo's `withLinkWay`) — chosen by screen-ui's
// Connector. The harness
// kills and restarts the probe; `state()` says which way the page is on and what each way delivered.

import type { LinkSession } from "@yoyocontrol/link-web";
import type { ScreenLink, ScreenLinkVideo, ScreenLinkVideoEvent, ScreenTransport } from "@yoyocontrol/screen-web";
import { defineElements, type Connector, type ScreenBackend, type ScreenRoute, type YoyoScreenElement } from "../../src/index.js";
// @ts-expect-error the demo's computer and its link way are plain JS
import { FakeComputer, fakeBackend } from "../../demo/fake-backend.js";
// @ts-expect-error plain JS
import { withLinkWay } from "../../demo/link-way.js";

interface Config {
  signal: string;
  fingerprint: string;
  credential: string;
  retryIntervalMs: number;
}

/** What each way delivered so far. */
const counts = { linkFrames: 0, linkDecodedOk: 0, linkDecodedFailed: 0, linkDials: 0, linkSessions: 0, tunnelAcks: 0, tunnelStreams: 0 };
const log: string[] = [];
const t0 = performance.now();
const note = (s: string) => log.push(`${Math.round(performance.now() - t0)} ${s}`);
let routing: Connector<LinkSession | null> | null = null;
let screen: YoyoScreenElement | null = null;

/** A ScreenLink that counts its pictures and the decoder's verdicts (the real `frameDecoded` results). */
function counted(link: ScreenLink): ScreenLink {
  return new Proxy(link, {
    get(target, prop, receiver) {
      if (prop !== "openVideo") return Reflect.get(target, prop, receiver);
      return (query: string, onEvent: (e: ScreenLinkVideoEvent) => void): ScreenLinkVideo => {
        const v = target.openVideo(query, (e) => {
          if (e.type === "frame") counts.linkFrames++;
          else note(`link video ${e.type}`);
          onEvent(e);
        });
        return {
          decoded: (frame, ok) => {
            if (ok) counts.linkDecodedOk++;
            else counts.linkDecodedFailed++;
            v.decoded(frame, ok);
          },
          requestKeyframe: () => v.requestKeyframe(),
          report: (r) => v.report(r),
          close: () => v.close(),
        };
      };
    },
  });
}

function backend(cfg: Config): ScreenBackend {
  const http = fakeBackend(new FakeComputer({})) as ScreenBackend;
  const transport = (route: ScreenRoute): ScreenTransport => {
    const inner = http.transport(route);
    return {
      fetch: (path, init) => {
        const kind = path.split("?", 1)[0];
        if (kind === "/stream") counts.tunnelStreams++;
        if (kind === "/stream/ack") counts.tunnelAcks++;
        return inner.fetch(path, init);
      },
    };
  };
  return withLinkWay(
    { ...http, cacheScope: "e2e", transport },
    {
      signal: cfg.signal,
      fingerprint: cfg.fingerprint,
      credential: cfg.credential,
      device: { id: "e2e-browser", name: "Headless Chrome" },
      policy: { retryIntervalMs: cfg.retryIntervalMs },
      routing: (c: Connector<LinkSession | null>) => (routing = c),
      wrap: counted,
      note: (s: string) => {
        if (s === "link up") counts.linkSessions++;
        if (s === "link up" || s.startsWith("link dial failed")) counts.linkDials++;
        note(s);
      },
    },
  ) as ScreenBackend;
}

function mount(cfg: Config): void {
  // the package registers its elements on import; bundled from its sources (no `sideEffects` entry) that is dropped
  defineElements();
  screen = document.createElement("yoyo-screen") as YoyoScreenElement;
  screen.style.cssText = "position:fixed;inset:0";
  document.body.append(screen);
  screen.host = { language: "en", preferencesNamespace: "YoyoE2E" };
  screen.backend = backend(cfg);
  screen.toggleStats();
}

/**
 * The probe's screen: 2 s of a moving picture (640×360, 30 fps, one key frame first) from this browser's H.264 encoder,
 * as a `UUCLIP01` file (uu-link-probe's `--screen-clip`), base64.
 */
async function makeClip(): Promise<string> {
  const [w, h, n] = [640, 360, 60];
  const canvas = new OffscreenCanvas(w, h);
  const g = canvas.getContext("2d")!;
  const records: Uint8Array[] = [];
  let failed: unknown = null;
  const encoder = new VideoEncoder({
    output: (chunk) => {
      const r = new Uint8Array(5 + chunk.byteLength);
      r[0] = chunk.type === "key" ? 1 : 0;
      new DataView(r.buffer).setUint32(1, chunk.byteLength);
      chunk.copyTo(r.subarray(5));
      records.push(r);
    },
    error: (e) => (failed = e),
  });
  encoder.configure({ codec: "avc1.42001f", width: w, height: h, framerate: 30, bitrate: 1_500_000, latencyMode: "realtime", avc: { format: "annexb" } });
  for (let i = 0; i < n; i++) {
    g.fillStyle = "#1c2540";
    g.fillRect(0, 0, w, h);
    g.fillStyle = "#f5a623";
    g.beginPath();
    g.arc(60 + (i / n) * (w - 120), h / 2 + Math.sin(i / 6) * 80, 40, 0, Math.PI * 2);
    g.fill();
    const f = new VideoFrame(canvas, { timestamp: i * 33_333 });
    encoder.encode(f, { keyFrame: i === 0 });
    f.close();
  }
  await encoder.flush();
  encoder.close();
  if (failed) throw failed;
  const head = new Uint8Array(12);
  head.set(new TextEncoder().encode("UUCLIP01"));
  new DataView(head.buffer).setUint16(8, w);
  new DataView(head.buffer).setUint16(10, h);
  const all = new Uint8Array(records.reduce((n, r) => n + r.length, head.length));
  all.set(head);
  let at = head.length;
  for (const r of records) {
    all.set(r, at);
    at += r.length;
  }
  let bin = "";
  for (let i = 0; i < all.length; i += 0x8000) bin += String.fromCharCode(...all.subarray(i, i + 0x8000));
  return btoa(bin);
}

/** The stats line as the page shows it (three-finger tap / `toggleStats()`). */
function statsText(): string | null {
  return screen?.shadowRoot?.querySelector(".stats")?.textContent ?? null;
}

function state() {
  return { stats: statsText(), route: routing?.current.id ?? null, deciding: routing?.isDeciding ?? null, ...counts, log: log.slice() };
}

(globalThis as { e2e?: unknown }).e2e = { makeClip, mount, state };
