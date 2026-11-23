// What the account server signs for computers (docs/ACCOUNT-LIB.md): tickets, service tokens and the revocation list,
// all compact JWS with EdDSA and the server's current key, each with its own `typ` (the ring's namespace). What a
// computer checks of them is @yoyocontrol/account (one implementation, re-exported here: this server's tests run it
// against what is signed here).
import { randomBytes } from "node:crypto";
import { SignJWT } from "jose";
import { SERVICE_TTL_S, TICKET_TTL_S } from "@yoyocontrol/account";
export * from "@yoyocontrol/account";
/** `sessionExpiresAt` (ms): when the device's session here ends — the computer's token for this ticket ends then too. */
export async function signTicket(ring, p) {
    const iat = Math.floor((p.now ?? Date.now()) / 1000);
    const { kid, key } = ring.current;
    return new SignJWT({ dev: p.device, ...(p.accountName ? { name: p.accountName } : {}), ...(p.sessionExpiresAt ? { sx: Math.floor(p.sessionExpiresAt / 1000) } : {}) })
        .setProtectedHeader({ alg: "EdDSA", kid, typ: ring.wire.ticketTyp })
        .setIssuer(p.issuer)
        .setSubject(p.account)
        .setAudience(p.linkId)
        .setIssuedAt(iat)
        .setExpirationTime(iat + TICKET_TTL_S)
        .setJti(randomBytes(16).toString("base64url"))
        .sign(key);
}
/** A service token: computer `linkId` of `account` may use `service` (the whole `aud`: `wire.service(name)`) for a day. */
export async function signServiceToken(ring, p) {
    const iat = Math.floor((p.now ?? Date.now()) / 1000);
    const { kid, key } = ring.current;
    const token = await new SignJWT({ cmp: p.linkId })
        .setProtectedHeader({ alg: "EdDSA", kid, typ: ring.wire.serviceTyp })
        .setIssuer(p.issuer)
        .setSubject(p.account)
        .setAudience(p.service)
        .setIssuedAt(iat)
        .setExpirationTime(iat + SERVICE_TTL_S)
        .sign(key);
    return { token, expiresAt: (iat + SERVICE_TTL_S) * 1000 };
}
export async function signRevocationList(ring, issuer, s, nowMs = Date.now()) {
    const { kid, key } = ring.current;
    return new SignJWT({ ver: s.version, devices: s.devices, computers: s.computers, disabled: s.disabled })
        .setProtectedHeader({ alg: "EdDSA", kid, typ: ring.wire.revocationsTyp })
        .setIssuer(issuer)
        .setSubject(s.account)
        .setIssuedAt(Math.floor(nowMs / 1000))
        .sign(key);
}
