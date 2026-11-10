// The browser's DTLS certificate is its client key on the server (docs/LINK.md「WebRTC」: `AuthRequest.client_key` =
// `dtls-sha256:<hex>`): a device token binds to it on first use, so a browser has to keep presenting the same one.
// This module keeps it — in IndexedDB by default, in whatever the host supplies otherwise.

/** Where a browser keeps its DTLS certificate between page loads. */
export interface CertificateStore {
  /** The kept certificate, or undefined when there is none yet. */
  load(): Promise<RTCCertificate | undefined>;
  /** Keeps `certificate` (replacing the old one). */
  save(certificate: RTCCertificate): Promise<void>;
}

/** How long a new certificate is valid (Chrome caps a certificate's lifetime at a year). */
export const CERTIFICATE_LIFETIME_MS = 365 * 24 * 3600 * 1000;
/** A kept certificate that expires sooner than this is replaced (which means pairing again). */
export const CERTIFICATE_RENEW_MS = 24 * 3600 * 1000;

/**
 * An IndexedDB store (database `dbName`, default `yoyocontrol-link`; object store `certificates`; the record under
 * `key`, default `rtc`). `RTCCertificate` is structured-cloneable, so the private key never leaves the browser.
 */
export function indexedDbCertificateStore(options: { dbName?: string; key?: string } = {}): CertificateStore {
  const dbName = options.dbName ?? "yoyocontrol-link";
  const key = options.key ?? "rtc";
  const open = () =>
    new Promise<IDBDatabase>((resolve, reject) => {
      const req = indexedDB.open(dbName, 1);
      req.onupgradeneeded = () => req.result.createObjectStore("certificates");
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
  const run = async <T>(mode: IDBTransactionMode, op: (s: IDBObjectStore) => IDBRequest<T>): Promise<T> => {
    const db = await open();
    try {
      return await new Promise<T>((resolve, reject) => {
        const tx = db.transaction("certificates", mode);
        const req = op(tx.objectStore("certificates"));
        tx.oncomplete = () => resolve(req.result);
        tx.onerror = () => reject(tx.error);
        tx.onabort = () => reject(tx.error);
      });
    } finally {
      db.close();
    }
  };
  return {
    load: async () => {
      const v = await run("readonly", (s) => s.get(key));
      return v instanceof RTCCertificate ? v : undefined;
    },
    save: async (certificate) => {
      await run("readwrite", (s) => s.put(certificate, key));
    },
  };
}

/** The default store, or null where the browser has no IndexedDB (a worker without it, Node). */
export function defaultCertificateStore(): CertificateStore | null {
  return typeof indexedDB === "undefined" ? null : indexedDbCertificateStore();
}

const pending = new WeakMap<CertificateStore, Promise<RTCCertificate>>();

/**
 * The certificate kept in `store`, or a new ECDSA P-256 one (valid `CERTIFICATE_LIFETIME_MS`) saved there when there
 * is none or it expires within `CERTIFICATE_RENEW_MS`. Concurrent calls on one store share one result. A new
 * certificate is a new client key: the server sees an unknown device until it pairs again.
 */
export function clientCertificate(store: CertificateStore): Promise<RTCCertificate> {
  const inFlight = pending.get(store);
  if (inFlight) return inFlight;
  const p = (async () => {
    const kept = await store.load();
    if (kept && kept.expires - Date.now() > CERTIFICATE_RENEW_MS) return kept;
    const fresh = await RTCPeerConnection.generateCertificate({ name: "ECDSA", namedCurve: "P-256", expires: CERTIFICATE_LIFETIME_MS } as AlgorithmIdentifier);
    await store.save(fresh);
    return fresh;
  })();
  pending.set(store, p);
  p.then(
    () => pending.delete(store),
    () => pending.delete(store),
  );
  return p;
}

/**
 * The client key the server sees for `certificate`: `"dtls-sha256:"` + the lower-case hex SHA-256 fingerprint (what
 * `AuthRequest.client_key` / `Session::remote_id()` are on an rtc session). Undefined when the browser has no
 * `RTCCertificate.getFingerprints()`.
 */
export function clientKeyOf(certificate: RTCCertificate): string | undefined {
  const fps = typeof certificate.getFingerprints === "function" ? certificate.getFingerprints() : [];
  const fp = fps.find((f) => f.algorithm?.toLowerCase() === "sha-256")?.value;
  return fp ? `dtls-sha256:${fp.replace(/:/g, "").toLowerCase()}` : undefined;
}
