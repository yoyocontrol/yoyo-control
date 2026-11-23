import { type KeyObject } from "node:crypto";
import { type AccountConfig } from "../config.js";
import { KeyRing } from "../keys.js";
import { OidcClient } from "../oidc.js";
import { Rechecker } from "../recheck.js";
import { AccountService, type Limits, type NoticeOut } from "../service.js";
/** The default namespace's signed texts and service names (a harness without ACCOUNT_NAMESPACE; `h.cfg.wire` has a
 *  harness's own). */
export declare const computerProofText: (origin: string, method: string, pathAndQuery: string, ts: number, bodyHash: string) => string;
export declare const joinProofText: (origin: string, linkId: string, account: string, deviceCode: string) => string;
export declare const joinKeyProofText: (origin: string, linkId: string, key: string) => string;
export declare const hostedProofText: (server: string, method: string, pathQ: string, ts: number, bodyHash: string) => string;
export declare const PUSH_SERVICE: string;
export declare const SPEECH_SERVICE: string;
import { Store } from "../store.js";
import { TestIdp } from "./idp.js";
export interface LinkKey {
    id: string;
    key: KeyObject;
    sign(text: string): string;
}
export declare function linkKey(): LinkKey;
export interface Harness {
    idp: TestIdp;
    store: Store;
    ring: KeyRing;
    cfg: AccountConfig;
    svc: AccountService;
    oidc: OidcClient;
    recheck: Rechecker;
    url: string;
    logs: string[];
    notices: NoticeOut[];
    clock: {
        t: number | null;
    };
    stop(): Promise<void>;
}
export declare function harness(o?: {
    env?: Record<string, string>;
    limits?: Partial<Limits>;
    dbFile?: string;
    idp?: (idp: TestIdp) => void;
}): Promise<Harness>;
export declare function stopAll(): Promise<void>;
export declare const b64url: (b: Buffer) => string;
export declare function pkce(): {
    verifier: string;
    challenge: string;
};
/** GET without following redirects. */
export declare function get(url: string, headers?: Record<string, string>): Promise<Response>;
export declare function post(url: string, body: unknown, headers?: Record<string, string>): Promise<Response>;
export declare const bearer: (t: string) => {
    authorization: string;
};
/** /v1/signin → the IdP → /v1/callback; the final Location (the app's redirect with code or error). */
export declare function throughIdp(h: Harness, query: Record<string, string>): Promise<{
    location: string;
    signin: Response;
    callback: Response | null;
    authorize: URLSearchParams | null;
}>;
/** An app's whole sign-in: code + PKCE through the IdP, then /v1/token. */
export declare function appSignIn(h: Harness, o?: {
    device?: Record<string, unknown>;
    prompt?: string;
    redirect?: string;
}): Promise<{
    session: string;
    account: {
        id: string;
        name: string;
    };
    device: {
        id: string;
        name: string;
    };
    expiresAt: number;
}>;
/** A computer starts a join. */
export declare function enroll(h: Harness, k: LinkKey, extra?: Record<string, unknown>): Promise<{
    status: number;
    body: {
        device_code: string;
        user_code: string;
        qr: string;
        interval: number;
        error?: string;
    };
}>;
/** The computer's confirmation, signed with its Link key. */
export declare function confirm(h: Harness, k: LinkKey, deviceCode: string, account: string, signer?: LinkKey): Promise<Response>;
/** A computer joined to the account of `session`, the whole way. */
export declare function joinComputer(h: Harness, session: string, k?: LinkKey): Promise<{
    k: LinkKey;
    account: string;
    body: {
        server: {
            keys: unknown[];
        };
    };
}>;
/** A member computer's signed request. */
export declare function computerCall(h: Harness, k: LinkKey, method: "GET" | "POST", pathQ: string, body?: unknown, o?: {
    ts?: number;
    signer?: LinkKey;
}): Promise<Response>;
