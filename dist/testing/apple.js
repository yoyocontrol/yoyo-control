// A stand-in for Apple (tests; `@yoyocontrol/account-server/testing`): identity tokens as Sign in with Apple signs
// them (RS256 under a key of "Apple's", iss appleid.apple.com, the nonce's SHA-256), the keys to check them with, and
// a StoreKit check that takes the transactions it made.
import { createHash, generateKeyPairSync, randomBytes, sign } from "node:crypto";
import { APPLE_ISSUER } from "../apple.js";
export class TestApple {
    kid = `test-${randomBytes(4).toString("hex")}`;
    key;
    jwk;
    transactions = new Map();
    constructor() {
        const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
        this.key = privateKey;
        this.jwk = { ...publicKey.export({ format: "jwk" }), kid: this.kid, alg: "RS256", use: "sig" };
    }
    /** What the account server checks tokens with (`ServiceDeps.appleKeys`). */
    keys = async (kid) => (kid === this.kid ? this.jwk : undefined);
    /** An identity token for `sub` as the app would get it with `nonce` (raw: the token carries its SHA-256). */
    token(o) {
        const b64u = (v) => Buffer.from(JSON.stringify(v)).toString("base64url");
        const now = Math.floor(Date.now() / 1000);
        const claims = {
            iss: o.iss ?? APPLE_ISSUER, aud: o.aud, sub: o.sub, iat: now, exp: o.exp ?? now + 600,
            nonce: createHash("sha256").update(o.nonce).digest("hex"),
            ...(o.email ? { email: o.email, email_verified: "true" } : {}),
        };
        const input = `${b64u({ alg: "RS256", kid: this.kid })}.${b64u(claims)}`;
        return `${input}.${sign("RSA-SHA256", Buffer.from(input), this.key).toString("base64url")}`;
    }
    /** A StoreKit transaction's stand-in JWS: `storeKit` takes it (and nothing else). */
    transaction(t) {
        const jws = `test.${randomBytes(12).toString("base64url")}.jws`;
        this.transactions.set(jws, t);
        return jws;
    }
    /** `ServiceDeps.storeKit`. */
    storeKit = (jws) => this.transactions.get(jws) ?? null;
}
