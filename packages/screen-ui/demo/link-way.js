// A second way for a backend: a uu Link session over WebRTC (@yoyocontrol/link-web), chosen over the backend's own
// HTTP way by screen-ui's Connector — tried first, left when the session ends (back to HTTP), tried again every
// `retryIntervalMs` while on HTTP. The demo uses it with `uu-link-probe serve-rtc --screen-clip` (`?link=`), the
// end-to-end test (test/e2e) the same way. A real backend does the same with its own signaling path.
import { dialRtc, LinkError, linkScreen } from "@yoyocontrol/link-web";
import { candidate, Connector, ConnectWays } from "@yoyocontrol/screen-ui";

/**
 * `http` (a ScreenBackend whose `transport` always works) plus the link way. `link`: `{ signal, fingerprint,
 * credential, device?, policy?, wrap?, note? }` — `signal` the URL the offer is POSTed to (the answer comes back),
 * `fingerprint` the computer's pinned identity, `credential` its `hello.credential`; `wrap(screenLink)` and
 * `note(text)` are for watching it (the test counts pictures with them).
 */
export function withLinkWay(http, link) {
  const tunnel = candidate({ kind: "tunnel", id: "tunnel" });
  const screens = new WeakMap();
  const note = link.note ?? (() => {});
  let ways = null;
  return {
    ...http,
    makeRouting() {
      ways = new ConnectWays(tunnel, null, [tunnel]);
      const connector = new Connector(
        ways,
        {
          candidates: async () => ({ candidates: [candidate({ kind: "link", id: "link" })], fresh: true }),
          async probe(_candidate, signal) {
            try {
              const session = await dialRtc({
                signal: async (offer) => {
                  const res = await fetch(link.signal, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(offer), signal });
                  if (!res.ok) throw new Error(`signal: HTTP ${res.status}`);
                  return res.text();
                },
                pinnedFingerprint: link.fingerprint,
                credential: link.credential,
                device: link.device ?? { id: "screen-ui-demo", name: "screen-ui demo" },
                app: { name: "screen-ui-demo", version: "1" },
                abortSignal: signal,
                timeoutMs: 4000,
              });
              note("link up");
              void session.closed().then((r) => note(`link closed: ${r.description}`));
              return { t: "reached", link: session };
            } catch (e) {
              note(`link dial failed: ${e instanceof Error ? e.message : String(e)}`);
              return e instanceof LinkError && e.code === "unauthorized" ? { t: "unauthorized" } : { t: "unreachable" };
            }
          },
          release: (session) => void session?.close(),
          ended: (session) => (session ? session.closed().then(() => true) : Promise.resolve(false)),
        },
        link.policy ?? {},
      );
      connector.linkPossible = true;
      link.routing?.(connector);
      return connector;
    },
    screenLink(route) {
      const session = route.id === "link" ? ways?.link(route) : null;
      if (!session || session.isClosed) return null;
      let s = screens.get(session);
      if (!s) {
        s = linkScreen(session);
        if (link.wrap) s = link.wrap(s);
        screens.set(session, s);
      }
      return s;
    },
  };
}
