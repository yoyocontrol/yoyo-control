// IPv4 address classes: whether the address a router reports as its external one can be reached from the internet.
/** Parses dotted-quad IPv4 into four octets, or null. */
export function parseIPv4(address) {
    const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(address.trim());
    if (!m)
        return null;
    const o = [Number(m[1]), Number(m[2]), Number(m[3]), Number(m[4])];
    return o.every((n) => n <= 255) ? o : null;
}
export function classifyIPv4(address) {
    const o = parseIPv4(address);
    if (!o)
        return null;
    const [a, b, c] = o;
    if (a === 0)
        return "unspecified";
    if (a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168))
        return "private";
    if (a === 100 && b >= 64 && b <= 127)
        return "cgnat";
    if (a === 127)
        return "loopback";
    if (a === 169 && b === 254)
        return "link-local";
    if (a >= 224)
        return "reserved";
    if ((a === 192 && b === 0 && (c === 0 || c === 2)) ||
        (a === 198 && (b === 18 || b === 19)) ||
        (a === 198 && b === 51 && c === 100) ||
        (a === 203 && b === 0 && c === 113))
        return "reserved";
    return "public";
}
/** True when the address is a public unicast IPv4 address. */
export function isPublicIPv4(address) {
    return classifyIPv4(address) === "public";
}
