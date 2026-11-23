// The IdP re-check (docs/ACCOUNT-LIB.md; ACCOUNT_IDP_RECHECK=1, off by default): once an hour each device
// session's IdP refresh token is used to ask the IdP whether that sign-in still stands.
//
// - One writer per session: a check of a session that is already being checked waits for that one (in this process)
//   or is skipped (a lease in the database, against an admin command's process). Two refreshes with the same token
//   would look like a stolen token to an IdP with reuse detection (many have it) and end the whole family.
// - The new refresh token is written, with the account's new name, in one transaction before anything else counts
//   it as done; the write is a compare-and-swap on the token that was used.
// - A network failure, a timeout, a 5xx, a 429, or any answer but a definite `invalid_grant` = "don't know, later".
// - `invalid_grant` ends that one device session (the device signs in again). Never the account, never the account's
//   other devices, never its computers: an IdP-wide "sign out everywhere" shows up in each session's own next check.
// - A session without a refresh token (the IdP gave none, or it was signed in while the re-check was off) is not
//   checked, and that is not a failure.
import type { IdpIdentity, Idp } from "./oidc.js";
import type { Session, Store } from "./store.js";

export const RECHECK_EVERY_MS = 3_600_000;
/** How long one check may hold its session's lease (the IdP call has a 10 s timeout). */
export const LEASE_MS = 60_000;

export type CheckResult = "ok" | "ended" | "retry" | "unchecked" | "busy" | "gone";

export class Rechecker {
  private inflight = new Map<string, Promise<CheckResult>>();
  private timer: NodeJS.Timeout | null = null;
  private running: Promise<unknown> | null = null;

  constructor(
    private readonly store: Store,
    private readonly idp: Idp,
    private readonly o: {
      now?: () => number;
      log?: (line: string) => void;
      /** A session ended by `invalid_grant` (the service revokes its device on the computers and pushes the notice). */
      onEnded?: (s: Session) => Promise<void> | void;
    } = {},
  ) {}

  private get now() {
    return this.o.now ?? Date.now;
  }
  private log(l: string) {
    (this.o.log ?? console.log)(l);
  }

  /** Checks one session now (coalesced with a check of it already under way). */
  check(sessionId: string): Promise<CheckResult> {
    const running = this.inflight.get(sessionId);
    if (running) return running;
    const p = this.checkOnce(sessionId).finally(() => this.inflight.delete(sessionId));
    this.inflight.set(sessionId, p);
    return p;
  }

  private async checkOnce(id: string): Promise<CheckResult> {
    const now = this.now();
    // the lease: only one writer, across processes too
    const leased = this.store.run(
      "UPDATE sessions SET lease_until = ? WHERE id = ? AND ended_at IS NULL AND expires_at > ? AND idp_refresh IS NOT NULL AND (lease_until IS NULL OR lease_until < ?)",
      now + LEASE_MS, id, now, now,
    );
    if (!leased) {
      const s = this.store.session(id);
      if (!s || s.ended_at !== null || s.expires_at <= now) return "gone";
      if (!s.idp_refresh) return "unchecked";
      return "busy";
    }
    const s = this.store.session(id)!;
    const account = this.store.account(s.account_id);
    if (!account) return "gone";
    const used = s.idp_refresh!;
    const out = await this.idp.refresh(used, account.sub);
    const t = this.now();
    if (out.kind === "ok") {
      const saved = this.store.tx(() => {
        const n = this.store.run(
          "UPDATE sessions SET idp_refresh = ?, idp_checked_at = ?, idp_check_result = 'ok', lease_until = NULL WHERE id = ? AND idp_refresh = ? AND ended_at IS NULL",
          out.refreshToken ?? used, t, id, used,
        );
        if (n) updateName(this.store, account.id, out.identity);
        return n;
      });
      if (!saved) {
        // ended (signed out, removed) while the IdP answered: the new token goes with it
        this.log(`[account] re-check ${id.slice(0, 8)}…: the session ended meanwhile`);
        return "gone";
      }
      return "ok";
    }
    if (out.kind === "retry") {
      this.store.run("UPDATE sessions SET idp_check_result = ?, lease_until = NULL WHERE id = ?", `retry: ${out.reason}`.slice(0, 120), id);
      this.log(`[account] re-check ${id.slice(0, 8)}…: later (${out.reason})`);
      return "retry";
    }
    const ended = this.store.tx(() => {
      const n = this.store.run(
        "UPDATE sessions SET ended_at = ?, end_reason = 'idp_invalid_grant', idp_refresh = NULL, idp_checked_at = ?, idp_check_result = 'invalid_grant', lease_until = NULL WHERE id = ? AND idp_refresh = ? AND ended_at IS NULL",
        t, t, id, used,
      );
      return n;
    });
    if (!ended) return "gone";
    this.log(`[account] re-check ${id.slice(0, 8)}…: the IdP no longer stands by this sign-in (invalid_grant): that device signs in again`);
    await this.o.onEnded?.({ ...s, ended_at: t, end_reason: "idp_invalid_grant" });
    return "ended";
  }

  /** The sessions due (not checked for an hour), one after another. */
  async runDue(limit = 200): Promise<Record<CheckResult, number>> {
    const now = this.now();
    const due = this.store.all<{ id: string }>(
      "SELECT id FROM sessions WHERE ended_at IS NULL AND expires_at > ? AND idp_refresh IS NOT NULL AND (idp_checked_at IS NULL OR idp_checked_at <= ?) ORDER BY coalesce(idp_checked_at, 0) LIMIT ?",
      now, now - RECHECK_EVERY_MS, limit,
    );
    const counts: Record<CheckResult, number> = { ok: 0, ended: 0, retry: 0, unchecked: 0, busy: 0, gone: 0 };
    for (const { id } of due) {
      // (a failed check is retried at the next round, not at once: "later" means later)
      const r = await this.check(id).catch((e: Error) => {
        this.log(`[account] re-check ${id.slice(0, 8)}…: ${e.message.slice(0, 120)}`);
        this.store.run("UPDATE sessions SET lease_until = NULL WHERE id = ?", id);
        return "retry" as const;
      });
      counts[r]++;
      if (r === "retry") this.store.run("UPDATE sessions SET idp_checked_at = ? WHERE id = ?", now - RECHECK_EVERY_MS + 10 * 60_000, id);
    }
    return counts;
  }

  /** Every five minutes, the sessions that are due. */
  start(everyMs = 5 * 60_000) {
    this.timer = setInterval(() => {
      if (this.running) return;
      this.running = this.runDue()
        .then((c) => {
          if (c.ok + c.ended + c.retry) this.log(`[account] re-check: ${c.ok} ok, ${c.ended} ended, ${c.retry} later`);
        })
        .catch(() => {})
        .finally(() => (this.running = null));
    }, everyMs);
    this.timer.unref();
  }
  stop() {
    if (this.timer) clearInterval(this.timer);
  }
}

function updateName(store: Store, account: string, id: IdpIdentity | null) {
  if (id?.name) store.run("UPDATE accounts SET name = ? WHERE id = ? AND (name IS NULL OR name != ?)", id.name, account, id.name);
}
