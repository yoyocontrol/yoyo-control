/** A Mac this browser paired with: what it takes to reach it again. */
export interface PairedMac {
    /** The Mac's server id. */
    id: string;
    /** Its name (from the pairing link, then from each `welcome`). */
    name: string;
    /** Its identity fingerprint (`sha256:<hex>`): pinned on every connection. */
    fingerprint: string;
    /** This browser's device token there (`Bearer <token>`). */
    token: string;
    /** The signaling server of the connection (the one it paired through, e.g. `https://signal.example.com`). */
    relay: string;
    /** When it was paired (ms since 1970). */
    pairedAt: number;
    /** What the Mac said it is last time (`welcome.server.platform`: "mac"…). */
    platform?: string | null;
}
/**
 * Who this browser is to every Mac: its device id (`hello.device.id`) and the DTLS certificate whose fingerprint the
 * Macs bind its tokens to (docs/LINK.md「WebRTC」: a new certificate means pairing again). The certificate is kept by
 * link-web's certificate store (`DirectWebOptions.certificateStore`), the id here.
 */
export interface DeviceIdentity {
    /** 8–64 of `A–Z a–z 0–9 _ -` (a UUID). */
    deviceId: string;
    certificate: RTCCertificate;
}
/** What a `DirectStore` keeps of the identity: the device id. `certificate`: where an earlier build kept it; moved to
 *  the certificate store on first use (the Macs know that one) and dropped here. */
export interface StoredIdentity {
    deviceId: string;
    certificate?: RTCCertificate;
}
/** Where the paired Macs and the identity are kept. `browserStore()` (IndexedDB) or `memoryStore()`, or your own. */
export interface DirectStore {
    macs(): Promise<PairedMac[]>;
    saveMac(mac: PairedMac): Promise<void>;
    removeMac(id: string): Promise<void>;
    identity(): Promise<StoredIdentity | null>;
    saveIdentity(identity: StoredIdentity): Promise<void>;
}
/** The IndexedDB database `browserStore` opens by default. */
export declare const DEFAULT_DATABASE = "yoyocontrol-web";
/** The paired Macs and the device id in IndexedDB (database `name`: object stores `macs`, keyed by `id`, and `meta`). */
export declare function browserStore(name?: string, factory?: IDBFactory): DirectStore;
/** Kept in memory only (tests; a page that must not remember anything). */
export declare function memoryStore(): DirectStore;
