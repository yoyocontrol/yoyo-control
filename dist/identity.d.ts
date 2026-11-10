import { type KeyObject } from "node:crypto";
export declare const KEY_FILE = "tls-key.der";
export interface Identity {
    /** The private key (Node's), for signing. */
    readonly key: KeyObject;
    /** The public key as X9.63 bytes (04 ‖ X ‖ Y, 65 bytes). */
    readonly publicKey: Buffer;
    /** `"sha256:" + hex(SHA-256(publicKey))`: what a phone pins (the Mac's `RemoteIdentity.fingerprint`). */
    readonly keyFingerprint: string;
}
/** The identity in `dir` (made when missing; the directory is created 0700). */
export declare function loadOrCreateIdentity(dir: string): Identity;
/** `"sha256:"` + lowercase hex of SHA-256 over `bytes`. */
export declare function fingerprint(bytes: Uint8Array): string;
/** A P-256 private key from its X9.63 bytes (04 ‖ X ‖ Y ‖ D). */
export declare function keyFromX963(raw: Uint8Array): KeyObject;
/** The private key's X9.63 bytes (04 ‖ X ‖ Y ‖ D). */
export declare function x963Private(key: KeyObject): Buffer;
/** The public key's X9.63 bytes (04 ‖ X ‖ Y) of a private or public P-256 key. */
export declare function x963Public(key: KeyObject): Buffer;
/** Writes `data` as 0600 through a temporary file (a reader never sees half of it). */
export declare function writePrivate(path: string, data: Uint8Array | string): void;
