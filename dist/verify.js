import { LinkError } from "./errors.js";
const encoder = new TextEncoder();
function hex(bytes) {
    const b = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
    let s = "";
    for (const x of b)
        s += x.toString(16).padStart(2, "0");
    return s;
}
function base64(s) {
    const bin = atob(s.trim());
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++)
        out[i] = bin.charCodeAt(i);
    return out;
}
function subtle() {
    const s = globalThis.crypto?.subtle;
    if (!s)
        throw new LinkError("unsupported", "WebCrypto is not available (a secure context is needed)");
    return s;
}
/**
 * A secret for a later ICE restart and the key it is known by: `key` (lowercase hex SHA-256 of the secret's UTF-8)
 * goes with an offer, the secret only with the restart itself, so whoever carries the offer can't restart the
 * connection from it.
 */
export async function newRestartSecret() {
    const b = globalThis.crypto.getRandomValues(new Uint8Array(18));
    const secret = btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_");
    return { secret, key: hex(await subtle().digest("SHA-256", encoder.encode(secret))) };
}
/** A SHA-256 fingerprint in any of its spellings (`sha256:ab…`, `AB:CD:…`, upper or lower case, padded) as bare lower-case hex. */
export function normalizeFingerprint(fp) {
    return fp.trim().toLowerCase().replace(/^sha-?256[: ]/, "").replace(/[:\s]/g, "");
}
/** Every `a=fingerprint:sha-256 …` of an SDP, as bare lower-case hex. */
export function sdpFingerprints(sdp) {
    const out = [];
    for (const line of sdp.split(/\r?\n/)) {
        const m = /^a=fingerprint:sha-256\s+([0-9A-Fa-f:]+)\s*$/.exec(line.trim());
        if (m)
            out.push(normalizeFingerprint(m[1]));
    }
    return out;
}
/** SHA-256 of `bytes` as lower-case hex. */
export async function sha256Hex(bytes) {
    return hex(await subtle().digest("SHA-256", typeof bytes === "string" ? encoder.encode(bytes) : bytes));
}
/** The text the identity key signs: `"yoyocontrol-rtc-v1:" + sha256(offer SDP, hex) + ":" + fingerprint`. */
export async function rtcSignedText(offerSdp, fingerprint) {
    return `yoyocontrol-rtc-v1:${await sha256Hex(offerSdp)}:${fingerprint}`;
}
/** The answer object of a signaling reply (an object, or its JSON text); `protocol` when it isn't one. */
export function parseAnswer(reply) {
    let v = reply;
    if (typeof v === "string") {
        try {
            v = JSON.parse(v);
        }
        catch {
            throw new LinkError("protocol", "the signaling answer is not JSON");
        }
    }
    const a = v;
    const b = a?.binding;
    if (!a || typeof a !== "object" || typeof a.answer !== "string" || typeof a.fingerprint !== "string" || typeof a.sig !== "string" || !b || typeof b.key !== "string" || typeof b.sig !== "string" || typeof b.id !== "string") {
        throw new LinkError("protocol", "the signaling answer lacks answer / fingerprint / binding / sig");
    }
    return a;
}
/**
 * Checks that `answer` comes from the computer whose identity is `pinnedFingerprint` (docs/LINK.md「WebRTC」), for the
 * offer we sent: `SHA-256(binding.key)` is the pinned fingerprint, `sig` verifies with that key over
 * `rtcSignedText(offerSdp, answer.fingerprint)`, and the answer SDP's DTLS fingerprint is `answer.fingerprint`. Any
 * mismatch throws `LinkError("verification")`: a hard failure, never retried on the same answer.
 */
export async function verifyAnswer(offerSdp, answer, pinnedFingerprint) {
    const fail = (why) => {
        throw new LinkError("verification", why);
    };
    let key, sig;
    try {
        key = base64(answer.binding.key);
        sig = base64(answer.sig);
    }
    catch {
        return fail("the answer's key or signature is not base64");
    }
    if (key.length !== 65 || key[0] !== 0x04)
        fail("the identity key is not an uncompressed P-256 point");
    if ((await sha256Hex(key)) !== normalizeFingerprint(pinnedFingerprint))
        fail("the identity key is not the pinned computer's");
    if (sig.length !== 64)
        fail("the signature is not 64 bytes (r‖s)");
    const s = subtle();
    let ok = false;
    try {
        const k = await s.importKey("raw", key, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
        ok = await s.verify({ name: "ECDSA", hash: "SHA-256" }, k, sig, encoder.encode(await rtcSignedText(offerSdp, answer.fingerprint)));
    }
    catch {
        ok = false;
    }
    if (!ok)
        fail("the answer's signature does not verify");
    const want = normalizeFingerprint(answer.fingerprint);
    if (!/^[0-9a-f]{64}$/.test(want))
        fail("the DTLS fingerprint is not a SHA-256 one");
    const inSdp = sdpFingerprints(answer.answer);
    if (inSdp.length === 0 || inSdp.some((f) => f !== want))
        fail("the answer SDP's DTLS fingerprint is not the signed one");
}
