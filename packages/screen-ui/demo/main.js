// The demo page: <yoyo-screen> on the in-memory computer. Query: `?lang=zh` (Chinese), `?scheme=dark`,
// `?state=agent|viewer|unavailable|permission`, `?clipboard=1` (open the Clipboard sheet's page instead),
// `?link=<signal url>&fp=<fingerprint>[&token=probe]` (a uu Link way next to the in-memory one: README「Demo」).
import "@yoyocontrol/screen-ui";
import { FakeComputer, fakeBackend } from "./fake-backend.js";

const q = new URLSearchParams(location.search);
const state = q.get("state");
const pc = new FakeComputer({
  controller: state === "agent" ? "agent" : state === "viewer" ? "user" : "none",
  controllerDevice: state === "viewer" ? { id: "someone-else", name: "Mia’s iPhone" } : null,
  unavailable: state === "unavailable",
  permission: state === "permission",
});
const http = fakeBackend(pc);
const backend = q.get("link")
  ? (await import("./link-way.js")).withLinkWay(http, { signal: q.get("link"), fingerprint: q.get("fp") ?? "", credential: `Bearer ${q.get("token") ?? "probe"}`, note: (s) => console.info(s) })
  : http;
const host = {
  language: q.get("lang") === "zh" ? "zh-Hans" : "en",
  colorScheme: q.get("scheme") ?? null,
  agentName: q.get("agent") ?? null,
  preferencesNamespace: "YoyoDemo",
  onClose: () => history.back(),
};
if (q.get("clipboard")) {
  const screen = document.querySelector("yoyo-screen");
  screen.remove();
  const page = document.createElement("yoyo-clipboard");
  page.style.cssText = "display:block;padding:12px 16px;background:#f2f2f7;min-height:100%";
  document.body.style.background = "#f2f2f7";
  page.host = host;
  page.backend = backend;
  document.body.append(page);
} else {
  const screen = document.querySelector("yoyo-screen");
  screen.host = host;
  screen.backend = backend;
  if (q.get("stats")) setTimeout(() => screen.toggleStats(), 500);
  if (q.get("card")) setTimeout(() => screen.showGestures(), 800);
  window.demo = { pc, screen };
}
