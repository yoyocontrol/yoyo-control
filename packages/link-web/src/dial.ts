import { clientCertificate, defaultCertificateStore, type CertificateStore } from "./certificate.js";
import { denyCode, denyForClose, LinkError } from "./errors.js";
import { encodeFrame, FrameReader, messageBytes } from "./framing.js";
import { LinkMedia } from "./media.js";
import { LinkSession, MAX_DATAGRAM, type Hello, type Welcome } from "./session.js";
import { browserIface, type Iface } from "./stats.js";
import { newRestartSecret, parseAnswer, verifyAnswer, type RtcOffer } from "./verify.js";
import { loadLinkMedia, type ClientMediaConfig, type WasmSource } from "./wasm.js";

/** What this client says it takes, in `hello.features` by default (as the iOS kit). */
export const DEFAULT_FEATURES = ["screen", "audio", "cursor", "input"];
/** The whole dial (signaling, ICE, DTLS, `welcome`) by default. */
export const DIAL_TIMEOUT_MS = 15_000;
/** ICE gathering waits at most this long before the offer goes (non-trickle). */
export const GATHER_TIMEOUT_MS = 1000;

export interface DialRtcOptions {
  /**
   * The host's signaling path: hands the offer (`{v: 1, offer, device}`) to the computer some way (the relay's
   * `POST /v1/rtc/<fp>`, a local `POST /link/rtc`, the host's own backend) and resolves with its answer — the object,
   * or its JSON text. A rejection fails the dial with `LinkError("signal")` (its `cause` is the host's error).
   */
  signal: (offer: RtcOffer) => Promise<unknown>;
  /** The computer's identity fingerprint (`sha256:<hex>`, as paired): the answer must be signed by it. */
  pinnedFingerprint: string;
  /** `hello.credential` (`Bearer <device token>`, an authority-mode ticket, `Pair <code>`…). */
  credential: string;
  /** This browser as a device (`hello.device`, also in the offer). */
  device: { id: string; name: string };
  /** `hello.app`. */
  app: { name: string; version: string };
  /** `hello.features` (default `DEFAULT_FEATURES`). */
  features?: string[];
  /** STUN servers for the browser's own reflexive candidates (default none). */
  iceServers?: RTCIceServer[];
  /**
   * The DTLS certificate(s) to use; wins over `certificateStore`. The certificate is the client key the server binds
   * a device token to (`dtls-sha256:<hex>`), so it has to stay the same between dials.
   */
  certificates?: RTCCertificate[];
  /**
   * Where the DTLS certificate is kept when `certificates` isn't given (default: IndexedDB, `indexedDbCertificateStore()`;
   * made on first use, `clientCertificate`). `null`: a fresh certificate per connection (the server sees a new
   * client each time: only for credentials that don't bind to the client key).
   */
  certificateStore?: CertificateStore | null;
  /** The whole dial (default `DIAL_TIMEOUT_MS`). */
  timeoutMs?: number;
  /** ICE gathering cap before the offer goes (default `GATHER_TIMEOUT_MS`). */
  gatherTimeoutMs?: number;
  /** The media layer: on (default), its config, or `false` for a session without media (RPC / control only). */
  media?: boolean | ClientMediaConfig;
  /** Where the `.wasm` comes from (default: next to this module). */
  wasm?: WasmSource;
  /** This device's network interface for `link.stats` (default: from `navigator.connection`). */
  iface?: Iface | (() => Iface);
  /** Cancels the dial (the peer connection closes; rejects with `LinkError("closed")`). */
  abortSignal?: AbortSignal;
  /** Makes the peer connection (default `new RTCPeerConnection(config)`): another runtime, a test. */
  createPeerConnection?: (config: RTCConfiguration) => RTCPeerConnection;
}

/** The clock the media layer runs on: µs since the page started (monotonic). */
const mediaNow = () => Math.max(1, Math.round(performance.now() * 1000));

/**
 * Dials a computer over WebRTC (docs/LINK.md「WebRTC」): one peer connection with the negotiated `control` (id 0) and
 * `dgram` (id 1, unordered, no retransmits) channels; a non-trickle offer (ICE gathering ≤ `gatherTimeoutMs`) goes
 * through `signal`; the answer is verified against the pinned identity (`verifyAnswer`) before it is applied; then
 * `hello` → `welcome` on `control`. Resolves with the session; rejects with a `LinkError`: `denied` (with its `code`),
 * `verification`, `signal`, `timeout`, `closed`, `unsupported`.
 */
