// Yoyo Control's standard pairing (docs/REMOTE.md「配对」), for products that let phones pair the way its Mac does:
// `devices.json` (0600) with the paired devices and the SHA-256 of their tokens (each bound to the link key it first
// came with), a one-time pairing code (128 bits, 5 min, used once, 10 wrong tries end it), at most 32 devices, and the
// pairing link. Phones pair over the uu Link (`hello.credential = "Pair <code>"`: `pair`, then `authenticateLink`).
// A product with its own credentials (tickets, sessions) doesn't need this.

import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { readFileSync } from "node:fs";
import { writePrivate } from "./identity.js";

export const CODE_TTL_MS = 5 * 60_000;
export const MAX_CODE_ATTEMPTS = 10;
export const MAX_DEVICES = 32;
/** An invitation's life (`invite`, docs/ACCOUNT.md「批准」), and how many may wait. */
export const INVITE_TTL_MS = 10 * 60_000;
export const MAX_INVITES = 8;
const SEEN_WRITE_EVERY_MS = 3_600_000;
const NAME_MAX = 64;

export interface Device {
  id: string;
  name: string;
  pairedAt: number;
  lastSeenAt?: number;
}

export interface PairingCode {
  code: string;
  expiresAt: number;
}

interface Stored extends Device {
  tokenHash: string;
  /** hex of the uu Link client key the token was first used with (docs/LINK.md「身份与信任」); cleared by pairing again */
  linkKey?: string;
}

export class PairError extends Error {
  constructor(
    readonly kind: "bad-code" | "bad-device" | "full",
    message: string,
  ) {
    super(message);
    this.name = "PairError";
  }
}

export interface DeviceStoreOptions {
  now?: () => number;
  /** Called after the list or the pairing code changed. */
  onChange?: () => void;
  log?: (line: string) => void;
}

export class DeviceStore {
  readonly path: string;
  private readonly now: () => number;
  private readonly log: (line: string) => void;
  onChange: (() => void) | undefined;
  private devices: Stored[];
  private code: PairingCode | null = null;
  private wrongCodes = 0;
  /** Codes for one phone each: the code → who may use it (`invite`). */
  private invites = new Map<string, { deviceId: string; linkKey: string; expiresAt: number }>();

  constructor(path: string, opts: DeviceStoreOptions = {}) {
    this.path = path;
    this.now = opts.now ?? Date.now;
    this.log = opts.log ?? (() => {});
    this.onChange = opts.onChange;
    this.devices = load(path);
  }

  get list(): Device[] {
    return this.devices.map(({ tokenHash: _, linkKey: __, ...d }) => d);
  }

  get isEmpty(): boolean {
    return this.devices.length === 0;
  }

  /** The live pairing code, if any. */
  get pairingCode(): PairingCode | null {
    if (this.code && this.code.expiresAt <= this.now()) this.code = null;
    return this.code;
  }

  /** The device holding `token` (its `lastSeenAt` noted), or null. */
  authenticate(token: string | null | undefined): Device | null {
    if (!token) return null;
    const hash = sha256hex(token);
    const d = this.devices.find((x) => safeEqual(x.tokenHash, hash));
    if (!d) return null;
    const t = this.now();
    const write = d.lastSeenAt === undefined || t - d.lastSeenAt >= SEEN_WRITE_EVERY_MS;
    d.lastSeenAt = t;
    if (write) this.save();
    const { tokenHash: _, linkKey: __, ...out } = d;
    return out;
  }

  /**
   * `authenticate` for a uu Link session from the client key `key` (hex): the token's first link session binds it to
   * that key (saved); later ones with another key are `other-key` until the phone pairs again.
   */
  authenticateLink(token: string | null | undefined, key: string): { kind: "accepted"; device: Device } | { kind: "other-key"; device: Device } | { kind: "unknown" } {
    const device = this.authenticate(token);
    if (!device) return { kind: "unknown" };
    const d = this.devices.find((x) => x.id === device.id);
    if (!d) return { kind: "unknown" };
    const k = key.toLowerCase();
    if (d.linkKey) return d.linkKey === k ? { kind: "accepted", device } : { kind: "other-key", device };
    d.linkKey = k;
    this.save();
    return { kind: "accepted", device };
  }

  /** A new pairing code (the one before it no longer works). */
  startPairing(): PairingCode {
    this.code = { code: randomToken(16), expiresAt: this.now() + CODE_TTL_MS };
    this.wrongCodes = 0;
    this.onChange?.();
    return this.code;
  }

  /** The code is no longer shown. */
  stopPairing(): void {
    const had = this.code !== null;
    this.code = null;
    if (had) this.onChange?.();
  }

  /**
   * A code for the phone `id` alone, over a link session from `linkKey` (hex), asked for by a phone already paired
   * (docs/ACCOUNT.md「批准」): good for INVITE_TTL_MS, once, beside the shown code.
   */
  invite(id: string, linkKey: string): PairingCode {
    if (!validDeviceId(id)) throw new PairError("bad-device", "device.id must be 8–64 of A–Z a–z 0–9 _ -");
    const key = linkKey.toLowerCase();
    if (!/^[0-9a-f]{64}$/.test(key)) throw new PairError("bad-device", "linkKey must be 64 hex digits");
    const t = this.now();
    for (const [c, v] of this.invites) if (v.expiresAt <= t || v.deviceId === id) this.invites.delete(c);
    if (this.invites.size >= MAX_INVITES) throw new PairError("full", "too many invitations waiting");
    const c = { code: randomToken(16), expiresAt: t + INVITE_TTL_MS };
    this.invites.set(c.code, { deviceId: id, linkKey: key, expiresAt: c.expiresAt });
    return c;
  }

