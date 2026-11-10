/** What `/status` says as `app` (only this answer counts as Yoyo Control). */
export declare const APP_ID = "YoyoControl";
/** The app's name, as people see it. */
export declare const APP_NAME = "Yoyo Control";
/** Its bundle id (TCC grants and installs are keyed by it). */
export declare const BUNDLE_ID = "ca.sarria.yoyocontrol.mac";
/** The local API versions this package speaks (`/status` `api`; +1 there = an incompatible change). */
export declare const API: {
    readonly min: 1;
    readonly max: 1;
};
/** How long an app this package opened may take to answer on its socket. */
export declare const APP_LAUNCH_TIMEOUT_MS = 10000;
/** How long the socket may take to answer one `/status` probe. */
export declare const PROBE_TIMEOUT_MS = 2000;
/** A child service's "start me again" exit (EX_TEMPFAIL): respawned on the next use without the failure backoff. */
export declare const RESTART_EXIT = 75;
/** A child service without Screen Recording is restarted this long after it started (to see a new grant). */
export declare const REFRESH_GRANT_MS = 15000;
/** The running app's socket for this macOS account. */
export declare function appSocketPath(home?: string): string;
/** Where an installed Yoyo Control.app is looked for: the Applications folders (not build folders). */
export declare function appCandidates(home?: string): string[];
/** The first installed Yoyo Control.app, or null. */
export declare function findApp(candidates?: readonly string[], exists?: (p: string) => boolean): string | null;
/** What an installed app bundle looks like now (its Info.plist's mtime and size); null when it isn't there. */
export declare function appStamp(path: string): string | null;
/** Opens the app in the background without activating it (`open -g -j`); resolves once `open` returns. */
export declare function openApp(path: string): Promise<void>;
/** The child service to run: `explicit` when set (even if missing), else the first of `candidates` that exists. */
export declare function resolveChildPath(explicit: string | null | undefined, candidates?: readonly string[], exists?: (p: string) => boolean): string | null;
/**
 * How a remote server's endpoint is asked for: `known` — the one in hand (started if there is none); `restart` — it
 * stopped answering: start it again with the same token; `rekey` — it refused the token, or something else answered:
 * start it with a new token.
 */
export type RemoteMode = "known" | "restart" | "rekey";
/**
 * What a failed request to a remote server says about it: refused / unreachable / reset → `restart`; 401 → `rekey`;
 * no answer in time, or anything else → `busy` (it may just be slow: never a reason to restart it).
 */
export declare function remoteFailure(err: unknown): RemoteMode | "busy";
