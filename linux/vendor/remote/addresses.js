// This host's addresses as a phone may reach them on its local network (the pairing link's `a`): the interfaces', or
// what the caller advertises instead (a container doesn't see its host's address).
import { networkInterfaces } from "node:os";
import { classifyIPv4 } from "./portmap/index.js";
/** This host's IPv4 addresses a phone may reach: every interface's but loopback and link-local, in interface order. */
export function interfaceAddresses(ifaces = networkInterfaces()) {
    const out = [];
    for (const list of Object.values(ifaces)) {
        for (const a of list ?? []) {
            if ((a.family !== "IPv4" && a.family !== 4) || a.internal)
                continue;
            const c = classifyIPv4(a.address);
            if (!c || c === "loopback" || c === "link-local" || c === "unspecified")
                continue;
            if (!out.includes(a.address))
                out.push(a.address);
        }
    }
    return out;
}
/**
 * `"ip"`, `"ip:port"` or `{ host, port? }` → an endpoint (`port` default `defaultPort`); IPv4 only (what a pairing
 * link carries). Throws on anything else.
 */
export function parseEndpoint(e, defaultPort) {
    let host;
    let port;
    if (typeof e === "string") {
        const m = /^([^:]+)(?::(\d+))?$/.exec(e.trim());
        if (!m)
            throw new Error(`not an ip[:port]: ${e}`);
        host = m[1];
        port = m[2] !== undefined ? Number(m[2]) : undefined;
    }
    else {
        host = e.host;
        port = e.port;
    }
    if (!classifyIPv4(host))
        throw new Error(`not an IPv4 address: ${host}`);
    const p = port ?? defaultPort;
    if (!Number.isInteger(p) || p < 1 || p > 65535)
        throw new Error(`not a port: ${p}`);
    return { host, port: p };
}
