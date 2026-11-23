// The account server as a relying party of one OpenID Connect provider (docs/ACCOUNT-LIB.md): the
// authorization code flow with PKCE (S256, sent whether or not the IdP says it supports it), a nonce, the state kept
// here; a confidential client (client_secret_basic, else _post). Only standard things: discovery, the JWKS, the
// id_token. Identity is `iss` + `sub` and nothing else; `name` / `preferred_username` are only what is shown, and
// `email` / `email_verified` / `hd` are read only to match an `@domain` in ACCOUNT_ALLOW.
//
// What differs between IdPs and is handled here, not in settings:
// - Google writes `iss` as https://accounts.google.com or accounts.google.com: both are taken, stored as the first.
// - A refresh token: asked for only when the hourly re-check is on (ACCOUNT_IDP_RECHECK=1). Google: access_type=offline
//   and prompt=consent (it hands one out only on a consent). Others: the `offline_access` scope when the IdP lists it
//   (Keycloak's plain refresh tokens die with its 30-minute-idle browser session).
// - The RFC 9207 `iss` on the callback is checked when the IdP says it sends one.
import { createRemoteJWKSet, customFetch, jwtVerify, type JWTPayload } from "jose";
import { GOOGLE_ISSUERS, isGoogle, normalizeIssuer, type AccountConfig } from "./config.js";

/** Who signed in, from a verified id_token. */
export interface IdpIdentity {
  /** The issuer as stored (normalized: Google's bare form as its URL). */
  iss: string;
  sub: string;
  /** What is shown: `name`, else `preferred_username`; null when neither. */
  name: string | null;
  email?: string;
  email_verified?: boolean;
  hd?: string;
}

export type RefreshOutcome =
  /** The sign-in stands. `refreshToken`: the new one when the IdP rotated it (null = keep the old). */
  | { kind: "ok"; refreshToken: string | null; identity: IdpIdentity | null }
  /** The IdP said, definitely, that this refresh token is no good (signed out, disabled, revoked, reused). */
  | { kind: "invalid_grant" }
  /** Anything else: the network, a 5xx, a 429, a misconfigured client, an id_token that did not verify. */
  | { kind: "retry"; reason: string };

export interface Idp {
  authorizationUrl(p: { state: string; nonce: string; challenge: string; prompt?: string | undefined }): Promise<string>;
  /** Whether the callback's `iss` parameter (RFC 9207) is right, or absent where it may be. */
  callbackIssOk(iss: string | null): Promise<boolean>;
  exchange(code: string, verifier: string, nonce: string): Promise<{ identity: IdpIdentity; refreshToken: string | null }>;
  refresh(refreshToken: string, expectedSub: string): Promise<RefreshOutcome>;
}

export class IdpError extends Error {
  constructor(readonly code: string, message: string) {
    super(message);
  }
}

interface Discovery {
  issuer: string;
  authorization_endpoint: string;
  token_endpoint: string;
  jwks_uri: string;
  scopes_supported?: string[];
  token_endpoint_auth_methods_supported?: string[];
  id_token_signing_alg_values_supported?: string[];
  authorization_response_iss_parameter_supported?: boolean;
  end_session_endpoint?: string;
}

const TIMEOUT_MS = 10_000;
const ASYMMETRIC = /^(RS|PS|ES)(256|384|512)$|^EdDSA$|^Ed25519$/;
const isLocal = (u: URL) => u.hostname === "localhost" || u.hostname === "127.0.0.1" || u.hostname === "[::1]";

export class OidcClient implements Idp {
  private disc: Discovery | null = null;
  private discAt = 0;
  private jwks: ReturnType<typeof createRemoteJWKSet> | null = null;
  private readonly redirectUri: string;

  private readonly fetch: typeof fetch;

  /** `fetch`: tests stand in for the network with it (e.g. a mock IdP answering as https://accounts.google.com). */
  constructor(private readonly cfg: Pick<AccountConfig, "issuer" | "clientId" | "clientSecret" | "publicUrl" | "recheck" | "allow">, o: { fetch?: typeof fetch } = {}) {
    this.redirectUri = `${cfg.publicUrl}/v1/callback`;
    this.fetch = o.fetch ?? fetch;
  }

