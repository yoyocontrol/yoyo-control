#!/usr/bin/env node
// The admin commands' entry (admin.ts has them): the same database and keys as the running server.
//   yoyo-account-admin <command>   (same environment: ACCOUNT_DATA_DIR, ACCOUNT_NAMESPACE, the IdP's settings)
import { readFileSync } from "node:fs";
import { Wire } from "@yoyocontrol/account";
import { join } from "node:path";
import { AdminError, runAdmin } from "./admin.js";
import { configFromEnv } from "./config.js";
import { KeyRing } from "./keys.js";
import { OidcClient } from "./oidc.js";
import { Rechecker } from "./recheck.js";
import { Store } from "./store.js";
async function main() {
    const dir = process.env.ACCOUNT_DATA_DIR?.trim() || "/data";
    const wire = new Wire(process.env.ACCOUNT_NAMESPACE?.trim() || undefined);
    const store = new Store(join(dir, "account.db"), wire);
    const ring = KeyRing.load(join(dir, "keys.json"), wire);
    const recheck = async () => {
        const f = process.env.ACCOUNT_OIDC_CLIENT_SECRET_FILE?.trim();
        const cfg = configFromEnv(process.env, f ? readFileSync(f, "utf8") : undefined);
        // (an ended session's device goes on the revocation list here; the server pushes the notice from the outbox)
        return new Rechecker(store, new OidcClient(cfg), {
            onEnded: (s) => {
                if (s.device_id)
                    store.revoke(s.account_id, { devices: [s.device_id] }, Math.floor(Date.now() / 1000), Date.now());
            },
        });
    };
    try {
        const issuer = process.env.ACCOUNT_OIDC_ISSUER?.trim();
        console.log(await runAdmin(process.argv.slice(2), { store, ring, recheck, ...(issuer ? { issuer } : {}) }));
    }
    catch (e) {
        console.error(e instanceof AdminError ? e.message : e);
        process.exitCode = 1;
    }
    finally {
        store.close();
    }
}
void main();
