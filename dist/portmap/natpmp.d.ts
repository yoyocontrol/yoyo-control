export declare const PMP_PORT = 5351;
/** RFC 6886 §3.1: 250 ms, doubling. Three tries (1.75 s) are enough on a LAN; a router that is silent doesn't speak it. */
export declare const PMP_TIMEOUTS_MS: number[];
export type Protocol = "tcp" | "udp";
export declare const PMP_RESULTS: Record<number, string>;
export declare function pmpExternalAddressRequest(): Uint8Array;
export interface PmpExternalAddress {
    result: number;
    epoch: number;
    address: string;
}
export declare function parsePmpExternalAddress(b: Uint8Array): PmpExternalAddress | null;
/** A mapping request. `lifetime` 0 with `externalPort` 0 deletes the mapping of `internalPort`. */
export declare function pmpMapRequest(protocol: Protocol, internalPort: number, externalPort: number, lifetime: number): Uint8Array;
export interface PmpMapResponse {
    result: number;
    epoch: number;
    internalPort: number;
    externalPort: number;
    lifetime: number;
}
export declare function parsePmpMapResponse(b: Uint8Array, protocol: Protocol): PmpMapResponse | null;
export declare const PCP_VERSION = 2;
export declare const PCP_OP_ANNOUNCE = 0;
export declare const PCP_OP_MAP = 1;
export declare const PCP_RESULTS: Record<number, string>;
/** `::ffff:a.b.c.d`, or the all-zero IPv4 "any" (`::ffff:0.0.0.0`) for an empty / unparsable address. */
export declare function ipv4Mapped(address: string): Uint8Array;
export declare function pcpAnnounceRequest(clientAddress: string): Uint8Array;
export interface PcpMapRequest {
    nonce: Uint8Array;
    protocol: Protocol;
    internalPort: number;
    externalPort: number;
    externalAddress?: string;
    lifetime: number;
    clientAddress: string;
}
export declare function pcpMapRequest(r: PcpMapRequest): Uint8Array;
export interface PcpResponse {
    version: number;
    opcode: number;
    result: number;
    lifetime: number;
    epoch: number;
    /** MAP only */
    map?: {
        nonce: Uint8Array;
        protocol: number;
        internalPort: number;
        externalPort: number;
        externalAddress: string | null;
    };
}
/**
 * Parses a PCP response. A NAT-PMP-only gateway answers a PCP request with a NAT-PMP header (version 0, result 1
 * "unsupported version"): that comes back as `{ version: 0, result: 1 }`.
 */
export declare function parsePcpResponse(b: Uint8Array): PcpResponse | null;
