// Apple's signed things an account server can take (docs/ACCOUNT-LIB.md「登录」「订阅」): a Sign in with Apple identity
// token from an app's native sign-in (an RS256 JWT under Apple's published keys), revoking that grant when the account
// is deleted (Apple's rule for apps that offer the sign-in), and a StoreKit 2 transaction (an ES256 JWS whose x5c
// chain ends at Apple Root CA - G3). Node's crypto only.
import { createHash, createPrivateKey, createPublicKey, sign, verify, X509Certificate } from "node:crypto";
export const APPLE_ISSUER = "https://appleid.apple.com";
export const APPLE_KEYS_URL = "https://appleid.apple.com/auth/keys";
export const APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token";
export const APPLE_REVOKE_URL = "https://appleid.apple.com/auth/revoke";
/** SHA-256 of Apple Root CA - G3's DER (https://www.apple.com/certificateauthority/), the StoreKit chains' root. */
export const APPLE_ROOT_G3_SHA256 = "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179";
/** The extensions Apple's own libraries look for: the App Store receipt signer (leaf) and Apple WWDR CA G6
 *  (intermediate), as DER-encoded OIDs 1.2.840.113635.100.6.11.1 and 1.2.840.113635.100.6.2.1. */
const LEAF_OID = Buffer.from("060a2a864886f76364060b01", "hex");
const INTERMEDIATE_OID = Buffer.from("060a2a864886f76364060201", "hex");
/** Apple's keys, fetched at most once a day (and again, at most once a minute, for a key id not held yet). */
export function cachedAppleKeys(fetchKeys = fetchAppleKeys, now = Date.now) {
    let keys = [];
    let at = -Infinity;
    return async (kid) => {
        const t = now();
        const stale = t - at > 24 * 3600_000;
        const unknown = !keys.some((k) => k.kid === kid) && t - at > 60_000;
        if (stale || unknown) {
            try {
                keys = await fetchKeys();
                at = t;
            }
            catch {
                // Apple unreachable: the keys held (if any) go on
            }
        }
        return keys.find((k) => k.kid === kid);
    };
}
async function fetchAppleKeys() {
    const r = await fetch(APPLE_KEYS_URL, { signal: AbortSignal.timeout(5000), redirect: "error" });
    if (!r.ok)
        throw new Error(`apple keys: ${r.status}`);
    const body = (await r.json());
    return Array.isArray(body.keys) ? body.keys.slice(0, 32) : [];
}
/**
 * The identity token's subject (and email, if any), when it is Apple's (RS256 under a key of theirs), for one of
 * `audiences` (the apps' bundle ids), not expired, and carries SHA-256(`nonce`) (hex, as iOS apps send it) or the nonce
 * itself. null otherwise.
 */
export async function verifyIdentityToken(token, nonce, audiences, key, now = Date.now()) {
    const parts = token.split(".");
    if (parts.length !== 3 || !nonce)
        return null;
    const header = json(parts[0]);
    const claims = json(parts[1]);
    if (header?.alg !== "RS256" || typeof header.kid !== "string" || !claims)
        return null;
    const jwk = await key(header.kid);
    if (!jwk)
        return null;
    let ok = false;
    try {
        ok = verify("RSA-SHA256", Buffer.from(`${parts[0]}.${parts[1]}`), createPublicKey({ key: jwk, format: "jwk" }), Buffer.from(parts[2], "base64url"));
    }
    catch {
        return null;
    }
    if (!ok)
        return null;
    if (claims.iss !== APPLE_ISSUER || typeof claims.sub !== "string" || !claims.sub || claims.sub.length > 255)
        return null;
    const aud = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
    if (!aud.some((a) => typeof a === "string" && audiences.includes(a)))
        return null;
    if (typeof claims.exp !== "number" || claims.exp * 1000 < now)
        return null;
    const hashed = createHash("sha256").update(nonce).digest("hex");
    if (claims.nonce !== hashed && claims.nonce !== nonce)
        return null;
    // (Apple writes email_verified as a boolean or as the string "true")
    const verified = claims.email_verified === true || claims.email_verified === "true";
    return { sub: claims.sub, ...(typeof claims.email === "string" ? { email: claims.email, email_verified: verified } : {}) };
}
/** The client secret Apple's token endpoints want: an ES256 JWT by the Sign in with Apple key, iss = team, sub = the
 *  app, aud = Apple, good for 5 minutes. */
