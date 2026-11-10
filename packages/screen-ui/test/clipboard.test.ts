import assert from "node:assert/strict";
import { test } from "node:test";
import { ClipboardActions, ClipboardHints, ClipboardMarks, ClipboardState, clipboardSupported, middleTruncated } from "../src/clipboard-model.js";
import type { ScreenBackend, ScreenEvent } from "../src/contracts.js";
import { Words } from "../src/strings.js";

const w = new Words({ language: "en" });
const text = (n: number, source: "mac" | "phone" = "mac") => ({ changeCount: n, kind: "text", preview: "npm run build && npm test --watch", source });

test("what the clipboard UI may do, and its lines", () => {
  assert.deepEqual(ClipboardActions.enabled({ available: true, item: { ...text(1), text: "x" } }), { copy: true, share: true, save: false, send: true });
  assert.deepEqual(ClipboardActions.enabled({ available: false }), { copy: false, share: false, save: false, send: false });
  assert.equal(ClipboardActions.enabled({ available: true, item: { changeCount: 1, kind: "files", files: [{ name: "d", dir: true }] } }).save, false);
  assert.equal(ClipboardActions.previewLine({ changeCount: 1, kind: "image", width: 1280, height: 720 }, w), "Image · 1280×720");
  assert.equal(ClipboardActions.previewLine({ changeCount: 1, kind: "files", files: [{ name: "a.pdf" }], moreFiles: 2 }, w), "3 files · a.pdf");
  assert.equal(ClipboardActions.macHint(text(1), w), `Copied on Mac: “${middleTruncated(text(1).preview, 24)}” — Copy here`);
  assert.equal(middleTruncated("abcdefghij", 5), "ab…ij");
  assert.ok(ClipboardActions.looksLikeCode("const a = 1;"));
  assert.ok(!ClipboardActions.looksLikeCode("Hello there"));
  assert.equal(ClipboardActions.footer({ ...text(1), source: "agent", at: 0 }, new Words({ language: "en", agentName: "Claude" })), "Copied by Claude");
});

test("what goes onto the computer's clipboard, and copy moves", () => {
  assert.deepEqual(ClipboardActions.payload({ text: "hi" }, 10, w), { put: { text: "hi" } });
  assert.ok("error" in ClipboardActions.payload({ text: "  " }, 10, w));
  const big = new File([new Uint8Array(20)], "big.bin");
  assert.deepEqual(ClipboardActions.payload({ files: [big] }, 10, w), { error: "big.bin is too large (max 10 B)." });
  assert.deepEqual(ClipboardActions.copyMove({ available: true, item: { ...text(3), text: "x" } }), { t: "text", text: "x" });
  assert.deepEqual(ClipboardActions.copyMove({ available: true, item: { changeCount: 4, kind: "image" } }), { t: "image", changeCount: 4 });
  assert.deepEqual(ClipboardActions.copyMove({ available: false, reason: "locked" }), { t: "unavailable", reason: "locked" });
  assert.equal(ClipboardActions.sentMessage({ files: [big] }, [{ path: "/Users/x/Downloads/big.bin" }], w), "Sent to the Mac · saved in Downloads");
  assert.equal(ClipboardActions.copyItem({ available: true, item: { changeCount: 1, kind: "concealed" } }, w).enabled, false);
});

test("the dot and the hints", () => {
  const m = new ClipboardMarks();
  assert.equal(m.macIsNew(text(2), w), false, "nothing known yet");
  m.knowMac(text(1));
  assert.equal(m.macIsNew(text(2), w), true);
  assert.equal(m.macIsNew(text(3, "phone"), w), false, "this device sent it");
  assert.equal(m.phoneIsNew("a", "text"), true);
  m.sawMenu("a", text(2));
  assert.equal(m.dot("a", "text", text(2), w), false);
  assert.deepEqual(ClipboardHints.onMacChange(text(5), 4, w), { t: "mac", changeCount: 5 });
  assert.equal(ClipboardHints.onMacChange(text(5), null, w), null, "the first heard is no change");
  assert.equal(clipboardSupported(false, { status: 403 }), false);
  assert.equal(clipboardSupported(false, { status: 500 }), true);
});

test("the shared state loads, is patched by events, and keeps one per computer", async () => {
  let loads = 0;
  const events: ScreenEvent[] = [];
  const waker: { wake: (() => void) | null } = { wake: null };
  const backend: ScreenBackend = {
    cacheScope: "c1",
    status: async () => ({ available: true, screenRecording: true, accessibility: true, displays: [], controller: "none" }),
    transport: () => ({ fetch: async () => new Response(null, { status: 404 }) }),
    clipboard: async () => {
      loads++;
      return { available: true, item: { ...text(1), text: "npm" } };
    },
    events: () => ({
      [Symbol.asyncIterator]: () => ({
        next: async () => {
          while (!events.length) await new Promise<void>((r) => (waker.wake = r));
          return { value: events.shift()!, done: false };
        },
        return: async () => ({ value: undefined, done: true }),
      }),
    }),
  };
  ClipboardState.forgetAll();
  const s = ClipboardState.of(backend);
  assert.equal(ClipboardState.of(backend), s);
  let seen = 0;
  const stop = s.observe(() => seen++);
  await s.load();
  await s.load();
  assert.equal(loads, 1, "kept for the TTL");
  events.push({ type: "clipboard.changed", available: true, item: text(2) });
  waker.wake?.();
  await new Promise((r) => setTimeout(r, 10));
  assert.equal(s.status?.item?.changeCount, 2);
  assert.equal(s.status?.item?.text, undefined, "the event carries no text");
  assert.ok(seen >= 2);
  stop();
  ClipboardState.forgetAll();
});
