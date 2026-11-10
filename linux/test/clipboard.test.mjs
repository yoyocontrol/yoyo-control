// The clipboard: the pure parts (preview, cut, uri lists) and the routes over a faked yoyo-x11clip (test/fakes.mjs).
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { request } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";
import { CLIP, clipPreview, clipText, fileUri, imageTypeOf, mimeOf, parseUriList } from "../clipboard.mjs";
import { YoyoLinux } from "../server.mjs";
import { fakeSpawn } from "./fakes.mjs";

test("clipboard: preview — 160 characters, newline runs as ⏎, … when cut; the text cut at 1 MiB on a character boundary", () => {
  assert.equal(clipPreview("hello\n\n  world  \r\nthree"), "hello⏎ world⏎ three");
  const long = "字".repeat(300);
  const p = clipPreview(long);
  assert.equal([...p].length, 160);
  assert.ok(p.endsWith("…"));
  assert.equal(clipPreview("a".repeat(160)), "a".repeat(160));
  assert.deepEqual(clipText("abc"), { text: "abc", truncated: false });
  const cut = clipText("é".repeat(600_000)); // 1.2 MB of 2-byte characters
  assert.equal(cut.truncated, true);
  assert.equal(Buffer.byteLength(cut.text), CLIP.textMax);
  const odd = clipText(`a${"é".repeat(600_000)}`);
  assert.equal(Buffer.byteLength(odd.text), CLIP.textMax - 1, "never half a character");
});

test("clipboard: uri lists → local paths; paths → file URIs; types by extension", () => {
  assert.deepEqual(parseUriList("# comment\r\nfile:///home/u/a%20b.png\r\nhttps://example.com/x\r\nfile://localhost/etc/hosts\r\nfile://otherhost/x\r\n"), ["/home/u/a b.png", "/etc/hosts"]);
  assert.deepEqual(parseUriList("copy\nfile:///tmp/%E4%BD%A0.txt\nfile:///tmp/b"), ["/tmp/你.txt", "/tmp/b"]);
  assert.equal(fileUri("/home/u/Downloads/a b#1.png"), "file:///home/u/Downloads/a%20b%231.png");
  assert.deepEqual(parseUriList(`${fileUri("/tmp/你 好.txt")}\r\n`), ["/tmp/你 好.txt"]);
  assert.equal(imageTypeOf("/x/IMG_1.JPEG"), "image/jpeg");
  assert.equal(imageTypeOf("/x/a.pdf"), null);
  assert.equal(mimeOf("/x/a.unknown"), "application/octet-stream");
});

const TOKEN = "c".repeat(64);
const fake = fakeSpawn();
const lines = [];
const svc = new YoyoLinux({ token: TOKEN, spawnFn: fake.spawn, logLine: (l) => lines.push(l) });
let port;
const dir = mkdtempSync(join(tmpdir(), "yoyo-clip-"));
before(async () => {
  port = (await svc.listen(0, "127.0.0.1")).port;
  for (let i = 0; i < 100 && !svc.clipboard.running; i++) await new Promise((r) => setTimeout(r, 10));
});
after(() => {
  svc.close();
  rmSync(dir, { recursive: true, force: true });
});

function call(method, path, { body, stream } = {}) {
  return new Promise((resolve, reject) => {
    const b = body === undefined ? undefined : Buffer.from(typeof body === "string" ? body : JSON.stringify(body));
    const req = request({ host: "127.0.0.1", port, method, path, headers: { authorization: `Bearer ${TOKEN}`, ...(b ? { "content-type": "application/json", "content-length": b.length } : {}) } }, (res) => {
      if (stream) return resolve({ res, req });
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const buf = Buffer.concat(chunks);
        let json;
        try {
          json = JSON.parse(buf.toString());
        } catch {}
        resolve({ status: res.statusCode, headers: res.headers, buf, json });
      });
    });
    req.on("error", reject);
    req.end(b);
  });
}

/** /events lines as they come. */
async function events() {
  const { res, req } = await call("GET", "/events", { stream: true });
  const got = [];
  let rest = "";
  res.setEncoding("utf8");
  res.on("data", (d) => {
    rest += d;
    for (let i = rest.indexOf("\n"); i >= 0; i = rest.indexOf("\n")) {
      got.push(JSON.parse(rest.slice(0, i)));
      rest = rest.slice(i + 1);
    }
  });
  const until = async (pred, what) => {
    for (let i = 0; i < 200; i++) {
      if (pred(got)) return got;
      await new Promise((r) => setTimeout(r, 10));
    }
    throw new Error(`timed out waiting for ${what}: ${JSON.stringify(got)}`);
  };
  return { got, until, close: () => req.destroy() };
}

test("clipboard: /status says it's there; GET is the empty clipboard at first (changeCount 1); /events: state, then the clipboard line", async () => {
  assert.equal((await call("GET", "/status")).json.features.clipboard, true);
  const r = await call("GET", "/clipboard");
  assert.equal(r.status, 200);
  assert.equal(r.json.ok, true);
  assert.equal(r.json.kind, "empty");
  assert.equal(r.json.changeCount, 1);
  const ev = await events();
  await ev.until((g) => g.length >= 2, "two lines");
  assert.equal(ev.got[0].type, "state");
  assert.deepEqual({ ...ev.got[1], at: 0 }, { type: "clipboard", changeCount: 1, kind: "empty", preview: "", size: null, at: 0 });
  ev.close();
});

