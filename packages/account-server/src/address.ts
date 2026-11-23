// IP addresses as the account server sees its clients: one form per address (an IPv4-mapped IPv6 one is its IPv4
// one) and what kind it is (loopback, private, public). Only `node:net`-free byte parsing: no lookups.
import { isIP } from "node:net";

// ----------------------------------------------------------------------------- addresses

/** An address's bytes: 4 for IPv4, 16 for IPv6 (every spelling: `::`, a dotted IPv4 tail, hex groups), or null. A zone
 *  (`%en0`) and brackets are left off. Validated by `net.isIP` first, then expanded without guessing. */
export function ipBytes(ip: string): Uint8Array | null {
  const bare = ip.trim().replace(/^\[|\]$/g, "").replace(/%.*$/, "");
  const family = isIP(bare);
  if (family === 4) return Uint8Array.from(bare.split(".").map(Number));
  if (family !== 6) return null;
  let text = bare.toLowerCase();
  // a dotted IPv4 tail as its two groups
  const dotted = /^(.*:)(\d+\.\d+\.\d+\.\d+)$/.exec(text);
  if (dotted) {
    const q = dotted[2]!.split(".").map(Number);
    text = `${dotted[1]}${((q[0]! << 8) | q[1]!).toString(16)}:${((q[2]! << 8) | q[3]!).toString(16)}`;
  }
  const [head, tail] = text.includes("::") ? (text.split("::") as [string, string]) : [text, null];
  const left = head ? head.split(":") : [];
  const right = tail ? tail.split(":") : [];
  const groups = tail === null ? left : [...left, ...Array<string>(8 - left.length - right.length).fill("0"), ...right];
  if (groups.length !== 8) return null;
  const out = new Uint8Array(16);
  groups.forEach((g, i) => {
    const v = parseInt(g, 16);
    out[i * 2] = v >> 8;
    out[i * 2 + 1] = v & 0xff;
  });
  return out;
}

/** The IPv4 address an IPv6 one stands for, when it does, and how: IPv4-mapped (`::ffff:0:0/96`, the core and the OS
 *  treat it as the IPv4 one), IPv4-compatible (`::/96`, but not `::` and `::1`; taken as the IPv4 one too), or one
 *  that carries it to an IPv4 network elsewhere: the well-known NAT64 prefix (`64:ff9b::/96`, through a translator),
 *  6to4 (`2002:<v4>::/48`, through a relay). */
function embeddedV4(b: Uint8Array): { v4: Uint8Array; carried: boolean } | null {
  const zero = (from: number, to: number) => b.subarray(from, to).every((x) => x === 0);
  if (zero(0, 10) && b[10] === 0xff && b[11] === 0xff) return { v4: b.subarray(12), carried: false };
  if (zero(0, 12) && !zero(12, 15)) return { v4: b.subarray(12), carried: false };
  if (b[0] === 0x00 && b[1] === 0x64 && b[2] === 0xff && b[3] === 0x9b && zero(4, 12)) return { v4: b.subarray(12), carried: true };
  if (b[0] === 0x20 && b[1] === 0x02) return { v4: b.subarray(2, 6), carried: true };
  return null;
}

/** An address as the Link core will take it: an IPv6 one that stands for an IPv4 one (mapped, compatible) as that IPv4
 *  one, dotted; others as given (without zone or brackets). null: not an IP. */
export function normalizeIp(ip: string): string | null {
  const b = ipBytes(ip);
  if (!b) return null;
  if (b.length === 4) return Array.from(b).join(".");
  const e = embeddedV4(b);
  // (NAT64 and 6to4 stay as they are: IPv6 addresses the core sends to; only their kind comes from the IPv4 one)
  if (e && !e.carried) return Array.from(e.v4).join(".");
  return ip.trim().replace(/^\[|\]$/g, "").replace(/%.*$/, "").toLowerCase();
}

/** Where an offer came from, as the server decided (app.ts rtcSource): this computer itself (a page on localhost), a
 *  private network (the LAN, an overlay network's 100.64/10), or a public address (a page elsewhere, through the signaling
 *  service). */
export type OfferScope = "this computer" | "private" | "public";

/** What kind of address `ip` is: loopback, one the core never checks towards (unspecified, multicast, link-local,
 *  broadcast), one of a private network (RFC 1918, CGNAT / a tailnet, IPv6 ULA fc00::/7, site-local fec0::/10,
 *  local-use NAT64 64:ff9b:1::/48), or a public one. null: not an IP. An IPv4-mapped or -compatible IPv6 address is
 *  its IPv4 one; one that carries an IPv4 address elsewhere (NAT64, 6to4) is that one's kind when it is private or
 *  public, otherwise `never` (a loopback inside it is a translator's or relay's, never this computer's). */
export function addressKind(ip: string): "loopback" | "never" | "private" | "public" | null {
  let b = ipBytes(ip);
  if (!b) return null;
  if (b.length === 16) {
    // local-use NAT64 (RFC 8215): a network's own translator, to its own IPv4 side
    if (b[0] === 0x00 && b[1] === 0x64 && b[2] === 0xff && b[3] === 0x9b && b[4] === 0x00 && b[5] === 0x01) return "private";
    const e = embeddedV4(b);
    if (e?.carried) {
      const k = addressKind(Array.from(e.v4).join("."));
      return k === "private" || k === "public" ? k : "never";
    }
    if (e) b = e.v4;
  }
  if (b.length === 4) {
    const [x, y] = b as unknown as [number, number, number, number];
    if (x === 127) return "loopback";
    if (x === 0 || x >= 224 || (x === 169 && y === 254)) return "never";
    if (x === 10 || (x === 172 && y >= 16 && y <= 31) || (x === 192 && y === 168) || (x === 100 && y >= 64 && y <= 127)) return "private";
    return "public";
  }
  const zero15 = b.subarray(0, 15).every((x) => x === 0);
  if (zero15 && b[15] === 1) return "loopback";
  if (zero15 && b[15] === 0) return "never";
  if (b[0] === 0xff || (b[0] === 0xfe && (b[1]! & 0xc0) === 0x80)) return "never";
  if ((b[0]! & 0xfe) === 0xfc) return "private";
  // site-local (deprecated, RFC 3879: still a site's own)
  if (b[0] === 0xfe && (b[1]! & 0xc0) === 0xc0) return "private";
  return "public";
}
