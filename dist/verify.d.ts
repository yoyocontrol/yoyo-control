/** What the browser hands to the host's signaling path (docs/LINK.md「WebRTC」). */
export interface RtcOffer {
    v: 1;
    /** The non-trickle offer SDP (every gathered candidate in it). */
    offer: string;
    device: {
        id: string;
        name: string;
    };
    /** The key of this connection's next ICE restart (`newRestartSecret().key`): a server that takes restarts keeps it. */
    rk?: string;
    /** An ICE restart: the secret whose key an earlier offer of this connection gave (docs/LINK.md「WebRTC」「换网络」). */
    restart?: string;
}
/** The server's identity binding (`/status.link`'s `{id, key, sig}`): `key` = its P-256 identity key, base64. */
export interface RtcBinding {
    id: string;
    key: string;
    sig: string;
}
/** What the signaling path answers. */
export interface RtcAnswer {
    v: 1;
    answer: string;
    /** `sha256:<hex>` of the server's DTLS certificate. */
    fingerprint: string;
    binding: RtcBinding;
    /** base64 `r‖s`: ECDSA-P256-SHA256 by the identity key over `rtcSignedText(offer, fingerprint)`. */
    sig: string;
    /** The server takes ICE restarts of this connection (offers with `restart`); absent from older servers. */
    restarts?: boolean;
}
/**
 * A secret for a later ICE restart and the key it is known by: `key` (lowercase hex SHA-256 of the secret's UTF-8)
 * goes with an offer, the secret only with the restart itself, so whoever carries the offer can't restart the
 * connection from it.
 */
export declare function newRestartSecret(): Promise<{
    secret: string;
    key: string;
}>;
/** A SHA-256 fingerprint in any of its spellings (`sha256:ab…`, `AB:CD:…`, upper or lower case, padded) as bare lower-case hex. */
export declare function normalizeFingerprint(fp: string): string;
/** Every `a=fingerprint:sha-256 …` of an SDP, as bare lower-case hex. */
export declare function sdpFingerprints(sdp: string): string[];
/** SHA-256 of `bytes` as lower-case hex. */
export declare function sha256Hex(bytes: Uint8Array<ArrayBuffer> | string): Promise<string>;
/** The text the identity key signs: `"yoyocontrol-rtc-v1:" + sha256(offer SDP, hex) + ":" + fingerprint`. */
export declare function rtcSignedText(offerSdp: string, fingerprint: string): Promise<string>;
/** The answer object of a signaling reply (an object, or its JSON text); `protocol` when it isn't one. */
export declare function parseAnswer(reply: unknown): RtcAnswer;
/**
 * Checks that `answer` comes from the computer whose identity is `pinnedFingerprint` (docs/LINK.md「WebRTC」), for the
 * offer we sent: `SHA-256(binding.key)` is the pinned fingerprint, `sig` verifies with that key over
 * `rtcSignedText(offerSdp, answer.fingerprint)`, and the answer SDP's DTLS fingerprint is `answer.fingerprint`. Any
 * mismatch throws `LinkError("verification")`: a hard failure, never retried on the same answer.
 */
export declare function verifyAnswer(offerSdp: string, answer: RtcAnswer, pinnedFingerprint: string): Promise<void>;
