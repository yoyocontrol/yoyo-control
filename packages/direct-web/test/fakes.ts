import { LinkError, type DialRtcOptions, type LinkSession } from "@yoyocontrol/link-web";
import type { ScreenLink as MediaLink, ScreenLinkAudioEvent, ScreenLinkVideoEvent } from "@yoyocontrol/screen-web";
import type { DeviceIdentity, PairedMac } from "../src/store.js";

export type Route = (path: string, init: RequestInit) => Response | Promise<Response>;

/** A link session that answers RPC from `route` (enough of LinkSession for the backend). */
export class FakeSession {
  isClosed = false;
  closes: { code: number; reason: string }[] = [];
  requests: { path: string; method: string; body: string | null }[] = [];
  private closedListeners: (() => void)[] = [];
  constructor(
    public route: Route = () => json(404, { error: "not found" }),
    public server = { id: "mac-1", name: "Studio", platform: "mac" },
    public principal: unknown = { device: { id: "browser-1", name: "Chrome on Mac" } },
  ) {}
  get welcome() {
    return { server: this.server, principal: this.principal, features: [], maxDatagram: 1200 };
  }
  async fetch(path: string, init: RequestInit = {}): Promise<Response> {
    if (this.isClosed) throw new LinkError("closed", "the session is over");
    this.requests.push({ path, method: init.method ?? "GET", body: typeof init.body === "string" ? init.body : null });
    return this.route(path, init);
  }
  async close(code = 0, reason = ""): Promise<void> {
    if (this.isClosed) return;
    this.isClosed = true;
    this.closes.push({ code, reason });
    for (const l of this.closedListeners.splice(0)) l();
  }
  /** The network ended it. */
  drop(): void {
    this.isClosed = true;
    for (const l of this.closedListeners.splice(0)) l();
  }
  asSession(): LinkSession {
    return this as unknown as LinkSession;
  }
}

export function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...headers } });
}

/** A dialer that hands out `next()`'s sessions (or throws what it returns) and records every dial. */
export class FakeDialer {
  dials: DialRtcOptions[] = [];
  constructor(public next: (o: DialRtcOptions) => FakeSession | Error | Promise<FakeSession | Error>) {}
  dial = async (o: DialRtcOptions): Promise<LinkSession> => {
    this.dials.push(o);
    const r = await this.next(o);
    if (r instanceof Error) throw r;
    return r.asSession();
  };
}

/** screen-web's ScreenLink, recording what the page did. */
export class FakeMediaLink implements MediaLink {
  pathLabel = "link lan";
  isLocalNetwork = true;
  rttMinMs: number | null = 1.5;
  statsLine: string | null = "lan wifi rtt 1.5/2/3 ms";
  isClosed = false;
  closed = new Promise<string>(() => {});
  videos: { query: string; emit: (e: ScreenLinkVideoEvent) => void; decoded: [number, boolean][]; reports: unknown[]; keyframes: number; closed: boolean }[] = [];
  audios: { query: string; emit: (e: ScreenLinkAudioEvent) => void; closed: boolean }[] = [];
  inputs: [string, boolean][] = [];
  controls: boolean[] = [];
  holder: { id: string; name?: string } | null = { id: "browser-1", name: "Chrome on Mac" };
  inputError: ((e: unknown) => void) | null = null;
  openVideo(query: string, onEvent: (e: ScreenLinkVideoEvent) => void) {
    const v = { query, emit: onEvent, decoded: [] as [number, boolean][], reports: [] as unknown[], keyframes: 0, closed: false };
    this.videos.push(v);
    return {
      decoded: (f: number, ok: boolean) => void v.decoded.push([f, ok]),
      requestKeyframe: () => void v.keyframes++,
      report: (r: Record<string, unknown>) => void v.reports.push(r),
      close: () => void (v.closed = true),
    };
  }
  openAudio(query: string, onEvent: (e: ScreenLinkAudioEvent) => void) {
    const a = { query, emit: onEvent, closed: false };
    this.audios.push(a);
    return { close: () => void (a.closed = true) };
  }
  sendInput(json: string, move: boolean) {
    this.inputs.push([json, move]);
  }
  setInputErrorHandler(h: ((e: unknown) => void) | null) {
    this.inputError = h;
  }
  async control(take: boolean) {
    this.controls.push(take);
    return { granted: take && this.holder?.id === "browser-1", holder: take ? this.holder : null };
  }
}

export const MAC: PairedMac = {
  id: "mac-1",
  name: "Studio",
  fingerprint: `sha256:${"ab".repeat(32)}`,
  token: "tok-1",
  relay: "https://relay.test",
  pairedAt: 1,
  platform: "mac",
};

export const IDENTITY: DeviceIdentity = {
  deviceId: "browser-1",
  certificate: { expires: Date.now() + 100 * 86_400_000, getFingerprints: () => [] } as unknown as RTCCertificate,
};

export const flush = async () => {
  for (let i = 0; i < 20; i++) await new Promise((r) => setTimeout(r, 0));
};
