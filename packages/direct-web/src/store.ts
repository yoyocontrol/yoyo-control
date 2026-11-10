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
export const DEFAULT_DATABASE = "yoyocontrol-web";

const MACS = "macs";
const META = "meta";
const IDENTITY_KEY = "identity";

function done<T>(req: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error ?? new Error("IndexedDB request failed"));
  });
}

/** The paired Macs and the device id in IndexedDB (database `name`: object stores `macs`, keyed by `id`, and `meta`). */
export function browserStore(name: string = DEFAULT_DATABASE, factory: IDBFactory = indexedDB): DirectStore {
  let db: Promise<IDBDatabase> | null = null;
  const open = () => {
    db ??= new Promise((resolve, reject) => {
      const req = factory.open(name, 1);
      req.onupgradeneeded = () => {
        const d = req.result;
        if (!d.objectStoreNames.contains(MACS)) d.createObjectStore(MACS, { keyPath: "id" });
        if (!d.objectStoreNames.contains(META)) d.createObjectStore(META);
      };
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => {
        db = null;
        reject(req.error ?? new Error("IndexedDB is not available"));
      };
    });
    return db;
  };
  const store = async (which: string, mode: IDBTransactionMode) => (await open()).transaction(which, mode).objectStore(which);
  return {
    async macs() {
      const list = (await done((await store(MACS, "readonly")).getAll())) as PairedMac[];
      return list.sort((a, b) => a.pairedAt - b.pairedAt);
    },
    async saveMac(mac) {
      await done((await store(MACS, "readwrite")).put(mac));
    },
    async removeMac(id) {
      await done((await store(MACS, "readwrite")).delete(id));
    },
    async identity() {
      return ((await done((await store(META, "readonly")).get(IDENTITY_KEY))) as StoredIdentity | undefined) ?? null;
    },
    async saveIdentity(identity) {
      await done((await store(META, "readwrite")).put(identity, IDENTITY_KEY));
    },
  };
}

/** Kept in memory only (tests; a page that must not remember anything). */
export function memoryStore(): DirectStore {
  const macs = new Map<string, PairedMac>();
  let identity: StoredIdentity | null = null;
  return {
    async macs() {
      return [...macs.values()].sort((a, b) => a.pairedAt - b.pairedAt);
    },
    async saveMac(mac) {
      macs.set(mac.id, { ...mac });
    },
    async removeMac(id) {
      macs.delete(id);
    },
    async identity() {
      return identity;
    },
    async saveIdentity(i) {
      identity = i;
    },
  };
}
