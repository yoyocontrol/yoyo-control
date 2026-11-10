// Finding Yoyo Control on this Mac (docs/LOCAL-API.md「找到它」): its fixed socket, the installed app, opening it in
// the background, and noticing when the installed bundle was replaced.
import { execFile } from "node:child_process";
import { existsSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** What `/status` says as `app` (only this answer counts as Yoyo Control). */
export const APP_ID = "YoyoControl";
/** The app's name, as people see it. */
export const APP_NAME = "Yoyo Control";
/** Its bundle id (TCC grants and installs are keyed by it). */
export const BUNDLE_ID = "ca.sarria.yoyocontrol.mac";
/** The local API versions this package speaks (`/status` `api`; +1 there = an incompatible change). */
export const API = { min: 1, max: 1 } as const;
/** How long an app this package opened may take to answer on its socket. */
export const APP_LAUNCH_TIMEOUT_MS = 10_000;
/** How long the socket may take to answer one `/status` probe. */
export const PROBE_TIMEOUT_MS = 2000;
/** A child service's "start me again" exit (EX_TEMPFAIL): respawned on the next use without the failure backoff. */
export const RESTART_EXIT = 75;
/** A child service without Screen Recording is restarted this long after it started (to see a new grant). */
export const REFRESH_GRANT_MS = 15_000;

/** The running app's socket for this macOS account. */
export function appSocketPath(home: string = homedir()): string {
  return join(home, "Library", "Application Support", "YoyoControl", "screen.sock");
}

/** Where an installed Yoyo Control.app is looked for: the Applications folders (not build folders). */
export function appCandidates(home: string = homedir()): string[] {
  return ["/Applications/Yoyo Control.app", join(home, "Applications", "Yoyo Control.app")];
}

/** The first installed Yoyo Control.app, or null. */
export function findApp(candidates: readonly string[] = appCandidates(), exists: (p: string) => boolean = existsSync): string | null {
  return candidates.find((p) => exists(p)) ?? null;
}

/** What an installed app bundle looks like now (its Info.plist's mtime and size); null when it isn't there. */
export function appStamp(path: string): string | null {
  try {
    const st = statSync(join(path, "Contents", "Info.plist"));
    return `${st.mtimeMs}:${st.size}`;
  } catch {
    return null;
  }
}

/** Opens the app in the background without activating it (`open -g -j`); resolves once `open` returns. */
export function openApp(path: string): Promise<void> {
  return new Promise((resolve, reject) => {
    execFile("open", ["-g", "-j", path], { timeout: 10_000 }, (err, _out, stderr) => {
      if (err) reject(new Error(String(stderr).trim() || err.message));
      else resolve();
    });
  });
}

/** The child service to run: `explicit` when set (even if missing), else the first of `candidates` that exists. */
export function resolveChildPath(explicit: string | null | undefined, candidates: readonly string[] = [], exists: (p: string) => boolean = existsSync): string | null {
  if (explicit) return explicit;
  return candidates.find((p) => exists(p)) ?? null;
}

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
export function remoteFailure(err: unknown): RemoteMode | "busy" {
  const e = err as { code?: unknown; name?: unknown; httpStatus?: unknown; cause?: { code?: unknown } } | null;
  if (e?.httpStatus === 401) return "rekey";
  const code = typeof e?.code === "string" ? e.code : typeof e?.cause?.code === "string" ? e.cause.code : "";
  if (["ECONNREFUSED", "EHOSTUNREACH", "ENETUNREACH", "EHOSTDOWN", "ECONNRESET", "EPIPE", "ENOENT", "ENOTFOUND"].includes(code)) return "restart";
  return "busy";
}
