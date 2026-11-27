// The account server's storage: one SQLite file (<data dir>/account.db, 0600; node:sqlite, WAL). What is in it
// (docs/ACCOUNT-LIB.md): accounts by `iss` + `sub` and their shown names; tombstones of removed ones;
// each account's computers (Link id, name, WebRTC fingerprint, relay URLs with their tokens, the addresses their Link
// entry listens on, the origins of their own
// pages) and devices (id, name, the digest of their public key, last use); device sessions (their tokens only as
// SHA-256, the IdP refresh token that came with that sign-in); sign-ins on their way through the IdP; join codes;
// join keys the admin made (as SHA-256); sign-ins by QR code on their way; revocations and those still to take effect. Never a password (the IdP has those), never a computer's own tokens.
import { createHash, randomBytes } from "node:crypto";
import { chmodSync, existsSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { DatabaseSync, type SQLInputValue } from "node:sqlite";
import { DEFAULT_WIRE, type RevocationEntry, type RevocationState, type Wire } from "@yoyocontrol/account";

export const SCHEMA_VERSION = 6;
/** How long a device's revocation stays on the list (seconds): past the longest a computer's token of it can live. */
export const REVOCATION_KEEP_S = 200 * 86_400;
export const sha256 = (s: string) => createHash("sha256").update(s, "utf8").digest("base64url");
export const randomId = (prefix: string, bytes = 16) => `${prefix}${randomBytes(bytes).toString("base64url")}`;

export interface Account {
  id: string;
  iss: string;
  sub: string;
  name: string | null;
  created_at: number;
  disabled_at: number | null;
}
export interface Device {
  id: string;
  account_id: string;
  name: string;
  platform: string | null;
  /** A browser signed in at a computer's own page: that computer's Link id (it may end this device's session). */
  computer: string | null;
  key: string | null;
  key_digest: string | null;
  created_at: number;
  last_used_at: number | null;
  removed_at: number | null;
}
export interface Session {
  id: string;
  account_id: string;
  device_id: string | null;
  /** `app`: a device's (it holds the token). `web`: this server's /c page (a cookie). `browser`: a browser signed in at a
   *  computer's own page — nobody holds its token; it is there so the device shows in My Devices and can be removed. */
  /** `app` (the apps' bearer), `hosted` (the hosted web client's bearer, bound to its device key), `web` (this server's
   *  /c page's cookie), `browser` (a browser signed in at a computer's own page: nobody holds its token). */
  kind: "app" | "hosted" | "web" | "browser";
  created_at: number;
  expires_at: number;
  last_used_at: number | null;
  ended_at: number | null;
  end_reason: string | null;
  idp_refresh: string | null;
  idp_checked_at: number | null;
  idp_check_result: string | null;
  lease_until: number | null;
}
export interface Computer {
  link_id: string;
  account_id: string;
  name: string;
  fingerprint: string | null;
  relays: string;
  direct: string;
  origins: string;
  /** The signaling service the computer waits for browsers' offers at (an origin), or null. */
  signal: string | null;
  /** What the computer says of itself for its product's own clients (a JSON object, opaque here), or null. */
  info: string | null;
  joined_at: number;
  updated_at: number;
}
/** An account's entitlement from one purchase (`source` "appstore": a StoreKit original transaction). Times unix ms. */
export interface Entitlement {
  source: string;
  original_id: string;
  account_id: string;
  product_id: string;
  expires_at: number | null;
  revoked_at: number | null;
  environment: string;
  updated_at: number;
}
export interface Enrollment {
  id: string;
  device_code_hash: string;
  user_code: string;
  link_id: string;
  name: string;
  fingerprint: string | null;
  relays: string;
  direct: string;
  origins: string;
  signal: string | null;
  info: string | null;
  expect: string | null;
  ip: string;
  created_at: number;
  expires_at: number;
  last_poll_at: number | null;
  status: "pending" | "approved" | "declined" | "confirmed";
  approved_account: string | null;
  approved_device_name: string | null;
  approved_at: number | null;
}
export interface Signin {
  state: string;
  kind: "app" | "web" | "computer";
  /** base64url SHA-256 of the cookie the browser that started it holds (`web`, `computer`); "" for an app's. */
  bind: string;
  verifier: string;
  nonce: string;
  redirect_uri: string;
  client_state: string;
  challenge: string;
  computer: string | null;
  created_at: number;
  expires_at: number;
}
export interface AppCode {
  code_hash: string;
  account_id: string;
  challenge: string;
  redirect_uri: string;
  idp_refresh: string | null;
  /** A code for a computer's own page: only that computer (its Link id) may trade it. */
  computer: string | null;
  expires_at: number;
}
export interface OutboxRow {
  id: number;
  account_id: string;
  seq: number;
  payload: string;
}

/** An email's password: the account it signs in to, its scrypt hash. */
export interface PasswordLogin {
  email: string;
  account_id: string;
  hash: string;
  created_at: number;
  updated_at: number;
}

/** A sign-in by QR code (docs/ACCOUNT-LIB.md「扫码登录」): a new device asked with its key; a signed-in one approves
 *  the code it shows; the new device polls with its secret (kept only as SHA-256) and gets its session, once. */
export interface QrSignin {
  id: string;
  request_hash: string;
  user_code: string;
  device_name: string;
  platform: string;
  /** The new device's raw Ed25519 public key (base64url): its session is bound to it. */
  key: string;
  ip: string;
  created_at: number;
  expires_at: number;
  last_poll_at: number | null;
  status: "pending" | "approved" | "declined" | "done";
  approved_account: string | null;
  approved_device: string | null;
  approved_at: number | null;
}

/** A one-time code mailed for a sign-up (`pending`: the password's hash, set once the code is given) or a reset. */
export interface EmailCode {
  email: string;
  purpose: string;
  code_hash: string;
  pending: string | null;
  expires_at: number;
  attempts: number;
  sent_at: number;
  /** The hour `sends` counts in (its start). */
  window_at: number;
  sends: number;
}

const SCHEMA = `
CREATE TABLE IF NOT EXISTS accounts (
  id TEXT PRIMARY KEY, iss TEXT NOT NULL, sub TEXT NOT NULL, name TEXT,
  created_at INTEGER NOT NULL, disabled_at INTEGER, UNIQUE (iss, sub));
CREATE TABLE IF NOT EXISTS tombstones (
  iss TEXT NOT NULL, sub TEXT NOT NULL, account_id TEXT NOT NULL, removed_at INTEGER NOT NULL, PRIMARY KEY (iss, sub));
CREATE TABLE IF NOT EXISTS devices (
  id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, name TEXT NOT NULL,
  platform TEXT, key TEXT, key_digest TEXT, created_at INTEGER NOT NULL, last_used_at INTEGER, removed_at INTEGER, computer TEXT);
CREATE INDEX IF NOT EXISTS devices_account ON devices (account_id);
CREATE TABLE IF NOT EXISTS sessions (
  id TEXT PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE,
  account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  device_id TEXT REFERENCES devices(id) ON DELETE CASCADE, kind TEXT NOT NULL,
  created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, last_used_at INTEGER, ended_at INTEGER, end_reason TEXT,
  idp_refresh TEXT, idp_checked_at INTEGER, idp_check_result TEXT, lease_until INTEGER);
CREATE INDEX IF NOT EXISTS sessions_account ON sessions (account_id);
CREATE INDEX IF NOT EXISTS sessions_device ON sessions (device_id);
CREATE TABLE IF NOT EXISTS computers (
  link_id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, name TEXT NOT NULL,
  fingerprint TEXT, relays TEXT NOT NULL DEFAULT '[]', direct TEXT NOT NULL DEFAULT '[]', origins TEXT NOT NULL DEFAULT '[]',
  joined_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, signal TEXT, info TEXT);
CREATE INDEX IF NOT EXISTS computers_account ON computers (account_id);
CREATE TABLE IF NOT EXISTS signins (
  state TEXT PRIMARY KEY, kind TEXT NOT NULL, bind TEXT NOT NULL DEFAULT '', verifier TEXT NOT NULL, nonce TEXT NOT NULL, redirect_uri TEXT NOT NULL,
  client_state TEXT NOT NULL, challenge TEXT NOT NULL, computer TEXT, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS app_codes (
  code_hash TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, challenge TEXT NOT NULL,
  redirect_uri TEXT NOT NULL, idp_refresh TEXT, computer TEXT, expires_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS enrollments (
  id TEXT PRIMARY KEY, device_code_hash TEXT NOT NULL UNIQUE, user_code TEXT NOT NULL UNIQUE, link_id TEXT NOT NULL,
  name TEXT NOT NULL, fingerprint TEXT, relays TEXT NOT NULL, direct TEXT NOT NULL DEFAULT '[]', origins TEXT NOT NULL, signal TEXT, info TEXT, expect TEXT, ip TEXT NOT NULL,
  created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, last_poll_at INTEGER, status TEXT NOT NULL,
  approved_account TEXT, approved_device_name TEXT, approved_at INTEGER);
CREATE TABLE IF NOT EXISTS join_keys (
  key_hash TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, uses_left INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS revocations (
  account_id TEXT NOT NULL, kind TEXT NOT NULL, id TEXT NOT NULL, at INTEGER NOT NULL, PRIMARY KEY (account_id, kind, id));
CREATE TABLE IF NOT EXISTS revocation_versions (
  account_id TEXT PRIMARY KEY, version INTEGER NOT NULL, disabled INTEGER);
CREATE TABLE IF NOT EXISTS entitlements (
  source TEXT NOT NULL, original_id TEXT NOT NULL, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  product_id TEXT NOT NULL, expires_at INTEGER, revoked_at INTEGER, environment TEXT NOT NULL, updated_at INTEGER NOT NULL,
  PRIMARY KEY (source, original_id));
CREATE INDEX IF NOT EXISTS entitlements_account ON entitlements (account_id);
CREATE TABLE IF NOT EXISTS password_logins (
  email TEXT PRIMARY KEY, account_id TEXT NOT NULL UNIQUE REFERENCES accounts(id) ON DELETE CASCADE,
  hash TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS email_codes (
  email TEXT NOT NULL, purpose TEXT NOT NULL, code_hash TEXT NOT NULL, pending TEXT, expires_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0, sent_at INTEGER NOT NULL, window_at INTEGER NOT NULL, sends INTEGER NOT NULL,
  PRIMARY KEY (email, purpose));
CREATE TABLE IF NOT EXISTS qr_signins (
  id TEXT PRIMARY KEY, request_hash TEXT NOT NULL UNIQUE, user_code TEXT NOT NULL UNIQUE, device_name TEXT NOT NULL,
  platform TEXT NOT NULL, key TEXT NOT NULL, ip TEXT NOT NULL, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
  last_poll_at INTEGER, status TEXT NOT NULL, approved_account TEXT, approved_device TEXT, approved_at INTEGER);
CREATE TABLE IF NOT EXISTS outbox (
  id INTEGER PRIMARY KEY AUTOINCREMENT, account_id TEXT NOT NULL, seq INTEGER NOT NULL, payload TEXT NOT NULL, created_at INTEGER NOT NULL);
`;

export class Store {
  readonly db: DatabaseSync;
  private stmts = new Map<string, ReturnType<DatabaseSync["prepare"]>>();
  private depth = 0;

  /** `wire`: the namespace its session tokens and join keys are named in (the server's). */
  constructor(file: string, private readonly wire: Wire = DEFAULT_WIRE) {
    if (file !== ":memory:") {
      mkdirSync(dirname(file), { recursive: true });
      const fresh = !existsSync(file);
      this.db = new DatabaseSync(file);
      if (fresh) chmodSync(file, 0o600);
    } else this.db = new DatabaseSync(file);
    this.db.exec("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;");
    const v = (this.db.prepare("PRAGMA user_version").get() as { user_version: number }).user_version;
    if (v > SCHEMA_VERSION) throw new Error(`account.db is schema ${v}, newer than this server's ${SCHEMA_VERSION}`);
    // one step at a time, each in its own transaction, the version asked again inside (the server and an admin command
    // may open it at the same moment)
    const hasTable = (t: string) => !!this.db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get(t);
    const steps: Record<number, () => string> = {
      // 1 → 2 (a browser's sign-in at a computer's own page): devices know which computer made them; the two tables of
      // sign-ins on their way (minutes old at most) are made anew with their new columns
      1: () => "ALTER TABLE devices ADD COLUMN computer TEXT; DROP TABLE IF EXISTS signins; DROP TABLE IF EXISTS app_codes;",
      // 2 → 3 (the hosted web client): a computer says which signaling service it waits for browsers at (a table not
      // there yet is made whole below)
      2: () => ["computers", "enrollments"].filter(hasTable).map((t) => `ALTER TABLE ${t} ADD COLUMN signal TEXT;`).join(" "),
      // 3 → 4: what a computer says of itself for its product's clients (`info`); entitlements are a new table
      3: () => ["computers", "enrollments"].filter(hasTable).map((t) => `ALTER TABLE ${t} ADD COLUMN info TEXT;`).join(" "),
      // 4 → 5: email and password (`password_logins`, `email_codes`: new tables, made whole below)
      4: () => "",
      // 5 → 6: sign-in by QR code (`qr_signins`: a new table, made whole below)
      5: () => "",
    };
    for (let from = v; from > 0 && from < SCHEMA_VERSION; from++) {
      this.db.exec("BEGIN IMMEDIATE");
      try {
        if ((this.db.prepare("PRAGMA user_version").get() as { user_version: number }).user_version === from) {
          this.db.exec(`${steps[from]!()} PRAGMA user_version = ${from + 1};`);
        }
        this.db.exec("COMMIT");
      } catch (e) {
        this.db.exec("ROLLBACK");
        throw e;
      }
    }
    this.db.exec(SCHEMA);
    this.db.exec(`PRAGMA user_version = ${SCHEMA_VERSION}`);
  }

  close() {
    this.db.close();
  }

  private q(sql: string) {
    let s = this.stmts.get(sql);
    if (!s) {
      s = this.db.prepare(sql);
      this.stmts.set(sql, s);
    }
    return s;
  }
  get<T>(sql: string, ...a: SQLInputValue[]): T | undefined {
    return this.q(sql).get(...a) as T | undefined;
  }
  all<T>(sql: string, ...a: SQLInputValue[]): T[] {
    return this.q(sql).all(...a) as T[];
  }
  run(sql: string, ...a: SQLInputValue[]): number {
    return Number(this.q(sql).run(...a).changes);
  }

  /** `fn` in one transaction (BEGIN IMMEDIATE: one writer at a time, this process or an admin command's). */
  tx<T>(fn: () => T): T {
    if (this.depth) return fn();
    this.db.exec("BEGIN IMMEDIATE");
    this.depth++;
    try {
      const r = fn();
      this.db.exec("COMMIT");
      return r;
    } catch (e) {
      this.db.exec("ROLLBACK");
      throw e;
    } finally {
      this.depth--;
    }
  }

  // --------------------------------------------------------------------------- accounts

  account(id: string) {
    return this.get<Account>("SELECT * FROM accounts WHERE id = ?", id);
  }
  accountOf(iss: string, sub: string) {
    return this.get<Account>("SELECT * FROM accounts WHERE iss = ? AND sub = ?", iss, sub);
  }
  tombstone(iss: string, sub: string) {
    return this.get<{ account_id: string; removed_at: number }>("SELECT account_id, removed_at FROM tombstones WHERE iss = ? AND sub = ?", iss, sub);
  }
  /** An email's password login (docs/ACCOUNT-LIB.md「邮箱和密码」). */
  passwordLogin(email: string) {
    return this.get<PasswordLogin>("SELECT * FROM password_logins WHERE email = ?", email);
  }
  /** The code on its way for `email` and `purpose`. */
  emailCode(email: string, purpose: string) {
    return this.get<EmailCode>("SELECT * FROM email_codes WHERE email = ? AND purpose = ?", email, purpose);
  }

  /** The account of `iss` + `sub` (made now when there is none), or why there is none to be had. */
  signInAccount(iss: string, sub: string, name: string | null, now: number): { account: Account } | { refused: "removed" | "disabled" } {
    return this.tx(() => {
      if (this.tombstone(iss, sub)) return { refused: "removed" as const };
      let a = this.accountOf(iss, sub);
      if (!a) {
        const id = randomId("a_");
        this.run("INSERT INTO accounts (id, iss, sub, name, created_at) VALUES (?,?,?,?,?)", id, iss, sub, name, now);
        a = this.account(id)!;
      } else if (name && name !== a.name) {
        this.run("UPDATE accounts SET name = ? WHERE id = ?", name, a.id);
        a = { ...a, name };
      }
      if (a.disabled_at !== null) return { refused: "disabled" as const };
      return { account: a };
    });
  }

  // --------------------------------------------------------------------------- devices

  /** The device this sign-in is: the account's device with the same public key (not removed), else a new one. */
  deviceFor(account: string, d: { name: string; platform: string | null; key: string | null; keyDigest: string | null; computer?: string | null }, now: number): Device {
    if (d.keyDigest) {
      const old = this.get<Device>("SELECT * FROM devices WHERE account_id = ? AND key_digest = ? AND removed_at IS NULL", account, d.keyDigest);
      if (old) {
        this.run("UPDATE devices SET name = ?, platform = ?, last_used_at = ? WHERE id = ?", d.name, d.platform, now, old.id);
        return { ...old, name: d.name, platform: d.platform, last_used_at: now };
      }
    }
    const id = randomId("d_");
    this.run("INSERT INTO devices (id, account_id, name, platform, key, key_digest, created_at, last_used_at, computer) VALUES (?,?,?,?,?,?,?,?,?)", id, account, d.name, d.platform, d.key, d.keyDigest, now, now, d.computer ?? null);
    return this.get<Device>("SELECT * FROM devices WHERE id = ?", id)!;
  }
  device(id: string) {
    return this.get<Device>("SELECT * FROM devices WHERE id = ?", id);
  }
  devicesOf(account: string) {
    return this.all<Device>("SELECT * FROM devices WHERE account_id = ? AND removed_at IS NULL ORDER BY created_at", account);
  }
  /** The devices signed in now (a live session): what "My devices" shows — one that signed out is not one of them,
   *  though its row stays (the same key signing in again is the same device). */
  signedInDevicesOf(account: string, now: number) {
    return this.all<Device>(
      "SELECT d.* FROM devices d WHERE d.account_id = ? AND d.removed_at IS NULL AND EXISTS (SELECT 1 FROM sessions s WHERE s.device_id = d.id AND s.ended_at IS NULL AND s.expires_at > ?) ORDER BY d.created_at",
      account, now,
    );
  }
  /** The devices that count against the account's limit: those signed in now. */
  countDevices(account: string, now: number) {
    return this.signedInDevicesOf(account, now).length;
  }

  // --------------------------------------------------------------------------- sessions

  createSession(p: { account: string; device: string | null; kind: Session["kind"]; now: number; maxAgeMs: number; idpRefresh: string | null; replaceDeviceSessions?: boolean }): { id: string; token: string; expiresAt: number } {
    const id = randomId("s_", 12);
    const token = `${this.wire.sessionPrefix}${randomBytes(32).toString("base64url")}`;
    const expiresAt = p.now + p.maxAgeMs;
    this.tx(() => {
      // one live session per device: a new sign-in on the same device ends the old one
      if (p.device && p.replaceDeviceSessions !== false) this.run("UPDATE sessions SET ended_at = ?, end_reason = 'replaced', idp_refresh = NULL WHERE device_id = ? AND ended_at IS NULL", p.now, p.device);
      this.run("INSERT INTO sessions (id, token_hash, account_id, device_id, kind, created_at, expires_at, idp_refresh) VALUES (?,?,?,?,?,?,?,?)", id, sha256(token), p.account, p.device, p.kind, p.now, expiresAt, p.idpRefresh);
    });
    return { id, token, expiresAt };
  }
  sessionOfToken(token: string) {
    return this.get<Session>("SELECT * FROM sessions WHERE token_hash = ?", sha256(token));
  }
  session(id: string) {
    return this.get<Session>("SELECT * FROM sessions WHERE id = ?", id);
  }
  touchSession(s: Session, now: number) {
    // (a write a minute at most per session)
    if (s.last_used_at && now - s.last_used_at < 60_000) return;
    this.run("UPDATE sessions SET last_used_at = ? WHERE id = ?", now, s.id);
    if (s.device_id) this.run("UPDATE devices SET last_used_at = ? WHERE id = ?", now, s.device_id);
  }
  /** Ends live sessions (and drops their IdP refresh tokens); the number ended. */
  endSessions(where: "id" | "device_id" | "account_id", value: string, reason: string, now: number): number {
    return this.run(`UPDATE sessions SET ended_at = ?, end_reason = ?, idp_refresh = NULL, lease_until = NULL WHERE ${where} = ? AND ended_at IS NULL`, now, reason, value);
  }

  // --------------------------------------------------------------------------- sign-ins on their way, app codes

  putSignin(s: Signin) {
    this.run(
      "INSERT INTO signins (state, kind, bind, verifier, nonce, redirect_uri, client_state, challenge, computer, created_at, expires_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
      s.state, s.kind, s.bind, s.verifier, s.nonce, s.redirect_uri, s.client_state, s.challenge, s.computer, s.created_at, s.expires_at,
    );
  }
  /** The pending sign-in of `state`, once (taken out whether or not it is still good). */
  takeSignin(state: string, now: number): Signin | null {
    return this.tx(() => {
      const s = this.get<Signin>("SELECT * FROM signins WHERE state = ?", state);
      if (!s) return null;
      this.run("DELETE FROM signins WHERE state = ?", state);
      return s.expires_at > now ? s : null;
    });
  }
  countSignins(now: number) {
    return this.get<{ n: number }>("SELECT count(*) AS n FROM signins WHERE expires_at > ?", now)!.n;
  }
  putAppCode(c: AppCode) {
    this.run("INSERT INTO app_codes (code_hash, account_id, challenge, redirect_uri, idp_refresh, computer, expires_at) VALUES (?,?,?,?,?,?,?)", c.code_hash, c.account_id, c.challenge, c.redirect_uri, c.idp_refresh, c.computer, c.expires_at);
  }
  takeAppCode(code: string, now: number): AppCode | null {
    return this.tx(() => {
      const c = this.get<AppCode>("SELECT * FROM app_codes WHERE code_hash = ?", sha256(code));
      if (!c) return null;
      this.run("DELETE FROM app_codes WHERE code_hash = ?", c.code_hash);
      return c.expires_at > now ? c : null;
    });
  }

  // --------------------------------------------------------------------------- computers

  computer(linkId: string) {
    return this.get<Computer>("SELECT * FROM computers WHERE link_id = ?", linkId);
  }
  computersOf(account: string) {
    return this.all<Computer>("SELECT * FROM computers WHERE account_id = ? ORDER BY joined_at", account);
  }
  countComputers(account: string) {
    return this.get<{ n: number }>("SELECT count(*) AS n FROM computers WHERE account_id = ?", account)!.n;
  }

  // --------------------------------------------------------------------------- enrollments (join codes)

  enrollmentOfCode(userCode: string) {
    return this.get<Enrollment>("SELECT * FROM enrollments WHERE user_code = ?", userCode);
  }
  enrollmentOfDeviceCode(deviceCode: string) {
    return this.get<Enrollment>("SELECT * FROM enrollments WHERE device_code_hash = ?", sha256(deviceCode));
  }
  /** The addresses the open join codes were asked from (one entry per code). */
  openEnrollmentAddresses(now: number): string[] {
    return this.all<{ ip: string }>("SELECT ip FROM enrollments WHERE expires_at > ? AND status IN ('pending','approved')", now).map((r) => r.ip);
  }
  countEnrollments(now: number, ip?: string) {
    return ip === undefined
      ? this.get<{ n: number }>("SELECT count(*) AS n FROM enrollments WHERE expires_at > ? AND status IN ('pending','approved')", now)!.n
      : this.get<{ n: number }>("SELECT count(*) AS n FROM enrollments WHERE expires_at > ? AND status IN ('pending','approved') AND ip = ?", now, ip)!.n;
  }

  // --------------------------------------------------------------------------- sign-ins by QR code

  qrSigninOfCode(userCode: string) {
    return this.get<QrSignin>("SELECT * FROM qr_signins WHERE user_code = ?", userCode);
  }
  qrSigninOfRequest(request: string) {
    return this.get<QrSignin>("SELECT * FROM qr_signins WHERE request_hash = ?", sha256(request));
  }
  /** The addresses the open QR sign-ins were asked from (one entry per sign-in). */
  openQrSigninAddresses(now: number): string[] {
    return this.all<{ ip: string }>("SELECT ip FROM qr_signins WHERE expires_at > ? AND status IN ('pending','approved')", now).map((r) => r.ip);
  }

  // --------------------------------------------------------------------------- join keys (the admin's)

  /** A new join key of `account` (admin.ts join-key): a computer that has it joins that account without anyone's
   *  approval, `uses` times at most, until `expiresAt`. Only its SHA-256 is kept. */
  createJoinKey(account: string, uses: number, expiresAt: number, now: number): string {
    const key = `${this.wire.joinKeyPrefix}${randomBytes(32).toString("base64url")}`;
    this.run("INSERT INTO join_keys (key_hash, account_id, created_at, expires_at, uses_left) VALUES (?,?,?,?,?)", sha256(key), account, now, expiresAt, uses);
    return key;
  }
  /** One use of a join key taken: its account's id, or null (unknown, expired, used up). */
  useJoinKey(key: string, now: number): string | null {
    return this.tx(() => {
      const k = this.get<{ account_id: string }>("SELECT account_id FROM join_keys WHERE key_hash = ? AND expires_at > ? AND uses_left > 0", sha256(key), now);
      if (!k) return null;
      this.run("UPDATE join_keys SET uses_left = uses_left - 1 WHERE key_hash = ?", sha256(key));
      return k.account_id;
    });
  }

  /** How many join keys of `account` are still good (the app's own: a few at a time). */
  countJoinKeys(account: string, now: number) {
    return this.get<{ n: number }>("SELECT count(*) AS n FROM join_keys WHERE account_id = ? AND expires_at > ? AND uses_left > 0", account, now)!.n;
  }

  // --------------------------------------------------------------------------- entitlements

  /** One purchase is one account's: the last one to report it (a family member's phone signed into another account
   *  takes it over). */
  putEntitlement(e: Entitlement) {
    this.run(
      "INSERT INTO entitlements (source, original_id, account_id, product_id, expires_at, revoked_at, environment, updated_at) VALUES (?,?,?,?,?,?,?,?) ON CONFLICT (source, original_id) DO UPDATE SET account_id = excluded.account_id, product_id = excluded.product_id, expires_at = excluded.expires_at, revoked_at = excluded.revoked_at, environment = excluded.environment, updated_at = excluded.updated_at",
      e.source, e.original_id, e.account_id, e.product_id, e.expires_at, e.revoked_at, e.environment, e.updated_at,
    );
  }
  entitlementsOf(account: string) {
    return this.all<Entitlement>("SELECT * FROM entitlements WHERE account_id = ? ORDER BY updated_at", account);
  }

  // --------------------------------------------------------------------------- revocations

  revocationState(account: string): RevocationState {
    const v = this.get<{ version: number; disabled: number | null }>("SELECT version, disabled FROM revocation_versions WHERE account_id = ?", account);
    // devices' entries older than anything a computer could still hold of them are left out (a computer's token ends
    // with its device's session, 90 days at most after its ticket, and what that sign-in registered there for pushes a
    // week after that — the server's REGISTRATION_GRACE_S; REVOCATION_KEEP_S is past both, and must stay so)
    const rows = this.all<{ kind: string; id: string; at: number }>("SELECT kind, id, at FROM revocations WHERE account_id = ? AND (kind != 'device' OR at > ?) ORDER BY at, id", account, Math.floor(Date.now() / 1000) - REVOCATION_KEEP_S);
    const pick = (k: string): RevocationEntry[] => rows.filter((r) => r.kind === k).map((r) => ({ id: r.id, at: r.at }));
    return { account, version: v?.version ?? 0, devices: pick("device"), computers: pick("computer"), disabled: v?.disabled ?? null };
  }

  /**
   * Revocations of one account, in one step: entries added (an entry's `at` only moves later), the disabled mark set
   * or cleared, the version raised by one, and the notice for it queued (outbox: main.ts pushes it). The new version.
   */
  revoke(account: string, r: { devices?: string[]; computers?: string[]; disabled?: number | null }, atSec: number, now: number): number {
    return this.tx(() => {
      const added: { devices: RevocationEntry[]; computers: RevocationEntry[] } = { devices: [], computers: [] };
      for (const [kind, ids] of [["device", r.devices ?? []], ["computer", r.computers ?? []]] as const) {
        for (const id of ids) {
          this.run("INSERT INTO revocations (account_id, kind, id, at) VALUES (?,?,?,?) ON CONFLICT (account_id, kind, id) DO UPDATE SET at = max(at, excluded.at)", account, kind, id, atSec);
          (kind === "device" ? added.devices : added.computers).push({ id, at: atSec });
        }
      }
      const cur = this.get<{ version: number; disabled: number | null }>("SELECT version, disabled FROM revocation_versions WHERE account_id = ?", account);
      const disabled = r.disabled === undefined ? (cur?.disabled ?? null) : r.disabled;
      // (never below the clock: a database restored from a backup, or lost, still hands out a version past every one
      // a computer holds — it would refuse a lower one as a replay and stop taking revocations)
      const version = Math.max((cur?.version ?? 0) + 1, now);
      this.run("INSERT INTO revocation_versions (account_id, version, disabled) VALUES (?,?,?) ON CONFLICT (account_id) DO UPDATE SET version = excluded.version, disabled = excluded.disabled", account, version, disabled);
      this.run("INSERT INTO outbox (account_id, seq, payload, created_at) VALUES (?,?,?,?)", account, version, JSON.stringify({ ...added, disabled }), now);
      return version;
    });
  }

  outbox(limit = 100) {
    return this.all<OutboxRow>("SELECT id, account_id, seq, payload FROM outbox ORDER BY id LIMIT ?", limit);
  }
  outboxDone(id: number) {
    this.run("DELETE FROM outbox WHERE id = ?", id);
  }

  /** Rows past their use: sign-ins and app codes expired, join codes an hour after, sessions a week after they ended
   *  or expired (kept that long for `admin.ts account`). */
  sweep(now: number) {
    this.run("DELETE FROM signins WHERE expires_at <= ?", now);
    this.run("DELETE FROM app_codes WHERE expires_at <= ?", now);
    this.run("DELETE FROM join_keys WHERE expires_at <= ? OR uses_left <= 0", now);
    // a device with no key that is signed in nowhere can never come back as itself (a browser whose 30 days ran out, a
    // script's sign-in): it is gone
    this.run("UPDATE devices SET removed_at = ? WHERE removed_at IS NULL AND key_digest IS NULL AND NOT EXISTS (SELECT 1 FROM sessions s WHERE s.device_id = devices.id AND s.ended_at IS NULL AND s.expires_at > ?)", now, now);
    this.run("DELETE FROM qr_signins WHERE expires_at <= ?", now - 600_000);
    this.run("DELETE FROM enrollments WHERE expires_at <= ? OR status IN ('declined','confirmed') AND created_at <= ?", now - 3_600_000, now - 600_000);
    this.run("DELETE FROM sessions WHERE (ended_at IS NOT NULL AND ended_at <= ?) OR expires_at <= ?", now - 7 * 86_400_000, now - 7 * 86_400_000);
    this.run("UPDATE sessions SET idp_refresh = NULL WHERE expires_at <= ? AND idp_refresh IS NOT NULL", now);
  }
}
