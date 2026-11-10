export type AddressClass = "public" | "private" | "cgnat" | "loopback" | "link-local" | "unspecified" | "reserved";
/** Parses dotted-quad IPv4 into four octets, or null. */
export declare function parseIPv4(address: string): [number, number, number, number] | null;
export declare function classifyIPv4(address: string): AddressClass | null;
/** True when the address is a public unicast IPv4 address. */
export declare function isPublicIPv4(address: string): boolean;
