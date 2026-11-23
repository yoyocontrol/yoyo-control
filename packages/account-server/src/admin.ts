// The admin's commands (docs/ACCOUNT-LIB.md): run on the relay machine, next to the running server,
// against the same database (SQLite allows the second writer; every change is one transaction). Revocations they make
// go into the outbox, which the server signs and pushes within seconds; the pulled list has them at once.
//
//   yoyo-account-admin <command>
//
//   accounts                       every account: id, issuer, sub, name, state, computers, devices
//   add-account <sub> [name]       the account of that `sub` at the configured IdP, before its person ever signed in
//                                  (so computers can be put into it first); the id of the one there is, if there is
//   join-key <id> [uses] [hours]   a key (shown once) with which a computer joins that account without anyone's
//                                  approval — for the admin's own headless machines: `npm run account -- join --key`
//                                  on the computer. 1 use and 24 hours unless said (at most 100 uses, 30 days)
//   account <id>                   one account: its computers, devices and sessions
//   disable <id> | enable <id>     a disabled account cannot sign in, get tickets or approve; its sessions end and its
//                                  computers are told (the revocation list's `disabled`); enable lets it sign in again
//   remove <id>                    the account, its computers, devices and sessions deleted; a tombstone stays: the same
//                                  iss + sub cannot sign in until `clear-tombstone`
//   tombstones                     the removed iss + sub pairs
//   clear-tombstone <iss> <sub>    lets that iss + sub sign in again (as a new account)
//   revoke-device <device id>      that device's sessions end; its computers drop it
//   rebind-issuer <old> <new>      the IdP's issuer URL changed (new domain, http → https): move every account and
//                                  tombstone over, so nobody becomes a new account. Refuses when that would merge two
//   rotate-key                     a new signing key, endorsed by the current one (computers take it via the chain)
//   keys                           the signing keys' ids
//   recheck                        the IdP re-check of every session with a refresh token, now (even if it is off)
import { normalizeIssuer } from "./config.js";
import type { KeyRing } from "./keys.js";
import type { Rechecker } from "./recheck.js";
import type { Account, Device, Session, Store } from "./store.js";

export class AdminError extends Error {}

const sec = (ms: number) => Math.floor(ms / 1000);
const date = (ms: number | null) => (ms ? new Date(ms).toISOString().slice(0, 16).replace("T", " ") : "-");

function needAccount(store: Store, id: string | undefined): Account {
  const a = id ? store.account(id) : undefined;
  if (!a) throw new AdminError(`no account ${id ?? "(none given)"}`);
  return a;
}

export function disableAccount(store: Store, id: string, now = Date.now()): number {
  const a = needAccount(store, id);
  return store.tx(() => {
    store.run("UPDATE accounts SET disabled_at = ? WHERE id = ?", now, a.id);
    const ended = store.endSessions("account_id", a.id, "admin_disabled", now);
    const devices = store.devicesOf(a.id).map((d) => d.id);
    store.revoke(a.id, { devices, disabled: sec(now) }, sec(now), now);
    return ended;
  });
}

export function enableAccount(store: Store, id: string, now = Date.now()) {
  const a = needAccount(store, id);
  store.tx(() => {
    store.run("UPDATE accounts SET disabled_at = NULL WHERE id = ?", a.id);
    // (the devices' entries stay: what they held before stays void; they sign in again)
    store.revoke(a.id, { disabled: null }, sec(now), now);
  });
}

export function removeAccount(store: Store, id: string, now = Date.now()) {
  const a = needAccount(store, id);
  store.tx(() => {
    const devices = store.devicesOf(a.id).map((d) => d.id);
    const computers = store.computersOf(a.id).map((c) => c.link_id);
    store.run("INSERT OR REPLACE INTO tombstones (iss, sub, account_id, removed_at) VALUES (?,?,?,?)", a.iss, a.sub, a.id, now);
    // the revocations outlive the account (keyed by its id, which is never handed out again): its computers learn it
    store.revoke(a.id, { devices, computers, disabled: sec(now) }, sec(now), now);
    store.run("DELETE FROM app_codes WHERE account_id = ?", a.id);
    store.run("DELETE FROM accounts WHERE id = ?", a.id);
    store.run("DELETE FROM enrollments WHERE approved_account = ?", a.id);
  });
}