export async function dialRtc(options: DialRtcOptions): Promise<LinkSession> {
  const timeoutMs = options.timeoutMs ?? DIAL_TIMEOUT_MS;
  const make = options.createPeerConnection ?? ((c: RTCConfiguration) => {
    if (typeof RTCPeerConnection === "undefined") throw new LinkError("unsupported", "this browser has no WebRTC");
    return new RTCPeerConnection(c);
  });
  const mediaModule = options.media === false ? null : loadLinkMedia(options.wasm);
  // a failed load is reported when the media layer is needed, not as an unhandled rejection meanwhile
  mediaModule?.catch(() => {});
  const store = options.certificateStore === undefined ? defaultCertificateStore() : options.certificateStore;
  let certificates = options.certificates;
  if (!certificates && store) {
    try {
      certificates = [await clientCertificate(store)];
    } catch (e) {
      throw new LinkError("unsupported", `no DTLS certificate: ${e instanceof Error ? e.message : String(e)}`, undefined, { cause: e });
    }
  }
  const pc = make({
    iceServers: options.iceServers ?? [],
    bundlePolicy: "max-bundle",
    ...(certificates ? { certificates } : {}),
  });
  const control = pc.createDataChannel("control", { negotiated: true, id: 0, ordered: true });
  const dgram = pc.createDataChannel("dgram", { negotiated: true, id: 1, ordered: false, maxRetransmits: 0 });
  control.binaryType = "arraybuffer";
  dgram.binaryType = "arraybuffer";

  let timer: ReturnType<typeof setTimeout> | undefined;
  let onAbort: (() => void) | undefined;
  const stop = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new LinkError("timeout", `no session in ${timeoutMs} ms`)), timeoutMs);
    onAbort = () => reject(new LinkError("closed", "the dial was cancelled"));
    if (options.abortSignal?.aborted) onAbort();
    options.abortSignal?.addEventListener("abort", onAbort, { once: true });
  });
  stop.catch(() => {});
  const race = <T>(p: Promise<T>) => Promise.race([p, stop]);

  const t0 = performance.now();
  const mark = () => Math.round((performance.now() - t0) * 10) / 10;
  try {
    await race(pc.setLocalDescription(await race(pc.createOffer())));
    await race(gathered(pc, options.gatherTimeoutMs ?? GATHER_TIMEOUT_MS));
    const gatheredMs = mark();
    const sdp = pc.localDescription?.sdp;
    if (!sdp) throw new LinkError("protocol", "no local description");
    let next = await race(newRestartSecret());
    let reply: unknown;
    try {
      reply = await race(options.signal({ v: 1, offer: sdp, device: options.device, rk: next.key }));
    } catch (e) {
      if (e instanceof LinkError && (e.kind === "timeout" || e.kind === "closed")) throw e;
      throw new LinkError("signal", `signaling failed: ${e instanceof Error ? e.message : String(e)}`, undefined, { cause: e });
    }
    const answeredMs = mark();
    const answer = parseAnswer(reply);
    await race(verifyAnswer(sdp, answer, options.pinnedFingerprint));
    await race(pc.setRemoteDescription({ type: "answer", sdp: answer.answer }));
    await race(opened(control, pc));
    const connectedMs = mark();

    const hello: Hello = { credential: options.credential, device: options.device, app: options.app, features: options.features ?? DEFAULT_FEATURES };
    // an ICE restart over the same signaling path (docs/LINK.md「WebRTC」「换网络」): new candidates and ICE credentials
    // for the same DTLS, SCTP and channels; the session calls it when the path is lost
    const gatherMs = options.gatherTimeoutMs ?? GATHER_TIMEOUT_MS;
    const restartIce = async () => {
      if (pc.signalingState === "have-local-offer") await pc.setLocalDescription({ type: "rollback" });
      await pc.setLocalDescription(await pc.createOffer({ iceRestart: true }));
      // gathering starts again a moment later: "complete" from the last round doesn't count
      await gathered(pc, gatherMs, true);
      const offerSdp = pc.localDescription?.sdp;
      if (!offerSdp) throw new LinkError("protocol", "no local description");
      const following = await newRestartSecret();
      let back: unknown;
      try {
        back = await options.signal({ v: 1, offer: offerSdp, device: options.device, restart: next.secret, rk: following.key });
      } catch (e) {
        throw new LinkError("signal", `restart signaling failed: ${e instanceof Error ? e.message : String(e)}`, undefined, { cause: e });
      }
      next = following; // the server took the old secret: the next restart needs this one
      const a = parseAnswer(back);
      await verifyAnswer(offerSdp, a, options.pinnedFingerprint);
      await pc.setRemoteDescription({ type: "answer", sdp: a.answer });
      return a.restarts === true;
    };
    const reader = new FrameReader();
    const { welcome, early } = await race(handshake(control, reader, hello));
    const module = mediaModule ? await race(mediaModule) : null;
    const config = typeof options.media === "object" ? options.media : {};
    const iface = options.iface;
    let session: LinkSession | null = null;
    const media = module
      ? new LinkMedia(
          module.createClientMedia({ ...config, maxDatagram: Math.min(config.maxDatagram ?? MAX_DATAGRAM, welcome.maxDatagram > 0 ? welcome.maxDatagram : MAX_DATAGRAM) }),
          (d) => session?.sendDatagramRaw(d),
          mediaNow,
        )
      : null;
    session = new LinkSession({
      pc,
      control,
      dgram,
      reader,
      early,
      hello,
      welcome,
      media,
      iface: typeof iface === "function" ? iface : iface ? () => iface : browserIface,
      timing: { gatheredMs, answeredMs, connectedMs, welcomeMs: mark() },
      ...(answer.restarts === true ? { restartIce } : {}),
    });
    // the path (lan / direct / punched) from the selected candidate pair before the caller looks (one getStats call)
    await race(session.firstStats);
    return session;
  } catch (e) {
    try {
      pc.close();
    } catch {
      /* closed */
    }
    throw e;
  } finally {
    clearTimeout(timer);
    if (onAbort) options.abortSignal?.removeEventListener("abort", onAbort);
  }
}