test("clipboard: a copy in the desktop — text, its preview and size, ?text=0, a line on /events; 1 MiB+ is truncated", async () => {
  const ev = await events();
  await ev.until((g) => g.length >= 2, "the first lines");
  fake.state.clipCopy({ targets: ["TARGETS", "UTF8_STRING", "text/html"], text: "你好\nworld", textSize: 12, textCut: false });
  await ev.until((g) => g.some((l) => l.type === "clipboard" && l.kind === "text"), "the text line");
  const line = ev.got.find((l) => l.kind === "text");
  assert.deepEqual([line.preview, line.size, line.text, line.source], ["你好⏎ world", 12, undefined, undefined], "a summary only: never the text");
  const r = await call("GET", "/clipboard");
  assert.deepEqual([r.json.kind, r.json.text, r.json.truncated, r.json.changeCount], ["text", "你好\nworld", undefined, line.changeCount]);
  assert.equal((await call("GET", "/clipboard?text=0")).json.text, undefined);
  const big = "x".repeat(CLIP.textMax + 10);
  fake.state.clipCopy({ targets: ["UTF8_STRING"], text: big, textSize: big.length, textCut: false });
  await ev.until((g) => g.filter((l) => l.kind === "text").length >= 2, "the big text");
  const b = await call("GET", "/clipboard");
  assert.equal(b.json.truncated, true);
  assert.equal(b.json.text.length, CLIP.textMax);
  assert.equal(b.json.size, CLIP.textMax + 10);
  ev.close();
});

test("clipboard: an image (PNG asked of the helper once per changeCount), files (served from the path), empty, concealed, other", async () => {
  const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);
  fake.state.clipPng = png;
  fake.state.clipCopy({ targets: ["TARGETS", "image/png"], png: { size: 7, width: 640, height: 480 } });
  await new Promise((r) => setTimeout(r, 30));
  const st = (await call("GET", "/clipboard")).json;
  assert.deepEqual([st.kind, st.size, st.width, st.height, st.preview], ["image", 7, 640, 480, ""]);
  const img = await call("GET", "/clipboard/image");
  assert.equal(img.status, 200);
  assert.equal(img.headers["content-type"], "image/png");
  assert.equal(img.headers["x-clipboard-change-count"], String(st.changeCount));
  assert.deepEqual(img.buf, png);
  fake.state.clipPng = Buffer.from("changed");
  assert.deepEqual((await call("GET", "/clipboard/image")).buf, png, "cached for this changeCount");
  assert.equal((await call("GET", "/clipboard/file?index=0")).status, 404, "not files");
  // files (Thunar: uri-list + gnome-copied-files)
  const a = join(dir, "a b.txt");
  writeFileSync(a, "hello");
  fake.state.clipCopy({ targets: ["text/uri-list", "x-special/gnome-copied-files"], uris: `${fileUri(a)}\r\n${fileUri(dir)}\r\n` });
  await new Promise((r) => setTimeout(r, 30));
  const f = (await call("GET", "/clipboard")).json;
  assert.equal(f.kind, "files");
  assert.deepEqual(f.files, [{ name: "a b.txt", size: 5, dir: false }, { name: dir.split("/").pop(), size: null, dir: true }]);
  assert.equal(f.size, 5);
  assert.equal(f.preview, `a b.txt, ${dir.split("/").pop()}`);
  const file = await call("GET", "/clipboard/file?index=0");
  assert.equal(file.status, 200);
  assert.equal(file.buf.toString(), "hello");
  assert.equal(file.headers["content-disposition"], "attachment; filename*=UTF-8''a%20b.txt");
  assert.equal(file.headers["content-type"], "text/plain");
  assert.equal((await call("GET", "/clipboard/file?index=1")).status, 400, "a folder");
  assert.equal((await call("GET", "/clipboard/file?index=2")).status, 404);
  assert.equal((await call("GET", "/clipboard/file")).status, 400, "index is required");
  // links only: not files; text instead
  fake.state.clipCopy({ targets: ["text/uri-list", "UTF8_STRING"], uris: "https://example.com\r\n", text: "https://example.com", textSize: 19 });
  await new Promise((r) => setTimeout(r, 30));
  assert.equal((await call("GET", "/clipboard")).json.kind, "text");
  fake.state.clipCopy({ targets: ["x-kde-passwordManagerHint", "UTF8_STRING"] });
  await new Promise((r) => setTimeout(r, 30));
  assert.equal((await call("GET", "/clipboard")).json.kind, "concealed");
  assert.equal((await call("GET", "/clipboard/image")).status, 404);
  fake.state.clipCopy({ targets: ["image/bmp"] });
  await new Promise((r) => setTimeout(r, 30));
  assert.equal((await call("GET", "/clipboard")).json.kind, "other");
  fake.state.clipCopy({ owner: false, targets: [] });
  await new Promise((r) => setTimeout(r, 30));
  assert.equal((await call("GET", "/clipboard")).json.kind, "empty", "the copying app exited");
});

