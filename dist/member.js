// A computer in a person's account at an account server (docs/ACCOUNT-LIB.md): the account comes from a sign-in
// system, and the account server says which computers and devices are that account's.
//
// - Joining: with a code somebody signed in approves (the server shows who; this computer confirms it — the person at
//   it, or by itself when it was told which account to expect), or with a join key the server's admin made. Either way
//   the command comes from this computer itself. What joining leaves here is one file (0600, `file`): the server's
//   address and signing keys, the owner — pinned: nothing the server says later changes who that is — and the newest
//   revocation list.
// - Coming in: a device brings a ticket the server signed for it and this computer (`redeem`) and gets this computer's
//   own token, as it would for a pairing code: what that token is and where it is kept stays the server's own business.
//   It names the account, the device and when the ticket was made; it counts while this computer is in that account
//   and the device is not revoked (`ticketValid`).
// - Revocations: this computer asks the server for its account's signed list and waits on it (a request the server
//   answers when the list changes, 25 s at most), so a removed device is out within seconds while the server is up;
//   when the server is not reachable everything already signed in goes on (and nothing new is revoked anyway).
// - Services: what the account brings this computer (a relay, a push relay's token…), by name; the library does not
//   know what they are (`services()`).
// - Leaving: from this computer, or when the signed list says the account's person took it out.
import { createHash } from "node:crypto";
import { chmodSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { cleanJwk, DEFAULT_WIRE, kidOf, ReplayCache, RevocationView, TicketError, verifyKeyChain, verifyRevocationList, verifyTicket, Wire, } from "./protocol.js";
const LINK_ID_RE = /^[0-9a-f]{64}$/;
const ACCOUNT_ID_RE = /^a_[A-Za-z0-9_-]{10,40}$/;
/** An https origin a URL parser takes too (its port in range): no path, query or fragment. */
export const validOrigin = (u) => {
    if (typeof u !== "string" || !/^https:\/\/[A-Za-z0-9.-]+(:[0-9]{1,5})?$/.test(u))
        return false;
    try {
        new URL(u);
        return true;
    }
    catch {
        return false;
    }
};
const loopback = (origin) => /^https?:\/\/(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/.test(origin);
const SERVICE_NAME_RE = /^[a-z][a-z0-9-]{0,31}$/;
const FIELD_NAME_RE = /^[A-Za-z][A-Za-z0-9_]{0,31}$/;
/**
 * The server's answer (or what the file kept) as services: only what is whole. A name is 1-32 of [a-z0-9-]; each is an
 * object whose `url` is an https origin — or, from an account server on this computer itself (tests, a local run), one
 * on loopback: a server elsewhere never points this computer's requests at its own loopback — and whose other fields
 * are short printable strings or (`expiresAt`) a time. At most 16; anything else is left out. What a service's own
 * rules are (which needs which) is the caller's: `AccountMemberOptions.validServices`.
 */
export function validServices(j, server) {
    const out = {};
    if (!j || typeof j !== "object" || Array.isArray(j))
        return out;
    for (const [name, v] of Object.entries(j).slice(0, 16)) {
        if (!SERVICE_NAME_RE.test(name) || !v || typeof v !== "object" || Array.isArray(v))
            continue;
        const o = v;
        const url = o.url;
        if (!(validOrigin(url) || (loopback(server) && typeof url === "string" && loopback(url) && serverOrigin(url) === url)))
            continue;
        const entry = { url };
        let whole = true;
        for (const [k, x] of Object.entries(o).slice(0, 16)) {
            if (k === "url")
                continue;
            if (!FIELD_NAME_RE.test(k))
                continue;
            if (k === "expiresAt") {
                if (typeof x === "number" && Number.isFinite(x))
                    entry.expiresAt = x;
                else
                    whole = false;
            }
            else if (typeof x === "string" && x.length <= 2048 && /^[\x21-\x7e]*$/.test(x))
                entry[k] = x;
            else if (x !== null && x !== undefined)
                whole = false;
        }
        if (whole)
            out[name] = entry;
    }
    return out;
}
/** How long a ticket's token may count when its ticket names no end of the device's session (an older account server):
 *  the longest a session lives there. */
export const TICKET_SESSION_MAX_S = 90 * 86_400;
export class JoinError extends Error {
    status;
    constructor(status, message) {
        super(message);
        this.status = status;
    }
}
const sha256 = (s) => createHash("sha256").update(s, "utf8").digest("base64url");
const short = (id) => `${id.slice(0, 10)}…`;
/** An account server's address as it is kept and compared: an https origin (http only on loopback). */
export function serverOrigin(raw) {
    if (typeof raw !== "string" || raw.length > 256)
        return null;
    let u;
    try {
        u = new URL(raw.trim());
    }
    catch {
        return null;
    }
    const local = u.hostname === "localhost" || u.hostname === "127.0.0.1" || u.hostname === "[::1]";
    if (u.protocol !== "https:" && !(u.protocol === "http:" && local))
        return null;
    if (u.username || u.password || u.search || u.hash || (u.pathname !== "/" && u.pathname !== ""))
        return null;
    return u.origin;
}
function validRecord(j, wire, keep) {
    const r = j;
    if (!r || typeof r !== "object" || r.v !== 1 || serverOrigin(r.server) !== r.server || !Array.isArray(r.keys))
        return null;
    const keys = r.keys.map((k) => cleanJwk(k, wire)).filter((k) => !!k);
    if (!keys.length || typeof r.account?.id !== "string" || !ACCOUNT_ID_RE.test(r.account.id) || typeof r.linkId !== "string" || !LINK_ID_RE.test(r.linkId))
        return null;
    const rv = r.revocations;
    const devices = Array.isArray(rv?.devices) ? rv.devices.filter((d) => d && typeof d.id === "string" && Number.isInteger(d.at)).map((d) => ({ id: d.id, at: d.at })) : [];
    return {
        v: 1, server: r.server, keys, account: { id: r.account.id, name: typeof r.account.name === "string" ? r.account.name : null }, linkId: r.linkId,
        joinedAt: typeof r.joinedAt === "number" ? r.joinedAt : 0,
        since: typeof r.since === "number" ? r.since : typeof r.joinedAt === "number" ? r.joinedAt : 0,
        synced: r.synced === true,
        revocations: { version: Number.isInteger(rv?.version) ? rv.version : 0, devices, disabled: Number.isInteger(rv?.disabled) ? rv.disabled : null },
        ...(r.services && Object.keys(keep(r.services, r.server)).length ? { services: keep(r.services, r.server) } : {}),
    };
}
/** How often a computer asks what its account brings it (ms), how long before a token of its own runs out it asks anyway,
 *  and how long it waits after an ask that failed (doubling from the first to the second). */
const SERVICES_EVERY_MS = 6 * 3600_000;
const SERVICES_BEFORE_END_MS = 12 * 3600_000;
const SERVICES_RETRY_MIN_MS = 15_000;
const SERVICES_RETRY_MAX_MS = 10 * 60_000;
/** How long what a sign-in registered here is still sent to after the sign-in itself ran out (seconds). The device was
 *  not removed, and a notification is what brings its person back to sign in again — but only for a while: a device
 *  whose sign-in ran out is no longer in the account's list of devices, so nobody could remove it any more. */
export const REGISTRATION_GRACE_S = 7 * 86_400;
export class AccountMember {
    o;
    rec = null;
    /** The file is there but is not a record: this computer is in an account it cannot read — nothing comes in by ticket,
     *  and joining again needs `leave` first. */
    broken = false;
    replay = new ReplayCache();
    pending = null;
    pollTimer = null;
    sync = null;
    running = false;
    stopped = false;
    wake = null;
    inflight = new Set();
    sentSelf = null;
    /** The membership whose services were last asked for and answered in this run (`servicesKey`), when, when not to ask
     *  before and how long to wait after the next ask that fails, and whether an ask was wanted (`refreshServices`). */
    servicesFor = "";
    servicesAt = 0;
    servicesNotBefore = 0;
    servicesRetryMs = 0;
    servicesWanted = false;
    servicesSaid = "";
    keysFetchedAt = 0;
    fetch;
    wire;
    keep;
    log;
    now;
    constructor(o) {
        this.o = o;
        this.fetch = o.fetch ?? fetch;
        this.log = o.log ?? ((l) => console.log(l));
        this.now = o.now ?? Date.now;
        this.wire = o.namespace ? new Wire(o.namespace) : DEFAULT_WIRE;
        const own = o.validServices;
        this.keep = own ? (raw, server) => own(validServices(raw, server), server) : validServices;
        this.load();
    }
    load() {
        let text;
        try {
            text = readFileSync(this.o.file, "utf8");
        }
        catch (e) {
            this.broken = e.code !== "ENOENT";
            if (this.broken)
                this.log(`[account] cannot read ${this.o.file}: ${e.message} (nothing comes in by ticket until it can be read)`);
            return;
        }
        try {
            this.rec = validRecord(JSON.parse(text), this.wire, this.keep);
        }
        catch {
            this.rec = null;
        }
        this.broken = !this.rec;
        if (this.broken)
            this.log(`[account] ${this.o.file} is not a membership record (npm run account -- leave clears it)`);
    }
    save(rec) {
        this.rec = rec;
        this.broken = false;
        if (!rec) {
            rmSync(this.o.file, { force: true });
            this.o.onChange?.();
            return;
        }
        mkdirSync(dirname(this.o.file), { recursive: true });
        const tmp = `${this.o.file}.${process.pid}.tmp`;
        writeFileSync(tmp, `${JSON.stringify(rec, null, 1)}\n`, { mode: 0o600 });
        try {
            chmodSync(tmp, 0o600);
        }
        catch {
            // Windows: the folder's own permissions are the guard
        }
        renameSync(tmp, this.o.file);
    }
    current() {
        return this.rec;
    }
    status() {
        const r = this.rec;
        const p = this.pending;
        return {
            member: r ? { server: r.server, account: r.account, joinedAt: r.joinedAt, disabled: r.revocations.disabled !== null, listVersion: r.revocations.version } : null,
            pending: p ? { server: p.server, userCode: p.userCode, qr: p.qr, expiresAt: p.expiresAt, state: p.state, ...(p.claimant ? { claimant: p.claimant } : {}), ...(p.error ? { error: p.error } : {}) } : null,
            sync: this.sync,
        };
    }
    /** Whether one of this computer's own tokens made for a ticket still counts: the same account and this membership of
     *  it (a ticket from before this computer last joined is void), the device's session at the server not over (`sx`),
     *  the device not revoked since the ticket (`tat`, unix seconds), the account not disabled. */
    ticketValid(t) {
        return t.sx * 1000 > this.now() && this.deviceCounts(t);
    }
    /** What the account brings this computer now (null: in no account, or its account disabled): each service the
     *  server lent, those with a token of this computer's own while it has not run out. */
    services() {
        const r = this.rec;
        if (!r || r.revocations.disabled !== null)
            return null;
        const out = {};
        for (const [name, x] of Object.entries(r.services ?? {}))
            if (x.expiresAt === undefined || x.expiresAt > this.now())
                out[name] = x;
        return out;
    }
    /** A service refused this computer's token (it ran out early, the server's key changed): asked for again on the
     *  loop's next round, a minute after the last answer at the earliest. */
    refreshServices() {
        this.servicesWanted = true;
    }
    /** Whether what a sign-in of the account registered here to be sent to later still counts (a push registration,
     *  say): its device not removed or signed out since, this computer still in that account — and
     *  the sign-in not run out for longer than REGISTRATION_GRACE_S. */
    registrationCounts(t) {
        return (t.sx + REGISTRATION_GRACE_S) * 1000 > this.now() && this.deviceCounts(t);
    }
    /** The device that came in with a ticket issued at `tat` is still one of this computer's account, not removed since
     *  (`ticketValid` without the sign-in's own end). */
    deviceCounts(t) {
        const r = this.rec;
        if (!r || r.account.id !== t.acc || (t.tat + 1) * 1000 <= r.since)
            return false;
        return !new RevocationView({ account: r.account.id, version: r.revocations.version, devices: r.revocations.devices, computers: [], disabled: r.revocations.disabled }).isRevoked(t.dev, t.tat);
    }
    /** A ticket taken (once): its claims, or a TicketError. */
    async redeem(jwt) {
        const r = this.rec;
        const self = this.o.self();
        // (a computer whose Link key is no longer the one it joined with is not that member any more)
        if (!r || !self || self.linkId !== r.linkId)
            throw new TicketError("not_owner", "this computer is in no account");
        const kid = kidOf(jwt);
        if (kid && !r.keys.some((k) => k.kid === kid))
            await this.refreshKeys().catch(() => { });
        // nothing comes in before the account's revocation list has been seen once (a fresh membership knows of no
        // revoked device yet): asked for now, without waiting on it
        if (this.rec && !this.rec.synced)
            await this.pull(this.rec, 0).catch(() => { });
        const now = this.rec;
        if (!now || now.account.id !== r.account.id)
            throw new TicketError("not_owner", "this computer is in no account");
        if (!now.synced)
            throw new TicketError("busy", "the account's revocation list has not been fetched yet");
        const claims = await verifyTicket(jwt, {
            issuer: now.server, keys: now.keys, owner: now.account.id, linkId: now.linkId, replay: this.replay, now: this.now(), wire: this.wire,
            revoked: new RevocationView({ account: now.account.id, version: now.revocations.version, devices: now.revocations.devices, computers: [], disabled: now.revocations.disabled }),
        });
        // (one made before this computer last joined the account: an earlier membership's)
        if ((claims.iat + 1) * 1000 <= now.since)
            throw new TicketError("expired", "a ticket from before this computer joined");
        return claims;
    }
    /** The server's keys fetched (a minute apart at most): a new one is kept only through the chain of endorsements
     *  from one already pinned. */
    async refreshKeys(offered) {
        const r = this.rec;
        if (!r)
            return;
        if (offered === undefined) {
            if (this.now() - this.keysFetchedAt < 60_000)
                return;
            this.keysFetchedAt = this.now();
            const res = await this.fetch(`${r.server}/.well-known/jwks.json`, { signal: AbortSignal.timeout(10_000), redirect: "error" });
            if (!res.ok)
                return;
            offered = (await res.json()).keys;
        }
        if (!Array.isArray(offered) || offered.length > 32)
            return;
        const trusted = await verifyKeyChain(r.keys, offered.map((k) => cleanJwk(k, this.wire)).filter((k) => !!k), this.wire);
        if (trusted.length > r.keys.length && this.rec === r) {
            this.save({ ...r, keys: trusted });
            this.log(`[account] the account server has ${trusted.length - r.keys.length} new signing key(s), endorsed by one pinned here`);
        }
    }
    // --------------------------------------------------------------------------- joining
    canJoin(serverRaw) {
        const server = serverOrigin(serverRaw);
        if (!server)
            throw new JoinError(400, "the account server is an https address (https://account.example.com)");
        if (this.rec || this.broken)
            throw new JoinError(409, "this computer is in an account already: leave it first");
        const self = this.o.self();
        if (!self)
            throw new JoinError(409, "this computer has no Link entry (LINK=off, or it has not started): it cannot join an account");
        return { server, self };
    }
    async post(server, path, body) {
        let res;
        try {
            res = await this.fetch(`${server}${path}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body), signal: AbortSignal.timeout(15_000), redirect: "error" });
        }
        catch (e) {
            throw new JoinError(502, `the account server is not answering (${e.name})`);
        }
        const j = (await res.json().catch(() => ({})));
        return { status: res.status, body: j && typeof j === "object" ? j : {} };
    }
    /** What the server answered a join with, taken as this computer's membership. */
    adopt(server, self, b) {
        const account = b.account;
        const srv = b.server;
        const keys = Array.isArray(srv?.keys) ? srv.keys.map((k) => cleanJwk(k, this.wire)).filter((k) => !!k) : [];
        if (typeof account?.id !== "string" || !ACCOUNT_ID_RE.test(account.id) || srv?.url !== server || !keys.length)
            throw new JoinError(502, "the account server's answer is not a membership");
        if (this.rec || this.broken)
            throw new JoinError(409, "this computer is in an account already: leave it first");
        // (when, by the server's clock: tickets are stamped with that clock)
        const at = b.computer?.joinedAt;
        const since = typeof at === "number" && Number.isFinite(at) && Math.abs(at - this.now()) < 86_400_000 ? at : this.now();
        const rec = { v: 1, server, keys, account: { id: account.id, name: typeof account.name === "string" ? account.name.slice(0, 64) : null }, linkId: self.linkId, joinedAt: this.now(), since, synced: false, revocations: { version: 0, devices: [], disabled: null } };
        this.save(rec);
        this.sentSelf = JSON.stringify(selfBody(self));
        this.log(`[account] this computer joined account ${short(rec.account.id)}${rec.account.name ? ` (${rec.account.name})` : ""} at ${server}`);
        this.endPending();
        this.kick();
        return rec;
    }
    /** With a join key the server's admin made: no approval, no confirmation. */
    async joinWithKey(serverRaw, key) {
        const { server, self } = this.canJoin(serverRaw);
        if (typeof key !== "string" || !this.wire.joinKeyRe.test(key))
            throw new JoinError(400, "that is not a join key");
        const proof = this.o.sign(self.linkId, this.wire.joinKeyProofText(server, self.linkId, key));
        if (!proof)
            throw new JoinError(409, "this computer's Link key cannot sign (is the Link entry up?)");
        const r = await this.post(server, "/v1/computers/join", { key, ...selfBody(self), linkId: self.linkId, proof });
        if (r.status !== 200)
            throw new JoinError(r.status === 429 ? 429 : 403, `the account server refused the key (${String(r.body.error ?? r.status)})`);
        return this.adopt(server, self, r.body);
    }
    /** A join code asked of the server: shown here, approved by somebody signed in (a phone that scans it, or a client the code is typed in).
     *  `expect`: the account (its id, or its `sub` at the sign-in system) that may have this computer — an approval by
     *  that account is confirmed without anyone at this computer. */
    async startJoin(serverRaw, expect = null) {
        const { server, self } = this.canJoin(serverRaw);
        this.endPending();
        const r = await this.post(server, "/v1/computers/enroll", { ...selfBody(self), linkId: self.linkId, ...(expect ? { expect } : {}) });
        const b = r.body;
        if (r.status !== 200 || typeof b.device_code !== "string" || typeof b.user_code !== "string" || typeof b.qr !== "string") {
            throw new JoinError(r.status === 429 ? 429 : 502, `the account server gave no code (${String(b.error ?? r.status)})`);
        }
        const interval = Math.min(30, Math.max(1, Number(b.interval) || 2));
        this.pending = { server, userCode: b.user_code, qr: b.qr, expiresAt: this.now() + Math.min(3600, Number(b.expires_in) || 600) * 1000, state: "waiting", deviceCode: b.device_code, expect, interval };
        this.log(`[account] join code asked of ${server}${expect ? " (an account is expected)" : ""}`);
        this.schedulePoll();
        return this.status().pending;
    }
    schedulePoll() {
        if (this.pollTimer)
            clearTimeout(this.pollTimer);
        const p = this.pending;
        if (!p || p.state === "failed" || this.stopped)
            return;
        this.pollTimer = setTimeout(() => void this.poll().catch(() => { }), p.interval * 1000);
        this.pollTimer.unref();
    }
    async poll() {
        const p = this.pending;
        if (!p || p.state === "failed")
            return;
        if (this.now() >= p.expiresAt) {
            p.state = "failed";
            p.error = "the code expired";
            return;
        }
        if (p.state === "waiting") {
            let r;
            try {
                r = await this.post(p.server, "/v1/computers/poll", { device_code: p.deviceCode });
            }
            catch {
                return this.schedulePoll();
            }
            if (this.pending !== p)
                return;
            if (r.status === 200 && r.body.status === "approved") {
                const c = r.body.claimant;
                if (typeof c?.account?.id !== "string" || !ACCOUNT_ID_RE.test(c.account.id)) {
                    p.state = "failed";
                    p.error = "the account server's answer names no account";
                    return;
                }
                p.state = "approved";
                if (typeof r.body.confirmBy === "number")
                    p.expiresAt = r.body.confirmBy;
                p.claimant = {
                    account: { id: c.account.id, name: typeof c.account.name === "string" ? c.account.name.slice(0, 64) : null },
                    idp: { ...(typeof c.idp?.name === "string" ? { name: c.idp.name.slice(0, 64) } : {}), ...(typeof c.idp?.sub === "string" ? { sub: c.idp.sub.slice(0, 255) } : {}) },
                    ...(typeof c.by === "string" ? { by: c.by.slice(0, 64) } : {}),
                };
                this.log(`[account] join: approved by account ${short(c.account.id)}${p.claimant.account.name ? ` (${p.claimant.account.name})` : ""}; ${p.expect ? "checking it is the expected one" : "waiting for the confirmation on this computer"}`);
                // told beforehand which account may have it: that one's approval needs nobody here
                const e = p.expect;
                if (e && (e.account === undefined || e.account === c.account.id) && (e.sub === undefined || e.sub === p.claimant.idp?.sub)) {
                    await this.confirmJoin().catch((err) => this.log(`[account] join: the confirmation failed (${err.message})`));
                }
                return;
            }
            const err = String(r.body.error ?? "");
            if (err === "authorization_pending" || err === "slow_down" || r.status >= 500 || r.status === 429) {
                if (err === "slow_down")
                    p.interval = Math.min(30, p.interval + 1);
                return this.schedulePoll();
            }
            p.state = "failed";
            p.error = err === "access_denied" ? "declined" : err === "expired_token" ? "the code expired" : `the account server said ${err || r.status}`;
            return;
        }
        // approved, not confirmed yet: only the expiry is watched
        this.schedulePoll();
    }
    /** The person at this computer agrees to who approved (or it was the expected account): this computer is theirs. */
    async confirmJoin() {
        const p = this.pending;
        if (!p || p.state !== "approved" || !p.claimant)
            throw new JoinError(409, "nothing approved to confirm");
        const self = this.o.self();
        if (!self)
            throw new JoinError(409, "this computer has no Link entry");
        const proof = this.o.sign(self.linkId, this.wire.joinProofText(p.server, self.linkId, p.claimant.account.id, p.deviceCode));
        if (!proof)
            throw new JoinError(409, "this computer's Link key cannot sign (is the Link entry up?)");
        const r = await this.post(p.server, "/v1/computers/confirm", { device_code: p.deviceCode, proof });
        if (r.status !== 200)
            throw new JoinError(502, `the account server refused the confirmation (${String(r.body.error ?? r.status)})`);
        // (the server's answer must name the account that was shown here)
        if (r.body.account?.id !== p.claimant.account.id)
            throw new JoinError(502, "the account server confirmed another account than the one shown");
        return this.adopt(p.server, self, r.body);
    }
    /** The join under way given up (and the server told, so the code is dead). */
    async cancelJoin() {
        const p = this.pending;
        this.endPending();
        if (p && p.state !== "failed")
            await this.post(p.server, "/v1/computers/decline", { device_code: p.deviceCode }).catch(() => { });
    }
    endPending() {
        if (this.pollTimer)
            clearTimeout(this.pollTimer);
        this.pollTimer = null;
        this.pending = null;
    }
    /** Out of the account (from this computer itself): the record goes, so every token made for a ticket is void at
     *  once; the server is told when it can be reached. */
    async leave() {
        const r = this.rec;
        if (!r && !this.broken)
            return false;
        this.save(null);
        for (const ac of this.inflight)
            ac.abort();
        if (r) {
            this.log(`[account] this computer left account ${short(r.account.id)}`);
            await this.signed(r, "POST", "/v1/computer/leave", {}).then((res) => res.body?.cancel(), () => { });
        }
        return true;
    }
    // --------------------------------------------------------------------------- keeping in step with the server
    async signed(r, method, pathQ, body, timeoutMs = 15_000) {
        const raw = body === undefined ? "" : JSON.stringify(body);
        const ts = Math.floor(this.now() / 1000);
        const sig = this.o.sign(r.linkId, this.wire.computerProofText(r.server, method, pathQ, ts, createHash("sha256").update(raw, "utf8").digest("base64url")));
        if (!sig)
            throw new Error("the Link key cannot sign as the id this computer joined with");
        const ac = new AbortController();
        this.inflight.add(ac);
        const timer = setTimeout(() => ac.abort(), timeoutMs);
        try {
            return await this.fetch(`${r.server}${pathQ}`, { method, headers: { authorization: `${this.wire.linkScheme} ${r.linkId}.${ts}.${sig}`, ...(raw ? { "content-type": "application/json" } : {}) }, ...(raw ? { body: raw } : {}), signal: ac.signal, redirect: "error" });
        }
        finally {
            clearTimeout(timer);
            this.inflight.delete(ac);
        }
    }
    /** The loop: what this computer is (name, relays, …) told to the server when it changed; the revocation list asked
     *  for and waited on. Runs while the server does; idle while this computer is in no account. */
    start() {
        if (this.running)
            return;
        this.running = true;
        this.stopped = false;
        void this.loop();
    }
    stop() {
        this.stopped = true;
        for (const ac of this.inflight)
            ac.abort();
        if (this.pollTimer)
            clearTimeout(this.pollTimer);
        this.kick();
    }
    kick() {
        this.wake?.();
    }
    sleep(ms) {
        return new Promise((resolve) => {
            const t = setTimeout(done, ms);
            t.unref();
            const self = this;
            function done() {
                clearTimeout(t);
                if (self.wake === done)
                    self.wake = null;
                resolve();
            }
            this.wake = done;
        });
    }
    async loop() {
        const min = this.o.timing?.retryMinMs ?? 5_000;
        const max = this.o.timing?.retryMaxMs ?? 5 * 60_000;
        let delay = 0;
        let said = "";
        while (!this.stopped) {
            const r = this.rec;
            if (!r) {
                await this.sleep(60_000);
                continue;
            }
            try {
                // (what this computer says of itself is told when it can be: a refusal must never keep the revocation list
                // from being asked for)
                let aside = null;
                // (first: a relay the account brings is part of what this computer then says of itself)
                if (this.servicesDue(r))
                    await this.pullServices(r).catch((e) => void (aside = e));
                await this.tellSelf(r).catch((e) => void (aside ??= e));
                const cur = this.rec;
                if (cur)
                    await this.pull(cur);
                // (the list was asked for and answered: no waiting before the next ask, whatever else was refused — that is
                // told again next time round)
                const note = aside;
                const msg = note ? note.message.slice(0, 160) : "";
                this.sync = { at: this.now(), ...(msg ? { error: msg } : {}) };
                if (msg && msg !== said)
                    this.log(`[account] the account server: ${msg} (told again later; revocations still come)`);
                delay = 0;
                said = msg;
            }
            catch (e) {
                if (this.stopped || !this.rec || this.rec.account.id !== r.account.id)
                    continue;
                const older = e instanceof TicketError && e.code === "replayed";
                const msg = older ? "its revocation list is older than the one held here (was its data restored from a backup?): revocations made since are NOT known here" : e.message.slice(0, 160);
                this.sync = { at: this.now(), error: msg };
                if (msg !== said)
                    this.log(`[account] the account server: ${msg} (retrying; what is signed in here goes on)`);
                said = msg;
                delay = Math.min(max, Math.max(min, delay * 2));
            }
            // (a moment between two answers even when all is well: a server answering at once must not be asked in a spin)
            await this.sleep(delay || 1_000);
        }
        this.running = false;
    }
    /** One membership: the account, and when this computer joined it (leaving and joining again is another). */
    servicesKey(r) {
        return `${r.server} ${r.account.id} ${r.joinedAt} ${r.since}`;
    }
    servicesDue(r) {
        const now = this.now();
        if (this.servicesFor !== this.servicesKey(r) && this.servicesFor !== `asking ${this.servicesKey(r)}`) {
            // a membership not asked for yet in this run (the server just started, or it just joined): asked at once,
            // whatever an earlier one's asks came to
            this.servicesFor = `asking ${this.servicesKey(r)}`;
            this.servicesAt = 0;
            this.servicesNotBefore = 0;
            this.servicesRetryMs = 0;
            this.servicesWanted = false;
            return true;
        }
        if (now < this.servicesNotBefore)
            return false;
        // (then a few times a day; sooner when a token of its own is about to run out or was refused)
        if (this.servicesFor !== this.servicesKey(r) || now - this.servicesAt >= SERVICES_EVERY_MS)
            return true;
        if (this.servicesWanted)
            return now - this.servicesAt >= 60_000;
        const ends = Object.values(r.services ?? {}).map((x) => x.expiresAt).filter((x) => typeof x === "number");
        return ends.some((e) => e - now < SERVICES_BEFORE_END_MS);
    }
    /**
     * Asks the account server what the account brings this computer. Only a good answer changes what is held. A server
     * that says "nothing for you" without a signature (404: an older one without the route, or one that lost its list;
     * 403: the account disabled, which its signed list says too) is taken as an answer of nothing new — what is held
     * stays, asked again in a few hours: a computer is taken out of its account by a signed list alone, and what it held
     * goes with the membership then. Anything else (the server away, an error of its own) is asked again soon, each
     * wait twice the last.
     */
    async pullServices(r) {
        const key = this.servicesKey(r);
        this.servicesRetryMs = Math.min(SERVICES_RETRY_MAX_MS, Math.max(SERVICES_RETRY_MIN_MS, this.servicesRetryMs * 2));
        this.servicesNotBefore = this.now() + this.servicesRetryMs;
        const res = await this.signed(r, "GET", "/v1/computer/services");
        const answered = () => {
            this.servicesFor = key;
            this.servicesAt = this.now();
            this.servicesNotBefore = 0;
            this.servicesRetryMs = 0;
            this.servicesWanted = false;
        };
        if (res.status === 404 || res.status === 403) {
            await res.body?.cancel().catch(() => { });
            const cur = this.rec;
            if (cur && this.servicesKey(cur) === key) {
                answered();
                if (this.servicesSaid !== `${key} ${res.status}`)
                    this.log(`[account] the account server brings this computer nothing ${res.status === 403 ? "(the account is disabled)" : "(an older server, or it does not list this computer)"}: what is held stays as it is`);
                this.servicesSaid = `${key} ${res.status}`;
            }
            return;
        }
        if (!res.ok) {
            await res.body?.cancel().catch(() => { });
            throw new Error(`services refused (${res.status})`);
        }
        const next = this.keep(await res.json(), r.server);
        const cur = this.rec;
        // (left, or joined anew, while it was on its way: not this membership's)
        if (!cur || this.servicesKey(cur) !== key)
            return;
        answered();
        this.servicesSaid = "";
        if (JSON.stringify(cur.services ?? {}) === JSON.stringify(next))
            return;
        const before = cur.services ?? {};
        const { services: _gone, ...rest } = cur;
        this.save({ ...rest, ...(Object.keys(next).length ? { services: next } : {}) });
        // (said when what it is changed — a service's address, a fixed token — not at each new token of its own)
        const what = (x) => JSON.stringify(Object.entries(x).map(([n, e]) => [n, e.expiresAt === undefined ? e : { ...e, token: undefined, expiresAt: undefined }]));
        if (what(before) !== what(next)) {
            const names = Object.entries(next).map(([n, e]) => `${n} ${new URL(e.url).host}`);
            this.log(`[account] the account brings this computer: ${names.length ? names.join(", ") : "nothing"}`);
        }
        this.o.onServices?.();
    }
    async tellSelf(r) {
        const self = this.o.self();
        if (!self || self.linkId !== r.linkId)
            return;
        const body = JSON.stringify(selfBody(self));
        if (body === this.sentSelf)
            return;
        const res = await this.signed(r, "POST", "/v1/computer/update", selfBody(self));
        await res.body?.cancel().catch(() => { });
        // (404: the server does not list this computer — the revocation request below says what that means)
        if (res.ok || res.status === 404)
            this.sentSelf = body;
        else
            throw new Error(`update refused (${res.status})`);
    }
    async pull(r, wait = this.o.timing?.waitS ?? 25) {
        const res = await this.signed(r, "GET", `/v1/computer/revocations?account=${encodeURIComponent(r.account.id)}&after=${r.revocations.version}&wait=${wait}`, undefined, (wait + 20) * 1000);
        if (res.status === 404) {
            await res.body?.cancel().catch(() => { });
            // not a signed statement: the server may have lost its data, or be another one — this computer stays as it is
            throw new Error("it does not list this computer (kept as it is: only a signed list takes a computer out)");
        }
        if (!res.ok) {
            await res.body?.cancel().catch(() => { });
            throw new Error(`revocation list refused (${res.status}${res.status === 401 ? ": is this computer's clock right?" : ""})`);
        }
        const b = (await res.json());
        if (typeof b.list !== "string")
            throw new Error("no revocation list in the answer");
        const kid = kidOf(b.list);
        if (kid && !r.keys.some((k) => k.kid === kid))
            await this.refreshKeys(b.keys);
        const keyed = this.rec;
        if (!keyed || keyed.account.id !== r.account.id || keyed.server !== r.server)
            return;
        const list = await verifyRevocationList(b.list, { issuer: keyed.server, keys: keyed.keys, owner: keyed.account.id, minVersion: keyed.revocations.version, now: this.now(), wire: this.wire });
        // (left, or joined anew, while the list was on its way or being checked: it is not this membership's)
        const cur = this.rec;
        if (cur !== keyed)
            return;
        if (list.computers.some((c) => c.id === cur.linkId)) {
            this.log(`[account] account ${short(cur.account.id)} took this computer out (its signed list says so): it is in no account now`);
            this.save(null);
            return;
        }
        if (cur.synced && list.version === cur.revocations.version)
            return;
        this.save({ ...cur, synced: true, revocations: { version: list.version, devices: list.devices, disabled: list.disabled } });
        this.o.onChange?.();
        this.log(`[account] revocation list #${list.version}: ${list.devices.length} device(s)${list.disabled !== null ? ", the account is disabled" : ""}`);
    }
}
function selfBody(s) {
    // (`signal`: an account server from before the hosted web client ignores it)
    return { name: s.name, fingerprint: s.fingerprint ?? null, relays: s.relays.slice(0, 4), direct: s.direct.filter((d) => d.length <= 64).slice(0, 16), origins: s.origins.slice(0, 16), signal: s.signal ?? null };
}
export { TicketError };
export { sha256 as accountSha256 };
