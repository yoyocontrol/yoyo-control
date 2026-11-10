import { EventEmitter } from "node:events";
import type { Identity } from "./identity.js";
/** Where a server keeps its room: `explicit`, else `YOYO_SIGNAL_URL`; none is built in (`""`: no signaling server). */
export declare function signalUrl(explicit?: string): string;
export declare const RELAY_PING_MS = 30000;
export declare const RELAY_PONG_TIMEOUT_MS = 45000;
export declare const RELAY_MAX_BACKOFF_MS = 60000;
type WebSocketCtor = new (url: string) => WebSocket;
export interface SignalOptions {
    identity: Pick<Identity, "key" | "publicKey" | "keyFingerprint">;
    /** Default `signalUrl()`. */
    url?: string;
    log?: (line: string) => void;
    /** Tests: another WebSocket. */
    WebSocket?: WebSocketCtor;
}
/** The room of a key: 64 lowercase hex digits (its fingerprint without "sha256:"). */
export declare function relayRoom(keyFingerprint: string): string;
/** The answer to the room's challenge: `{ type: "hello", v: 1, key, sig }`, `sig` = raw r ‖ s over "yoyocontrol-relay-v1:" + nonce. */
export declare function relayHello(nonce: string, identity: Pick<Identity, "key" | "publicKey">): string;
/** The uu Link the room tells phones about (docs/RELAY.md「候选」): the binding and where the endpoint is. */
export interface SignalLink {
    id: string;
    key: string;
    sig: string;
    relays: string[];
    direct: string[];
}
/** `{"direct":[…],"id","key","relays":[…],"sig","type":"link"}`. */
export declare function linkMessage(link: SignalLink): string;
/** `{"id","type":"account"}` (`"id":null`: none). */
export declare function accountMessage(id: string | null): string;
/** Events: `change` (registered or not: `registered`); `unlinked` (the room says it isn't in its account any more). */
export declare class SignalClient extends EventEmitter {
    readonly base: string;
    readonly room: string;
    private readonly opts;
    private readonly log;
    private readonly WS;
    private control;
    private running;
    private _registered;
    private backoff;
    private lastPong;
    private pinger;
    private retry;
    private linkText;
    private account;
    constructor(opts: SignalOptions);
    get registered(): boolean;
    start(): void;
    /** Leaves the room. */
    stop(): void;
    /** The link told to the room (null: none — not sent; a room keeps the last one until this server registers again). */
    setLink(link: SignalLink | null): void;
    /**
     * The account this server is in (docs/ACCOUNT.md; null: none), told to the room after `ready` and when it changes.
     * The room answers `{"type":"account","state"}`; "unlinked" (it isn't in that account's directory any more) is the
     * `unlinked` event.
     */
    setAccount(id: string | null): void;
    private connect;
    private handle;
    private send;
    private startPinging;
    private stopPinging;
    private dropped;
    private again;
    private setRegistered;
}
export {};
