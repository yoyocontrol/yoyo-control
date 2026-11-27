#!/usr/bin/env node
// An account server on loopback for another implementation's tests (the Mac's AccountMembership): the library's
// harness (dist/testing: `npm run build` first) with a stand-in Apple, one signed-in phone, a join key for it — and a
// small control server to drive it. Prints one JSON line `{ url, key, control }` and runs until stdin closes.
//   GET  <control>/ticket?computer=<linkId>&device=<name>   a ticket for that device of the account (signed in once)
//   POST <control>/remove?device=<name>                     the device removed from the account
//   GET  <control>/computers                                the account's computers as its phone sees them
//   POST <control>/approve?code=<join code>                 the phone approves a computer's join code
import { createServer } from "node:http";
import { appleSignIn, bearer, get, harness, post, TestApple } from "../dist/testing/index.js";

const apple = new TestApple();
const h = await harness({ oidc: false, apple, env: { ACCOUNT_APPLE_AUDIENCES: "com.example.remote", ACCOUNT_OPEN: "1" } });
const phone = await appleSignIn(h, apple);
const jk = await (await post(`${h.url}/v1/join-keys`, {}, bearer(phone.session))).json();
const devices = new Map();
const device = async (name) => {
  if (!devices.has(name)) devices.set(name, await appleSignIn(h, apple, { device: { name, platform: "ios" } }));
  return devices.get(name);
};
const control = createServer(async (req, res) => {
  const u = new URL(req.url, "http://x");
  const send = (status, body) => {
    res.writeHead(status, { "content-type": "application/json" });
    res.end(JSON.stringify(body));
  };
  try {
    if (u.pathname === "/ticket") {
      const d = await device(u.searchParams.get("device") ?? "iPad");
      const r = await post(`${h.url}/v1/tickets`, { computer: u.searchParams.get("computer") }, bearer(d.session));
      return send(r.status, { ...(await r.json()), device: d.device.id, account: d.account.id });
    }
    if (u.pathname === "/remove") {
      const d = await device(u.searchParams.get("device") ?? "iPad");
      const r = await fetch(`${h.url}/v1/devices/${d.device.id}`, { method: "DELETE", headers: bearer(phone.session) });
      return send(r.status, await r.json());
    }
    if (u.pathname === "/approve") {
      const r = await post(`${h.url}/v1/computers/approve`, { user_code: u.searchParams.get("code") }, bearer(phone.session));
      return send(r.status, await r.json());
    }
    if (u.pathname === "/computers") return send(200, await (await get(`${h.url}/v1/computers`, bearer(phone.session))).json());
    send(404, { error: "not found" });
  } catch (e) {
    send(500, { error: String(e) });
  }
});
await new Promise((r) => control.listen(0, "127.0.0.1", r));
process.stdout.write(`${JSON.stringify({ url: h.url, key: jk.key, account: phone.account.id, control: `http://127.0.0.1:${control.address().port}` })}\n`);
process.stdin.resume();
process.stdin.on("end", async () => {
  control.close();
  await h.stop();
  process.exit(0);
});
