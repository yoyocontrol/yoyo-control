// This computer in its person's account (docs/ACCOUNT.md, the library: docs/ACCOUNT-LIB.md): @yoyocontrol/account's
// AccountMember (vendored in vendor/account) with remote access's devices and link.
//
// - Joining: a phone paired here (with a code) that is signed in hands this computer a one-use join key over its link
//   (`POST /account/join { server, key }`); or on this computer, `yoyo account join --key <key> <server>` (an admin's
//   key) or `yoyo account join <server>` (a code the account's phone approves, then `yoyo account confirm`). What it
//   leaves is `<home>/account.json` (0600): the account server, its keys, the owner — pinned.
// - Coming in: a device of the account says `hello.credential = "Ticket <ticket>"` (the account server signed it for
//   this computer); taken, it gets this computer's own token the way a pairing does (`DeviceStore.admit`), ending with
//   its sign-in and gone when the account's signed list says so (`prune`).
// - What it says of itself to the account server: its Link id, name, addresses, and for the app (`info`) its server
//   id, platform, identity fingerprint and Link binding — what a phone that never paired here needs to dial it.
// - Signed with the link key (`<home>/link-key`, the raw Ed25519 seed the link's endpoint uses).
import { createPrivateKey, createPublicKey, sign } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { AccountMember, JoinError, TICKET_SESSION_MAX_S, TicketError } from "./vendor/account/index.js";

/** PKCS#8 of an Ed25519 private key, up to its 32-byte seed. */
const ED25519_PKCS8 = Buffer.from("302e020100300506032b657004220420", "hex");

export class RemoteAccount {
  /** `remote`: the RemoteAccess (its devices, link, settings, name). `fetch`, `timing`: tests. */
  constructor({ remote, log = () => {}, fetch, timing }) {
    this.remote = remote;
    this.log = log;
    this.key = null;
    this.member = new AccountMember({
      file: join(remote.home, "account.json"),
      self: () => this.self(),
      sign: (id, text) => this.sign(id, text),
      log,
      onChange: () => this.changed(),
      ...(fetch ? { fetch } : {}),
      ...(timing ? { timing } : {}),
    });
  }

  start() {
    this.member.start();
    // (a sign-in that ran out is no revocation: its tokens go on the hour)
    this.sweep = setInterval(() => this.changed(), 3600_000);
    this.sweep.unref?.();
  }

  stop() {
    clearInterval(this.sweep);
    this.member.stop();
  }

  /** In an account (or one whose file cannot be read): the link must listen for its devices. */
  get joined() {
    return this.member.current() !== null;
  }

  /** The link key: its private key and Link id, read once (null: no key yet — the link never ran). */
  linkKey() {
    if (this.key) return this.key;
    try {
      const seed = readFileSync(join(this.remote.home, "link-key"));
      if (seed.length !== 32) return null;
      const priv = createPrivateKey({ key: Buffer.concat([ED25519_PKCS8, seed]), format: "der", type: "pkcs8" });
      const x = createPublicKey(priv).export({ format: "jwk" }).x;
      this.key = { priv, id: Buffer.from(x, "base64url").toString("hex") };
      return this.key;
    } catch {
      return null;
    }
  }

  sign(id, text) {
    const k = this.linkKey();
    if (!k || id !== k.id) return null;
    return sign(null, Buffer.from(text, "utf8"), k.priv).toString("base64url");
  }

  /** What this computer says of itself to the account server (null: no link key yet). */
  self() {
    const k = this.linkKey();
    if (!k) return null;
    const r = this.remote;
    const j = r.link?.json() ?? null;
    return {
      linkId: k.id,
      name: r.name,
      relays: j?.relays ?? r.linkRelays.map((u) => u.replace(/\?.*$/, "")),
      direct: j?.direct ?? [],
      origins: [],
      info: {
        id: r.settings.serverId,
        platform: r.svc.platform?.id ?? "linux",
        ...(r.identity ? { fp: r.identity.keyFingerprint } : {}),
        ...(j ? { link: { id: j.id, key: j.key, sig: j.sig, port: j.port } } : {}),
      },
    };
  }

  /** The list changed, or this computer left: tokens that no longer count go; the listener follows. */
  changed() {
    const gone = this.remote.devices.prune((g) => this.member.ticketValid(g));
    if (gone) this.log(`remote: ${gone} device(s) of the account no longer let in`);
    void this.remote.update();
  }

  /**
   * `hello.credential = "Ticket <jwt>"`: the ticket taken once, the device let in with a token of this computer's own
   * (`welcome.principal.token`, as a pairing hands it). `{ ok, principal } | { ok: false, code, message }`.
   */
  async redeem(jwt, r, source) {
    let claims;
    try {
      claims = await this.member.redeem(jwt);
    } catch (err) {
      const code = err instanceof TicketError ? err.code : "error";
      this.log(`link: a ticket refused from ${source} (${code})`);
      return { ok: false, code: code === "busy" ? "busy" : "unauthorized", message: `the ticket was refused (${code})` };
    }
    const id = r.hello?.device?.id ?? "";
    const name = r.hello?.device?.name || claims.dev.name;
    try {
      const token = this.remote.devices.admit(id, name, r.clientKey, { acc: claims.sub, dev: claims.dev.id, tat: claims.iat, sx: claims.sx ?? claims.iat + TICKET_SESSION_MAX_S });
      this.log(`link: ${name} came in by its account (from ${source})`);
      const s = this.remote;
      return { ok: true, principal: { device: { id, name }, token, server: { id: s.settings.serverId, name: s.name, platform: s.svc.platform?.id ?? "linux" } } };
    } catch (err) {
      if (err?.kind === "full") return { ok: false, code: "busy", message: "too many devices; remove one first" };
      return { ok: false, code: "unauthorized", message: err.message };
    }
  }

  /** `GET /account` and the status's `account`: the membership (null: in none), a join under way. */
  json() {
    const st = this.member.status();
    return {
      account: st.member ? { id: st.member.account.id, name: st.member.account.name, server: st.member.server, joinedAt: st.member.joinedAt, disabled: st.member.disabled } : null,
      ...(st.pending ? { pending: st.pending } : {}),
      ...(st.sync?.error ? { error: st.sync.error } : {}),
    };
  }

  /** `POST /account/join { server, key }` (a paired phone) or the admin socket's (also `{ server }` alone: a join code). */
  async join(body) {
    try {
      if (typeof body?.key === "string") await this.member.joinWithKey(body.server, body.key);
      else await this.member.startJoin(body?.server, body?.expect ?? null);
      void this.remote.update();
      return { status: 200, json: this.json() };
    } catch (err) {
      return { status: err instanceof JoinError ? err.status : 500, json: { error: err.message } };
    }
  }

  async confirm() {
    try {
      await this.member.confirmJoin();
      void this.remote.update();
      return { status: 200, json: this.json() };
    } catch (err) {
      return { status: err instanceof JoinError ? err.status : 500, json: { error: err.message } };
    }
  }

  async leave() {
    await this.member.cancelJoin();
    const left = await this.member.leave();
    return { status: 200, json: { ...this.json(), left } };
  }
}