export function clearTombstone(store: Store, iss: string, sub: string): boolean {
  return store.run("DELETE FROM tombstones WHERE iss = ? AND sub = ?", normalizeIssuer(iss), sub) > 0;
}

export function revokeDevice(store: Store, id: string, now = Date.now()) {
  const d = store.device(id);
  if (!d) throw new AdminError(`no device ${id}`);
  store.tx(() => {
    store.run("UPDATE devices SET removed_at = coalesce(removed_at, ?) WHERE id = ?", now, d.id);
    store.endSessions("device_id", d.id, "admin_revoked", now);
    store.revoke(d.account_id, { devices: [d.id] }, sec(now), now);
  });
}

export function rebindIssuer(store: Store, oldIss: string, newIss: string, dryRun = false): { accounts: number; tombstones: number } {
  const from = normalizeIssuer(oldIss);
  const to = normalizeIssuer(newIss);
  if (from === to) throw new AdminError("the two issuers are the same");
  const clash = store.all<{ sub: string }>("SELECT a.sub FROM accounts a JOIN accounts b ON a.sub = b.sub WHERE a.iss = ? AND b.iss = ?", from, to);
  if (clash.length) throw new AdminError(`${clash.length} sub(s) already have an account under ${to} (they signed in after the change): remove those first (admin.ts accounts)`);
  const counts = {
    accounts: store.get<{ n: number }>("SELECT count(*) AS n FROM accounts WHERE iss = ?", from)!.n,
    tombstones: store.get<{ n: number }>("SELECT count(*) AS n FROM tombstones WHERE iss = ?", from)!.n,
  };
  if (dryRun) return counts;
  store.tx(() => {
    store.run("UPDATE accounts SET iss = ? WHERE iss = ?", to, from);
    store.run("UPDATE OR REPLACE tombstones SET iss = ? WHERE iss = ?", to, from);
  });
  return counts;
}

