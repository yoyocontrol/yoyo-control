/** Where a browser keeps its DTLS certificate between page loads. */
export interface CertificateStore {
    /** The kept certificate, or undefined when there is none yet. */
    load(): Promise<RTCCertificate | undefined>;
    /** Keeps `certificate` (replacing the old one). */
    save(certificate: RTCCertificate): Promise<void>;
}
/** How long a new certificate is valid (Chrome caps a certificate's lifetime at a year). */
export declare const CERTIFICATE_LIFETIME_MS: number;
/** A kept certificate that expires sooner than this is replaced (which means pairing again). */
export declare const CERTIFICATE_RENEW_MS: number;
/**
 * An IndexedDB store (database `dbName`, default `yoyocontrol-link`; object store `certificates`; the record under
 * `key`, default `rtc`). `RTCCertificate` is structured-cloneable, so the private key never leaves the browser.
 */
export declare function indexedDbCertificateStore(options?: {
    dbName?: string;
    key?: string;
}): CertificateStore;
/** The default store, or null where the browser has no IndexedDB (a worker without it, Node). */
export declare function defaultCertificateStore(): CertificateStore | null;
/**
 * The certificate kept in `store`, or a new ECDSA P-256 one (valid `CERTIFICATE_LIFETIME_MS`) saved there when there
 * is none or it expires within `CERTIFICATE_RENEW_MS`. Concurrent calls on one store share one result. A new
 * certificate is a new client key: the server sees an unknown device until it pairs again.
 */
export declare function clientCertificate(store: CertificateStore): Promise<RTCCertificate>;
/**
 * The client key the server sees for `certificate`: `"dtls-sha256:"` + the lower-case hex SHA-256 fingerprint (what
 * `AuthRequest.client_key` / `Session::remote_id()` are on an rtc session). Undefined when the browser has no
 * `RTCCertificate.getFingerprints()`.
 */
export declare function clientKeyOf(certificate: RTCCertificate): string | undefined;
