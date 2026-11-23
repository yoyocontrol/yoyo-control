import { type JWTPayload } from "jose";
import { type AccountConfig } from "./config.js";
/** Who signed in, from a verified id_token. */
export interface IdpIdentity {
    /** The issuer as stored (normalized: Google's bare form as its URL). */
    iss: string;
    sub: string;
    /** What is shown: `name`, else `preferred_username`; null when neither. */
    name: string | null;
    email?: string;
    email_verified?: boolean;
    hd?: string;
}
export type RefreshOutcome = 
/** The sign-in stands. `refreshToken`: the new one when the IdP rotated it (null = keep the old). */
{
    kind: "ok";
    refreshToken: string | null;
    identity: IdpIdentity | null;
}
/** The IdP said, definitely, that this refresh token is no good (signed out, disabled, revoked, reused). */
 | {
    kind: "invalid_grant";
}
/** Anything else: the network, a 5xx, a 429, a misconfigured client, an id_token that did not verify. */
 | {
    kind: "retry";
    reason: string;
};
export interface Idp {
    authorizationUrl(p: {
        state: string;
        nonce: string;
        challenge: string;
        prompt?: string | undefined;
    }): Promise<string>;
    /** Whether the callback's `iss` parameter (RFC 9207) is right, or absent where it may be. */
    callbackIssOk(iss: string | null): Promise<boolean>;
    exchange(code: string, verifier: string, nonce: string): Promise<{
        identity: IdpIdentity;
        refreshToken: string | null;
    }>;
    refresh(refreshToken: string, expectedSub: string): Promise<RefreshOutcome>;
}
export declare class IdpError extends Error {
    readonly code: string;
    constructor(code: string, message: string);
}
interface Discovery {
    issuer: string;
    authorization_endpoint: string;
    token_endpoint: string;
    jwks_uri: string;
    scopes_supported?: string[];
    token_endpoint_auth_methods_supported?: string[];
    id_token_signing_alg_values_supported?: string[];
    authorization_response_iss_parameter_supported?: boolean;
    end_session_endpoint?: string;
}
export declare class OidcClient implements Idp {
    private readonly cfg;
    private disc;
    private discAt;
    private jwks;
    private readonly redirectUri;
    private readonly fetch;
    /** `fetch`: tests stand in for the network with it (e.g. a mock IdP answering as https://accounts.google.com). */
    constructor(cfg: Pick<AccountConfig, "issuer" | "clientId" | "clientSecret" | "publicUrl" | "recheck" | "allow">, o?: {
        fetch?: typeof fetch;
    });
    /** The discovery document, fetched on first use and again a day later (and after a failure). */
    discovery(): Promise<Discovery>;
    /** The scopes asked for: `openid profile`, `email` for an @domain allow-list, `offline_access` for the re-check. */
    scopes(d: Discovery): string;
    authorizationUrl(p: {
        state: string;
        nonce: string;
        challenge: string;
        prompt?: string | undefined;
    }): Promise<string>;
    callbackIssOk(iss: string | null): Promise<boolean>;
    private token;
    /** A verified id_token's identity (`nonce`: what this sign-in sent; undefined for a refresh's, which has none). */
    verifyIdToken(idToken: string, nonce: string | undefined): Promise<IdpIdentity>;
    exchange(code: string, verifier: string, nonce: string): Promise<{
        identity: IdpIdentity;
        refreshToken: string | null;
    }>;
    refresh(refreshToken: string, expectedSub: string): Promise<RefreshOutcome>;
}
/** The identity in verified id_token claims: `sub`, the shown name, and (for the allow-list) email / hd. */
export declare function identityOf(p: JWTPayload & Record<string, unknown>, clientId: string, nonce: string | undefined): IdpIdentity;
/** Text from outside shown to people: no control or bidi-override characters, trimmed to `max` characters. */
export declare function cleanText(s: string, max: number): string;
export {};