export async function runAdmin(args: string[], deps: { store: Store; ring: KeyRing; recheck?: () => Promise<Rechecker>; now?: () => number; issuer?: string }): Promise<string> {
  const { store, ring } = deps;
  const now = deps.now ?? Date.now;
  const [cmd, a1, a2] = args;
  switch (cmd) {
    case "accounts": {
      const rows = store.all<Account & { computers: number; devices: number }>(
        "SELECT a.*, (SELECT count(*) FROM computers c WHERE c.account_id = a.id) AS computers, (SELECT count(*) FROM devices d WHERE d.account_id = a.id AND d.removed_at IS NULL) AS devices FROM accounts a ORDER BY a.created_at",
      );
      if (!rows.length) return "no accounts";
      return rows.map((r) => `${r.id}  ${r.name ?? "-"}  ${r.iss}  sub=${r.sub}  ${r.disabled_at ? "DISABLED" : "active"}  ${r.computers} computer(s)  ${r.devices} device(s)  since ${date(r.created_at)}`).join("\n");
    }
    case "add-account": {
      if (!deps.issuer) throw new AdminError("add-account needs ACCOUNT_OIDC_ISSUER in the environment");
      if (!a1 || a1.length > 255) throw new AdminError("add-account <sub> [name]");
      const got = store.signInAccount(normalizeIssuer(deps.issuer), a1, a2?.trim().slice(0, 64) || null, now());
      if ("refused" in got) throw new AdminError(`that sub's account is ${got.refused} (clear-tombstone / enable first)`);
      return `${got.account.id}  ${got.account.name ?? "-"}  ${got.account.iss}  sub=${got.account.sub}`;
    }
    case "join-key": {
      const a = needAccount(store, a1);
      if (a.disabled_at !== null) throw new AdminError("that account is disabled");
      const uses = a2 === undefined ? 1 : Number(a2);
      const hours = args[3] === undefined ? 24 : Number(args[3]);
      if (!Number.isInteger(uses) || uses < 1 || uses > 100 || !(hours > 0) || hours > 720) throw new AdminError("join-key <account id> [uses 1-100] [hours, at most 720]");
      const key = store.createJoinKey(a.id, uses, now() + hours * 3_600_000, now());
      return `${key}\n(${uses} use(s), ${hours} h; shown once: on the computer, npm run account -- join --server <this server> --key <it>)`;
    }
    case "account": {
      const a = needAccount(store, a1);
      const lines = [`${a.id}  ${a.name ?? "-"}  ${a.iss}  sub=${a.sub}  ${a.disabled_at ? `DISABLED ${date(a.disabled_at)}` : "active"}`];
      for (const c of store.computersOf(a.id)) lines.push(`  computer ${c.link_id.slice(0, 16)}…  ${c.name}  joined ${date(c.joined_at)}`);
      for (const d of store.all<Device>("SELECT * FROM devices WHERE account_id = ? ORDER BY created_at", a.id)) {
        lines.push(`  device ${d.id}  ${d.name}  ${d.platform ?? "-"}  last used ${date(d.last_used_at)}${d.removed_at ? `  REMOVED ${date(d.removed_at)}` : ""}`);
      }
      for (const s of store.all<Session>("SELECT * FROM sessions WHERE account_id = ? ORDER BY created_at", a.id)) {
        lines.push(`  session ${s.id} (${s.kind}) device ${s.device_id ?? "-"}  until ${date(s.expires_at)}  ${s.ended_at ? `ended ${date(s.ended_at)} (${s.end_reason})` : "live"}  idp ${s.idp_refresh ? (s.idp_check_result ?? "not checked yet") : "unchecked"}`);
      }
      return lines.join("\n");
    }
    case "disable":
      return `disabled ${needAccount(store, a1).id}: ${disableAccount(store, a1!, now())} session(s) ended`;
    case "enable":
      enableAccount(store, a1!, now());
      return `enabled ${a1}: its devices sign in again`;
    case "remove": {
      const a = needAccount(store, a1);
      removeAccount(store, a.id, now());
      return `removed ${a.id}; tombstone for ${a.iss} sub=${a.sub} (admin.ts clear-tombstone to let it sign in again)`;
    }
    case "tombstones": {
      const rows = store.all<{ iss: string; sub: string; account_id: string; removed_at: number }>("SELECT * FROM tombstones ORDER BY removed_at");
      return rows.length ? rows.map((r) => `${r.iss}  sub=${r.sub}  was ${r.account_id}  removed ${date(r.removed_at)}`).join("\n") : "no tombstones";
    }
    case "clear-tombstone":
      if (!a1 || !a2) throw new AdminError("clear-tombstone <iss> <sub>");
      return clearTombstone(store, a1, a2) ? `cleared: ${a1} sub=${a2} may sign in again (a new account)` : "no such tombstone";
    case "revoke-device":
      revokeDevice(store, a1 ?? "", now());
      return `revoked ${a1}`;
    case "rebind-issuer": {
      if (!a1 || !a2) throw new AdminError("rebind-issuer <old issuer> <new issuer> [--dry-run]");
      const dry = args.includes("--dry-run");
      const n = rebindIssuer(store, a1, a2, dry);
      return `${dry ? "would move" : "moved"} ${n.accounts} account(s) and ${n.tombstones} tombstone(s) from ${normalizeIssuer(a1)} to ${normalizeIssuer(a2)}${dry ? "" : ": now set ACCOUNT_OIDC_ISSUER to the new one and restart"}`;
    }
    case "rotate-key": {
      const k = await ring.rotate();
      return `new signing key ${k.kid} (endorsed by the one before); restart the server to sign with it`;
    }
    case "keys":
      return ring.jwks().map((k, i, all) => `${k.kid}${i === all.length - 1 ? "  (current)" : ""}`).join("\n");
    case "recheck": {
      if (!deps.recheck) throw new AdminError("recheck needs the IdP settings in the environment");
      const r = await (await deps.recheck()).runDue(10_000);
      return `re-check: ${r.ok} ok, ${r.ended} ended (invalid_grant), ${r.retry} later, ${r.busy} busy`;
    }
    default:
      throw new AdminError("commands: accounts, add-account <sub> [name], join-key <id> [uses] [hours], account <id>, disable <id>, enable <id>, remove <id>, tombstones, clear-tombstone <iss> <sub>, revoke-device <id>, rebind-issuer <old> <new> [--dry-run], rotate-key, keys, recheck");
  }
}
