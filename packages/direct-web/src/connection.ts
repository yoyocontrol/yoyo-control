import { dialRtc, type DialRtcOptions, type LinkSession } from "@yoyocontrol/link-web";
import { DirectError, directError, type DirectMessages } from "./errors.js";
import { fallbackSignal, pathsTurn, signalPaths } from "./signal.js";
import type { DeviceIdentity, PairedMac } from "./store.js";

/** Makes a session (default link-web's `dialRtc`): tests and other runtimes put their own here. */
export type Dialer = (options: DialRtcOptions) => Promise<LinkSession>;

/** What every connection to a Mac shares: who this browser is, how it dials. */
export interface DialSettings {
  identity: DeviceIdentity;
  /** `hello.device.name` (e.g. "Safari on iPhone"). */
  deviceName: string;
  /** `hello.app`. */
  app: { name: string; version: string };
  iceServers: RTCIceServer[];
  /** Signaling servers tried before the Mac's relay (`signalPaths`; default none, `DirectWeb` gives `DEFAULT_SIGNALS`). */
  signals?: string[];
  /** Ask the signaling path for TURN before each dial (`relayTurn`; default true). */
  turn?: boolean;
  /** One dial, start to `welcome` (default link-web's 15 s). */
  timeoutMs?: number;
  dial?: Dialer;
  /** The relay's `fetch` (default the global one). */
  fetch?: typeof fetch;
  /** The host's words for failures (`DirectError.message` by kind). */
  messages?: DirectMessages;
}

/** The first retry waits this long after a failed dial, doubling up to `MAX_BACKOFF_MS`. */
export const FIRST_BACKOFF_MS = 1000;
export const MAX_BACKOFF_MS = 10_000;

/** The ICE servers of one dial to `mac`: the settings' STUN plus, unless `turn: false`, TURN from its signaling paths. */
export async function iceServersFor(settings: DialSettings, mac: Pick<PairedMac, "fingerprint" | "relay">): Promise<RTCIceServer[]> {
  if (settings.turn === false) return settings.iceServers;
  return [...settings.iceServers, ...(await pathsTurn(signalPaths(settings.signals ?? [], mac.relay), mac.fingerprint, settings.fetch))];
}

/** The `DialRtcOptions` of one dial to `mac` with `credential`. */
export function dialOptions(settings: DialSettings, mac: Pick<PairedMac, "fingerprint" | "relay">, credential: string, extra: Partial<DialRtcOptions> = {}): DialRtcOptions {
  return {
    signal: fallbackSignal(signalPaths(settings.signals ?? [], mac.relay), mac.fingerprint, settings.fetch),
    pinnedFingerprint: mac.fingerprint,
    credential,
    device: { id: settings.identity.deviceId, name: settings.deviceName },
    app: settings.app,
    iceServers: settings.iceServers,
    certificates: [settings.identity.certificate],
    ...(settings.timeoutMs ? { timeoutMs: settings.timeoutMs } : {}),
    ...extra,
  };
}

/**
 * The uu Link session to one paired Mac, made when something needs it and made again after it ended (the link is
 * the only way a browser has to a Mac: no HTTP fallback). One dial at a time; concurrent callers share it. After a
 * failed dial the next one waits (1 s, doubling to 10 s; `retryNow()` skips the wait). A failure that retrying can't
 * fix (`unpaired`, `verification`, `unsupported`) sticks until `retryNow()`.
 */
export class MacConnection {
  private live: LinkSession | null = null;
  private dialing: Promise<LinkSession> | null = null;
  private failure: DirectError | null = null;
  private failedAt = 0;
  private backoff = 0;
  private closedForGood = false;
  private readonly listeners = new Set<(session: LinkSession) => void>();
  private wake: (() => void) | null = null;

  constructor(
    private mac: PairedMac,
    private readonly settings: DialSettings,
    /** A new `welcome` said something about the Mac (its name, platform): the store keeps it. */
    private readonly onMacChanged: (mac: PairedMac) => void = () => {},
  ) {}

  /** The open session, if there is one now. */
  get current(): LinkSession | null {
    return this.live && !this.live.isClosed ? this.live : null;
  }

  /** The host's words for failures (from the settings). */
  get messages(): DirectMessages {
    return this.settings.messages ?? {};
  }

  /** The last dial's failure (null after a success). */
  get lastError(): DirectError | null {
    return this.failure;
  }

  /** Hears every new session (after `welcome`); returns the unsubscribe. */
  onSession(listener: (session: LinkSession) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  /** The open session, or a new one. Rejects with a `DirectError`. */
  session(): Promise<LinkSession> {
    if (this.closedForGood) return Promise.reject(new DirectError("unreachable", "the connection was closed"));
    const open = this.current;
    if (open) return Promise.resolve(open);
    this.dialing ??= this.dial().finally(() => (this.dialing = null));
    return this.dialing;
  }

  /** The next dial goes at once (and a sticky failure is forgotten). */
  retryNow(): void {
    this.failure = null;
    this.backoff = 0;
    this.wake?.();
  }

  /** Ends the session and makes no more. */
  close(): void {
    this.closedForGood = true;
    this.wake?.();
    const s = this.live;
    this.live = null;
    if (s && !s.isClosed) void s.close(0, "closed");
  }

  private async dial(): Promise<LinkSession> {
    const f = this.failure;
    if (f && !f.retryable) throw f;
    if (f && this.backoff > 0) await this.wait(this.failedAt + this.backoff - Date.now());
    if (this.closedForGood) throw new DirectError("unreachable", "the connection was closed");
    const dial = this.settings.dial ?? dialRtc;
    let session: LinkSession;
    try {
      const iceServers = await iceServersFor(this.settings, this.mac);
      session = await dial(dialOptions(this.settings, this.mac, `Bearer ${this.mac.token}`, { iceServers }));
    } catch (e) {
      const err = directError(e, false, this.settings.messages);
      this.failure = err;
      this.failedAt = Date.now();
      this.backoff = this.backoff ? Math.min(this.backoff * 2, MAX_BACKOFF_MS) : FIRST_BACKOFF_MS;
      throw err;
    }
    if (this.closedForGood) {
      void session.close(0, "closed");
      throw new DirectError("unreachable", "the connection was closed");
    }
    this.failure = null;
    this.backoff = 0;
    this.live = session;
    const server = session.server;
    if (server && (server.name !== this.mac.name || server.platform !== (this.mac.platform ?? null))) {
      this.mac = { ...this.mac, name: server.name || this.mac.name, platform: server.platform || null };
      this.onMacChanged(this.mac);
    }
    for (const l of this.listeners) l(session);
    return session;
  }

  private wait(ms: number): Promise<void> {
    if (ms <= 0) return Promise.resolve();
    return new Promise((resolve) => {
      const t = setTimeout(() => {
        this.wake = null;
        resolve();
      }, ms);
      this.wake = () => {
        clearTimeout(t);
        this.wake = null;
        resolve();
      };
    });
  }
}
