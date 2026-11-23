// The account server's signing keys (Ed25519): tickets, revocation lists and notices, and each later key's
// endorsement. In <data dir>/keys.json (0600), made at the first start. A computer pins the keys it was given when it
// joined; a key added later (`admin.ts rotate-key`) carries an endorsement signed by
// the key before it, so a computer that meets an unknown `kid` fetches /.well-known/jwks.json and takes the new key
// only through a chain of endorsements from one it pinned (verifyKeyChain) — the HTTPS answer alone is not enough.
import { createPrivateKey, generateKeyPairSync, randomBytes, type KeyObject } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { CompactSign } from "jose";
import { DEFAULT_WIRE, type PublicJwk, type Wire } from "@yoyocontrol/account";

export { publicKeyOf, verifyKeyChain, type PublicJwk } from "@yoyocontrol/account";

interface StoredKey {
  kid: string;
  x: string;
  d: string;
  created: number;
  endorsement?: string;
}

const kidOf = () => randomBytes(9).toString("base64url");

export class KeyRing {
  private keys: StoredKey[];
  private objects = new Map<string, KeyObject>();

  private constructor(private readonly file: string | null, keys: StoredKey[], readonly wire: Wire) {
    this.keys = keys;
  }

  /** The ring in `file` (made, with one key, when there is none); `null` = in memory only (tests). `wire`: the names
   *  it signs under (the server's namespace). */
  static load(file: string | null, wire: Wire = DEFAULT_WIRE): KeyRing {
    if (file && existsSync(file)) {
      const j = JSON.parse(readFileSync(file, "utf8")) as { v: number; keys: StoredKey[] };
      if (j.v !== 1 || !Array.isArray(j.keys) || !j.keys.length) throw new Error(`${file}: not a key ring`);
      return new KeyRing(file, j.keys, wire);
    }
    const ring = new KeyRing(file, [KeyRing.fresh()], wire);
    ring.save();
    return ring;
  }

  private static fresh(): StoredKey {
    const { privateKey } = generateKeyPairSync("ed25519");
    const jwk = privateKey.export({ format: "jwk" }) as { x: string; d: string };
    return { kid: kidOf(), x: jwk.x, d: jwk.d, created: Date.now() };
  }

  private save() {
    if (!this.file) return;
    mkdirSync(dirname(this.file), { recursive: true });
    const tmp = `${this.file}.tmp`;
    writeFileSync(tmp, `${JSON.stringify({ v: 1, keys: this.keys }, null, 1)}\n`, { mode: 0o600 });
    chmodSync(tmp, 0o600);
    renameSync(tmp, this.file);
  }

  /** The key new things are signed with: the newest. */
  get current(): { kid: string; key: KeyObject } {
    const k = this.keys.at(-1)!;
    return { kid: k.kid, key: this.objectOf(k) };
  }

  private objectOf(k: StoredKey): KeyObject {
    let o = this.objects.get(k.kid);
    if (!o) {
      o = createPrivateKey({ key: { kty: "OKP", crv: "Ed25519", x: k.x, d: k.d }, format: "jwk" });
      this.objects.set(k.kid, o);
    }
    return o;
  }

  /** The public keys, oldest first (what /.well-known/jwks.json serves and a joining computer pins). */
  jwks(): PublicJwk[] {
    return this.keys.map((k) => ({ kty: "OKP", crv: "Ed25519", x: k.x, kid: k.kid, alg: "EdDSA", use: "sig", ...(k.endorsement ? { [this.wire.endorsementField]: k.endorsement } : {}) }));
  }

  /** A new current key, endorsed by the one before it. The old keys stay (computers that pinned them still verify,
   *  and they still verify what was signed before); `retire` drops the oldest ones but `keep`. */
  async rotate(): Promise<PublicJwk> {
    const prev = this.keys.at(-1)!;
    const next = KeyRing.fresh();
    const payload = new TextEncoder().encode(JSON.stringify({ kid: next.kid, x: next.x, iat: Math.floor(Date.now() / 1000) }));
    next.endorsement = await new CompactSign(payload).setProtectedHeader({ alg: "EdDSA", kid: prev.kid, typ: this.wire.endorsementTyp }).sign(this.objectOf(prev));
    this.keys.push(next);
    this.save();
    return this.jwks().at(-1)!;
  }

  retire(keep: number): number {
    const drop = Math.max(0, this.keys.length - Math.max(1, keep));
    if (!drop) return 0;
    for (const k of this.keys.splice(0, drop)) this.objects.delete(k.kid);
    this.save();
    return drop;
  }
}
