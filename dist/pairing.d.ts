/**
 * The web pairing link a Mac shows (docs/REMOTE.md「配对」):
 * `<web app>/pair#v=1&id=<serverId>&n=<name>&fp=<sha256:hex>&c=<code>`. Everything is in the
 * fragment, which a browser never sends to a server; nothing here sends it anywhere either.
 */
export interface PairingLink {
    /** The Mac's server id (`id`). */
    serverId: string;
    /** The Mac's name as it was when the code was shown (`n`). */
    name: string;
    /** The Mac's identity fingerprint, `sha256:` + 64 lowercase hex (`fp`): the link's answers must be signed by it. */
    fingerprint: string;
    /** The one-time pairing code (`c`). */
    code: string;
}
/** Why a pairing link can't be used. */
export declare class PairingLinkError extends Error {
    constructor(message: string);
}
/**
 * Reads a pairing link: the whole URL, or just its fragment (with or without `#`). Throws a `PairingLinkError` when a
 * field is missing or malformed, or the version isn't 1.
 */
export declare function parsePairingLink(input: string | URL): PairingLink;
