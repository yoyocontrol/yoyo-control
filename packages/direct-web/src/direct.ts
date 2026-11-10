import { clientCertificate, dialRtc, indexedDbCertificateStore, type CertificateStore } from "@yoyocontrol/link-web";
import { deviceName } from "@yoyocontrol/screen-web";
import { DirectBackend, type DirectBackendOptions } from "./backend.js";
import { dialOptions, iceServersFor, MacConnection, type Dialer, type DialSettings } from "./connection.js";
import { DirectError, directError, type DirectMessages } from "./errors.js";
import type { PairingLink } from "./pairing.js";
import { DEFAULT_ICE_SERVERS, DEFAULT_SIGNALS } from "./signal.js";
import { browserStore, type DeviceIdentity, type DirectStore, type PairedMac } from "./store.js";

export interface DirectWebOptions {
  /** `hello.app` (e.g. `{ name: "Yoyo Control Web", version: "1.0" }`). */
  app: { name: string; version: string };
  /** Where Macs and the identity are kept (default `browserStore()`, IndexedDB). */
  store?: DirectStore;
  /** The signaling server new pairings signal through (none is built in: without one, `pair` fails); a paired Mac
   *  keeps its own. */
  relay?: string;
  /** More signaling servers every dial tries before the Mac's own (default `DEFAULT_SIGNALS`: none). */
  signals?: string[];
  /** STUN servers for the browser's reflexive candidates (default `DEFAULT_ICE_SERVERS`: none). */
  iceServers?: RTCIceServer[];
  /** Ask the relay for TURN servers before each dial (default true; docs/RELAY.md「TURN」). */
  turn?: boolean;
  /** `hello.device.name` (default from the user agent: "Safari on iPhone"). */
  deviceName?: string;
  /** One dial's limit (default link-web's). */
  timeoutMs?: number;
  /** Your words for the failures the pages and your UI show (`DirectError.message` by kind; default: short English). */
  messages?: DirectMessages;
  /** Where the DTLS certificate (this browser's key to the Macs) is kept: default link-web's IndexedDB store
   *  (`indexedDbCertificateStore()`, database `yoyocontrol-link`), the one every link-web dial uses by default. */
  certificateStore?: CertificateStore;
  /** Tests / other runtimes: the dialer, the relay's fetch, the screen media of a session. */
  dial?: Dialer;
  fetch?: typeof fetch;
  screenLink?: DirectBackendOptions["screenLink"];
}

/** The `welcome.principal` of a pairing session (docs/LINK.md「配对」). */
interface PairingPrincipal {
  token?: unknown;
  device?: { id?: unknown; name?: unknown };
  server?: { id?: unknown; name?: unknown };
}

/**
 * Yoyo Control in a browser: the paired Macs (kept in the store), pairing from a Mac's web pairing link, and one
 * `DirectBackend` per Mac for the pages (`<yoyo-screen>`, `<yoyo-clipboard>`, `ScreenPreview`). The link (WebRTC
 * signaled through the relay, the Mac's identity pinned) is the only way to a Mac: a browser can't pin the Mac's TLS
 * listener, so there is no HTTP fallback.
 */
export class DirectWeb {
  private readonly store: DirectStore;
  private identityPromise: Promise<DeviceIdentity> | null = null;
  private readonly backends = new Map<string, DirectBackend>();

  constructor(private readonly options: DirectWebOptions) {
    this.store = options.store ?? browserStore();
  }

  /** The paired Macs, oldest first. */
  macs(): Promise<PairedMac[]> {
    return this.store.macs();
  }

  /** This browser's device id (made the first time) and DTLS certificate (link-web's `clientCertificate`: kept in the
   *  certificate store, a new one a day before it expires — the Macs then need pairing again). */
  identity(): Promise<DeviceIdentity> {
    this.identityPromise ??= this.loadIdentity().catch((e: unknown) => {
      this.identityPromise = null;
      throw e;
    });
    return this.identityPromise;
  }

