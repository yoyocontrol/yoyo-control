import { type DialRtcOptions, type LinkSession } from "@yoyocontrol/link-web";
import { DirectError, type DirectMessages } from "./errors.js";
import type { DeviceIdentity, PairedMac } from "./store.js";
/** Makes a session (default link-web's `dialRtc`): tests and other runtimes put their own here. */
export type Dialer = (options: DialRtcOptions) => Promise<LinkSession>;
/** What every connection to a Mac shares: who this browser is, how it dials. */
export interface DialSettings {
    identity: DeviceIdentity;
    /** `hello.device.name` (e.g. "Safari on iPhone"). */
    deviceName: string;
    /** `hello.app`. */
    app: {
        name: string;
        version: string;
    };
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
export declare const FIRST_BACKOFF_MS = 1000;
export declare const MAX_BACKOFF_MS = 10000;
/** The ICE servers of one dial to `mac`: the settings' STUN plus, unless `turn: false`, TURN from its signaling paths. */
export declare function iceServersFor(settings: DialSettings, mac: Pick<PairedMac, "fingerprint" | "relay">): Promise<RTCIceServer[]>;
/** The `DialRtcOptions` of one dial to `mac` with `credential`. */
export declare function dialOptions(settings: DialSettings, mac: Pick<PairedMac, "fingerprint" | "relay">, credential: string, extra?: Partial<DialRtcOptions>): DialRtcOptions;
/**
 * The uu Link session to one paired Mac, made when something needs it and made again after it ended (the link is
 * the only way a browser has to a Mac: no HTTP fallback). One dial at a time; concurrent callers share it. After a
 * failed dial the next one waits (1 s, doubling to 10 s; `retryNow()` skips the wait). A failure that retrying can't
 * fix (`unpaired`, `verification`, `unsupported`) sticks until `retryNow()`.
 */
export declare class MacConnection {
    private mac;
    private readonly settings;
    /** A new `welcome` said something about the Mac (its name, platform): the store keeps it. */
    private readonly onMacChanged;
    private live;
    private dialing;
    private failure;
    private failedAt;
    private backoff;
    private closedForGood;
    private readonly listeners;
    private wake;
    constructor(mac: PairedMac, settings: DialSettings, 
    /** A new `welcome` said something about the Mac (its name, platform): the store keeps it. */
    onMacChanged?: (mac: PairedMac) => void);
    /** The open session, if there is one now. */
    get current(): LinkSession | null;
    /** The host's words for failures (from the settings). */
    get messages(): DirectMessages;
    /** The last dial's failure (null after a success). */
    get lastError(): DirectError | null;
    /** Hears every new session (after `welcome`); returns the unsubscribe. */
    onSession(listener: (session: LinkSession) => void): () => void;
    /** The open session, or a new one. Rejects with a `DirectError`. */
    session(): Promise<LinkSession>;
    /** The next dial goes at once (and a sticky failure is forgotten). */
    retryNow(): void;
    /** Ends the session and makes no more. */
    close(): void;
    private dial;
    private wait;
}
