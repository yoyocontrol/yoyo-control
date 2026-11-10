// NAT-PMP (RFC 6886) and PCP (RFC 6887) packets: pure encoders and decoders. Both talk to the gateway on UDP 5351.
import { parseIPv4 } from "./address.js";
export const PMP_PORT = 5351;
/** RFC 6886 §3.1: 250 ms, doubling. Three tries (1.75 s) are enough on a LAN; a router that is silent doesn't speak it. */
export const PMP_TIMEOUTS_MS = [250, 500, 1000];
// ---- NAT-PMP ----
export const PMP_RESULTS = {
    0: "success",
    1: "unsupported version",
    2: "not authorized / refused",
    3: "network failure",
    4: "out of resources",
    5: "unsupported opcode",
};
export function pmpExternalAddressRequest() {
    return Uint8Array.of(0, 0);
}
export function parsePmpExternalAddress(b) {
    if (b.length < 8 || b[0] !== 0 || b[1] !== 128)
        return null;
    const v = view(b);
    const result = v.getUint16(2);
    if (result !== 0)
        return { result, epoch: 0, address: "" };
    if (b.length < 12)
        return null;
    return { result, epoch: v.getUint32(4), address: `${b[8]}.${b[9]}.${b[10]}.${b[11]}` };
}
/** A mapping request. `lifetime` 0 with `externalPort` 0 deletes the mapping of `internalPort`. */
export function pmpMapRequest(protocol, internalPort, externalPort, lifetime) {
    const b = new Uint8Array(12);
    const v = view(b);
    b[0] = 0;
    b[1] = protocol === "udp" ? 1 : 2;
    v.setUint16(4, internalPort);
    v.setUint16(6, externalPort);
    v.setUint32(8, lifetime);
    return b;
}
export function parsePmpMapResponse(b, protocol) {
    const op = protocol === "udp" ? 129 : 130;
    if (b.length < 4 || b[0] !== 0 || b[1] !== op)
        return null;
    const v = view(b);
    const result = v.getUint16(2);
    if (result !== 0)
        return { result, epoch: 0, internalPort: 0, externalPort: 0, lifetime: 0 };
    if (b.length < 16)
        return null;
    return { result, epoch: v.getUint32(4), internalPort: v.getUint16(8), externalPort: v.getUint16(10), lifetime: v.getUint32(12) };
}
// ---- PCP ----
export const PCP_VERSION = 2;
export const PCP_OP_ANNOUNCE = 0;
export const PCP_OP_MAP = 1;
export const PCP_RESULTS = {
    0: "success",
    1: "unsupported version",
    2: "not authorized",
    3: "malformed request",
    4: "unsupported opcode",
    5: "unsupported option",
    6: "malformed option",
    7: "network failure",
    8: "no resources",
    9: "unsupported protocol",
    10: "user exceeded quota",
    11: "cannot provide external",
    12: "address mismatch",
    13: "excessive remote peers",
};
/** `::ffff:a.b.c.d`, or the all-zero IPv4 "any" (`::ffff:0.0.0.0`) for an empty / unparsable address. */
export function ipv4Mapped(address) {
    const out = new Uint8Array(16);
    out[10] = 0xff;
    out[11] = 0xff;
    const o = parseIPv4(address);
    if (o)
        out.set(o, 12);
    return out;
}
function mappedToIPv4(b, at) {
    for (let i = 0; i < 10; i++)
        if (b[at + i] !== 0)
            return null;
    if (b[at + 10] !== 0xff || b[at + 11] !== 0xff)
        return null;
    return `${b[at + 12]}.${b[at + 13]}.${b[at + 14]}.${b[at + 15]}`;
}
function pcpHeader(b, opcode, lifetime, clientAddress) {
    b[0] = PCP_VERSION;
    b[1] = opcode & 0x7f;
    view(b).setUint32(4, lifetime);
    b.set(ipv4Mapped(clientAddress), 8);
}
export function pcpAnnounceRequest(clientAddress) {
    const b = new Uint8Array(24);
    pcpHeader(b, PCP_OP_ANNOUNCE, 0, clientAddress);
    return b;
}
export function pcpMapRequest(r) {
    if (r.nonce.length !== 12)
        throw new Error("PCP nonce must be 12 bytes");
    const b = new Uint8Array(60);
    pcpHeader(b, PCP_OP_MAP, r.lifetime, r.clientAddress);
    b.set(r.nonce, 24);
    b[36] = r.protocol === "udp" ? 17 : 6;
    const v = view(b);
    v.setUint16(40, r.internalPort);
    v.setUint16(42, r.externalPort);
    b.set(ipv4Mapped(r.externalAddress ?? ""), 44);
    return b;
}
/**
 * Parses a PCP response. A NAT-PMP-only gateway answers a PCP request with a NAT-PMP header (version 0, result 1
 * "unsupported version"): that comes back as `{ version: 0, result: 1 }`.
 */
export function parsePcpResponse(b) {
    if (b.length < 4)
        return null;
    if (b[0] === 0) {
        // NAT-PMP's answer: op ≥ 128, 16-bit result
        if ((b[1] & 0x80) === 0)
            return null;
        return { version: 0, opcode: b[1] & 0x7f, result: view(b).getUint16(2), lifetime: 0, epoch: 0 };
    }
    if (b.length < 24 || (b[1] & 0x80) === 0)
        return null;
    const v = view(b);
    const res = { version: b[0], opcode: b[1] & 0x7f, result: b[3], lifetime: v.getUint32(4), epoch: v.getUint32(8) };
    if (res.opcode === PCP_OP_MAP && b.length >= 60) {
        res.map = {
            nonce: b.slice(24, 36),
            protocol: b[36],
            internalPort: v.getUint16(40),
            externalPort: v.getUint16(42),
            externalAddress: mappedToIPv4(b, 44),
        };
    }
    return res;
}
function view(b) {
    return new DataView(b.buffer, b.byteOffset, b.byteLength);
}