  private async loadIdentity(): Promise<DeviceIdentity> {
    if (!this.options.certificateStore && typeof RTCPeerConnection === "undefined") throw new DirectError("unsupported", "this browser has no WebRTC");
    const certificates = this.options.certificateStore ?? indexedDbCertificateStore();
    const kept = await this.store.identity();
    const deviceId = kept?.deviceId ?? crypto.randomUUID();
    if (kept?.certificate) {
      // an earlier build kept the certificate itself: it moves to the certificate store (unless that has one), so the tokens the
      // Macs bound to it keep working
      if (!(await certificates.load())) await certificates.save(kept.certificate);
      await this.store.saveIdentity({ deviceId });
    } else if (!kept) {
      await this.store.saveIdentity({ deviceId });
    }
    return { deviceId, certificate: await clientCertificate(certificates) };
  }

  private async settings(): Promise<DialSettings> {
    const o = this.options;
    return {
      identity: await this.identity(),
      deviceName: o.deviceName ?? deviceName(typeof navigator === "undefined" ? "" : navigator.userAgent),
      app: o.app,
      iceServers: o.iceServers ?? DEFAULT_ICE_SERVERS,
      signals: o.signals ?? DEFAULT_SIGNALS,
      ...(o.turn === false ? { turn: false } : {}),
      ...(o.timeoutMs ? { timeoutMs: o.timeoutMs } : {}),
      ...(o.dial ? { dial: o.dial } : {}),
      ...(o.fetch ? { fetch: o.fetch } : {}),
      ...(o.messages ? { messages: o.messages } : {}),
    };
  }

  /**
   * Pairs with the Mac of `link` over the link itself (`hello.credential = "Pair <code>"`): the Mac checks the code as a
   * phone's, binds the new token to this browser's certificate and returns it in `welcome.principal`. The
   * Mac is saved and returned. Rejects with a `DirectError`: `pairing` (the code was refused), `offline`,
   * `unreachable`, `busy` (too many paired devices, too many tries), `verification`, `unsupported`.
   */
  async pair(link: PairingLink): Promise<PairedMac> {
    const settings = await this.settings();
    const relay = this.options.relay;
    if (!relay) throw new Error("DirectWeb: no signaling server to pair through (options.relay); none is built in");
    const dial = settings.dial ?? dialRtc;
    let session;
    try {
      const target = { fingerprint: link.fingerprint, relay };
      session = await dial(dialOptions(settings, target, `Pair ${link.code}`, { media: false, iceServers: await iceServersFor(settings, target) }));
    } catch (e) {
      throw directError(e, true, this.options.messages);
    }
    try {
      const p = (session.principal ?? {}) as PairingPrincipal;
      if (typeof p.token !== "string" || !p.token) throw new DirectError("pairing", "the Mac did not hand out a token (an older Mac: update Yoyo Control)");
      const server = session.server;
      const mac: PairedMac = {
        id: (typeof p.server?.id === "string" && p.server.id) || server.id || link.serverId,
        name: (typeof p.server?.name === "string" && p.server.name) || server.name || link.name,
        fingerprint: link.fingerprint,
        token: p.token,
        relay,
        pairedAt: Date.now(),
        platform: server.platform || null,
      };
      this.backends.get(mac.id)?.close();
      this.backends.delete(mac.id);
      await this.store.saveMac(mac);
      return mac;
    } finally {
      void session.close(0, "paired");
    }
  }

  /** Forgets the Mac here (its session ends). The Mac keeps listing this browser until it is removed there. */
  async forget(id: string): Promise<void> {
    this.disconnect(id);
    await this.store.removeMac(id);
  }

  /** The pages' backend for `mac` (one per Mac, shared by its pages: one session). `onUnpaired`: the Mac stopped
   *  knowing this browser. */
  async backend(mac: PairedMac, onUnpaired?: () => void): Promise<DirectBackend> {
    const kept = this.backends.get(mac.id);
    if (kept) return kept;
    const connection = new MacConnection(mac, await this.settings(), (m) => void this.store.saveMac(m));
    const b = new DirectBackend(mac, connection, {
      onUnpaired: () => {
        this.disconnect(mac.id);
        onUnpaired?.();
      },
      ...(this.options.screenLink ? { screenLink: this.options.screenLink } : {}),
    });
    const raced = this.backends.get(mac.id);
    if (raced) {
      b.close();
      return raced;
    }
    this.backends.set(mac.id, b);
    return b;
  }

  /** Ends the Mac's session and its events reader (a later `backend()` makes new ones). */
  disconnect(id: string): void {
    this.backends.get(id)?.close();
    this.backends.delete(id);
  }

  /** Ends every session. */
  close(): void {
    for (const id of [...this.backends.keys()]) this.disconnect(id);
  }
}
