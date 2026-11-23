import { type KeyObject } from "node:crypto";
import { type PublicJwk, type Wire } from "@yoyocontrol/account";
export { publicKeyOf, verifyKeyChain, type PublicJwk } from "@yoyocontrol/account";
export declare class KeyRing {
    private readonly file;
    readonly wire: Wire;
    private keys;
    private objects;
    private constructor();
    /** The ring in `file` (made, with one key, when there is none); `null` = in memory only (tests). `wire`: the names
     *  it signs under (the server's namespace). */
    static load(file: string | null, wire?: Wire): KeyRing;
    private static fresh;
    private save;
    /** The key new things are signed with: the newest. */
    get current(): {
        kid: string;
        key: KeyObject;
    };
    private objectOf;
    /** The public keys, oldest first (what /.well-known/jwks.json serves and a joining computer pins). */
    jwks(): PublicJwk[];
    /** A new current key, endorsed by the one before it. The old keys stay (computers that pinned them still verify,
     *  and they still verify what was signed before); `retire` drops the oldest ones but `keep`. */
    rotate(): Promise<PublicJwk>;
    retire(keep: number): number;
}
