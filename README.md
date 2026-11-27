# @yoyocontrol/account-web

A browser's side of an account server (`@yoyocontrol/account-server`, `docs/ACCOUNT-LIB.md`): sign in with the
account (code + PKCE through the server's `/v1/signin`), a session bound to an Ed25519 device key made in this browser
and never extractable (every request signed: `<ns>-proof`), the account's computers, and a ticket into each (a Link
`hello`'s `Ticket <ticket>`). No service address is built in: the page names its account server and its return address
(which the server lists in `ACCOUNT_WEB_REDIRECTS`).

```ts
import { beginSignIn, finishSignIn, idbKeep, isSignInReturn, pendingKeep, resumeSignIn } from "@yoyocontrol/account-web";

const keep = idbKeep();
const pending = pendingKeep();
// the button
const { url, pending: p } = await beginSignIn("https://account.example.com", "https://app.example.com/account/return");
pending.set(p);
location.assign(url);
// the return page
if (isSignInReturn(location.href)) {
  const client = await finishSignIn(location.href, pending.get(), { keep, deviceName: "Safari on Mac" });
  pending.set(null);
}
// any visit
const client = await resumeSignIn({ keep });
const computers = await client?.computers();
const ticket = await client?.ticket(computers![0]!.linkId);
```

Sign-in by QR code: the page shows a code another device of the account (signed in already) scans and approves; the
session it then gets is bound to this browser's key all the same. A signed-in page approves others' codes too.

```ts
const qr = await beginQrSignIn("https://account.example.com", { keep, deviceName: "Chrome on Windows" });
show(qrSignInLink("https://app.example.com/login", qr.code), qr.userCode);   // the QR code and its text
const client = await qr.wait({ signal });                                     // approved: signed in, kept
// on a signed-in page that opened https://app.example.com/login#<code>
const what = await client.lookupSignIn(signInCode(location.hash));            // which device, from where, when
await client.approveSignIn(what.code);                                         // or declineSignIn
```

`namespace` (default `yoyo`) is the account server's `ACCOUNT_NAMESPACE`.
