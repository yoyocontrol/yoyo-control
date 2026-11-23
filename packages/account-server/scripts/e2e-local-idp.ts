// End to end against a real, local IdP (docs/ACCOUNT-LIB.md): starts the account server in this
// process on loopback (its data in a fresh temporary directory), then plays the phone's sign-in sheet (a cookie jar
// and the IdP's own login form: the first form with a password field), the app's code exchange, a computer's join
// (with its own Link key and confirmation), a ticket checked the way a computer checks it, the revocation list, the
// IdP re-check, and — when E2E_REVOKE_CMD is given — the IdP revoking the user, after which the next re-check ends that
// device session and nothing else.
//
//   ACCOUNT_OIDC_ISSUER=… ACCOUNT_OIDC_CLIENT_ID=… ACCOUNT_OIDC_CLIENT_SECRET=… E2E_USER=… E2E_PASSWORD=… \
//   [ACCOUNT_PUBLIC_URL=http://127.0.0.1:4490] [E2E_REVOKE_CMD='…'] node --import tsx packages/account-server/scripts/e2e-local-idp.ts
//
// It never prints a token, a code or the password: only steps, statuses, ids and timings. Never point it at an IdP
// whose users are real people's.
import { execSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { configFromEnv } from "../src/config.js";
import { KeyRing } from "../src/keys.js";
import { OidcClient } from "../src/oidc.js";
import { Rechecker } from "../src/recheck.js";
import { AccountService } from "../src/service.js";
import { Store } from "../src/store.js";
import { linkKey } from "../src/testing/harness.js";
import { ReplayCache, verifyRevocationList, verifyTicket } from "../src/ticket.js";

void (async () => {
const env = process.env;
const user = env.E2E_USER ?? "";
const password = env.E2E_PASSWORD ?? "";
if (!user || !password) throw new Error("E2E_USER and E2E_PASSWORD (a throwaway user of a local IdP)");
const port = Number(env.E2E_PORT ?? 4490);
const cfg = configFromEnv({ ACCOUNT_PUBLIC_URL: `http://127.0.0.1:${port}`, ACCOUNT_IDP_RECHECK: "1", ACCOUNT_APP_REDIRECTS: "example://account", ...env });
const dir = mkdtempSync(join(tmpdir(), "acct-e2e-"));
const store = new Store(join(dir, "account.db"), cfg.wire);
const ring = KeyRing.load(join(dir, "keys.json"), cfg.wire);
const logs: string[] = [];
const idp = new OidcClient(cfg);
const svc = new AccountService({ cfg, store, idp, ring, log: (l) => logs.push(l) });
const recheck = new Rechecker(store, idp, { log: (l) => logs.push(l), onEnded: (s) => svc.sessionEnded(s) });
const server = createServer(svc.handle);
await new Promise<void>((r) => server.listen(port, "127.0.0.1", r));
const ACCT = cfg.publicUrl;
const step = (s: string, d: Record<string, unknown> = {}) => console.log(JSON.stringify({ step: s, ...d }));
let failed = 0;
const check = (ok: boolean, what: string) => {
  if (!ok) failed++;
  console.log(`${ok ? "ok  " : "FAIL"} ${what}`);
};

// ---------------------------------------------------------------- the sign-in sheet: a cookie jar and the IdP's form
const jar = new Map<string, Map<string, string>>();
function cookieHeader(u: URL) {
  return [...(jar.get(u.host) ?? new Map())].map(([k, v]) => `${k}=${v}`).join("; ");
}
function store_(u: URL, res: Response) {
  for (const sc of res.headers.getSetCookie()) {
    const [kv, ...attrs] = sc.split(";");
    const i = kv!.indexOf("=");
    const k = kv!.slice(0, i).trim();
    const v = kv!.slice(i + 1).trim();
    const m = jar.get(u.host) ?? new Map<string, string>();
    if (!v || attrs.some((a) => /max-age=0\b/i.test(a))) m.delete(k);
    else m.set(k, v);
    jar.set(u.host, m);
  }
}
async function sheet(start: string, ephemeral: boolean): Promise<{ final: URL; passwordPages: number; ms: number; hops: number }> {
  if (ephemeral) jar.clear();
  const t0 = performance.now();
  let url = new URL(start);
  let init: RequestInit = {};
  let passwordPages = 0;
  for (let hop = 0; hop < 25; hop++) {
    const res = await fetch(url, { ...init, redirect: "manual", headers: { ...((init.headers as Record<string, string>) ?? {}), cookie: cookieHeader(url) } });
    store_(url, res);
    init = {};
    const loc = res.headers.get("location");
    if (loc) {
      const next = new URL(loc, url);
      if (next.protocol === "example:") return { final: next, passwordPages, ms: Math.round(performance.now() - t0), hops: hop + 1 };
      url = next;
      continue;
    }
    const html = await res.text();
    const forms = html.match(/<form[\s\S]*?<\/form>/gi) ?? [];
    const f = forms.find((x) => /type="?password/i.test(x));
    if (!f) throw new Error(`stuck at ${url.host}${url.pathname} (${res.status})`);
    passwordPages++;
    const action = new URL((/action="([^"]*)"/i.exec(f)?.[1] ?? url.toString()).replace(/&amp;/g, "&"), url);
    const body = new URLSearchParams();
    for (const m of f.matchAll(/<input[^>]*>/gi)) {
      const name = /name="([^"]*)"/i.exec(m[0])?.[1];
      if (!name) continue;
      const type = (/type="([^"]*)"/i.exec(m[0])?.[1] ?? "text").toLowerCase();
      const value = (/value="([^"]*)"/i.exec(m[0])?.[1] ?? "").replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#39;/g, "'");
      if (type === "password") body.set(name, password);
      else if (/user|login|email|name/i.test(name) && type !== "hidden") body.set(name, user);
      else if (type !== "checkbox" && type !== "submit") body.set(name, value);
    }
    url = action;
    init = { method: "POST", body, headers: { "content-type": "application/x-www-form-urlencoded" } };
  }
  throw new Error("too many hops");
}
async function appSignIn(ephemeral: boolean, deviceName: string) {
  const verifier = randomBytes(32).toString("base64url");
  const challenge = createHash("sha256").update(verifier).digest("base64url");
  const s = await sheet(`${ACCT}/v1/signin?${new URLSearchParams({ redirect_uri: "example://account", state: "e2e", code_challenge: challenge, code_challenge_method: "S256" })}`, ephemeral);
  const code = s.final.searchParams.get("code");
  if (!code) throw new Error(`sign-in came back with ${s.final.searchParams.get("error")}`);
  const t = await fetch(`${ACCT}/v1/token`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ grant_type: "authorization_code", code, code_verifier: verifier, device: { name: deviceName, platform: "ios", key: randomBytes(32).toString("base64url") } }) });
  const b = (await t.json()) as { session: string; account: { id: string; name: string }; device: { id: string } };
  return { ...b, passwordPages: s.passwordPages, ms: s.ms, hops: s.hops };
}
const auth = (s: string) => ({ authorization: `Bearer ${s}` });
const postJson = (path: string, body: unknown, headers: Record<string, string> = {}) => fetch(`${ACCT}${path}`, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });

