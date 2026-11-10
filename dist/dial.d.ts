import { type CertificateStore } from "./certificate.js";
import { LinkSession, type Welcome } from "./session.js";
import { type Iface } from "./stats.js";
import { type RtcOffer } from "./verify.js";
import { type ClientMediaConfig, type WasmSource } from "./wasm.js";
/** What this client says it takes, in `hello.features` by default (as the iOS kit). */
export declare const DEFAULT_FEATURES: string[];
/** The whole dial (signaling, ICE, DTLS, `welcome`) by default. */
export declare const DIAL_TIMEOUT_MS = 15000;
/** ICE gathering waits at most this long before the offer goes (non-trickle). */
export declare const GATHER_TIMEOUT_MS = 1000;
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
    device: {
        id: string;
        name: string;
    };
    /** `hello.app`. */
    app: {
        name: string;
        version: string;
    };
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
/**
 * Dials a computer over WebRTC (docs/LINK.md「WebRTC」): one peer connection with the negotiated `control` (id 0) and
 * `dgram` (id 1, unordered, no retransmits) channels; a non-trickle offer (ICE gathering ≤ `gatherTimeoutMs`) goes
 * through `signal`; the answer is verified against the pinned identity (`verifyAnswer`) before it is applied; then
 * `hello` → `welcome` on `control`. Resolves with the session; rejects with a `LinkError`: `denied` (with its `code`),
 * `verification`, `signal`, `timeout`, `closed`, `unsupported`.
 */
export declare function dialRtc(options: DialRtcOptions): Promise<LinkSession>;
/** `welcome` leniently: missing fields as empty. */
export declare function parseWelcome(f: Record<string, unknown>): Welcome;
