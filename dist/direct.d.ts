import { type CertificateStore } from "@yoyocontrol/link-web";
import { DirectBackend, type DirectBackendOptions } from "./backend.js";
import { type Dialer } from "./connection.js";
import { type DirectMessages } from "./errors.js";
import type { PairingLink } from "./pairing.js";
import { type DeviceIdentity, type DirectStore, type PairedMac } from "./store.js";
export interface DirectWebOptions {
    /** `hello.app` (e.g. `{ name: "Yoyo Control Web", version: "1.0" }`). */
    app: {
        name: string;
        version: string;
    };
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
/**
 * Yoyo Control in a browser: the paired Macs (kept in the store), pairing from a Mac's web pairing link, and one
 * `DirectBackend` per Mac for the pages (`<yoyo-screen>`, `<yoyo-clipboard>`, `ScreenPreview`). The link (WebRTC
 * signaled through the relay, the Mac's identity pinned) is the only way to a Mac: a browser can't pin the Mac's TLS
 * listener, so there is no HTTP fallback.
 */
export declare class DirectWeb {
    private readonly options;
    private readonly store;
    private identityPromise;
    private readonly backends;
    constructor(options: DirectWebOptions);
    /** The paired Macs, oldest first. */
    macs(): Promise<PairedMac[]>;
    /** This browser's device id (made the first time) and DTLS certificate (link-web's `clientCertificate`: kept in the
     *  certificate store, a new one a day before it expires — the Macs then need pairing again). */
    identity(): Promise<DeviceIdentity>;
    private loadIdentity;
    private settings;
    /**
     * Pairs with the Mac of `link` over the link itself (`hello.credential = "Pair <code>"`): the Mac checks the code as a
     * phone's, binds the new token to this browser's certificate and returns it in `welcome.principal`. The
     * Mac is saved and returned. Rejects with a `DirectError`: `pairing` (the code was refused), `offline`,
     * `unreachable`, `busy` (too many paired devices, too many tries), `verification`, `unsupported`.
     */
    pair(link: PairingLink): Promise<PairedMac>;
    /** Forgets the Mac here (its session ends). The Mac keeps listing this browser until it is removed there. */
    forget(id: string): Promise<void>;
    /** The pages' backend for `mac` (one per Mac, shared by its pages: one session). `onUnpaired`: the Mac stopped
     *  knowing this browser. */
    backend(mac: PairedMac, onUnpaired?: () => void): Promise<DirectBackend>;
    /** Ends the Mac's session and its events reader (a later `backend()` makes new ones). */
    disconnect(id: string): void;
    /** Ends every session. */
    close(): void;
}
