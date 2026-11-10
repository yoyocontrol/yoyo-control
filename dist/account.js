// Accounts (docs/ACCOUNT.md): a paired phone puts this server in its account's directory with a statement the server
// signs with its identity key; the account service checks it (and phones check it again) against the fingerprint.
import { sign } from "node:crypto";
/** An account id as the account service makes them: 32 lowercase hex digits. */
export function validAccount(id) {
    return typeof id === "string" && /^[0-9a-f]{32}$/.test(id);
}
/** `{ account, fp, key, sig, serverId, name, platform }`, `sig` (raw r ‖ s) over "yoyocontrol-account-v1:" + account + ":" + fp. */
export function accountStatement(identity, account, o) {
    const fp = identity.keyFingerprint.replace(/^sha256:/, "");
    const sig = sign("sha256", Buffer.from(`yoyocontrol-account-v1:${account}:${fp}`, "utf8"), { key: identity.key, dsaEncoding: "ieee-p1363" });
    return { account, fp, key: identity.publicKey.toString("base64"), sig: sig.toString("base64"), serverId: o.serverId, name: o.name, platform: o.platform };
}
