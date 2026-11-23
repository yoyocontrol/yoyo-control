/** An address's bytes: 4 for IPv4, 16 for IPv6 (every spelling: `::`, a dotted IPv4 tail, hex groups), or null. A zone
 *  (`%en0`) and brackets are left off. Validated by `net.isIP` first, then expanded without guessing. */
export declare function ipBytes(ip: string): Uint8Array | null;
/** An address as the Link core will take it: an IPv6 one that stands for an IPv4 one (mapped, compatible) as that IPv4
 *  one, dotted; others as given (without zone or brackets). null: not an IP. */
export declare function normalizeIp(ip: string): string | null;
/** Where an offer came from, as the server decided (app.ts rtcSource): this computer itself (a page on localhost), a
 *  private network (the LAN, an overlay network's 100.64/10), or a public address (a page elsewhere, through the signaling
 *  service). */
export type OfferScope = "this computer" | "private" | "public";
/** What kind of address `ip` is: loopback, one the core never checks towards (unspecified, multicast, link-local,
 *  broadcast), one of a private network (RFC 1918, CGNAT / a tailnet, IPv6 ULA fc00::/7, site-local fec0::/10,
 *  local-use NAT64 64:ff9b:1::/48), or a public one. null: not an IP. An IPv4-mapped or -compatible IPv6 address is
 *  its IPv4 one; one that carries an IPv4 address elsewhere (NAT64, 6to4) is that one's kind when it is private or
 *  public, otherwise `never` (a loopback inside it is a translator's or relay's, never this computer's). */
export declare function addressKind(ip: string): "loopback" | "never" | "private" | "public" | null;
