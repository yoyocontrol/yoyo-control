import { type AppleKeys, type StoreTransaction } from "../apple.js";
export declare class TestApple {
    readonly kid: string;
    private readonly key;
    private readonly jwk;
    private readonly transactions;
    constructor();
    /** What the account server checks tokens with (`ServiceDeps.appleKeys`). */
    readonly keys: AppleKeys;
    /** An identity token for `sub` as the app would get it with `nonce` (raw: the token carries its SHA-256). */
    token(o: {
        sub: string;
        nonce: string;
        aud: string;
        email?: string;
        exp?: number;
        iss?: string;
    }): string;
    /** A StoreKit transaction's stand-in JWS: `storeKit` takes it (and nothing else). */
    transaction(t: StoreTransaction): string;
    /** `ServiceDeps.storeKit`. */
    readonly storeKit: (jws: string) => StoreTransaction | null;
}
