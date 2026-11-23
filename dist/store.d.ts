import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { type RevocationState, type Wire } from "@yoyocontrol/account";
export declare const SCHEMA_VERSION = 3;
/** How long a device's revocation stays on the list (seconds): past the longest a computer's token of it can live. */
export declare const REVOCATION_KEEP_S: number;
export declare const sha256: (s: string) => string;
export declare const randomId: (prefix: string, bytes?: number) => string;
export interface Account {
    id: string;
    iss: string;
    sub: string;
    name: string | null;
    created_at: number;
    disabled_at: number | null;
}
export interface Device {
    id: string;
    account_id: string;
    name: string;
    platform: string | null;
    /** A browser signed in at a computer's own page: that computer's Link id (it may end this device's session). */
    computer: string | null;
    key: string | null;
    key_digest: string | null;
    created_at: number;
    last_used_at: number | null;
    removed_at: number | null;
}
export interface Session {
    id: string;
    account_id: string;
    device_id: string | null;
    /** `app`: a device's (it holds the token). `web`: this server's /c page (a cookie). `browser`: a browser signed in at a
     *  computer's own page — nobody holds its token; it is there so the device shows in My Devices and can be removed. */
    /** `app` (the apps' bearer), `hosted` (the hosted web client's bearer, bound to its device key), `web` (this server's
     *  /c page's cookie), `browser` (a browser signed in at a computer's own page: nobody holds its token). */
    kind: "app" | "hosted" | "web" | "browser";
    created_at: number;
    expires_at: number;
    last_used_at: number | null;
    ended_at: number | null;
    end_reason: string | null;
    idp_refresh: string | null;
    idp_checked_at: number | null;
    idp_check_result: string | null;
    lease_until: number | null;
}
export interface Computer {
    link_id: string;
    account_id: string;
    name: string;
    fingerprint: string | null;
    relays: string;
    direct: string;
    origins: string;
    /** The signaling service the computer waits for browsers' offers at (an origin), or null. */
    signal: string | null;
    joined_at: number;
    updated_at: number;
}
export interface Enrollment {
    id: string;
    device_code_hash: string;
    user_code: string;
    link_id: string;
    name: string;
    fingerprint: string | null;
    relays: string;
    direct: string;
    origins: string;
    signal: string | null;
    expect: string | null;
    ip: string;
    created_at: number;
    expires_at: number;
    last_poll_at: number | null;
    status: "pending" | "approved" | "declined" | "confirmed";
    approved_account: string | null;
    approved_device_name: string | null;
    approved_at: number | null;
}
export interface Signin {
    state: string;
    kind: "app" | "web" | "computer";
    /** base64url SHA-256 of the cookie the browser that started it holds (`web`, `computer`); "" for an app's. */
    bind: string;
    verifier: string;
    nonce: string;
    redirect_uri: string;
    client_state: string;
    challenge: string;
    computer: string | null;
    created_at: number;
    expires_at: number;
}
export interface AppCode {
    code_hash: string;
    account_id: string;
    challenge: string;
    redirect_uri: string;
    idp_refresh: string | null;
    /** A code for a computer's own page: only that computer (its Link id) may trade it. */
    computer: string | null;
    expires_at: number;
}
export interface OutboxRow {
    id: number;
    account_id: string;
    seq: number;
    payload: string;
}
export declare class Store {
    private readonly wire;
    readonly db: DatabaseSync;
    private stmts;
    private depth;
    /** `wire`: the namespace its session tokens and join keys are named in (the server's). */
    constructor(file: string, wire?: Wire);
    close(): void;
    private q;
    get<T>(sql: string, ...a: SQLInputValue[]): T | undefined;
    all<T>(sql: string, ...a: SQLInputValue[]): T[];
    run(sql: string, ...a: SQLInputValue[]): number;
    /** `fn` in one transaction (BEGIN IMMEDIATE: one writer at a time, this process or an admin command's). */
    tx<T>(fn: () => T): T;
    account(id: string): Account | undefined;
    accountOf(iss: string, sub: string): Account | undefined;
    tombstone(iss: string, sub: string): {
        account_id: string;
        removed_at: number;
    } | undefined;
    /** The account of `iss` + `sub` (made now when there is none), or why there is none to be had. */
    signInAccount(iss: string, sub: string, name: string | null, now: number): {
        account: Account;
    } | {
        refused: "removed" | "disabled";
    };
    /** The device this sign-in is: the account's device with the same public key (not removed), else a new one. */
    deviceFor(account: string, d: {
        name: string;
        platform: string | null;
        key: string | null;
        keyDigest: string | null;
        computer?: string | null;
    }, now: number): Device;
    device(id: string): Device | undefined;
    devicesOf(account: string): Device[];
    /** The devices signed in now (a live session): what "My devices" shows — one that signed out is not one of them,
     *  though its row stays (the same key signing in again is the same device). */
    signedInDevicesOf(account: string, now: number): Device[];
    /** The devices that count against the account's limit: those signed in now. */
    countDevices(account: string, now: number): number;
    createSession(p: {
        account: string;
        device: string | null;
        kind: Session["kind"];
        now: number;
        maxAgeMs: number;
        idpRefresh: string | null;
        replaceDeviceSessions?: boolean;
    }): {
        id: string;
        token: string;
        expiresAt: number;
    };
    sessionOfToken(token: string): Session | undefined;
    session(id: string): Session | undefined;
    touchSession(s: Session, now: number): void;
    /** Ends live sessions (and drops their IdP refresh tokens); the number ended. */
    endSessions(where: "id" | "device_id" | "account_id", value: string, reason: string, now: number): number;
    putSignin(s: Signin): void;
    /** The pending sign-in of `state`, once (taken out whether or not it is still good). */
    takeSignin(state: string, now: number): Signin | null;
    countSignins(now: number): number;
    putAppCode(c: AppCode): void;
    takeAppCode(code: string, now: number): AppCode | null;
    computer(linkId: string): Computer | undefined;
    computersOf(account: string): Computer[];
    countComputers(account: string): number;
    enrollmentOfCode(userCode: string): Enrollment | undefined;
    enrollmentOfDeviceCode(deviceCode: string): Enrollment | undefined;
    /** The addresses the open join codes were asked from (one entry per code). */
    openEnrollmentAddresses(now: number): string[];
    countEnrollments(now: number, ip?: string): number;
    /** A new join key of `account` (admin.ts join-key): a computer that has it joins that account without anyone's
     *  approval, `uses` times at most, until `expiresAt`. Only its SHA-256 is kept. */
    createJoinKey(account: string, uses: number, expiresAt: number, now: number): string;
    /** One use of a join key taken: its account's id, or null (unknown, expired, used up). */
    useJoinKey(key: string, now: number): string | null;
    revocationState(account: string): RevocationState;
    /**
     * Revocations of one account, in one step: entries added (an entry's `at` only moves later), the disabled mark set
     * or cleared, the version raised by one, and the notice for it queued (outbox: main.ts pushes it). The new version.
     */
    revoke(account: string, r: {
        devices?: string[];
        computers?: string[];
        disabled?: number | null;
    }, atSec: number, now: number): number;
    outbox(limit?: number): OutboxRow[];
    outboxDone(id: number): void;
    /** Rows past their use: sign-ins and app codes expired, join codes an hour after, sessions a week after they ended
     *  or expired (kept that long for `admin.ts account`). */
    sweep(now: number): void;
}
