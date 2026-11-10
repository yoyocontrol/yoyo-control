/** Why a pairing link can't be used. */
export class PairingLinkError extends Error {
    constructor(message) {
        super(message);
        this.name = "PairingLinkError";
    }
}
const FINGERPRINT = /^sha256:[0-9a-f]{64}$/;
/** `sha256:<hex>` in its one spelling (lowercase, no colons inside the hex); null when it isn't one. */
function fingerprintOf(raw) {
    const s = raw.trim().toLowerCase();
    const hex = s.startsWith("sha256:") ? s.slice(7).replace(/:/g, "") : s.replace(/:/g, "");
    const fp = `sha256:${hex}`;
    return FINGERPRINT.test(fp) ? fp : null;
}
/**
 * Reads a pairing link: the whole URL, or just its fragment (with or without `#`). Throws a `PairingLinkError` when a
 * field is missing or malformed, or the version isn't 1.
 */
export function parsePairingLink(input) {
    let fragment = typeof input === "string" ? input.trim() : input.hash;
    if (typeof input === "string" && /^[a-z][a-z0-9+.-]*:\/\//i.test(fragment)) {
        try {
            fragment = new URL(fragment).hash;
        }
        catch {
            throw new PairingLinkError("not a pairing link");
        }
    }
    const params = new URLSearchParams(fragment.startsWith("#") ? fragment.slice(1) : fragment);
    if (params.get("v") !== "1")
        throw new PairingLinkError(params.has("v") ? "this pairing link is from a newer version" : "not a pairing link");
    const serverId = params.get("id")?.trim() ?? "";
    const code = params.get("c")?.trim() ?? "";
    const fingerprint = fingerprintOf(params.get("fp") ?? "");
    if (!serverId || !code || !fingerprint)
        throw new PairingLinkError("the pairing link is incomplete");
    const name = (params.get("n") ?? "").replace(/[\u0000-\u001f\u007f]/g, " ").trim().slice(0, 64) || "Mac";
    return { serverId, name, fingerprint, code };
}