try {
  const d = await idp.discovery();
  step("discovery", { issuer: d.issuer, scope: idp.scopes(d), authMethods: d.token_endpoint_auth_methods_supported ?? null, endSession: !!d.end_session_endpoint });

  // 1. "Sign in" (shared browser session): the password once
  const phone = await appSignIn(false, "E2E phone");
  step("sign in (shared session)", { passwordPages: phone.passwordPages, hops: phone.hops, ms: phone.ms, account: phone.account.id, name: phone.account.name });
  check(phone.passwordPages === 1, "first sign-in asked for the password once");
  const me = (await (await fetch(`${ACCT}/v1/me`, { headers: auth(phone.session) })).json()) as { account: { iss: string; sub: string } };
  check(me.account.iss === cfg.issuer, "account keyed by the configured issuer");
  // 2. the same sheet again: does the IdP's browser session spare the password?
  const ipad = await appSignIn(false, "E2E iPad");
  step("sign in again (shared session)", { passwordPages: ipad.passwordPages, ms: ipad.ms });
  check(ipad.account.id === phone.account.id, "the same iss + sub is the same account");
  // 3. "Use another account" (ephemeral: an empty jar) always asks
  const other = await appSignIn(true, "E2E other");
  step("use another account (ephemeral)", { passwordPages: other.passwordPages, ms: other.ms });
  check(other.passwordPages === 1, "an ephemeral session asks for the password");

  // 4. a computer joins: enroll, the phone approves, the computer confirms with its Link key
  const k = linkKey();
  const t0 = performance.now();
  const e = (await (await postJson("/v1/computers/enroll", { linkId: k.id, name: "E2E computer", relays: ["https://relay.example.com/?token=e2e"] })).json()) as { device_code: string; user_code: string; qr: string };
  const ap = await postJson("/v1/computers/approve", { user_code: e.user_code.toLowerCase() }, auth(phone.session));
  check(ap.status === 200, "the phone approved the join code");
  const poll = (await (await postJson("/v1/computers/poll", { device_code: e.device_code })).json()) as { claimant: { account: { id: string; name: string } }; server: { keys: never[] } };
  check(poll.claimant.account.id === phone.account.id, "the computer sees who approved before it confirms");
  const cf = await postJson("/v1/computers/confirm", { device_code: e.device_code, proof: k.sign(cfg.wire.joinProofText(ACCT, k.id, phone.account.id, e.device_code)) });
  check(cf.status === 200, "confirmed on the computer with its Link key");
  step("join", { ms: Math.round(performance.now() - t0), qr: e.qr.replace(/\/C\/[A-Z]+$/, "/C/<code>") });
  const list = (await (await fetch(`${ACCT}/v1/computers`, { headers: auth(ipad.session) })).json()) as { computers: { linkId: string }[] };
  check(list.computers.some((c) => c.linkId === k.id), "another device of the account sees the computer at once");

  // 5. a ticket, checked as the computer checks it; a replay and the wrong computer refused
  const t = (await (await postJson("/v1/tickets", { computer: k.id }, auth(ipad.session))).json()) as { ticket: string };
  const replay = new ReplayCache();
  const claims = await verifyTicket(t.ticket, { issuer: ACCT, keys: poll.server.keys, owner: phone.account.id, linkId: k.id, replay });
  check(claims.dev.id === ipad.device.id, "the ticket names the device");
  check(await verifyTicket(t.ticket, { issuer: ACCT, keys: poll.server.keys, owner: phone.account.id, linkId: k.id, replay }).then(() => false, () => true), "a replayed ticket is refused");
  check(await verifyTicket(t.ticket, { issuer: ACCT, keys: poll.server.keys, owner: phone.account.id, linkId: linkKey().id, replay: new ReplayCache() }).then(() => false, () => true), "a ticket for this computer is refused on another");

  // 6. the IdP re-check with the refresh tokens this IdP gave
  const r1 = await recheck.runDue();
  step("re-check", r1);
  check(r1.ok >= 1 && r1.ended === 0, "the IdP stands by the sign-ins (rotated tokens stored)");
  // a second round right away: nothing is due; forcing one per session rotates again without reuse trouble
  for (const s of store.all<{ id: string }>("SELECT id FROM sessions WHERE ended_at IS NULL AND idp_refresh IS NOT NULL")) check((await recheck.check(s.id)) === "ok", `second refresh of ${s.id.slice(0, 8)}… ok`);

  // 7. a device removed: on the list a computer pulls
  await fetch(`${ACCT}/v1/devices/${other.device.id}`, { method: "DELETE", headers: auth(phone.session) });
  const ts = Math.floor(Date.now() / 1000);
  const path = `/v1/computer/revocations?account=${phone.account.id}`;
  const sig = k.sign(cfg.wire.computerProofText(ACCT, "GET", path, ts, createHash("sha256").update("").digest("base64url")));
  const rl = (await (await fetch(`${ACCT}${path}`, { headers: { authorization: `${cfg.wire.linkScheme} ${k.id}.${ts}.${sig}` } })).json()) as { list: string };
  const state = await verifyRevocationList(rl.list, { issuer: ACCT, keys: poll.server.keys, owner: phone.account.id, minVersion: 0 });
  check(state.devices.some((x) => x.id === other.device.id), "the removed device is on the signed revocation list");

  // 8. the IdP revokes the user: each session ends at its next check, the account and the computer stay
  if (env.E2E_REVOKE_CMD) {
    execSync(env.E2E_REVOKE_CMD, { stdio: "ignore" });
    for (const s of store.all<{ id: string }>("SELECT id FROM sessions WHERE ended_at IS NULL AND idp_refresh IS NOT NULL")) await recheck.check(s.id);
    const meAfter = await fetch(`${ACCT}/v1/me`, { headers: auth(phone.session) });
    check(meAfter.status === 401, "after the IdP revoked the user, the phone's session ended (invalid_grant)");
    check(store.computersOf(phone.account.id).length === 1 && !!store.account(phone.account.id), "the account and its computer stay");
    step("after IdP revoke", { ended: store.all("SELECT id FROM sessions WHERE end_reason = 'idp_invalid_grant'").length });
  }

  // 9. the logs carry no secret
  const secrets = [phone.session, ipad.session, other.session, password, t.ticket, e.device_code, ...store.all<{ idp_refresh: string }>("SELECT idp_refresh FROM sessions WHERE idp_refresh IS NOT NULL").map((r) => r.idp_refresh)];
  check(!logs.some((l) => secrets.some((s) => s && l.includes(s))), `no secret in the ${logs.length} log lines`);
} catch (e) {
  failed++;
  console.log(`FAIL ${(e as Error).message}`);
} finally {
  server.close();
  store.close();
  rmSync(dir, { recursive: true, force: true });
}
console.log(failed ? `${failed} failed` : "all passed");
process.exit(failed ? 1 : 0);
})();
