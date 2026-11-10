import type { ClipboardStatus, ScreenEvent, ScreenStatus } from "@yoyocontrol/screen-ui";

/**
 * The Mac's own answers (mac/README.md, docs/LOCAL-API.md) in the pages' shapes (docs/PROTOCOL.md), as the iOS
 * kit's `DirectBackend` maps them.
 */

type Json = Record<string, unknown>;
const obj = (v: unknown): Json | null => (v && typeof v === "object" && !Array.isArray(v) ? (v as Json) : null);

/** Automation drives the Mac (`automation.active`; an older Mac: `agentControl.active`). */
export function agentActive(mac: Json): boolean {
  return obj(mac.automation ?? mac.agentControl)?.active === true;
}

/** `controller`, `controllerSince`, `controllerDevice` from the Mac's `control`: a paired device holding it is
 *  `user` (this browser or another: the page tells by id); else automation is `agent`; else `none`. */
export function controlFields(control: unknown, agent: boolean): Pick<ScreenStatus, "controller" | "controllerSince" | "controllerDevice"> {
  const c = obj(control);
  const device = obj(c?.device);
  if (c?.controller === "remote" && device && typeof device.id === "string") {
    return {
      controller: "user",
      controllerDevice: { id: device.id, ...(typeof device.name === "string" ? { name: device.name } : {}) },
      controllerSince: typeof c.since === "number" ? c.since : null,
    };
  }
  return { controller: agent ? "agent" : "none", controllerDevice: null, controllerSince: null };
}

/** The Mac's `GET /status` as the page's `ScreenStatus`. */
export function statusFromMac(mac: Json): ScreenStatus {
  const s: ScreenStatus = {
    available: mac.ok === true,
    screenRecording: mac.screenRecording === true,
    accessibility: mac.accessibility === true,
    displays: Array.isArray(mac.displays) ? (mac.displays as ScreenStatus["displays"]) : [],
    states: Array.isArray(mac.states) ? (mac.states as NonNullable<ScreenStatus["states"]>) : [],
    ...controlFields(mac.control, agentActive(mac)),
  };
  if (typeof mac.error === "string") s.reason = mac.error;
  const console = obj(mac.console);
  if (console) s.console = { locked: console.locked === true };
  if (typeof mac.platform === "string") s.platform = mac.platform;
  const features = obj(mac.features);
  if (features) s.features = features as ScreenStatus["features"];
  return s;
}

/** The Mac's `GET /clipboard` (the item itself, with `ok`) as a `ClipboardStatus`. */
export function clipboardFromMac(body: Json): ClipboardStatus {
  const { ok: _ok, ...item } = body;
  return { available: true, item: item as unknown as NonNullable<ClipboardStatus["item"]> };
}

/** One `/events` line of the Mac as the pages' event (null: not one they follow). A `control` line never says
 *  `agent` (only `/status` does): the backend asks. */
export function eventFromMacLine(line: Json): ScreenEvent | null {
  switch (line.type) {
    case "state": {
      const console = obj(line.console);
      return {
        type: "screen.state",
        states: Array.isArray(line.states) ? (line.states as Extract<ScreenEvent, { type: "screen.state" }>["states"]) : [],
        ...(console ? { console: { locked: console.locked === true } } : {}),
      };
    }
    case "control":
      return { type: "screen.control", ...controlFields(line.control, false) };
    case "clipboard": {
      const { type: _type, ...item } = line;
      return { type: "clipboard.changed", available: true, item: item as unknown as NonNullable<Extract<ScreenEvent, { type: "clipboard.changed" }>["item"]> };
    }
    case "pairing":
      return { type: "pairing", open: line.open === true };
    default:
      return null;
  }
}

/** `filename*=UTF-8''<percent-encoded>` (or a plain `filename="…"`) of a `Content-Disposition`. */
export function filenameOf(contentDisposition: string | null): string | null {
  if (!contentDisposition) return null;
  const parts = contentDisposition.split(";").map((p) => p.trim());
  for (const p of parts) {
    const m = /^filename\*=(?:UTF-8)?''(.*)$/i.exec(p);
    if (m) {
      try {
        return decodeURIComponent(m[1]!);
      } catch {
        return m[1]!;
      }
    }
  }
  for (const p of parts) {
    if (/^filename=/i.test(p)) return p.slice("filename=".length).replace(/^"|"$/g, "");
  }
  return null;
}