  /**
   * Pairs the phone (`id`, `name`) with the live code, or an invitation made for it (then only over a session from
   * its `linkKey`): its token (shown once). The code is used up.
   */
  pair(code: string, id: string, name: string, linkKey?: string): string {
    if (!validDeviceId(id)) throw new PairError("bad-device", "device.id must be 8–64 of A–Z a–z 0–9 _ -");
    const t0 = this.now();
    const invited = [...this.invites].find(([c, v]) => safeEqual(c, code) && v.expiresAt > t0);
    if (invited && (invited[1].deviceId !== id || invited[1].linkKey !== linkKey?.toLowerCase())) {
      throw new PairError("bad-code", "the pairing code is wrong or has expired");
    }
    const live = this.pairingCode;
    if (!invited && (!live || !safeEqual(live.code, code))) {
      if (live) {
        this.wrongCodes++;
        if (this.wrongCodes >= MAX_CODE_ATTEMPTS) this.code = null;
        this.onChange?.();
      }
      throw new PairError("bad-code", "the pairing code is wrong or has expired");
    }
    this.devices = this.devices.filter((d) => d.id !== id);
    if (this.devices.length >= MAX_DEVICES) throw new PairError("full", "too many paired devices");
    const token = randomToken(32);
    const t = this.now();
    this.devices.push({ id, name: cleanName(name), pairedAt: t, lastSeenAt: t, tokenHash: sha256hex(token), ...(linkKey ? { linkKey: linkKey.toLowerCase() } : {}) });
    if (invited) this.invites.delete(invited[0]);
    else this.code = null;
    this.save();
    this.onChange?.();
    return token;
  }

  /** Forgets the device: its token stops working at once. false when it wasn't paired. */
  remove(id: string): boolean {
    const before = this.devices.length;
    this.devices = this.devices.filter((d) => d.id !== id);
    if (this.devices.length === before) return false;
    this.save();
    this.onChange?.();
    return true;
  }

  private save(): void {
    const body = {
      version: 1,
      devices: this.devices.map((d) => ({ id: d.id, name: d.name, pairedAt: d.pairedAt, ...(d.lastSeenAt !== undefined ? { lastSeenAt: d.lastSeenAt } : {}), tokenHash: d.tokenHash, ...(d.linkKey ? { linkKey: d.linkKey } : {}) })),
    };
    try {
      writePrivate(this.path, `${JSON.stringify(body, null, 2)}\n`);
    } catch (err) {
      this.log(`remote: cannot write ${this.path}: ${err instanceof Error ? err.message : String(err)}`);
    }
  }
}

function load(path: string): Stored[] {
  try {
    const j = JSON.parse(readFileSync(path, "utf8")) as { devices?: unknown };
    if (!Array.isArray(j.devices)) return [];
    return j.devices.flatMap((d: Record<string, unknown>) => {
      if (typeof d.id !== "string" || typeof d.tokenHash !== "string" || d.tokenHash.length !== 64 || typeof d.pairedAt !== "number") return [];
      return [{ id: d.id, name: typeof d.name === "string" ? d.name : d.id, pairedAt: d.pairedAt, ...(typeof d.lastSeenAt === "number" ? { lastSeenAt: d.lastSeenAt } : {}), tokenHash: d.tokenHash, ...(typeof d.linkKey === "string" && /^[0-9a-f]{64}$/.test(d.linkKey) ? { linkKey: d.linkKey } : {}) }];
    });
  } catch {
    return [];
  }
}

/** 8–64 of A–Z a–z 0–9 _ - (a UUID fits). */
export function validDeviceId(id: string): boolean {
  return /^[A-Za-z0-9_-]{8,64}$/.test(id);
}

/** Newlines and NULs out, trimmed, at most 64 characters; empty → "iPhone". */
export function cleanName(raw: string): string {
  const s = raw.replace(/[\r\n\u2028\u2029\0]/g, "").trim();
  return s ? [...s].slice(0, NAME_MAX).join("") : "iPhone";
}

/** `bytes` random bytes as base64url without padding. */
export function randomToken(bytes: number): string {
  return randomBytes(bytes).toString("base64url");
}

function sha256hex(s: string): string {
  return createHash("sha256").update(s, "utf8").digest("hex");
}

function safeEqual(a: string, b: string): boolean {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

/**
 * The pairing link a phone scans (docs/REMOTE.md「配对」):
 * `yoyocontrol://pair?v=2&id=<serverId>&n=<name>&fp=<key fingerprint>&l=&lk=&ls=[&lp=][&a=<IPv4,…>]&c=<code>`.
 * `l…`: the uu Link binding (`link`: id hex, identity key and signature as base64url, the UDP port), so the phone dials
 * the link from anywhere at once; `a`: this host's local addresses (hints beside the binding's).
 */
export function pairingLink(o: { serverId: string; name: string; fingerprint: string; code: string; link: { id: string; key: string; sig: string; port?: number }; addresses?: readonly string[]; scheme?: string }): string {
  const url64 = (b: string) => b.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const q = new URLSearchParams({ v: "2", id: o.serverId, n: o.name, fp: o.fingerprint, l: o.link.id, lk: url64(o.link.key), ls: url64(o.link.sig) });
  if (o.link.port) q.set("lp", String(o.link.port));
  if (o.addresses?.length) q.set("a", o.addresses.join(","));
  q.set("c", o.code);
  // the Mac's code writes spaces as %20 (URLComponents); readers take either
  return `${o.scheme ?? "yoyocontrol"}://pair?${q.toString().replace(/\+/g, "%20")}`;
}
