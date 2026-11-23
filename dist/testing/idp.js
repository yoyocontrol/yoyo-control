// A stand-in OpenID provider for tests and trying things out (never for anything real). It signs in whoever
// `user` is without a form, checks what a real one checks (client authentication, redirect_uri, PKCE, one-time codes),
// and rotates refresh tokens with reuse detection (a used one kills its family, as careful providers do). `mode` makes the
// token endpoint fail the ways the account server must tell apart.
import { createHash, generateKeyPairSync, randomBytes } from "node:crypto";
import { createServer } from "node:http";
import { exportJWK, SignJWT } from "jose";
export class TestIdp {
    server;
    issuer = "";
    /** What `iss` the id_tokens carry (default: the issuer). */
    issClaim = null;
    /** What `issuer` the discovery document names (default: the issuer). */
    discoveryIssuer = null;
    user = { sub: "u-alice", name: "Alice" };
    clientId = "example-account";
    clientSecret = "test-secret with spaces&symbols";
    /** Only `client_secret_post` advertised (and taken). */
    postOnly = false;
    scopes = ["openid", "profile", "email", "offline_access"];
    issParam = false;
    giveRefresh = true;
    rotate = true;
    mode = "ok";
    /** The next refresh answers after this long (a race test holds two in flight). */
    refreshDelayMs = 0;
    /** Every /authorize request's parameters. */
    authorizeRequests = [];
    refreshCalls = 0;
    /** What /authorize answers instead of a code. */
    authorizeError = null;
    nonceOverride = null;
    audOverride = null;
    azp = null;
    idTokenExpiresIn = 300;
    key = generateKeyPairSync("rsa", { modulusLength: 2048 });
    kid = randomBytes(6).toString("hex");
    codes = new Map();
    /** refresh token → its family and whether it is still the live one */
    refresh = new Map();
    deadFamilies = new Set();
    async start() {
        this.server = createServer((req, res) => void this.handle(req, res));
        await new Promise((r) => this.server.listen(0, "127.0.0.1", r));
        this.issuer = `http://127.0.0.1:${this.server.address().port}`;
        return this;
    }
    async stop() {
        this.server.closeAllConnections();
        await new Promise((r) => this.server.close(r));
    }
    /** Every refresh token of `sub` dead (the IdP's "sign out everywhere", or the user disabled). */
    revokeUser(sub) {
        for (const [, r] of this.refresh)
            if (r.user.sub === sub)
                this.deadFamilies.add(r.family);
    }
    liveRefreshTokens() {
        return [...this.refresh].filter(([, r]) => r.live && !this.deadFamilies.has(r.family)).map(([t]) => t);
    }
    async idToken(user, nonce) {
        const { sub, ...claims } = user;
        return new SignJWT({ ...claims, ...(nonce !== undefined ? { nonce: this.nonceOverride ?? nonce } : {}), ...(this.azp ? { azp: this.azp } : {}) })
            .setProtectedHeader({ alg: "RS256", kid: this.kid })
            .setIssuer(this.issClaim ?? this.issuer)
            .setSubject(sub)
            .setAudience(this.audOverride ?? this.clientId)
            .setIssuedAt()
            .setExpirationTime(Math.floor(Date.now() / 1000) + this.idTokenExpiresIn)
            .sign(this.key.privateKey);
    }
    newRefresh(user, family = randomBytes(6).toString("hex")) {
        const t = `rt-${randomBytes(16).toString("base64url")}`;
        this.refresh.set(t, { family, user, live: true });
        return t;
    }
    json(res, status, body) {
        res.writeHead(status, { "content-type": "application/json" });
        res.end(JSON.stringify(body));
    }
    async handle(req, res) {
        const u = new URL(req.url ?? "/", this.issuer);
        if (u.pathname === "/.well-known/openid-configuration") {
            return this.json(res, 200, {
                issuer: this.discoveryIssuer ?? this.issuer,
                authorization_endpoint: `${this.issuer}/authorize`,
                token_endpoint: `${this.issuer}/token`,
                jwks_uri: `${this.issuer}/jwks`,
                scopes_supported: this.scopes,
                token_endpoint_auth_methods_supported: this.postOnly ? ["client_secret_post"] : ["client_secret_basic", "client_secret_post"],
                id_token_signing_alg_values_supported: ["RS256", "none", "HS256"],
                code_challenge_methods_supported: ["S256"],
                ...(this.issParam ? { authorization_response_iss_parameter_supported: true } : {}),
            });
        }
        if (u.pathname === "/jwks")
            return this.json(res, 200, { keys: [{ ...(await exportJWK(this.key.publicKey)), kid: this.kid, alg: "RS256", use: "sig" }] });
        if (u.pathname === "/authorize") {
            this.authorizeRequests.push(u.searchParams);
            const p = u.searchParams;
            const back = new URL(p.get("redirect_uri"));
            back.searchParams.set("state", p.get("state") ?? "");
            if (this.issParam)
                back.searchParams.set("iss", this.issuer);
            if (this.authorizeError)
                back.searchParams.set("error", this.authorizeError);
            else {
                const code = randomBytes(12).toString("base64url");
                this.codes.set(code, { user: { ...this.user }, nonce: p.get("nonce") ?? "", challenge: p.get("code_challenge") ?? "", redirect: p.get("redirect_uri") ?? "", scope: p.get("scope") ?? "" });
                back.searchParams.set("code", code);
            }
            res.writeHead(302, { location: back.toString() });
            return res.end();
        }
        if (u.pathname === "/token" && req.method === "POST") {
            const chunks = [];
            for await (const c of req)
                chunks.push(c);
            const body = new URLSearchParams(Buffer.concat(chunks).toString("utf8"));
            if (this.mode === "drop")
                return req.socket.destroy();
            if (this.mode === "5xx")
                return this.json(res, 503, { error: "temporarily_unavailable" });
            if (this.mode === "429")
                return this.json(res, 429, { error: "slow_down" });
            if (this.mode === "html") {
                res.writeHead(502, { "content-type": "text/html" });
                return res.end("<html>bad gateway</html>");
            }
            let id = "";
            let secret = "";
            const basic = /^Basic (.+)$/.exec(req.headers.authorization ?? "");
            if (basic && !this.postOnly) {
                const [a, b] = Buffer.from(basic[1], "base64").toString("utf8").split(":");
                const dec = (s) => decodeURIComponent(s.replace(/\+/g, " "));
                id = dec(a ?? "");
                secret = dec(b ?? "");
            }
            else {
                id = body.get("client_id") ?? "";
                secret = body.get("client_secret") ?? "";
            }
            if (this.mode === "invalid_client" || id !== this.clientId || secret !== this.clientSecret)
                return this.json(res, 401, { error: "invalid_client" });
            if (body.get("grant_type") === "authorization_code") {
                const c = this.codes.get(body.get("code") ?? "");
                this.codes.delete(body.get("code") ?? "");
                const verifier = body.get("code_verifier") ?? "";
                if (!c || c.redirect !== body.get("redirect_uri") || createHash("sha256").update(verifier).digest("base64url") !== c.challenge)
                    return this.json(res, 400, { error: "invalid_grant" });
                return this.json(res, 200, {
                    access_token: "at-opaque",
                    token_type: "Bearer",
                    id_token: await this.idToken(c.user, c.nonce),
                    ...(this.giveRefresh ? { refresh_token: this.newRefresh(c.user) } : {}),
                    scope: c.scope,
                });
            }
            if (body.get("grant_type") === "refresh_token") {
                this.refreshCalls++;
                if (this.refreshDelayMs)
                    await new Promise((r) => setTimeout(r, this.refreshDelayMs));
                const t = body.get("refresh_token") ?? "";
                const r = this.refresh.get(t);
                if (!r || this.deadFamilies.has(r.family))
                    return this.json(res, 400, { error: "invalid_grant" });
                if (!r.live) {
                    // reuse of a rotated token: the whole family dies (reuse detection)
                    this.deadFamilies.add(r.family);
                    return this.json(res, 400, { error: "invalid_grant", error_description: "reused" });
                }
                let next;
                if (this.rotate) {
                    r.live = false;
                    next = this.newRefresh(r.user, r.family);
                }
                return this.json(res, 200, { access_token: "at-opaque", token_type: "Bearer", id_token: await this.idToken(r.user, undefined), ...(next ? { refresh_token: next } : {}) });
            }
            return this.json(res, 400, { error: "unsupported_grant_type" });
        }
        this.json(res, 404, { error: "not_found" });
    }
}
