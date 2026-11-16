// Which ICE candidates go into the offer that is sent (docs/LINK.md「客户端：浏览器」). A server reached through a
// public address may refuse an offer that names this device's private networks (the gateway does: it would aim the
// server's ICE checks into its own LAN), and a page granted the microphone gets its raw host addresses, not mDNS
// names. The offer sent is what the answer is signed over, so the filtering happens here, before signaling.

/** `"all"`: every candidate the browser gathered (at most `MAX_OFFER_CANDIDATES`). `"public"`: only UDP host,
 *  server-reflexive and relay candidates on a public address and a port ≥ 1024 (no private, ULA, CGNAT, loopback,
 *  link-local, multicast, broadcast or unspecified address, no mDNS name, no TCP); a related address (`raddr`) is
 *  blanked. */
export type CandidatePolicy = "all" | "public";

/** At most this many candidates go out (the gateway refuses an offer with more). */
export const MAX_OFFER_CANDIDATES = 32;

/** An IP address's bytes (4 or 16), or null when `ip` isn't one. Takes IPv6 with brackets, a zone (`%en0`) and an
 *  embedded dotted IPv4 tail. */
export function ipBytes(ip: string): Uint8Array | null {
  let s = ip.trim();
  if (s.startsWith("[") && s.endsWith("]")) s = s.slice(1, -1);
  const v4 = (t: string): number[] | null => {
    const p = t.split(".");
    if (p.length !== 4) return null;
    const out: number[] = [];
    for (const x of p) {
      if (!/^\d{1,3}$/.test(x)) return null;
      const n = Number(x);
      if (n > 255) return null;
      out.push(n);
    }
    return out;
  };
  if (!s.includes(":")) {
    const b = v4(s);
    return b ? Uint8Array.from(b) : null;
  }
  s = s.replace(/%.*$/, "");
  let tail: number[] = [];
  const lastColon = s.lastIndexOf(":");
  if (s.slice(lastColon + 1).includes(".")) {
    const b = v4(s.slice(lastColon + 1));
    if (!b) return null;
    tail = [(b[0]! << 8) | b[1]!, (b[2]! << 8) | b[3]!];
    s = s.slice(0, lastColon + 1) + "0:0";
  }
  const halves = s.split("::");
  if (halves.length > 2) return null;
  const group = (t: string) => (t === "" ? [] : t.split(":"));
  const head = group(halves[0]!);
  const rest = halves.length === 2 ? group(halves[1]!) : [];
  const words: number[] = [];
  for (const g of [...head, ...rest]) {
    if (!/^[0-9a-fA-F]{1,4}$/.test(g)) return null;
  }
  const fill = 8 - head.length - rest.length;
  if (halves.length === 2 ? fill < 1 : fill !== 0) return null;
  for (const g of head) words.push(parseInt(g, 16));
  for (let i = 0; i < (halves.length === 2 ? fill : 0); i++) words.push(0);
  for (const g of rest) words.push(parseInt(g, 16));
  if (tail.length) words.splice(6, 2, ...tail);
  const out = new Uint8Array(16);
  words.forEach((w, i) => {
    out[2 * i] = w >> 8;
    out[2 * i + 1] = w & 0xff;
  });
  return out;
}

/** The IPv4 address an IPv6 one stands for, and how: IPv4-mapped (`::ffff:0:0/96`) or -compatible (`::/96`, not `::`
 *  or `::1`), taken as the IPv4 one; or one that `carried` it to an IPv4 network elsewhere: the well-known NAT64
 *  prefix (`64:ff9b::/96`, a translator), 6to4 (`2002:<v4>::/48`, a relay). The same rules as the gateway's `addressKind` (nest). */
function embeddedV4(b: Uint8Array): { v4: Uint8Array; carried: boolean } | null {
  const zero = (from: number, to: number) => b.subarray(from, to).every((x) => x === 0);
  if (zero(0, 10) && b[10] === 0xff && b[11] === 0xff) return { v4: b.subarray(12), carried: false };
  if (zero(0, 12) && !zero(12, 15)) return { v4: b.subarray(12), carried: false };
  if (b[0] === 0x00 && b[1] === 0x64 && b[2] === 0xff && b[3] === 0x9b && zero(4, 12)) return { v4: b.subarray(12), carried: true };
  if (b[0] === 0x20 && b[1] === 0x02) return { v4: b.subarray(2, 6), carried: true };
  return null;
}

