// The account server's settings (docs/ACCOUNT-LIB.md), from the environment. Three of them say which IdP:
// ACCOUNT_OIDC_ISSUER, ACCOUNT_OIDC_CLIENT_ID, ACCOUNT_OIDC_CLIENT_SECRET (or _FILE). Everything else has a default
// except the server's own public origin. Pure: main.ts reads the environment and the secret file and hands them here.
// A program that embeds the server builds an AccountConfig itself instead (its `services` are any it lends).
import { Wire } from "@yoyocontrol/account";
export const GOOGLE_ISSUER = "https://accounts.google.com";
/** The two ways Google writes `iss` in an id_token (its OpenID docs: both occur). */
export const GOOGLE_ISSUERS = [GOOGLE_ISSUER, "accounts.google.com"];
/**
 * IdPs anyone can sign up at: the account server refuses to start against one unless ACCOUNT_ALLOW narrows who may
 * sign in, or ACCOUNT_OPEN=1 says that anyone with an account there may (and then gets an account here). Matched on
 * the issuer's host (and path, for the multi-tenant Microsoft endpoints). Not exhaustive: a self-hosted IdP with
 * self-registration turned on is just as open, and only its admin knows.
 */
export const OPEN_ISSUERS = [
    /^https:\/\/accounts\.google\.com$/,
    /^https:\/\/appleid\.apple\.com$/,
    /^https:\/\/login\.microsoftonline\.com\/(common|consumers|organizations|9188040d-6c67-4c5b-b112-36a304b66dad)(\/v2\.0)?$/,
    /^https:\/\/login\.live\.com$/,
    /^https:\/\/gitlab\.com$/,
];
export class ConfigError extends Error {
}
const isLocalHost = (h) => h === "localhost" || h === "127.0.0.1" || h === "[::1]" || h.endsWith(".localhost");
/** An https URL (http only for a loopback host: tests and local runs), without a trailing slash. */
function httpsUrl(name, v, opts = {}) {
    let u;
    try {
        u = new URL(v);
    }
    catch {
        throw new ConfigError(`${name} is a URL, not ${JSON.stringify(v)}`);
    }
    if (u.protocol !== "https:" && !(u.protocol === "http:" && isLocalHost(u.hostname)))
        throw new ConfigError(`${name} must be https (http only on localhost)`);
    if (u.search || u.hash || u.username || u.password)
        throw new ConfigError(`${name} has no query, fragment or credentials`);
    if (!opts.path && u.pathname !== "/")
        throw new ConfigError(`${name} is an origin (no path): ${v}`);
    return opts.path ? `${u.origin}${u.pathname.replace(/\/$/, "")}` : u.origin;
}
/** An issuer as it is compared: no trailing slash; Google's bare form written as its URL. */
export function normalizeIssuer(iss) {
    const t = iss.trim().replace(/\/+$/, "");
    return t === "accounts.google.com" ? GOOGLE_ISSUER : t;
}
export const isGoogle = (issuer) => normalizeIssuer(issuer) === GOOGLE_ISSUER;
export function parseAllow(v) {
    const items = (v ?? "").split(",").map((s) => s.trim()).filter(Boolean);
    if (!items.length)
        return null;
    const subs = new Set();
    const domains = [];
    for (const i of items) {
        if (i.startsWith("@")) {
            const d = i.slice(1).toLowerCase();
            if (!/^[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(d))
                throw new ConfigError(`ACCOUNT_ALLOW: ${i} is not @<domain>`);
            domains.push(d);
        }
        else
            subs.add(i);
    }
    return { subs, domains };
}
/** Whether these (verified) id_token claims may sign in. */
export function allowed(allow, issuer, claims) {
    if (!allow)
        return true;
    if (allow.subs.has(claims.sub))
        return true;
    if (!allow.domains.length)
        return false;
    if (isGoogle(issuer)) {
        // Google: the Workspace domain is `hd`; a gmail.com address with a custom domain's alias is not that domain
        return typeof claims.hd === "string" && allow.domains.includes(claims.hd.toLowerCase());
    }
    if (claims.email_verified !== true || typeof claims.email !== "string")
        return false;
    const at = claims.email.lastIndexOf("@");
    return at > 0 && allow.domains.includes(claims.email.slice(at + 1).toLowerCase());
}
/** Why this configuration must not start (an open IdP nobody narrowed), or null. */
export function opennessProblem(cfg) {
    if (cfg.allow || cfg.open)
        return null;
    if (!OPEN_ISSUERS.some((re) => re.test(normalizeIssuer(cfg.issuer))))
        return null;
    return `${cfg.issuer} lets anyone sign in: set ACCOUNT_ALLOW (subs, or @domain) or, if anyone with an account there may have one here, ACCOUNT_OPEN=1`;
}
/** An https origin and nothing after it (http for a loopback host: tests). */
function originOf(name, v) {
    const u = httpsUrl(name, v);
    if (new URL(u).origin !== u)
        throw new ConfigError(`${name} is an origin: https://host[:port], nothing after it`);
    return u;
}
const RELAY_TOKEN_RE = /^[A-Za-z0-9_-]{16,128}$/;
/** `relayTokenFile` / `signalKeyFile`: read ACCOUNT_RELAY_TOKEN_FILE / ACCOUNT_SIGNAL_KEY_FILE as they are now (main.ts:
 *  again when the file changed). */
export function configFromEnv(env, secretFromFile, relayTokenFile, signalKeyFile) {
    const need = (k) => {
        const v = env[k]?.trim();
        if (!v)
            throw new ConfigError(`${k} is needed`);
        return v;
    };
    const issuer = normalizeIssuer(httpsUrl("ACCOUNT_OIDC_ISSUER", need("ACCOUNT_OIDC_ISSUER"), { path: true }));
    const clientId = need("ACCOUNT_OIDC_CLIENT_ID");
    const clientSecret = (env.ACCOUNT_OIDC_CLIENT_SECRET?.trim() || secretFromFile?.trim()) ?? "";
    if (!clientSecret)
        throw new ConfigError("ACCOUNT_OIDC_CLIENT_SECRET (or ACCOUNT_OIDC_CLIENT_SECRET_FILE) is needed: the account server is a confidential client");
    const publicUrl = httpsUrl("ACCOUNT_PUBLIC_URL", need("ACCOUNT_PUBLIC_URL"));
    const list = (k) => (env[k] ?? "").split(",").map((s) => s.trim()).filter(Boolean);
    const appRedirects = list("ACCOUNT_APP_REDIRECTS");
    for (const r of appRedirects) {
        let u;
        try {
            u = new URL(r);
        }
        catch {
            throw new ConfigError(`ACCOUNT_APP_REDIRECTS: ${r} is not a URL`);
        }
        if (u.hash)
            throw new ConfigError(`ACCOUNT_APP_REDIRECTS: ${r} has a fragment`);
        if (u.protocol === "http:" && !isLocalHost(u.hostname))
            throw new ConfigError(`ACCOUNT_APP_REDIRECTS: ${r} is plain http`);
        if (["javascript:", "data:", "file:", "blob:"].includes(u.protocol))
            throw new ConfigError(`ACCOUNT_APP_REDIRECTS: ${r}`);
    }
    const webRedirects = list("ACCOUNT_WEB_REDIRECTS").map((r) => httpsUrl("ACCOUNT_WEB_REDIRECTS", r, { path: true }));
    // (a code that goes back to one of these makes a web page's key-bound session: no app's address may be one too)
    for (const r of webRedirects) {
        if (appRedirects.includes(r) || r === `${publicUrl}/v1/app-return`)
            throw new ConfigError(`ACCOUNT_WEB_REDIRECTS: ${r} is an app's redirect too`);
    }
    const appleAppIds = list("ACCOUNT_APPLE_APP_IDS");
    for (const a of appleAppIds)
        if (!/^[A-Z0-9]{10}\.[A-Za-z0-9.-]+$/.test(a))
            throw new ConfigError(`ACCOUNT_APPLE_APP_IDS: ${a} is not TEAMID.bundle.id`);
    const flag = (k) => {
        const v = (env[k] ?? "").trim();
        if (v === "" || v === "0")
            return false;
        if (v === "1")
            return true;
        throw new ConfigError(`${k} is 1 or 0, not ${v}`);
    };
    const port = Number(env.ACCOUNT_PORT ?? 4490);
    if (!Number.isInteger(port) || port <= 0 || port > 65535)
        throw new ConfigError("ACCOUNT_PORT");
    const relayUrl = env.ACCOUNT_RELAY_URL?.trim();
    const fixedToken = env.ACCOUNT_RELAY_TOKEN?.trim() || "";
    const relayTokenNow = () => {
        const t = fixedToken || relayTokenFile?.()?.trim() || "";
        return RELAY_TOKEN_RE.test(t) ? t : null;
    };
    if (relayUrl && relayTokenNow() === null)
        throw new ConfigError("ACCOUNT_RELAY_URL needs ACCOUNT_RELAY_TOKEN (or ACCOUNT_RELAY_TOKEN_FILE): the relay's token for this server's accounts, 16-128 of [A-Za-z0-9_-]");
    if (!relayUrl && (fixedToken || relayTokenFile))
        throw new ConfigError("ACCOUNT_RELAY_TOKEN without ACCOUNT_RELAY_URL");
    const signalUrl = env.ACCOUNT_SIGNAL_URL?.trim();
    const fixedKey = env.ACCOUNT_SIGNAL_KEY?.trim() || "";
    const signalKeyNow = () => {
        const k = fixedKey || signalKeyFile?.()?.trim() || "";
        // (never the relay token: that one rides in every relay URL a computer hands its devices)
        return RELAY_TOKEN_RE.test(k) && k !== relayTokenNow() ? k : null;
    };
    if (signalUrl && !relayUrl)
        throw new ConfigError("ACCOUNT_SIGNAL_URL needs ACCOUNT_RELAY_URL: browsers post their offers there with the relay's token");
    if (signalUrl && signalKeyNow() === null)
        throw new ConfigError("ACCOUNT_SIGNAL_URL needs ACCOUNT_SIGNAL_KEY (or ACCOUNT_SIGNAL_KEY_FILE): the signaling service's computer key for this server's accounts, 16-128 of [A-Za-z0-9_-], not the relay token");
    if (!signalUrl && (fixedKey || signalKeyFile))
        throw new ConfigError("ACCOUNT_SIGNAL_KEY without ACCOUNT_SIGNAL_URL");
    const pushUrl = env.ACCOUNT_PUSH_URL?.trim();
    const speechUrl = env.ACCOUNT_SPEECH_URL?.trim();
    let wire;
    try {
        wire = new Wire(env.ACCOUNT_NAMESPACE?.trim() || undefined);
    }
    catch (e) {
        throw new ConfigError(`ACCOUNT_NAMESPACE: ${e.message}`);
    }
    const services = [];
    if (relayUrl) {
        const url = originOf("ACCOUNT_RELAY_URL", relayUrl);
        services.push({ name: "relay", kind: "fixed", value: () => {
                const token = relayTokenNow();
                return token ? { url, token } : null;
            } });
    }
    if (pushUrl)
        services.push({ name: "push", kind: "token", url: originOf("ACCOUNT_PUSH_URL", pushUrl), service: "push" });
    if (speechUrl)
        services.push({ name: "speech", kind: "token", url: originOf("ACCOUNT_SPEECH_URL", speechUrl), service: "speech" });
    if (signalUrl) {
        const url = originOf("ACCOUNT_SIGNAL_URL", signalUrl);
        services.push({ name: "signal", kind: "fixed", value: () => {
                // (lent with the relay only: browsers post their offers there with the relay's token)
                const key = relayTokenNow() ? signalKeyNow() : null;
                return key ? { url, key } : null;
            } });
    }
    if (webRedirects[0]) {
        const url = new URL(webRedirects[0]).origin;
        services.push({ name: "web", kind: "fixed", value: () => ({ url }) });
    }
    const cfg = {
        issuer,
        clientId,
        clientSecret,
        publicUrl,
        allow: parseAllow(env.ACCOUNT_ALLOW),
        open: flag("ACCOUNT_OPEN"),
        recheck: flag("ACCOUNT_IDP_RECHECK"),
        appRedirects,
        webRedirects,
        appleAppIds,
        idpName: env.ACCOUNT_IDP_NAME?.trim() || new URL(issuer).host,
        serverName: env.ACCOUNT_SERVER_NAME?.trim() || new URL(publicUrl).host,
        dataDir: env.ACCOUNT_DATA_DIR?.trim() || "/data",
        host: env.ACCOUNT_HOST?.trim() || "127.0.0.1",
        port,
        trustProxy: flag("ACCOUNT_TRUST_PROXY"),
        wire,
        services,
    };
    const open = opennessProblem(cfg);
    if (open)
        throw new ConfigError(open);
    return cfg;
}
