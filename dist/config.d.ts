import { Wire } from "@yoyocontrol/account";
import { type AppleClient } from "./apple.js";
/**
 * One thing this server lends the computers of its accounts (GET /v1/computer/services), under `name` there. `fixed`:
 * the same fields for every computer (`value()` now: an origin `url` and short strings — a relay's token, a key; null
 * while there is none). `token`: an origin and a service token of each computer's own (`aud` = `wire.service(service)`,
 * a day long: the service checks it with this server's keys, @yoyocontrol/account `ServiceKeys`).
 */
export type ServiceSpec = {
    name: string;
    kind: "fixed";
    value: () => ({
        url: string;
    } & Record<string, string>) | null;
} | {
    name: string;
    kind: "token";
    url: string;
    service: string;
};
export declare const GOOGLE_ISSUER = "https://accounts.google.com";
/** The two ways Google writes `iss` in an id_token (its OpenID docs: both occur). */
export declare const GOOGLE_ISSUERS: string[];
/**
 * IdPs anyone can sign up at: the account server refuses to start against one unless ACCOUNT_ALLOW narrows who may
 * sign in, or ACCOUNT_OPEN=1 says that anyone with an account there may (and then gets an account here). Matched on
 * the issuer's host (and path, for the multi-tenant Microsoft endpoints). Not exhaustive: a self-hosted IdP with
 * self-registration turned on is just as open, and only its admin knows.
 */
export declare const OPEN_ISSUERS: RegExp[];
export interface Allow {
    /** Exact `sub` values. */
    subs: Set<string>;
    /** `@example.com` entries, lower case without the `@`: Google's `hd`, else a verified email's domain. */
    domains: string[];
}
/** An app's native Sign in with Apple (POST /v1/auth/apple): its identity token goes straight to this server. */
export interface AppleSignIn {
    /** The apps' bundle ids (the token's `aud` is one of them). */
    audiences: string[];
    /** The Sign in with Apple key: with it, an account deleted from the app has its Apple grant revoked (Apple's rule);
     *  without it nothing is revoked. Its `clientId` is the first audience. */
    client: AppleClient | null;
}
/** App Store subscriptions (POST /v1/entitlements/appstore): an app's StoreKit 2 transactions of these products. */
export interface AppStoreEntitlements {
    bundleId: string;
    products: string[];
}
export interface AccountConfig {
    /** The OpenID Connect provider's issuer; without one (an app's native Sign in with Apple alone), Apple's. */
    issuer: string;
    /** Whether an OpenID Connect provider is set up (GET /v1/signin; false: only the native sign-ins). */
    oidc: boolean;
    clientId: string;
    clientSecret: string;
    /** The account server's public origin, https://account.example.com (no path). */
    publicUrl: string;
    allow: Allow | null;
    /** ACCOUNT_OPEN=1: an open IdP without an allow-list, on purpose. */
    open: boolean;
    /** ACCOUNT_IDP_RECHECK=1: each device session's IdP refresh token is used once an hour to ask whether its sign-in
     *  still stands. Off by default. */
    recheck: boolean;
    /** Where the app may be sent back with a sign-in code (exact URLs; custom schemes allowed). The server's own
     *  `<publicUrl>/v1/app-return` is always allowed (iOS's `.https(host:path:)` callback). */
    appRedirects: string[];
    /** Where a hosted web client may be sent back (exact https URLs). Their origins may call the API (CORS). */
    webRedirects: string[];
    /** `TEAMID.bundle.id` entries for /.well-known/apple-app-site-association (webcredentials); none = not served. */
    appleAppIds: string[];
    /** What clients show for the IdP ("Example ID"); default its host. */
    idpName: string;
    /** What clients show for this server; default its host. */
    serverName: string;
    dataDir: string;
    host: string;
    port: number;
    /** Requests from loopback are the TLS front's: the client is its last X-Forwarded-For. */
    trustProxy: boolean;
    /** The wire names' namespace (ACCOUNT_NAMESPACE, default "yoyo"): the computers and services must use the same one. */
    wire: Wire;
    /** What the accounts' computers are lent, in this order (none: an empty list). From the environment: `relay`
     *  (ACCOUNT_RELAY_URL + ACCOUNT_RELAY_TOKEN or _FILE, read again when the file changes), `push` (ACCOUNT_PUSH_URL),
     *  `speech` (ACCOUNT_SPEECH_URL), `signal` (ACCOUNT_SIGNAL_URL + ACCOUNT_SIGNAL_KEY or _FILE: with the relay only,
     *  never its token) and `web` (the first of ACCOUNT_WEB_REDIRECTS' origin). */
    services: ServiceSpec[];
    /** ACCOUNT_APPLE_AUDIENCES (+ ACCOUNT_APPLE_TEAM_ID, ACCOUNT_APPLE_KEY_ID, ACCOUNT_APPLE_KEY or _FILE): null = off. */
    apple: AppleSignIn | null;
    /** ACCOUNT_APPSTORE_BUNDLE_ID + ACCOUNT_APPSTORE_PRODUCTS: null = off. */
    appstore: AppStoreEntitlements | null;
}
export declare class ConfigError extends Error {
}
/** An issuer as it is compared: no trailing slash; Google's bare form written as its URL. */
export declare function normalizeIssuer(iss: string): string;
export declare const isGoogle: (issuer: string) => boolean;
export declare function parseAllow(v: string | undefined): Allow | null;
/** Whether these (verified) id_token claims may sign in. */
export declare function allowed(allow: Allow | null, issuer: string, claims: {
    sub: string;
    email?: unknown;
    email_verified?: unknown;
    hd?: unknown;
}): boolean;
/** Why this configuration must not start (an open IdP nobody narrowed), or null. */
export declare function opennessProblem(cfg: Pick<AccountConfig, "issuer" | "allow" | "open"> & {
    apple?: AppleSignIn | null;
}): string | null;
/** `relayTokenFile` / `signalKeyFile`: read ACCOUNT_RELAY_TOKEN_FILE / ACCOUNT_SIGNAL_KEY_FILE as they are now (main.ts:
 *  again when the file changed). */
/** `appleKeyFromFile`: ACCOUNT_APPLE_KEY_FILE's content (main.ts reads it). */
export declare function configFromEnv(env: Record<string, string | undefined>, secretFromFile?: string, relayTokenFile?: () => string | null, signalKeyFile?: () => string | null, appleKeyFromFile?: string): AccountConfig;