/** What kind of address `ip` is (as the server's gateway decides it): loopback; one nobody sends ICE checks to
 *  (unspecified, multicast, broadcast, link-local); a private network's (RFC 1918, CGNAT 100.64/10, IPv6 ULA
 *  fc00::/7, site-local fec0::/10, local-use NAT64 64:ff9b:1::/48); or public. An IPv4-mapped or -compatible IPv6
 *  address is its IPv4 one; one that carries an IPv4 address elsewhere (well-known NAT64, 6to4) is that one's kind
 *  when public or private, else `never` (a loopback inside it is a translator's or relay's). null: not an IP (an mDNS
 *  name). */
export function addressKind(ip: string): "loopback" | "never" | "private" | "public" | null {
  const b = ipBytes(ip);
  if (!b) return null;
  if (b.length === 4) return v4Kind(b);
  // local-use NAT64 (RFC 8215): a network's own translator, reaching its own IPv4 side
  if (b[0] === 0x00 && b[1] === 0x64 && b[2] === 0xff && b[3] === 0x9b && b[4] === 0x00 && b[5] === 0x01) return "private";
  const e = embeddedV4(b);
  if (e) {
    const k = v4Kind(e.v4);
    return !e.carried || k === "public" || k === "private" ? k : "never";
  }
  return v6Kind(b);
}

function v4Kind(b: Uint8Array): "loopback" | "never" | "private" | "public" {
  const x = b[0]!;
  const y = b[1]!;
  if (x === 127) return "loopback";
  if (x === 0 || x >= 224 || (x === 169 && y === 254)) return "never";
  if (x === 10 || (x === 172 && y >= 16 && y <= 31) || (x === 192 && y === 168) || (x === 100 && y >= 64 && y <= 127)) return "private";
  return "public";
}

function v6Kind(b: Uint8Array): "loopback" | "never" | "private" | "public" {
  const zero15 = b.subarray(0, 15).every((x) => x === 0);
  if (zero15 && b[15] === 1) return "loopback";
  if (zero15 && b[15] === 0) return "never";
  if (b[0] === 0xff || (b[0] === 0xfe && (b[1]! & 0xc0) === 0x80)) return "never";
  if ((b[0]! & 0xfe) === 0xfc) return "private";
  // site-local (deprecated, RFC 3879: still a site's own)
  if (b[0] === 0xfe && (b[1]! & 0xc0) === 0xc0) return "private";
  return "public";
}

/** Whether a candidate (the fields after `a=candidate:`) may go out under `"public"`. */
export function isPublicCandidate(fields: string[]): boolean {
  if (fields.length < 8 || fields[2]!.toLowerCase() !== "udp" || fields[6] !== "typ") return false;
  if (!["host", "srflx", "relay"].includes(fields[7]!)) return false;
  const port = Number(fields[5]);
  if (!Number.isInteger(port) || port < 1024 || port > 65535) return false;
  return addressKind(fields[4]!) === "public";
}

/** The offer to send: `sdp` with the candidates `policy` lets through, at most `MAX_OFFER_CANDIDATES` (the
 *  highest priority ones), every other line as it was. */
export function offerSdp(sdp: string, policy: CandidatePolicy = "all"): string {
  const eol = sdp.includes("\r\n") ? "\r\n" : "\n";
  const lines = sdp.split(eol);
  const candidates: { i: number; fields: string[]; priority: number }[] = [];
  lines.forEach((l, i) => {
    if (!l.startsWith("a=candidate:")) return;
    const fields = l.slice("a=candidate:".length).trim().split(/\s+/);
    candidates.push({ i, fields, priority: Number(fields[3]) || 0 });
  });
  let keep = candidates.filter((c) => policy === "all" || isPublicCandidate(c.fields));
  if (keep.length > MAX_OFFER_CANDIDATES) {
    const top = new Set([...keep].sort((a, b) => b.priority - a.priority).slice(0, MAX_OFFER_CANDIDATES));
    keep = keep.filter((c) => top.has(c));
  }
  const kept = new Map(keep.map((c) => [c.i, c]));
  const out: string[] = [];
  lines.forEach((l, i) => {
    if (!l.startsWith("a=candidate:")) {
      out.push(l);
      return;
    }
    const c = kept.get(i);
    if (!c) return;
    if (policy === "public") {
      // the related address is the device's own (private) one: not sent
      const f = [...c.fields];
      const r = f.indexOf("raddr");
      if (r > 7 && r + 1 < f.length) f[r + 1] = "0.0.0.0";
      const p = f.indexOf("rport");
      if (p > 7 && p + 1 < f.length) f[p + 1] = "0";
      out.push(`a=candidate:${f.join(" ")}`);
    } else {
      out.push(l);
    }
  });
  return out.join(eol);
}
