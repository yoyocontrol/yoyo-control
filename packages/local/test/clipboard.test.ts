import assert from "node:assert/strict";
import { Readable } from "node:stream";
import { test } from "node:test";
import type { IncomingMessage } from "node:http";
import {
  ClipboardAnnouncer,
  ClipboardClient,
  CLIPBOARD_FILES_MAX,
  CLIPBOARD_TEXT_MAX,
  dispositionName,
  LocalError,
  parseClipboardItem,
  parseClipboardSummary,
  readAll,
  validateClipboardText,
  type ClipboardRequester,
  type RawResponse,
} from "../src/index.js";

test("summaries are read leniently: unknown kind → other, odd fields dropped, files capped, text only on items", () => {
  assert.equal(parseClipboardSummary({ kind: "text" }), null);
  const files = Array.from({ length: CLIPBOARD_FILES_MAX + 3 }, (_, i) => ({ name: `f${i}`, size: i === 0 ? -1 : 10, dir: i === 1 }));
  const s = parseClipboardSummary({ changeCount: 4.7, kind: "files", preview: "p".repeat(200), size: "big", at: 5, files: [...files, { size: 1 }], moreFiles: 2, source: "robot" })!;
  assert.equal(s.changeCount, 4);
  assert.equal(s.preview.length, 160);
  assert.equal(s.size, null);
  assert.equal(s.files!.length, CLIPBOARD_FILES_MAX);
  assert.deepEqual(s.files![0], { name: "f0", size: null, dir: false });
  assert.equal(s.files![1]!.dir, true);
  assert.equal(s.moreFiles, 2);
  assert.equal(s.source, undefined);
  assert.equal(parseClipboardSummary({ changeCount: 1, kind: "sticker", at: 1 })!.kind, "other");
  assert.deepEqual(parseClipboardItem({ changeCount: 1, kind: "text", preview: "hi", size: 2, at: 1, text: "hi", truncated: true, source: "phone" }), {
    changeCount: 1,
    kind: "text",
    preview: "hi",
    size: 2,
    at: 1,
    text: "hi",
    truncated: true,
    source: "phone",
  });
  assert.equal(parseClipboardItem({ changeCount: 1, kind: "image", at: 1, text: "no" })!.text, undefined);
});

test("text to write is checked; a disposition's UTF-8 name is decoded", () => {
  assert.equal(validateClipboardText("hi"), "hi");
  assert.throws(() => validateClipboardText(3), (e: unknown) => e instanceof LocalError && e.status === 400);
  assert.throws(() => validateClipboardText("  "), (e: unknown) => e instanceof LocalError && e.status === 400);
  assert.throws(() => validateClipboardText("é".repeat(CLIPBOARD_TEXT_MAX / 2 + 1)), (e: unknown) => e instanceof LocalError && e.status === 413);
  assert.equal(dispositionName(`attachment; filename="a_b.txt"; filename*=UTF-8''a%C3%A9b.txt`), "aéb.txt");
  assert.equal(dispositionName("attachment"), null);
  assert.equal(dispositionName(`attachment; filename*=UTF-8''%E0%A4`), null);
});

function fake(answers: Record<string, { status: number; headers?: Record<string, string>; body: string }>) {
  const calls: { method: string; path: string; body?: unknown }[] = [];
  const respond = (path: string): RawResponse => {
    const a = answers[path] ?? { status: 404, body: JSON.stringify({ error: "nope" }) };
    return { status: a.status, headers: a.headers ?? {}, body: Readable.from([Buffer.from(a.body)]) as unknown as IncomingMessage };
  };
  const r: ClipboardRequester = {
    request: async (method, path, body) => {
      calls.push({ method, path, body });
      return respond(path);
    },
    json: async <T,>(method: string, path: string, body?: unknown) => {
      calls.push({ method, path, body });
      const res = respond(path);
      const json = JSON.parse(String(await readAll(res.body)));
      if (res.status !== 200) throw new LocalError(json.error, 503);
      return json as T;
    },
  };
  return { r, calls };
}

test("ClipboardClient: read, image, file (its name from Content-Disposition only), writes with their source", async () => {
  const { r, calls } = fake({
    "/clipboard?text=0": { status: 200, body: JSON.stringify({ changeCount: 2, kind: "image", at: 1 }) },
    "/clipboard/image": { status: 200, body: "PNG" },
    "/clipboard/file?index=0": { status: 200, headers: { "content-length": "3", "content-disposition": "attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf" }, body: "PDF" },
    "/clipboard/file?index=1": { status: 200, headers: { "content-length": "1" }, body: "x" },
    "/clipboard/file?index=2": { status: 200, body: "?" },
    "/clipboard/file?index=3": { status: 400, body: JSON.stringify({ error: "a folder" }) },
    "/clipboard": { status: 200, body: JSON.stringify({ changeCount: 3, kind: "text", at: 1, text: "hi" }) },
  });
  const c = new ClipboardClient(r);
  assert.equal((await c.read(false)).kind, "image");
  assert.equal(String(await c.image()), "PNG");
  const f = await c.file(0);
  assert.deepEqual({ size: f.size, name: f.name, body: String(await readAll(f.body)) }, { size: 3, name: "résumé.pdf", body: "PDF" });
  assert.equal((await c.file(1)).name, null);
  await assert.rejects(c.file(2), (e: unknown) => e instanceof LocalError && e.status === 502);
  await assert.rejects(c.file(3), (e: unknown) => e instanceof LocalError && e.status === 400 && e.message === "a folder");
  await assert.rejects(c.file(9), (e: unknown) => e instanceof LocalError && e.status === 404 && e.message === "nope");
  assert.equal((await c.writeText("hi", "agent")).text, "hi");
  await c.writeFiles(["/Users/a/Downloads/x.png"], "phone");
  assert.deepEqual(calls.filter((x) => x.method === "POST").map((x) => x.body), [{ text: "hi", source: "agent" }, { files: ["/Users/a/Downloads/x.png"], source: "phone" }]);
});

test("ClipboardAnnouncer: once per changeCount, availability flips once, nothing before the first report", () => {
  const out: [boolean, number | null][] = [];
  const a = new ClipboardAnnouncer((available, item) => out.push([available, item?.changeCount ?? null]));
  a.gone();
  a.reported({ changeCount: 1, kind: "text", at: 1 });
  a.reported({ changeCount: 1, kind: "text", at: 1 });
  a.reported({ changeCount: 2, kind: "empty", at: 1 });
  a.gone();
  a.gone();
  a.reported({ changeCount: 2, kind: "empty", at: 1 });
  a.reported("junk");
  assert.deepEqual(out, [[true, 1], [true, null], [false, null], [true, null]]);
});
