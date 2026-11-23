# @yoyocontrol/account-server

An account server (`docs/ACCOUNT-LIB.md`): people sign in through an OpenID Connect provider; the server keeps which
computers and devices are each account's, signs tickets that let a device into one computer, signs each account's
revocation list, lends the accounts' computers whatever the operator set up (a relay, a push relay…), and has the
admin's commands. It never holds a computer's own tokens and is not on the data path. Node ≥ 22.13 (`node:sqlite`).

```sh
ACCOUNT_OIDC_ISSUER=https://id.example.com ACCOUNT_OIDC_CLIENT_ID=… ACCOUNT_OIDC_CLIENT_SECRET_FILE=… \
ACCOUNT_PUBLIC_URL=https://account.example.com ACCOUNT_APP_REDIRECTS=myapp://account \
ACCOUNT_DATA_DIR=/data yoyo-account-server          # listens on 127.0.0.1:4490 behind a TLS front
yoyo-account-admin accounts                          # the same environment: list, join-key, disable, rotate-key…
```

All settings are in `src/main.ts`'s header (`config.ts` reads them); `ACCOUNT_NAMESPACE` names everything on the wire
(default `yoyo`; computers use the same with `@yoyocontrol/account`). An IdP anyone can sign up at needs
`ACCOUNT_ALLOW` (subs or `@domain`) or `ACCOUNT_OPEN=1`.

Embedding it instead: build an `AccountConfig` (its `services` are any you lend: `fixed` values, or `token` ones that
get each computer a day-long service token), then

```js
import { AccountService, KeyRing, OidcClient, Store } from "@yoyocontrol/account-server";
const store = new Store("/data/account.db", cfg.wire), ring = KeyRing.load("/data/keys.json", cfg.wire);
const svc = new AccountService({ cfg, store, ring, idp: new OidcClient(cfg) });
http.createServer(svc.handle).listen(cfg.port, cfg.host);
```

Testing against it: `@yoyocontrol/account-server/testing` has a stand-in OpenID provider (`TestIdp`) and a whole server on
loopback (`harness()`, with `appSignIn`, `joinComputer`, `computerCall`, `linkKey`…; `h.cfg.wire` is its namespace).
Trying things out: `yoyo-account-dev [--port 4490] [--data <dir>] [--join-keys 2] [--namespace …] [--app-redirect …]`
runs one in front of the stand-in provider, which signs in "Alice" by itself — never for anything real.

This package's tests: `npm test` (the computer half from `@yoyocontrol/account` against a real server among them);
`scripts/e2e-local-idp.ts` walks sign-in, joining, tickets, revocation and the re-check against a local IdP.
