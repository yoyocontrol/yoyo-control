# @yoyocontrol/account

A computer's half of an account (`docs/ACCOUNT-LIB.md`): join an account server, pin its owner and signing keys, take
the tickets it signs for devices, follow its signed revocation list, and keep what the account lends the computer.
Also what a service checks of the account server's service tokens. Node ≥ 22, ESM, typed; depends on `jose`.

```js
import { AccountMember } from "@yoyocontrol/account";

const member = new AccountMember({
  file: "/path/to/account.json",                     // 0600: the membership (server, keys, owner, revocations)
  self: () => ({ linkId, name: "Study PC", relays, direct, origins: [], info: { platform: "linux" } }),   // info: for your clients
  sign: (id, text) => (id === linkId ? signWithLinkKey(text) : null),   // base64url Ed25519
  namespace: "yoyo",                                  // the account server's (ACCOUNT_NAMESPACE)
  onChange: () => dropTokensThatNoLongerCount(),      // a new revocation list, or out of the account
  onServices: () => useWhatTheAccountLends(member.services()),
});
member.start();

await member.joinWithKey("https://account.example.com", joinKey);   // or startJoin() / confirmJoin()
const claims = await member.redeem(ticketFromADevice);              // then hand out this computer's own token
member.ticketValid({ acc: claims.sub, dev: claims.dev.id, tat: claims.iat, sx: claims.sx });
```

- **Joining**: `startJoin(server, expect?)` shows a code somebody signed in approves (`current()` / `status().pending`),
  `confirmJoin()` is the person at the computer agreeing to who approved; `joinWithKey` is the admin's join key. The
  owner is pinned: nothing the server says later changes it; `leave()` is the only way out (or the signed list).
- **Tickets**: `redeem(jwt)` checks the signature against the pinned keys (a new key only through endorsements from a
  pinned one), the issuer, this computer, the owner, replay, and the revocation list; what token the computer then
  gives the device is its own business. `ticketValid` says whether such a token still counts.
- **Revocations**: the loop waits on the server's signed list (25 s requests); a removed device is out within seconds.
- **Services**: `services()` is what the server lends, by the operator's names (`{ relay: { url, token }, push: { url,
  token, expiresAt } … }`); entries with `expiresAt` are asked for again before they run out. `validServices` keeps
  only whole entries; `options.validServices` adds a caller's own rules.
- **Wire names**: everything on the wire (`typ`s, signed texts, token prefixes, header names) comes from `namespace`
  (`Wire`); the server, its computers and its services must agree on it.
- **Services' side**: `ServiceKeys` (the account server's keys, kept and refreshed) and `verifyServiceToken`.
