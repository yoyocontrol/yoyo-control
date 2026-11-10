import assert from "node:assert/strict";
import { test } from "node:test";
import { STRINGS, Words, type StringKey } from "../src/strings.js";

const placeholders = (s: string) => [...s.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();

test("every string has zh-Hans, with the same placeholders", () => {
  for (const [k, v] of Object.entries(STRINGS)) {
    assert.ok(v.en.trim(), `${k}: en`);
    assert.ok(v.zh.trim(), `${k}: zh-Hans`);
    assert.deepEqual(placeholders(v.zh), placeholders(v.en), `${k}: placeholders`);
  }
});

test("every Mac string has its other computer's twin", () => {
  for (const k of Object.keys(STRINGS)) {
    if (k.endsWith("Mac")) assert.ok(`${k.slice(0, -3)}Other` in STRINGS, `${k} has no …Other`);
    if (k.endsWith("Other")) assert.ok(`${k.slice(0, -5)}Mac` in STRINGS, `${k} has no …Mac`);
  }
});

test("words: the language, a host's overrides, placeholders, the computer", () => {
  const en = new Words({ language: "en" });
  assert.equal(en.t("takeOver"), "Take Over");
  assert.equal(en.t("tookOver", { name: "Mia" }), "Mia took over");
  assert.equal(en.c("pasteOn"), "Paste on Mac");
  en.mac = false;
  assert.equal(en.c("pasteOn"), "Paste on Computer");
  const zh = new Words({ language: "zh-Hans", strings: { takeOver: "接手" } });
  assert.equal(zh.t("takeOver"), "接手");
  assert.equal(zh.t("nFiles", { n: 3 }), "3 个文件");
  const s = zh.screenStrings();
  assert.equal(s.reason("timeout", "linux"), "桌面没有响应");
  assert.equal(s.reason("no-session", "linux"), null);
  assert.equal(s.unavailable("mac"), "无法显示屏幕");
  assert.equal(en.bytes(95_000_000), "95 MB");
  const key: StringKey = "justNow";
  assert.equal(en.relative(Date.now() - 5000), en.t(key));
});
