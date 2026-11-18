/** `"all"`: every candidate the browser gathered (at most `MAX_OFFER_CANDIDATES`). `"public"`: only UDP host,
 *  server-reflexive and relay candidates on a public address and a port ≥ 1024 (no private, ULA, CGNAT, loopback,
 *  link-local, multicast, broadcast or unspecified address, no mDNS name, no TCP); a related address (`raddr`) is
 *  blanked. */
export type CandidatePolicy = "all" | "public";
/** At most this many candidates go out (the gateway refuses an offer with more). */
export declare const MAX_OFFER_CANDIDATES = 32;
/** An IP address's bytes (4 or 16), or null when `ip` isn't one. Takes IPv6 with brackets, a zone (`%en0`) and an
 *  embedded dotted IPv4 tail. */
export declare function ipBytes(ip: string): Uint8Array | null;
/** What kind of address `ip` is (as the server's gateway decides it): loopback; one nobody sends ICE checks to
 *  (unspecified, multicast, broadcast, link-local); a private network's (RFC 1918, CGNAT 100.64/10, IPv6 ULA
 *  fc00::/7, site-local fec0::/10, local-use NAT64 64:ff9b:1::/48); or public. An IPv4-mapped or -compatible IPv6
 *  address is its IPv4 one; one that carries an IPv4 address elsewhere (well-known NAT64, 6to4) is that one's kind
 *  when public or private, else `never` (a loopback inside it is a translator's or relay's). null: not an IP (an mDNS
 *  name). */
export declare function addressKind(ip: string): "loopback" | "never" | "private" | "public" | null;
/** Whether a candidate (the fields after `a=candidate:`) may go out under `"public"`. */
export declare function isPublicCandidate(fields: string[]): boolean;
/** The offer to send: `sdp` with the candidates `policy` lets through, at most `MAX_OFFER_CANDIDATES` (the
 *  highest priority ones), every other line as it was. */
export declare function offerSdp(sdp: string, policy?: CandidatePolicy): string;