  /** The discovery document, fetched on first use and again a day later (and after a failure). */
  async discovery(): Promise<Discovery> {
    if (this.disc && Date.now() - this.discAt < 86_400_000) return this.disc;
    const r = await this.fetch(`${this.cfg.issuer}/.well-known/openid-configuration`, { signal: AbortSignal.timeout(TIMEOUT_MS), redirect: "error" });
    if (!r.ok) throw new IdpError("discovery", `discovery: HTTP ${r.status}`);
    const d = (await r.json()) as Discovery;
    if (typeof d.issuer !== "string" || normalizeIssuer(d.issuer) !== this.cfg.issuer) {
      throw new IdpError("discovery", `discovery names issuer ${String(d.issuer)}, not ${this.cfg.issuer}`);
    }
    for (const k of ["authorization_endpoint", "token_endpoint", "jwks_uri"] as const) {
      const u = new URL(String(d[k]));
      if (u.protocol !== "https:" && !(u.protocol === "http:" && isLocal(u))) throw new IdpError("discovery", `${k} is not https`);
    }
    const methods = d.token_endpoint_auth_methods_supported ?? ["client_secret_basic"];
    if (!methods.includes("client_secret_basic") && !methods.includes("client_secret_post")) {
      throw new IdpError("discovery", `the token endpoint takes neither client_secret_basic nor client_secret_post (${methods.join(", ")})`);
    }
    if (!this.disc || this.disc.jwks_uri !== d.jwks_uri) this.jwks = createRemoteJWKSet(new URL(d.jwks_uri), { timeoutDuration: TIMEOUT_MS, [customFetch]: this.fetch });
    this.disc = d;
    this.discAt = Date.now();
    return d;
  }

  /** The scopes asked for: `openid profile`, `email` for an @domain allow-list, `offline_access` for the re-check. */
  scopes(d: Discovery): string {
    const s = ["openid", "profile"];
    if (this.cfg.allow?.domains.length) s.push("email");
    if (this.cfg.recheck && !isGoogle(this.cfg.issuer) && (d.scopes_supported ?? []).includes("offline_access")) s.push("offline_access");
    return s.join(" ");
  }

  async authorizationUrl(p: { state: string; nonce: string; challenge: string; prompt?: string | undefined }): Promise<string> {
    const d = await this.discovery();
    const u = new URL(d.authorization_endpoint);
    const prompts = new Set((p.prompt ?? "").split(" ").filter(Boolean));
    const params: Record<string, string> = {
      response_type: "code",
      client_id: this.cfg.clientId,
      redirect_uri: this.redirectUri,
      scope: this.scopes(d),
      state: p.state,
      nonce: p.nonce,
      code_challenge: p.challenge,
      code_challenge_method: "S256",
    };
    if (this.cfg.recheck && isGoogle(this.cfg.issuer)) {
      params.access_type = "offline";
      prompts.add("consent");
    }
    if (prompts.size) params.prompt = [...prompts].join(" ");
    for (const [k, v] of Object.entries(params)) u.searchParams.set(k, v);
    return u.toString();
  }

  async callbackIssOk(iss: string | null): Promise<boolean> {
    const d = await this.discovery();
    if (iss === null) return !d.authorization_response_iss_parameter_supported;
    return normalizeIssuer(iss) === this.cfg.issuer;
  }

  private async token(params: Record<string, string>): Promise<{ status: number; body: Record<string, unknown> }> {
    const d = await this.discovery();
    const body = new URLSearchParams(params);
    const headers: Record<string, string> = { "content-type": "application/x-www-form-urlencoded", accept: "application/json" };
    const methods = d.token_endpoint_auth_methods_supported ?? ["client_secret_basic"];
    if (methods.includes("client_secret_basic")) {
      // RFC 6749 2.3.1: each form-urlencoded, then joined
      const enc = (s: string) => encodeURIComponent(s).replace(/%20/g, "+");
      headers.authorization = `Basic ${Buffer.from(`${enc(this.cfg.clientId)}:${enc(this.cfg.clientSecret)}`).toString("base64")}`;
    } else {
      body.set("client_id", this.cfg.clientId);
      body.set("client_secret", this.cfg.clientSecret);
    }
    const r = await this.fetch(d.token_endpoint, { method: "POST", headers, body, signal: AbortSignal.timeout(TIMEOUT_MS), redirect: "error" });
    const text = await r.text();
    let parsed: Record<string, unknown> = {};
    try {
      const j = JSON.parse(text) as unknown;
      if (j && typeof j === "object" && !Array.isArray(j)) parsed = j as Record<string, unknown>;
    } catch {
      /* not JSON: a proxy's error page */
    }
    return { status: r.status, body: parsed };
  }

  /** A verified id_token's identity (`nonce`: what this sign-in sent; undefined for a refresh's, which has none). */
  async verifyIdToken(idToken: string, nonce: string | undefined): Promise<IdpIdentity> {
    const d = await this.discovery();
    const algorithms = (d.id_token_signing_alg_values_supported ?? ["RS256"]).filter((a) => ASYMMETRIC.test(a));
    const { payload } = await jwtVerify(idToken, this.jwks!, {
      issuer: isGoogle(this.cfg.issuer) ? GOOGLE_ISSUERS : [d.issuer],
      audience: this.cfg.clientId,
      algorithms: algorithms.length ? algorithms : ["RS256"],
      clockTolerance: 60,
      requiredClaims: ["sub", "iat", "exp"],
    });
    return identityOf(payload, this.cfg.clientId, nonce);
  }

