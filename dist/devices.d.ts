export declare const CODE_TTL_MS: number;
export declare const MAX_CODE_ATTEMPTS = 10;
export declare const MAX_DEVICES = 32;
/** An invitation's life (`invite`, docs/ACCOUNT.md「批准」), and how many may wait. */
export declare const INVITE_TTL_MS: number;
export declare const MAX_INVITES = 8;
export interface Device {
    id: string;
    name: string;
    pairedAt: number;
    lastSeenAt?: number;
}
export interface PairingCode {
    code: string;
    expiresAt: number;
}
export declare class PairError extends Error {
    readonly kind: "bad-code" | "bad-device" | "full";
    constructor(kind: "bad-code" | "bad-device" | "full", message: string);
}
export interface DeviceStoreOptions {
    now?: () => number;
    /** Called after the list or the pairing code changed. */
    onChange?: () => void;
    log?: (line: string) => void;
}
export declare class DeviceStore {
    readonly path: string;
    private readonly now;
    private readonly log;
    onChange: (() => void) | undefined;
    private devices;
    private code;
    private wrongCodes;
    /** Codes for one phone each: the code → who may use it (`invite`). */
    private invites;
    constructor(path: string, opts?: DeviceStoreOptions);
    get list(): Device[];
    get isEmpty(): boolean;
    /** The live pairing code, if any. */
    get pairingCode(): PairingCode | null;
    /** The device holding `token` (its `lastSeenAt` noted), or null. */
    authenticate(token: string | null | undefined): Device | null;
    /**
     * `authenticate` for a uu Link session from the client key `key` (hex): the token's first link session binds it to
     * that key (saved); later ones with another key are `other-key` until the phone pairs again.
     */
    authenticateLink(token: string | null | undefined, key: string): {
        kind: "accepted";
        device: Device;
    } | {
        kind: "other-key";
        device: Device;
    } | {
        kind: "unknown";
    };
    /** A new pairing code (the one before it no longer works). */
    startPairing(): PairingCode;
    /** The code is no longer shown. */
    stopPairing(): void;
    /**
     * A code for the phone `id` alone, over a link session from `linkKey` (hex), asked for by a phone already paired
     * (docs/ACCOUNT.md「批准」): good for INVITE_TTL_MS, once, beside the shown code.
     */
    invite(id: string, linkKey: string): PairingCode;
    /**
     * Pairs the phone (`id`, `name`) with the live code, or an invitation made for it (then only over a session from
     * its `linkKey`): its token (shown once). The code is used up.
     */
    pair(code: string, id: string, name: string, linkKey?: string): string;
    /** Forgets the device: its token stops working at once. false when it wasn't paired. */
    remove(id: string): boolean;
    private save;
}
/** 8–64 of A–Z a–z 0–9 _ - (a UUID fits). */
export declare function validDeviceId(id: string): boolean;
/** Newlines and NULs out, trimmed, at most 64 characters; empty → "iPhone". */
export declare function cleanName(raw: string): string;
/** `bytes` random bytes as base64url without padding. */
export declare function randomToken(bytes: number): string;
/**
 * The pairing link a phone scans (docs/REMOTE.md「配对」):
 * `yoyocontrol://pair?v=2&id=<serverId>&n=<name>&fp=<key fingerprint>&l=&lk=&ls=[&lp=][&a=<IPv4,…>]&c=<code>`.
 * `l…`: the uu Link binding (`link`: id hex, identity key and signature as base64url, the UDP port), so the phone dials
 * the link from anywhere at once; `a`: this host's local addresses (hints beside the binding's).
 */
export declare function pairingLink(o: {
    serverId: string;
    name: string;
    fingerprint: string;
    code: string;
    link: {
        id: string;
        key: string;
        sig: string;
        port?: number;
    };
    addresses?: readonly string[];
    scheme?: string;
}): string;
