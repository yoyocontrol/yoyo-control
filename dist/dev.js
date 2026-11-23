#!/usr/bin/env node
// `yoyo-account-dev`: a whole account server on this computer for trying things out (docs/ACCOUNT-LIB.md): the tests'
// stand-in sign-in system (it signs in its one user, "Alice", without asking for anything) and the account server in
// front of it, on loopback. Its data is in a folder you name (kept between runs) or a fresh temporary one.
//
//   yoyo-account-dev [--port 4490] [--data <dir>] [--join-keys 2] [--web <return URL>] [--namespace yoyo]
//                    [--app-redirect myapp://account]
//
// It prints the server's address and, with --join-keys, that many join keys for Alice's account (one line each:
// `join key: <ns>_jk_…`) — for a computer under test to join with. --web: a hosted web client's return address it
// takes (ACCOUNT_WEB_REDIRECTS; http on loopback, e.g. http://127.0.0.1:18800/account/return). --namespace: the wire
// names' (ACCOUNT_NAMESPACE). --app-redirect: where an app may be sent back (ACCOUNT_APP_REDIRECTS, comma-separated).
// Never reachable from another machine; never use it for anything real.
import { mkdtempSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runAdmin } from "./admin.js";
import { configFromEnv } from "./config.js";
import { KeyRing } from "./keys.js";
import { OidcClient } from "./oidc.js";
import { AccountService } from "./service.js";
import { Store } from "./store.js";
import { TestIdp } from "./testing/idp.js";
void (async () => {
    const arg = (name) => {
        const i = process.argv.indexOf(`--${name}`);
        return i > 0 ? process.argv[i + 1] : undefined;
    };
    const port = Number(arg("port") ?? 4490);
    const dir = arg("data") ?? mkdtempSync(join(tmpdir(), "yoyo-account-dev-"));
    const idp = await new TestIdp().start();
    const cfg = configFromEnv({
        ACCOUNT_OIDC_ISSUER: idp.issuer,
        ACCOUNT_OIDC_CLIENT_ID: idp.clientId,
        ACCOUNT_OIDC_CLIENT_SECRET: idp.clientSecret,
        ACCOUNT_PUBLIC_URL: `http://127.0.0.1:${port}`,
        ACCOUNT_IDP_NAME: "Test ID",
        ACCOUNT_SERVER_NAME: "Test account server",
        ACCOUNT_DATA_DIR: dir,
        ACCOUNT_PORT: String(port),
        ...(arg("web") ? { ACCOUNT_WEB_REDIRECTS: arg("web") } : {}),
        ...(arg("namespace") ? { ACCOUNT_NAMESPACE: arg("namespace") } : {}),
        ...(arg("app-redirect") ? { ACCOUNT_APP_REDIRECTS: arg("app-redirect") } : {}),
    });
    const store = new Store(join(dir, "account.db"), cfg.wire);
    const ring = KeyRing.load(join(dir, "keys.json"), cfg.wire);
    const svc = new AccountService({ cfg, store, idp: new OidcClient(cfg), ring });
    setInterval(() => void svc.deliverNotices().catch(() => { }), 2_000).unref();
    const server = createServer(svc.handle);
    await new Promise((r) => server.listen(port, "127.0.0.1", r));
    console.log(`account server: ${cfg.publicUrl}   (data: ${dir}; sign-in system: ${idp.issuer}, signs in "${idp.user.name}" by itself)`);
    const n = Number(arg("join-keys") ?? 0);
    if (n > 0) {
        const account = (await runAdmin(["add-account", idp.user.sub, idp.user.name ?? ""], { store, ring, issuer: cfg.issuer })).split(" ")[0];
        for (let i = 0; i < n; i++)
            console.log(`join key: ${(await runAdmin(["join-key", account], { store, ring })).split("\n")[0]}`);
    }
    for (const sig of ["SIGINT", "SIGTERM"]) {
        process.on(sig, () => {
            svc.releaseWaiters();
            server.close();
            void idp.stop().finally(() => process.exit(0));
        });
    }
})();
