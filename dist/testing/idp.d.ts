import { type Server } from "node:http";
export interface TestUser {
    sub: string;
    name?: string;
    preferred_username?: string;
    email?: string;
    email_verified?: boolean;
    hd?: string;
}
export type TokenMode = "ok" | "5xx" | "429" | "drop" | "invalid_client" | "html";
export declare class TestIdp {
    server: Server;
    issuer: string;
    /** What `iss` the id_tokens carry (default: the issuer). */
    issClaim: string | null;
    /** What `issuer` the discovery document names (default: the issuer). */
    discoveryIssuer: string | null;
    user: TestUser;
    clientId: string;
    clientSecret: string;
    /** Only `client_secret_post` advertised (and taken). */
    postOnly: boolean;
    scopes: string[];
    issParam: boolean;
    giveRefresh: boolean;
    rotate: boolean;
    mode: TokenMode;
    /** The next refresh answers after this long (a race test holds two in flight). */
    refreshDelayMs: number;
    /** Every /authorize request's parameters. */
    authorizeRequests: URLSearchParams[];
    refreshCalls: number;
    /** What /authorize answers instead of a code. */
    authorizeError: string | null;
    nonceOverride: string | null;
    audOverride: string | string[] | null;
    azp: string | null;
    idTokenExpiresIn: number;
    private key;
    private kid;
    private codes;
    /** refresh token → its family and whether it is still the live one */
    private refresh;
    private deadFamilies;
    start(): Promise<this>;
    stop(): Promise<void>;
    /** Every refresh token of `sub` dead (the IdP's "sign out everywhere", or the user disabled). */
    revokeUser(sub: string): void;
    liveRefreshTokens(): string[];
    private idToken;
    private newRefresh;
    private json;
    private handle;
}
