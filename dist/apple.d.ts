import { type JsonWebKey } from "node:crypto";
export declare const APPLE_ISSUER = "https://appleid.apple.com";
export declare const APPLE_KEYS_URL = "https://appleid.apple.com/auth/keys";
export declare const APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token";
export declare const APPLE_REVOKE_URL = "https://appleid.apple.com/auth/revoke";
/** SHA-256 of Apple Root CA - G3's DER (https://www.apple.com/certificateauthority/), the StoreKit chains' root. */
export declare const APPLE_ROOT_G3_SHA256 = "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179";
/** A key of Apple's by its `kid` (tests: their own). */
export type AppleKeys = (kid: string) => Promise<JsonWebKey | undefined>;
/** Apple's keys, fetched at most once a day (and again, at most once a minute, for a key id not held yet). */
export declare function cachedAppleKeys(fetchKeys?: () => Promise<JsonWebKey[]>, now?: () => number): AppleKeys;
export interface AppleIdentity {
    sub: string;
    email?: string;
    email_verified?: boolean;
}
/**
 * The identity token's subject (and email, if any), when it is Apple's (RS256 under a key of theirs), for one of
 * `audiences` (the apps' bundle ids), not expired, and carries SHA-256(`nonce`) (hex, as iOS apps send it) or the nonce
 * itself. null otherwise.
 */
export declare function verifyIdentityToken(token: string, nonce: string, audiences: string[], key: AppleKeys, now?: number): Promise<AppleIdentity | null>;
/** The Sign in with Apple key (developer portal › Keys, "Sign in with Apple" for the app's App ID): what the server
 *  signs its client secret with to talk to Apple's token endpoints. `clientId`: the app's bundle id. */
export interface AppleClient {
    teamId: string;
    keyId: string;
    clientId: string;
    /** The .p8 as PEM. */
    privateKey: string;
}
/** The client secret Apple's token endpoints want: an ES256 JWT by the Sign in with Apple key, iss = team, sub = the
 *  app, aud = Apple, good for 5 minutes. */
export declare function clientSecret(c: AppleClient, now?: number): string;
/**
 * Revokes the Sign in with Apple grant behind a fresh authorization code (the app asks for one when the account is
 * deleted, as Apple requires): the code → a refresh token (`/auth/token`) → `/auth/revoke`. `sub`: the account's Apple
 * id; a code of somebody else's revokes nothing. Whether Apple took it.
 */
export declare function revokeAppleGrant(c: AppleClient, code: string, sub: string, post?: typeof fetch, now?: number): Promise<boolean>;
/** A StoreKit 2 transaction (`Transaction.jwsRepresentation`) as the account server keeps it. Times are unix ms. */
export interface StoreTransaction {
    bundleId: string;
    productId: string;
    originalTransactionId: string;
    expiresDate?: number;
    revocationDate?: number;
    environment: string;
    ownership?: string;
}
/**
 * The transaction, when its JWS is Apple's: ES256 by the leaf of an x5c chain leaf → intermediate → Apple Root CA G3,
 * each signed by the next, the leaf and intermediate carrying Apple's extensions, all valid at `now`. null otherwise.
 * `rootSha256`: another root (tests).
 */
export declare function verifyStoreKit(jws: string, now?: number, rootSha256?: string): StoreTransaction | null;
