/** The IndexedDB database `browserStore` opens by default. */
export const DEFAULT_DATABASE = "yoyocontrol-web";
const MACS = "macs";
const META = "meta";
const IDENTITY_KEY = "identity";
function done(req) {
    return new Promise((resolve, reject) => {
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error ?? new Error("IndexedDB request failed"));
    });
}
/** The paired Macs and the device id in IndexedDB (database `name`: object stores `macs`, keyed by `id`, and `meta`). */
export function browserStore(name = DEFAULT_DATABASE, factory = indexedDB) {
    let db = null;
    const open = () => {
        db ??= new Promise((resolve, reject) => {
            const req = factory.open(name, 1);
            req.onupgradeneeded = () => {
                const d = req.result;
                if (!d.objectStoreNames.contains(MACS))
                    d.createObjectStore(MACS, { keyPath: "id" });
                if (!d.objectStoreNames.contains(META))
                    d.createObjectStore(META);
            };
            req.onsuccess = () => resolve(req.result);
            req.onerror = () => {
                db = null;
                reject(req.error ?? new Error("IndexedDB is not available"));
            };
        });
        return db;
    };
    const store = async (which, mode) => (await open()).transaction(which, mode).objectStore(which);
    return {
        async macs() {
            const list = (await done((await store(MACS, "readonly")).getAll()));
            return list.sort((a, b) => a.pairedAt - b.pairedAt);
        },
        async saveMac(mac) {
            await done((await store(MACS, "readwrite")).put(mac));
        },
        async removeMac(id) {
            await done((await store(MACS, "readwrite")).delete(id));
        },
        async identity() {
            return (await done((await store(META, "readonly")).get(IDENTITY_KEY))) ?? null;
        },
        async saveIdentity(identity) {
            await done((await store(META, "readwrite")).put(identity, IDENTITY_KEY));
        },
    };
}
/** Kept in memory only (tests; a page that must not remember anything). */
export function memoryStore() {
    const macs = new Map();
    let identity = null;
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
