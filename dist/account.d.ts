import type { Identity } from "./identity.js";
/** An account id as the account service makes them: 32 lowercase hex digits. */
export declare function validAccount(id: unknown): id is string;
/** `{ account, fp, key, sig, serverId, name, platform }`, `sig` (raw r ‖ s) over "yoyocontrol-account-v1:" + account + ":" + fp. */
export declare function accountStatement(identity: Pick<Identity, "key" | "publicKey" | "keyFingerprint">, account: string, o: {
    serverId: string;
    name: string;
    platform: string;
}): {
    account: string;
    fp: string;
    key: string;
    sig: string;
    serverId: string;
    name: string;
    platform: string;
};