  async exchange(code: string, verifier: string, nonce: string): Promise<{ identity: IdpIdentity; refreshToken: string | null }> {
    let r: { status: number; body: Record<string, unknown> };
    try {
      r = await this.token({ grant_type: "authorization_code", code, redirect_uri: this.redirectUri, code_verifier: verifier });
    } catch (e) {
      throw new IdpError("idp_unreachable", `token endpoint: ${(e as Error).name}`);
    }
    if (r.status !== 200 || typeof r.body.id_token !== "string") {
      throw new IdpError("idp_token", `token endpoint: HTTP ${r.status}${typeof r.body.error === "string" ? ` ${r.body.error.slice(0, 40)}` : ""}`);
    }
    let identity: IdpIdentity;
    try {
      identity = await this.verifyIdToken(r.body.id_token, nonce);
    } catch (e) {
      throw new IdpError("id_token", `id_token: ${(e as Error).message.slice(0, 120)}`);
    }
    const refresh = typeof r.body.refresh_token === "string" && r.body.refresh_token ? r.body.refresh_token : null;
    return { identity, refreshToken: refresh };
  }

  async refresh(refreshToken: string, expectedSub: string): Promise<RefreshOutcome> {
    let r: { status: number; body: Record<string, unknown> };
    try {
      r = await this.token({ grant_type: "refresh_token", refresh_token: refreshToken });
    } catch (e) {
      return { kind: "retry", reason: `network (${(e as Error).name})` };
    }
    if (r.status >= 500 || r.status === 429) return { kind: "retry", reason: `HTTP ${r.status}` };
    if (r.status !== 200) {
      // only the one definite answer ends a session: anything else (invalid_client after a secret was rotated, a
      // proxy's 403, an unknown error) is this server's or the network's problem, not the person's sign-in
      if ((r.status === 400 || r.status === 401) && r.body.error === "invalid_grant") return { kind: "invalid_grant" };
      return { kind: "retry", reason: `HTTP ${r.status} ${typeof r.body.error === "string" ? r.body.error.slice(0, 40) : ""}`.trim() };
    }
    let identity: IdpIdentity | null = null;
    if (typeof r.body.id_token === "string") {
      try {
        identity = await this.verifyIdToken(r.body.id_token, undefined);
      } catch (e) {
        return { kind: "retry", reason: `refreshed id_token: ${(e as Error).message.slice(0, 80)}` };
      }
      if (identity.sub !== expectedSub) return { kind: "retry", reason: "refreshed id_token names another sub" };
    }
    const rotated = typeof r.body.refresh_token === "string" && r.body.refresh_token ? r.body.refresh_token : null;
    return { kind: "ok", refreshToken: rotated, identity };
  }
}

/** The identity in verified id_token claims: `sub`, the shown name, and (for the allow-list) email / hd. */
export function identityOf(p: JWTPayload & Record<string, unknown>, clientId: string, nonce: string | undefined): IdpIdentity {
  if (typeof p.sub !== "string" || !p.sub || p.sub.length > 255) throw new IdpError("id_token", "id_token has no usable sub");
  if (nonce !== undefined && p.nonce !== nonce) throw new IdpError("id_token", "id_token nonce does not match");
  // several audiences: OIDC Core 3.1.3.7 — then `azp` must be this client
  if ((Array.isArray(p.aud) && p.aud.length > 1) || p.azp !== undefined) {
    if (p.azp !== clientId) throw new IdpError("id_token", "id_token azp is another client");
  }
  const shown = (v: unknown) => (typeof v === "string" && v.trim() ? cleanText(v, 64) : null);
  const id: IdpIdentity = { iss: normalizeIssuer(String(p.iss)), sub: p.sub, name: shown(p.name) ?? shown(p.preferred_username) };
  if (typeof p.email === "string") id.email = p.email;
  if (typeof p.email_verified === "boolean") id.email_verified = p.email_verified;
  // (some IdPs send "true")
  else if (p.email_verified === "true") id.email_verified = true;
  if (typeof p.hd === "string") id.hd = p.hd;
  return id;
}

/** Text from outside shown to people: no control or bidi-override characters, trimmed to `max` characters. */
export function cleanText(s: string, max: number): string {
  return [...s.replace(/[\u0000-\u001f\u007f-\u009f​-‏‪-‮⁦-⁩﻿]/g, "").trim()].slice(0, max).join("");
}
