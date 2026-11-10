// The Windows platform (platform.mjs): the same server over the Windows helpers (windows/*.c) — their names, /status's
// app and platform, /frame through the video helper's --jpeg, input through yoyo-wininput (the xdotool lines), and
// the clipboard's Windows paths. The helpers are the Linux fakes (test/fakes.mjs) under the Windows names.
import assert from "node:assert/strict";
import { request } from "node:http";
import { after, before, test } from "node:test";
import { fileUri, parseUriList } from "../clipboard.mjs";
import { PLATFORMS, hostPlatform } from "../platform.mjs";
import { adminPath } from "../remote.mjs";
import { YoyoLinux } from "../server.mjs";
import { fakeProcess, fakeSpawn } from "./fakes.mjs";

const fake = fakeSpawn();
const spawned = [];
const jpegArgs = [];
const LINUX_NAME = { "yoyo-winvideo.exe": "yoyo-x11video", "yoyo-winaudio.exe": "yoyo-pa-opus", "yoyo-winclip.exe": "yoyo-x11clip", "yoyo-winwindows.exe": "yoyo-x11windows", "yoyo-wininput.exe": "xdotool" };
const spawn = (path, args, opts) => {
  const file = path.split(/[\\/]/).pop();
  spawned.push(file);
  if (file === "yoyo-winvideo.exe" && args[0] === "--jpeg") {
    jpegArgs.push(args);
    const p = fakeProcess();
    setImmediate(() => {
      p.stdout.write(Buffer.from([0xff, 0xd8, 0xff, 0xd9]));
      p.exit(0);
    });
    return p;
  }
  const as = LINUX_NAME[file];
  if (!as) throw new Error(`unexpected spawn ${path}`);
  return fake.spawn(as === "xdotool" ? "xdotool" : `/x/${as}`, args, opts);
};
const win = (o) => ({ or: false, instance: null, pid: 0, type: "normal", hidden: false, above: false, ...o });
fake.state.windows = {
  screen: [1280, 832],
  active: 3,
  windows: [
    win({ id: 1, class: "explorer", instance: "Progman", pid: 10, type: "desktop", x: 0, y: 0, w: 1280, h: 832 }),
    win({ id: 2, class: "explorer", instance: "Shell_TrayWnd", pid: 10, type: "dock", x: 0, y: 784, w: 1280, h: 48 }),
    win({ id: 3, class: "notepad", instance: "Notepad", pid: 20, x: 100, y: 100, w: 400, h: 300 }),
  ],
};

const TOKEN = "q".repeat(64);
const svc = new YoyoLinux({ token: TOKEN, platform: PLATFORMS.windows, spawnFn: spawn, logLine: () => {} });
let port;
before(async () => {
  port = (await svc.listen(0, "127.0.0.1")).port;
});
after(() => svc.close());