export function clientSecret(c, now = Date.now()) {
    const b64u = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
    const iat = Math.floor(now / 1000);
    const input = `${b64u({ alg: "ES256", kid: c.keyId })}.${b64u({ iss: c.teamId, iat, exp: iat + 300, aud: APPLE_ISSUER, sub: c.clientId })}`;
    const sig = sign("SHA256", Buffer.from(input), { key: createPrivateKey(c.privateKey), dsaEncoding: "ieee-p1363" });
    return `${input}.${sig.toString("base64url")}`;
}
/**
 * Revokes the Sign in with Apple grant behind a fresh authorization code (the app asks for one when the account is
 * deleted, as Apple requires): the code → a refresh token (`/auth/token`) → `/auth/revoke`. `sub`: the account's Apple
 * id; a code of somebody else's revokes nothing. Whether Apple took it.
 */
export async function revokeAppleGrant(c, code, sub, post = fetch, now = Date.now()) {
    const form = (o) => ({
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams(o).toString(),
        signal: AbortSignal.timeout(5000),
        redirect: "error",
    });
    const secret = clientSecret(c, now);
    const r = await post(APPLE_TOKEN_URL, form({ client_id: c.clientId, client_secret: secret, code, grant_type: "authorization_code" }));
    if (!r.ok)
        return false;
    const tokens = (await r.json());
    const claims = typeof tokens.id_token === "string" ? json(tokens.id_token.split(".")[1] ?? "") : null;
    if (claims?.sub !== sub)
        return false;
    const token = tokens.refresh_token ?? tokens.access_token;
    if (!token)
        return false;
    const hint = tokens.refresh_token ? "refresh_token" : "access_token";
    const v = await post(APPLE_REVOKE_URL, form({ client_id: c.clientId, client_secret: secret, token, token_type_hint: hint }));
    return v.ok;
}
/**
 * The transaction, when its JWS is Apple's: ES256 by the leaf of an x5c chain leaf → intermediate → Apple Root CA G3,
 * each signed by the next, the leaf and intermediate carrying Apple's extensions, all valid at `now`. null otherwise.
 * `rootSha256`: another root (tests).
 */
export function verifyStoreKit(jws, now = Date.now(), rootSha256 = APPLE_ROOT_G3_SHA256) {
    const parts = jws.split(".");
    if (parts.length !== 3)
        return null;
    const header = json(parts[0]);
    if (header?.alg !== "ES256" || !Array.isArray(header.x5c) || header.x5c.length !== 3)
        return null;
    let chain;
    try {
        chain = header.x5c.map((c) => new X509Certificate(Buffer.from(String(c), "base64")));
    }
    catch {
        return null;
    }
    const [leaf, intermediate, root] = chain;
    if (createHash("sha256").update(root.raw).digest("hex") !== rootSha256)
        return null;
    if (!intermediate.verify(root.publicKey) || !leaf.verify(intermediate.publicKey))
        return null;
    if (!leaf.raw.includes(LEAF_OID) || !intermediate.raw.includes(INTERMEDIATE_OID))
        return null;
    for (const c of chain) {
        if (Date.parse(c.validFrom) > now || Date.parse(c.validTo) < now)
            return null;
    }
    try {
        const ok = verify("SHA256", Buffer.from(`${parts[0]}.${parts[1]}`), { key: leaf.publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(parts[2], "base64url"));
        if (!ok)
            return null;
    }
    catch {
        return null;
    }
    const p = json(parts[1]);
    if (!p || typeof p.bundleId !== "string" || typeof p.productId !== "string" || typeof p.originalTransactionId !== "string")
        return null;
    return {
        bundleId: p.bundleId,
        productId: p.productId,
        originalTransactionId: p.originalTransactionId,
        ...(typeof p.expiresDate === "number" ? { expiresDate: p.expiresDate } : {}),
        ...(typeof p.revocationDate === "number" ? { revocationDate: p.revocationDate } : {}),
        environment: typeof p.environment === "string" ? p.environment : "Production",
        ...(typeof p.inAppOwnershipType === "string" ? { ownership: p.inAppOwnershipType } : {}),
    };
}
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function json(part) {
    try {
        const v = JSON.parse(Buffer.from(part, "base64url").toString("utf8"));
        return v && typeof v === "object" && !Array.isArray(v) ? v : null;
    }
    catch {
        return null;
    }
}
