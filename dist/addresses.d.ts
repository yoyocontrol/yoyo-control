import { networkInterfaces } from "node:os";
/** This host's IPv4 addresses a phone may reach: every interface's but loopback and link-local, in interface order. */
export declare function interfaceAddresses(ifaces?: ReturnType<typeof networkInterfaces>): string[];
/**
 * `"ip"`, `"ip:port"` or `{ host, port? }` → an endpoint (`port` default `defaultPort`); IPv4 only (what a pairing
 * link carries). Throws on anything else.
 */
export declare function parseEndpoint(e: string | {
    host: string;
    port?: number;
}, defaultPort: number): {
    host: string;
    port: number;
};