function call(method, path, body) {
  return new Promise((resolve, reject) => {
    const b = body === undefined ? undefined : Buffer.from(JSON.stringify(body));
    const req = request({ host: "127.0.0.1", port, method, path, headers: { authorization: `Bearer ${TOKEN}`, ...(b ? { "content-type": "application/json", "content-length": b.length } : {}) } }, (res) => {
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

test("hostPlatform: Windows on win32, Linux elsewhere; YOYO_PLATFORM overrides", () => {
  assert.equal(hostPlatform({}, "win32").id, "windows");
  assert.equal(hostPlatform({}, "linux").id, "linux");
  assert.equal(hostPlatform({ YOYO_PLATFORM: "windows" }, "linux").id, "windows");
  assert.equal(hostPlatform({ YOYO_PLATFORM: "nope" }, "darwin").id, "linux");
});

test("/status on Windows: app yoyo-windows, platform windows, the display named Windows", async () => {
  const r = await call("GET", "/status");
  assert.equal(r.status, 200);
  assert.equal(r.json.app, "yoyo-windows");
  assert.equal(r.json.platform, "windows");
  assert.equal(r.json.ok, true);
  assert.equal(r.json.displays[0].name, "Windows");
  assert.ok(spawned.includes("yoyo-winvideo.exe"), "the size comes from the Windows video helper");
});

test("GET /frame on Windows: the video helper's --jpeg with the size, the crop and the covering boxes", async () => {
  const plain = await call("GET", "/frame?maxWidth=640&quality=80");
  assert.equal(plain.status, 200);
  assert.equal(plain.headers["content-type"], "image/jpeg");
  assert.deepEqual(jpegArgs.at(-1), ["--jpeg", "80", "--size", "640", "416"]);
  assert.equal(fake.state.ffmpegArgs.length, 0, "no ffmpeg on Windows");

  const masked = await call("GET", "/frame?maxWidth=1280&visible=notepad&hide=explorer&crop=0,0,0.5,0.5");
  assert.equal(masked.status, 200);
  assert.equal(masked.headers["x-frame-filter"], "mask");
  const a = jpegArgs.at(-1);
  assert.deepEqual(a.slice(0, 10), ["--jpeg", "70", "--size", "640", "416", "--crop", "0", "0", "640", "416"]);
  const boxes = [];
  for (let i = a.indexOf("--box"); i >= 0; i = a.indexOf("--box", i + 1)) boxes.push(a.slice(i + 1, i + 5).map(Number));
  assert.ok(boxes.length > 0, "hide=explorer covers the desktop and the taskbar");
  assert.ok(boxes.some((b) => b[1] === 784 && b[3] === 48), "the taskbar's box");
  assert.ok(!boxes.some((b) => b[0] === 100 && b[1] === 100 && b[2] === 400 && b[3] === 300), "notepad is not covered");
});

test("POST /input on Windows: the xdotool lines go to yoyo-wininput", async () => {
  const before = fake.state.xdotool.length;
  const r = await call("POST", "/input", { type: "click", x: 0.5, y: 0.5 });
  assert.equal(r.status, 200);
  assert.ok(spawned.includes("yoyo-wininput.exe"));
  assert.deepEqual(fake.state.xdotool.slice(before), ["mousemove 640 416", "click 1"]);
});

test("GET /windows on Windows: the program is the app", async () => {
  const r = await call("GET", "/windows");
  assert.equal(r.status, 200);
  assert.deepEqual(r.json.focused, { pid: 20, bundleId: "notepad", name: "notepad" });
  assert.deepEqual(r.json.apps.map((x) => x.bundleId), ["notepad", "explorer"]);
});

test("the clipboard on Windows: file URIs ↔ Windows paths; a password manager's marker conceals", async () => {
  assert.deepEqual(parseUriList("file:///C:/Users/me/a%20b.txt\r\nfile://nas/share/c.txt\r\n", true), ["C:\\Users\\me\\a b.txt", "\\\\nas\\share\\c.txt"]);
  assert.equal(fileUri("C:\\Users\\me\\a b.txt", true), "file:///C:/Users/me/a%20b.txt");
  assert.deepEqual(parseUriList("file:///home/me/a%20b\n", false), ["/home/me/a b"]);
  fake.state.clipCopy({ targets: ["ExcludeClipboardContentFromMonitorProcessing", "text/plain;charset=utf-8"], text: "hunter2" });
  await new Promise((r) => setTimeout(r, 30));
  const c = await call("GET", "/clipboard");
  assert.equal(c.json.kind, "concealed");
  assert.equal(c.json.text, undefined);
});

test("adminPath: a socket file on POSIX, a named pipe per home on Windows", () => {
  assert.equal(adminPath("/var/lib/yoyo", "linux"), "/var/lib/yoyo/admin.sock");
  const a = adminPath("C:\\ProgramData\\yoyo", "win32");
  assert.match(a, /^\\\\\.\\pipe\\yoyo-remote-[0-9a-f]{16}$/);
  assert.equal(adminPath("C:\\ProgramData\\yoyo", "win32"), a, "stable");
  assert.notEqual(adminPath("C:\\other", "win32"), a);
});
