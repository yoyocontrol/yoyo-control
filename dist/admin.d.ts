import type { KeyRing } from "./keys.js";
import type { Rechecker } from "./recheck.js";
import type { Store } from "./store.js";
export declare class AdminError extends Error {
}
export declare function disableAccount(store: Store, id: string, now?: number): number;
export declare function enableAccount(store: Store, id: string, now?: number): void;
export declare function removeAccount(store: Store, id: string, now?: number): void;
export declare function clearTombstone(store: Store, iss: string, sub: string): boolean;
export declare function revokeDevice(store: Store, id: string, now?: number): void;
export declare function rebindIssuer(store: Store, oldIss: string, newIss: string, dryRun?: boolean): {
    accounts: number;
    tombstones: number;
};
export declare function runAdmin(args: string[], deps: {
    store: Store;
    ring: KeyRing;
    recheck?: () => Promise<Rechecker>;
    now?: () => number;
    issuer?: string;
}): Promise<string>;
