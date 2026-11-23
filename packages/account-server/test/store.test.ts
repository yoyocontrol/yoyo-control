// The account server's storage across versions: a database made by the first version (schema 1, as it is live) opens
// with this one — accounts, computers and devices as they were, the new columns there.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";
import { SCHEMA_VERSION, Store } from "../src/store.js";

test("a schema 1 database is brought to this version: what it holds stays, sign-ins on their way are dropped, new columns work", () => {
  const dir = mkdtempSync(join(tmpdir(), "acct-store-"));
  const file = join(dir, "account.db");
  try {
    // (the tables of schema 1 that changed since, as that version made them, and one it did not change)
    const old = new DatabaseSync(file);
    old.exec(`
      CREATE TABLE accounts (id TEXT PRIMARY KEY, iss TEXT NOT NULL, sub TEXT NOT NULL, name TEXT, created_at INTEGER NOT NULL, disabled_at INTEGER, UNIQUE (iss, sub));
      CREATE TABLE devices (id TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, name TEXT NOT NULL,
        platform TEXT, key TEXT, key_digest TEXT, created_at INTEGER NOT NULL, last_used_at INTEGER, removed_at INTEGER);
      CREATE TABLE signins (state TEXT PRIMARY KEY, kind TEXT NOT NULL, verifier TEXT NOT NULL, nonce TEXT NOT NULL, redirect_uri TEXT NOT NULL,
        client_state TEXT NOT NULL, challenge TEXT NOT NULL, computer TEXT, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL);
      CREATE TABLE app_codes (code_hash TEXT PRIMARY KEY, account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, challenge TEXT NOT NULL,
        redirect_uri TEXT NOT NULL, idp_refresh TEXT, expires_at INTEGER NOT NULL);
      INSERT INTO accounts (id, iss, sub, name, created_at) VALUES ('a_0123456789ab', 'https://id.example.com', 'u1', 'Alex', 1);
      INSERT INTO devices (id, account_id, name, platform, created_at) VALUES ('d_0123456789ab', 'a_0123456789ab', 'Phone', 'ios', 1);
      INSERT INTO signins VALUES ('s', 'app', 'v', 'n', 'example://account', '', 'c', NULL, 1, 2);
      PRAGMA user_version = 1;`);
    old.close();
    const store = new Store(file);
    assert.equal(store.get<{ user_version: number }>("PRAGMA user_version")!.user_version, SCHEMA_VERSION);
    assert.equal(store.account("a_0123456789ab")?.name, "Alex");
    assert.equal(store.device("d_0123456789ab")?.computer, null, "a device from before: no computer");
    assert.equal(store.countSignins(0), 0, "sign-ins on their way did not come along");
    // the new columns
    const now = Date.now();
    store.putSignin({ state: "s2", kind: "computer", bind: "b", verifier: "v", nonce: "n", redirect_uri: "https://computer.example.com/auth/account/callback", client_state: "x", challenge: "c", computer: "ab".repeat(32), created_at: now, expires_at: now + 1000 });
    assert.equal(store.takeSignin("s2", now)?.bind, "b");
    store.putAppCode({ code_hash: "h", account_id: "a_0123456789ab", challenge: "c", redirect_uri: "r", idp_refresh: null, computer: "ab".repeat(32), expires_at: now + 1000 });
    const browser = store.deviceFor("a_0123456789ab", { name: "Safari on Mac · Studio", platform: "web", key: null, keyDigest: null, computer: "ab".repeat(32) }, now);
    assert.equal(store.device(browser.id)?.computer, "ab".repeat(32));
    store.close();
    // and once more (already at this version): nothing to do, nothing lost
    const again = new Store(file);
    assert.equal(again.device(browser.id)?.computer, "ab".repeat(32));
    again.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("a schema 2 database gets the computers' signaling column; what they had stays", () => {
  const dir = mkdtempSync(join(tmpdir(), "acct-store-"));
  const file = join(dir, "account.db");
  try {
    const made = new Store(file);
    made.run("INSERT INTO accounts (id, iss, sub, name, created_at) VALUES ('a_0123456789ab', 'https://id.example.com', 'u1', 'Alex', 1)");
    made.run("INSERT INTO computers (link_id, account_id, name, relays, joined_at, updated_at) VALUES (?, 'a_0123456789ab', 'Studio', '[\"https://relay.example.com\"]', 1, 1)", "ab".repeat(32));
    made.close();
    // as schema 2 had it: no signal column
    const old = new DatabaseSync(file);
    old.exec("ALTER TABLE computers DROP COLUMN signal; ALTER TABLE enrollments DROP COLUMN signal; ALTER TABLE computers DROP COLUMN info; ALTER TABLE enrollments DROP COLUMN info; DROP TABLE entitlements; PRAGMA user_version = 2;");
    old.close();
    const store = new Store(file);
    assert.equal(store.get<{ user_version: number }>("PRAGMA user_version")!.user_version, SCHEMA_VERSION);
    const c = store.computer("ab".repeat(32))!;
    assert.equal(c.name, "Studio");
    assert.equal(c.relays, '["https://relay.example.com"]');
    assert.equal(c.signal, null);
    store.run("UPDATE computers SET signal = 'https://signal.example.com' WHERE link_id = ?", "ab".repeat(32));
    assert.equal(store.computer("ab".repeat(32))!.signal, "https://signal.example.com");
    assert.ok(store.all<{ name: string }>("PRAGMA table_info(enrollments)").some((c) => c.name === "signal"));
    store.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
