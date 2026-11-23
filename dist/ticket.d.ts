import { type RevocationState, type TicketDevice } from "@yoyocontrol/account";
import type { KeyRing } from "./keys.js";
export * from "@yoyocontrol/account";
/** `sessionExpiresAt` (ms): when the device's session here ends — the computer's token for this ticket ends then too. */
export declare function signTicket(ring: KeyRing, p: {
    issuer: string;
    account: string;
    accountName?: string | null;
    linkId: string;
    device: TicketDevice;
    sessionExpiresAt?: number;
    now?: number;
}): Promise<string>;
/** A service token: computer `linkId` of `account` may use `service` (the whole `aud`: `wire.service(name)`) for a day. */
export declare function signServiceToken(ring: KeyRing, p: {
    issuer: string;
    account: string;
    linkId: string;
    service: string;
    now?: number;
}): Promise<{
    token: string;
    expiresAt: number;
}>;
export declare function signRevocationList(ring: KeyRing, issuer: string, s: RevocationState, nowMs?: number): Promise<string>;