/** Resolves when ICE gathering is complete, or after `capMs` (the offer goes with what was gathered by then).
 *  `again`: an ICE restart's gathering, which may not have left the last round's "complete" yet. */
function gathered(pc: RTCPeerConnection, capMs: number, again = false): Promise<void> {
  if (pc.iceGatheringState === "complete" && !again) return Promise.resolve();
  return new Promise((resolve) => {
    const done = () => {
      clearTimeout(t);
      pc.removeEventListener("icegatheringstatechange", check);
      resolve();
    };
    const check = () => {
      if (pc.iceGatheringState === "complete") done();
    };
    const t = setTimeout(done, capMs);
    pc.addEventListener("icegatheringstatechange", check);
  });
}

/** Resolves when `ch` opens; rejects when the connection fails first. */
function opened(ch: RTCDataChannel, pc: RTCPeerConnection): Promise<void> {
  if (ch.readyState === "open") return Promise.resolve();
  return new Promise((resolve, reject) => {
    const off = () => {
      ch.removeEventListener("open", onOpen);
      ch.removeEventListener("close", onClose);
      pc.removeEventListener("connectionstatechange", onState);
    };
    const onOpen = () => {
      off();
      resolve();
    };
    const onClose = () => {
      off();
      reject(new LinkError("closed", "the control channel closed before it opened"));
    };
    const onState = () => {
      if (pc.connectionState === "failed" || pc.connectionState === "closed") {
        off();
        reject(new LinkError("closed", `the connection ${pc.connectionState} (ICE / DTLS)`));
      }
    };
    ch.addEventListener("open", onOpen);
    ch.addEventListener("close", onClose);
    pc.addEventListener("connectionstatechange", onState);
  });
}

/** `hello` → `welcome` (or `denied`, or a close / `bye` with a deny code). Frames after `welcome` are kept. */
function handshake(control: RTCDataChannel, reader: FrameReader, hello: Hello): Promise<{ welcome: Welcome; early: Record<string, unknown>[] }> {
  return new Promise((resolve, reject) => {
    const off = () => {
      control.removeEventListener("message", onMessage);
      control.removeEventListener("close", onClose);
    };
    const fail = (e: LinkError) => {
      off();
      reject(e);
    };
    const onClose = () => fail(new LinkError("closed", "the server closed the session before welcome"));
    const onMessage = (ev: MessageEvent) => {
      let frames: Record<string, unknown>[];
      try {
        frames = reader.push(messageBytes(ev.data));
      } catch (e) {
        fail(e as LinkError);
        return;
      }
      for (let i = 0; i < frames.length; i++) {
        const f = frames[i]!;
        if (f.t === "welcome") {
          off();
          resolve({ welcome: parseWelcome(f), early: frames.slice(i + 1) });
          return;
        }
        if (f.t === "denied") {
          const code = denyCode(f.code);
          fail(new LinkError("denied", typeof f.message === "string" && f.message ? f.message : code, code));
          return;
        }
        if (f.t === "bye") {
          const code = denyForClose(typeof f.code === "number" ? f.code : undefined);
          const reason = typeof f.reason === "string" ? f.reason : "";
          fail(code ? new LinkError("denied", reason || code, code) : new LinkError("closed", `the server closed the session before welcome${reason ? `: ${reason}` : ""}`));
          return;
        }
      }
    };
    control.addEventListener("message", onMessage);
    control.addEventListener("close", onClose);
    try {
      control.send(encodeFrame({ t: "hello", v: 1, ...hello }));
    } catch (e) {
      fail(new LinkError("closed", e instanceof Error ? e.message : String(e)));
    }
  });
}

/** `welcome` leniently: missing fields as empty. */
export function parseWelcome(f: Record<string, unknown>): Welcome {
  const s = f.server && typeof f.server === "object" ? (f.server as Record<string, unknown>) : {};
  const str = (v: unknown) => (typeof v === "string" ? v : "");
  return {
    server: { id: str(s.id), name: str(s.name), platform: str(s.platform) },
    principal: f.principal ?? null,
    features: Array.isArray(f.features) ? f.features.filter((x): x is string => typeof x === "string") : [],
    maxDatagram: typeof f.maxDatagram === "number" ? f.maxDatagram : 0,
  };
}
