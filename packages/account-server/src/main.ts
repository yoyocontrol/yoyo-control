#!/usr/bin/env node
// The account server's process, `yoyo-account-server` (service.ts; docs/ACCOUNT-LIB.md): an HTTP server on loopback
// behind a TLS front (ACCOUNT_TRUST_PROXY=1 takes the client's address from its X-Forwarded-For). Its configuration
// is the environment (config.ts; the three that say which IdP, and the rest):
//   ACCOUNT_OIDC_ISSUER, ACCOUNT_OIDC_CLIENT_ID, ACCOUNT_OIDC_CLIENT_SECRET (or ACCOUNT_OIDC_CLIENT_SECRET_FILE)
//   ACCOUNT_APPLE_AUDIENCES  the apps' bundle ids: their native Sign in with Apple (beside the IdP, or without one)
//     ACCOUNT_APPLE_TEAM_ID + ACCOUNT_APPLE_KEY_ID + ACCOUNT_APPLE_KEY (or _FILE: the .p8)   to revoke a deleted
//     account's Apple grant
//   ACCOUNT_APPSTORE_BUNDLE_ID + ACCOUNT_APPSTORE_PRODUCTS   App Store subscriptions the apps report
//   ACCOUNT_PUBLIC_URL      its own public origin, https://account.example.com — needed
//   ACCOUNT_ALLOW           subs and @domains that may sign in (needed for an IdP anyone can sign up at, or ACCOUNT_OPEN=1)
//   ACCOUNT_IDP_RECHECK     1: re-check each session with the IdP hourly (default off)
//   ACCOUNT_APP_REDIRECTS, ACCOUNT_WEB_REDIRECTS, ACCOUNT_APPLE_APP_IDS, ACCOUNT_IDP_NAME, ACCOUNT_SERVER_NAME
//   ACCOUNT_DATA_DIR        account.db and keys.json (default /data)
//   ACCOUNT_NAMESPACE       the wire names' namespace (default yoyo; computers and services use the same one)
//   ACCOUNT_HOST / ACCOUNT_PORT, ACCOUNT_TRUST_PROXY
//   ACCOUNT_RELAY_URL + ACCOUNT_RELAY_TOKEN (or ACCOUNT_RELAY_TOKEN_FILE)   the relay the accounts' computers may use
//   ACCOUNT_PUSH_URL        the push relay that takes this server's service tokens
//   ACCOUNT_SPEECH_URL      the speech services' front that takes them (hearing and speaking)
//   ACCOUNT_SIGNAL_URL + ACCOUNT_SIGNAL_KEY (or ACCOUNT_SIGNAL_KEY_FILE)   the signaling service they wait for browsers at
import { readFileSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { join } from "node:path";
import { ConfigError, configFromEnv } from "./config.js";
import { KeyRing } from "./keys.js";
import { OidcClient } from "./oidc.js";
import { Rechecker } from "./recheck.js";
import { AccountService } from "./service.js";
import { Store } from "./store.js";

const env = process.env;
let cfg;
try {
  const f = env.ACCOUNT_OIDC_CLIENT_SECRET_FILE?.trim();
  // (a file read again when it changed: a new relay token or signaling key — deploy.sh writes the files — needs no
  // restart; a file that cannot be read keeps the last one)
  const watched = (path: string | undefined) => {
    if (!path) return undefined;
    let value: string | null = null;
    let at = -1;
    return () => {
      try {
        const m = statSync(path).mtimeMs;
        if (m !== at) {
          value = readFileSync(path, "utf8");
          at = m;
        }
      } catch {
        // kept as it was
      }
      return value;
    };
  };
  const appleKey = env.ACCOUNT_APPLE_KEY_FILE?.trim();
  cfg = configFromEnv(env, f ? readFileSync(f, "utf8") : undefined, watched(env.ACCOUNT_RELAY_TOKEN_FILE?.trim()), watched(env.ACCOUNT_SIGNAL_KEY_FILE?.trim()), appleKey ? readFileSync(appleKey, "utf8") : undefined);
} catch (e) {
  console.error(`[account] ${e instanceof ConfigError ? e.message : String(e)}`);
  process.exit(1);
}
const store = new Store(join(cfg.dataDir, "account.db"), cfg.wire);
const ring = KeyRing.load(join(cfg.dataDir, "keys.json"), cfg.wire);
const idp = cfg.oidc ? new OidcClient(cfg) : null;
const service = new AccountService({ cfg, store, idp, ring });
// (the IdP may be down at start: sign-ins wait for it, everything else works without it)
idp?.discovery().then(
  (d) => console.log(`[account] IdP ${d.issuer}: PKCE S256, ${(d.token_endpoint_auth_methods_supported ?? ["client_secret_basic"]).includes("client_secret_basic") ? "client_secret_basic" : "client_secret_post"}`),
  (e: Error) => console.warn(`[account] IdP discovery failed (sign-ins wait for it): ${e.message.slice(0, 160)}`),
);
const recheck = idp ? new Rechecker(store, idp, { onEnded: (s) => service.sessionEnded(s) }) : null;
if (cfg.recheck) recheck?.start();
// revocations queued by admin commands (another process) reach the waiting computers within these 5 s; the old rows
const timers = [
  setInterval(() => void service.deliverNotices().catch(() => {}), 5_000),
  setInterval(() => store.sweep(Date.now()), 10 * 60_000),
];
for (const t of timers) t.unref();
store.sweep(Date.now());

const server = createServer(service.handle);
// (requests are small and quick: a slow sender is cut; the slowest is a callback's code exchange, 10 s at most)
server.requestTimeout = 20_000;
server.headersTimeout = 10_000;
server.listen(cfg.port, cfg.host, () =>
  console.log(`[account] listening on http://${cfg.host}:${cfg.port} as ${cfg.publicUrl}; ${cfg.oidc ? `IdP ${cfg.issuer}` : "no IdP"}${cfg.apple ? `; Sign in with Apple for ${cfg.apple.audiences.join(", ")}${cfg.apple.client ? " (grants revoked on deletion)" : ""}` : ""}${cfg.allow ? " (allow-list)" : cfg.open ? " (open on purpose)" : ""}${cfg.appstore ? "; App Store purchases" : ""}; re-check ${cfg.recheck ? "hourly" : "off"}`),
);
for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, () => {
    recheck?.stop();
    service.releaseWaiters();
    server.close();
    setTimeout(() => {
      store.close();
      process.exit(0);
    }, 500).unref();
  });
}
