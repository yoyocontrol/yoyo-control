// A stand-in Yoyo Control server on loopback TCP: just enough of the local API for the client's tests.
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";

export interface StandIn {
  server: Server;
  endpoint: { host: string; port: number };
  status: Record<string, unknown>;
  /** Every request: method, path with query, headers. */
  requests: { method: string; path: string; headers: IncomingMessage["headers"]; body: unknown }[];
  /** Open /events responses. */
  events: ServerResponse[];
  /** Lines every new /events subscriber gets at once. */
  eventLines: unknown[];
  /** Routes answered 404 (e.g. "/automation" for an older build). */
  missing: Set<string>;
  /** A route's own answer (status + JSON body, or a handler). */
  routes: Map<string, (req: IncomingMessage, res: ServerResponse, body: unknown) => void>;
  close(): Promise<void>;
}

export function push(s: StandIn, line: unknown): void {
  for (const res of s.events) if (!res.destroyed) res.write(`${JSON.stringify(line)}\n`);
}

export async function waitFor(cond: () => boolean, what: string, ms = 3000): Promise<void> {
  const until = Date.now() + ms;
  while (!cond()) {
    if (Date.now() > until) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 10));
  }
}

export async function startStandIn(status: Record<string, unknown> = {}, port = 0): Promise<StandIn> {
  const s: StandIn = {
    server: null as unknown as Server,
    endpoint: { host: "127.0.0.1", port: 0 },
    status: { ok: true, app: "YoyoControl", version: "1.0.5", build: "105", api: 1, session: { loggedIn: true }, screenRecording: true, accessibility: true, displays: [], ...status },
    requests: [],
    events: [],
    eventLines: [],
    missing: new Set(),
    routes: new Map(),
    close: async () => {
      for (const r of s.events) r.destroy();
      s.server.closeAllConnections();
      await new Promise<void>((r) => s.server.close(() => r()));
    },
  };
  s.server = createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => {
      const text = Buffer.concat(chunks).toString("utf8");
      let body: unknown;
      try {
        body = text ? JSON.parse(text) : undefined;
      } catch {
        body = text;
      }
      const path = req.url ?? "/";
      s.requests.push({ method: req.method ?? "GET", path, headers: req.headers, body });
      const route = path.split("?")[0]!;
      const json = (code: number, v: unknown) => {
        res.writeHead(code, { "content-type": "application/json" });
        res.end(JSON.stringify(v));
      };
      if (s.missing.has(route)) return json(404, { error: "no such route" });
      const own = s.routes.get(route);
      if (own) return own(req, res, body);
      switch (route) {
        case "/status":
          return json(200, s.status);
        case "/events":
          res.writeHead(200, { "content-type": "application/x-ndjson" });
          for (const l of s.eventLines) res.write(`${JSON.stringify(l)}\n`);
          s.events.push(res);
          return;
        case "/automation":
        case "/agent-control":
          return json(200, { ok: true, active: (body as { active?: boolean }).active, esc: true });
        case "/input":
          return json(200, { ok: true, ...((body as { seq?: number }).seq === 1 ? { stale: true } : {}) });
        default:
          return json(404, { error: `no ${route}` });
      }
    });
  });
  await new Promise<void>((r) => s.server.listen(port, "127.0.0.1", () => r()));
  s.endpoint = { host: "127.0.0.1", port: (s.server.address() as AddressInfo).port };
  return s;
}

/** A loopback port nothing listens on. */
export async function deadPort(): Promise<number> {
  const srv = createServer();
  await new Promise<void>((r) => srv.listen(0, "127.0.0.1", () => r()));
  const port = (srv.address() as AddressInfo).port;
  await new Promise<void>((r) => srv.close(() => r()));
  return port;
}

export const quiet = { log: () => {}, warn: () => {}, error: () => {} };
