import type { Idp } from "./oidc.js";
import type { Session, Store } from "./store.js";
export declare const RECHECK_EVERY_MS = 3600000;
/** How long one check may hold its session's lease (the IdP call has a 10 s timeout). */
export declare const LEASE_MS = 60000;
export type CheckResult = "ok" | "ended" | "retry" | "unchecked" | "busy" | "gone";
export declare class Rechecker {
    private readonly store;
    private readonly idp;
    private readonly o;
    private inflight;
    private timer;
    private running;
    constructor(store: Store, idp: Idp, o?: {
        now?: () => number;
        log?: (line: string) => void;
        /** A session ended by `invalid_grant` (the service revokes its device on the computers and pushes the notice). */
        onEnded?: (s: Session) => Promise<void> | void;
    });
    private get now();
    private log;
    /** Checks one session now (coalesced with a check of it already under way). */
    check(sessionId: string): Promise<CheckResult>;
    private checkOnce;
    /** The sessions due (not checked for an hour), one after another. */
    runDue(limit?: number): Promise<Record<CheckResult, number>>;
    /** Every five minutes, the sessions that are due. */
    start(everyMs?: number): void;
    stop(): void;
}
