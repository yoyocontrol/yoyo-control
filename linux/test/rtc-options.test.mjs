// server.mjs rtcOptions: the WebRTC port and the STUN servers from the flags or the environment.
import assert from "node:assert/strict";
import { test } from "node:test";

import { rtcOptions } from "../server.mjs";

test("rtc options: port and STUN from flags or environment", () => {
  assert.deepEqual(rtcOptions([], 47830, {}), { rtcPort: 47831, stun: [] });
  assert.deepEqual(rtcOptions(["--link-rtc-port", "off"], 47830, {}).rtcPort, null);
  assert.deepEqual(rtcOptions([], 47830, { YOYO_LINK_STUN: "a.example:3478, b.example:19302" }).stun, ["a.example:3478", "b.example:19302"]);
  assert.deepEqual(rtcOptions(["--link-stun", "c.example:3478"], 47830, { YOYO_LINK_STUN: "a.example:3478" }).stun, ["c.example:3478"]);
  assert.deepEqual(rtcOptions([], 47830, { YOYO_LINK_STUN: "off" }).stun, []);
});