test("clipboard: POST text / files — the helper owns it, source phone (or agent), /events at once; errors as the Mac's", async () => {
  const ev = await events();
  await ev.until((g) => g.length >= 2, "the first lines");
  const before = fake.state.clipWrites.length;
  const w = await call("POST", "/clipboard", { body: { text: "来自手机" } });
  assert.equal(w.status, 200);
  assert.deepEqual([w.json.ok, w.json.kind, w.json.text, w.json.source, w.json.preview], [true, "text", "来自手机", "phone", "来自手机"]);
  assert.equal(fake.state.clipWrites[before].head, `T ${Buffer.byteLength("来自手机")}`);
  assert.equal(fake.state.clipWrites[before].body.toString(), "来自手机");
  await ev.until((g) => g.some((l) => l.source === "phone"), "the write's line");
  // files, from the agent: uri-list, gnome-copied-files, the paths as text; one image file: its bytes as image/png
  const pic = join(dir, "IMG 1.png");
  writeFileSync(pic, "PNGDATA");
  const fw = await call("POST", "/clipboard", { body: { files: [pic], source: "agent" } });
  assert.equal(fw.status, 200);
  assert.deepEqual([fw.json.kind, fw.json.source, fw.json.files], ["files", "agent", [{ name: "IMG 1.png", size: 7, dir: false }]]);
  const fwrite = fake.state.clipWrites.at(-1);
  const uri = `${fileUri(pic)}\r\n`;
  const gnome = `copy\n${fileUri(pic)}`;
  assert.equal(fwrite.head, `F ${uri.length} ${gnome.length} ${pic.length} 7 image/png`);
  assert.equal(fwrite.body.toString(), uri + gnome + pic + "PNGDATA");
  // two files: no image data
  const txt = join(dir, "a b.txt");
  await call("POST", "/clipboard", { body: { files: [pic, txt] } });
  assert.match(fake.state.clipWrites.at(-1).head, / 0 -$/);
  // errors
  assert.equal((await call("POST", "/clipboard", { body: { text: "" } })).status, 400);
  assert.equal((await call("POST", "/clipboard", { body: { text: "x".repeat(CLIP.textMax + 1) } })).status, 413);
  assert.equal((await call("POST", "/clipboard", { body: { files: ["/no/such/file"] } })).status, 400);
  assert.equal((await call("POST", "/clipboard", { body: { files: ["relative.txt"] } })).status, 400);
  assert.equal((await call("POST", "/clipboard", { body: { files: Array(21).fill(pic) } })).status, 400);
  assert.equal((await call("POST", "/clipboard", { body: { text: "x", source: "mac" } })).status, 400);
  assert.equal((await call("POST", "/clipboard", { body: {} })).status, 400);
  assert.equal((await call("POST", "/clipboard", { body: "[" })).status, 400);
  // another program kept it (the helper couldn't own it): 503 with why
  fake.state.clipRefuse = true;
  const refused = await call("POST", "/clipboard", { body: { text: "x" } });
  fake.state.clipRefuse = false;
  assert.equal(refused.status, 503);
  assert.match(refused.json.error, /another program/);
  // changeCounts only grow
  const counts = ev.got.filter((l) => l.type === "clipboard").map((l) => l.changeCount);
  assert.deepEqual(counts, [...counts].sort((x, y) => x - y));
  ev.close();
});

test("clipboard: a PNG asked for just as the clipboard changed is refused (409), never filed under the old changeCount", async () => {
  fake.state.clipPng = Buffer.from([0x89, 0x50, 0x4e, 0x47, 9]);
  fake.state.clipCopy({ targets: ["image/png"], png: { size: 5, width: 2, height: 2 } });
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(svc.clipboard.item.kind, "image");
  // the helper reports a new copy, and the PNG is asked for before that report is read here
  const helper = fake.state.clipHelpers.find((h) => h.exitCode === null);
  helper.report(JSON.stringify({ own: false, owner: true, targets: ["image/png"], png: { size: 6, width: 3, height: 3 } }));
  await assert.rejects(svc.clipboard.image(), (e) => e.status === 409 && /changed/.test(e.message));
  await new Promise((r) => setTimeout(r, 30));
  const again = await svc.clipboard.image();
  assert.equal(again.changeCount, svc.clipboard.item.changeCount);
});

test("clipboard: no helper (no X yet, or it died): 503 for every route, features.clipboard false; it is started again", async () => {
  for (const h of fake.state.clipHelpers) h.exit(1);
  await new Promise((r) => setTimeout(r, 20));
  assert.equal((await call("GET", "/clipboard")).status, 503);
  assert.equal((await call("POST", "/clipboard", { body: { text: "x" } })).status, 503);
  assert.equal((await call("GET", "/clipboard/image")).status, 503);
  assert.equal((await call("GET", "/status")).json.features.clipboard, false);
  assert.ok(lines.some((l) => /starting it again/.test(l)));
});
