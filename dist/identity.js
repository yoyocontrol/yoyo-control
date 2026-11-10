// A server's identity: an EC P-256 key kept as a file in a directory of the caller's (0700; the file 0600) — the same
// file and the same pin as Yoyo Control's Mac (docs/REMOTE.md「身份」). Phones and browsers pin it by `keyFingerprint`;
// it signs the uu Link binding (docs/LINK.md「身份与信任」) and the sign-in at the signaling server.
//
// - `tls-key.der` (the name is from when it served TLS): the private key as X9.63 bytes (04 ‖ X ‖ Y ‖ D, 97 bytes).
//   A missing or unreadable key means a new key (every phone pairs again).
import { createHash, createPrivateKey, createPublicKey, generateKeyPairSync } from "node:crypto";
import { chmodSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
export const KEY_FILE = "tls-key.der";
/** The identity in `dir` (made when missing; the directory is created 0700). */
export function loadOrCreateIdentity(dir) {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    try {
        chmodSync(dir, 0o700);
    }
    catch {
        // not ours to change: the file is 0600 anyway
    }
    const keyPath = join(dir, KEY_FILE);
    const raw = readOrNull(keyPath);
    let key = null;
    if (raw) {
        try {
            key = keyFromX963(raw);
        }
        catch {
            key = null;
        }
    }
    if (!key) {
        key = generateKeyPairSync("ec", { namedCurve: "P-256" }).privateKey;
        writePrivate(keyPath, x963Private(key));
    }
    const publicKey = x963Public(key);
    return { key, publicKey, keyFingerprint: fingerprint(publicKey) };
}
/** `"sha256:"` + lowercase hex of SHA-256 over `bytes`. */
export function fingerprint(bytes) {
    return `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
}
/** A P-256 private key from its X9.63 bytes (04 ‖ X ‖ Y ‖ D). */
export function keyFromX963(raw) {
    const b = Buffer.from(raw);
    if (b.length !== 97 || b[0] !== 4)
        throw new Error("not an X9.63 P-256 private key");
    const u = (x) => x.toString("base64url");
    return createPrivateKey({ key: { kty: "EC", crv: "P-256", x: u(b.subarray(1, 33)), y: u(b.subarray(33, 65)), d: u(b.subarray(65, 97)) }, format: "jwk" });
}
/** The private key's X9.63 bytes (04 ‖ X ‖ Y ‖ D). */
export function x963Private(key) {
    const j = key.export({ format: "jwk" });
    return Buffer.concat([Buffer.from([4]), pad32(j.x), pad32(j.y), pad32(j.d)]);
}
/** The public key's X9.63 bytes (04 ‖ X ‖ Y) of a private or public P-256 key. */
export function x963Public(key) {
    const pub = key.type === "private" ? createPublicKey(key) : key;
    const j = pub.export({ format: "jwk" });
    if (j.crv !== "P-256")
        throw new Error("not a P-256 key");
    return Buffer.concat([Buffer.from([4]), pad32(j.x), pad32(j.y)]);
}
function pad32(b64url) {
    const b = Buffer.from(b64url, "base64url");
    return b.length >= 32 ? b.subarray(b.length - 32) : Buffer.concat([Buffer.alloc(32 - b.length), b]);
}
function readOrNull(path) {
    try {
        return readFileSync(path);
    }
    catch {
        return null;
    }
}
/** Writes `data` as 0600 through a temporary file (a reader never sees half of it). */
export function writePrivate(path, data) {
    const tmp = `${path}.tmp`;
    writeFileSync(tmp, data, { mode: 0o600 });
    chmodSync(tmp, 0o600);
    renameSync(tmp, path);
}
