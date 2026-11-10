// An in-memory computer for the demo page: a drawn desktop (a menu bar, a window with a text field, a dock, a moving
// ball and a clock) encoded to H.264 with WebCodecs and served as the stream's multipart parts, a client-drawn pointer
// that follows the input, silent Opus sound, a clipboard and its events, control and focus. Everything a real
// `ScreenBackend` answers, without a server.

const BOUNDARY = "frame";
const enc = new TextEncoder();

function part(headers, body) {
  let head = `--${BOUNDARY}\r\n`;
  for (const [k, v] of Object.entries(headers)) head += `${k}: ${v}\r\n`;
  head += `Content-Length: ${body.length}\r\n\r\n`;
  const h = enc.encode(head);
  const out = new Uint8Array(h.length + body.length + 2);
  out.set(h);
  out.set(body, h.length);
  out.set([13, 10], h.length + body.length);
  return out;
}

const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

/** The pointer's shape: a black arrow with a white edge, as a cursor part's PNG. */
function arrowPng() {
  const c = document.createElement("canvas");
  c.width = 28;
  c.height = 40;
  const g = c.getContext("2d");
  g.scale(2, 2);
  g.beginPath();
  g.moveTo(1.5, 1.5);
  g.lineTo(1.5, 16.5);
  g.lineTo(5, 13);
  g.lineTo(7.5, 18.5);
  g.lineTo(10, 17.5);
  g.lineTo(7.5, 12);
  g.lineTo(12, 12);
  g.closePath();
  g.lineJoin = "round";
  g.lineWidth = 1.5;
  g.strokeStyle = "#fff";
  g.stroke();
  g.fillStyle = "#000";
  g.fill();
  return c.toDataURL("image/png").split(",")[1];
}

export class FakeComputer {
  constructor(opts = {}) {
    this.display = { id: 1, width: 1512, height: 982, scale: 2, main: true, name: "Built-in Retina Display", kind: "builtin" };
    this.displays = [this.display, { id: 2, width: 1920, height: 1080, scale: 1, main: false, name: "Studio Display", kind: "external" }];
    this.controller = opts.controller ?? "none";
    this.controllerDevice = opts.controllerDevice ?? null;
    this.unavailable = opts.unavailable ?? false;
    this.permission = opts.permission ?? false;
    this.cursor = { x: 0.42, y: 0.46 };
    this.field = { x: 0.3, y: 0.34, w: 0.4, h: 0.06 };
    this.focused = false;
    this.typed = "Hello";
    this.log = [];
    this.clip = { changeCount: 1, kind: "text", text: "npm run build && npm test", preview: "npm run build && npm test", size: 26, at: Date.now() - 120000, source: "mac" };
    this.listeners = new Set();
    this.canvas = document.createElement("canvas");
    this.canvas.width = this.display.width;
    this.canvas.height = this.display.height;
    this.ctx = this.canvas.getContext("2d");
    this.shape = arrowPng();
    this.t0 = performance.now();
    this.draw();
  }

  status() {
    return {
      available: !this.unavailable,
      reason: this.unavailable ? "The screen helper can’t start" : null,
      screenRecording: !this.permission,
      accessibility: true,
      displays: this.displays,
      controller: this.controller,
      controllerSince: this.controller === "none" ? null : Date.now(),
      controllerDevice: this.controllerDevice,
      states: [{ display: 1, main: true, phase: "ready", since: Date.now() }],
      platform: "mac",
      features: { clipboard: true, audio: true, cursor: true, focus: true },
    };
  }

  post(event) {
    for (const fn of this.listeners) fn(event);
  }

  /** The drawn desktop at `t` ms. */
  draw() {
    const g = this.ctx, W = this.canvas.width, H = this.canvas.height;
    const t = (performance.now() - this.t0) / 1000;
    const bg = g.createLinearGradient(0, 0, W, H);
    bg.addColorStop(0, "#3a2f6b");
    bg.addColorStop(0.55, "#b4577a");
    bg.addColorStop(1, "#f1a26b");
    g.fillStyle = bg;
    g.fillRect(0, 0, W, H);
    // a moving ball (motion to watch)
    const bx = W * (0.5 + 0.38 * Math.sin(t * 0.9)), by = H * (0.78 + 0.08 * Math.cos(t * 1.7));
    g.fillStyle = "rgba(255,255,255,0.85)";
    g.beginPath();
    g.arc(bx, by, 26, 0, Math.PI * 2);
    g.fill();
    // the menu bar
    g.fillStyle = "rgba(255,255,255,0.72)";
    g.fillRect(0, 0, W, 26);
    g.fillStyle = "#111";
    g.font = "600 14px -apple-system, Helvetica, sans-serif";
    g.fillText("Finder", 34, 18);
    g.font = "14px -apple-system, Helvetica, sans-serif";
    ["File", "Edit", "View", "Go", "Window", "Help"].forEach((m, i) => g.fillText(m, 100 + i * 56, 18));
    const now = new Date();
    g.fillText(now.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" }), W - 96, 18);
    // a window
    const wx = W * 0.22, wy = H * 0.16, ww = W * 0.56, wh = H * 0.5;
    g.fillStyle = "rgba(0,0,0,0.25)";
    g.fillRect(wx + 6, wy + 10, ww, wh);
    g.fillStyle = "#f6f6f6";
    g.fillRect(wx, wy, ww, wh);
    g.fillStyle = "#e4e4e4";
    g.fillRect(wx, wy, ww, 34);
    for (const [i, c] of ["#ff5f57", "#febc2e", "#28c840"].entries()) {
      g.fillStyle = c;
      g.beginPath();
      g.arc(wx + 20 + i * 20, wy + 17, 6, 0, Math.PI * 2);
      g.fill();
    }
    g.fillStyle = "#333";
    g.font = "600 13px -apple-system, Helvetica, sans-serif";
    g.fillText("Notes — uu demo", wx + ww / 2 - 52, wy + 22);
    // the text field
    const f = this.field;
    g.fillStyle = "#fff";
    g.strokeStyle = this.focused ? "#3b82f6" : "#c8c8c8";
    g.lineWidth = this.focused ? 3 : 1;
    g.fillRect(f.x * W, f.y * H, f.w * W, f.h * H);
    g.strokeRect(f.x * W, f.y * H, f.w * W, f.h * H);
    g.fillStyle = "#111";
    g.font = "20px -apple-system, Helvetica, sans-serif";
    const caret = this.focused && Math.floor(t * 2) % 2 === 0 ? "|" : "";
    g.fillText(this.typed + caret, f.x * W + 12, f.y * H + f.h * H * 0.68);
    g.fillStyle = "#555";
    g.font = "16px -apple-system, Helvetica, sans-serif";
    const lines = ["Click the field above and type: the keyboard comes up by itself.", "Two fingers scroll, three fingers drag, a held touch selects.", "Pinch the picture to zoom; double-tap it to fit again."];
    lines.forEach((l, i) => g.fillText(l, wx + 28, wy + wh * 0.5 + i * 30));
    // the dock
    g.fillStyle = "rgba(255,255,255,0.35)";
    const dw = W * 0.42, dx = (W - dw) / 2, dy = H - 72;
    g.beginPath();
    g.roundRect(dx, dy, dw, 62, 18);
    g.fill();
    ["#4f8ef7", "#f7b84f", "#5fd068", "#e2574c", "#9b6cf2", "#3fc2c9", "#f28dc4"].forEach((c, i) => {
      g.fillStyle = c;
      g.beginPath();
      g.roundRect(dx + 16 + i * ((dw - 32) / 7), dy + 8, 46, 46, 11);
      g.fill();
    });
  }

  /** One input, as the server would apply it. */
  input(i) {
    this.log.push(i.type);
    if (typeof i.x === "number" && typeof i.y === "number") this.cursor = { x: i.x, y: i.y };
    if (i.type === "click" || i.type === "doubleClick") {
      const f = this.field;
      this.focused = i.x >= f.x && i.x <= f.x + f.w && i.y >= f.y && i.y <= f.y + f.h;
    }
    if (i.type === "type" && this.focused) this.typed += i.text;
    if (i.type === "key" && this.focused && i.key === "delete") this.typed = this.typed.slice(0, -1);
    this.cursorMoved?.();
  }
}

/** The fake computer as a `ScreenBackend`. */
export function fakeBackend(pc) {
  return {
    cacheScope: "demo",
    platformHint: "mac",
    async status() {
      await new Promise((r) => setTimeout(r, 60));
      return pc.status();
    },
    transport() {
      return {
        fetch: async (path, init) => {
          const route = path.split("?", 1)[0];
          if (route === "/stream") return stream(pc, init);
          if (route === "/stream/ack") {
            const a = JSON.parse(init.body);
            if (a.keyframe) pc.wantKey = true;
            return json(200, { ok: true, net: { grade: "good", rttMs: { min: 4, p50: 6, p90: 9 }, reasons: [] } });
          }
          if (route === "/audio") return audio(init);
          if (route === "/frame") return new Response(await new Promise((r) => pc.canvas.toBlob(r, "image/jpeg", 0.7)), { headers: { "content-type": "image/jpeg" } });
          return json(404, { error: "not here" });
        },
      };
    },
    async input(i) {
      if (pc.controller !== "user" || pc.controllerDevice?.id === "someone-else") throw Object.assign(new Error("not the controller"), { status: 409 });
      pc.input(i);
    },
    async setControl(controller, _route, device) {
      pc.controller = controller;
      pc.controllerDevice = controller === "user" ? device : null;
      pc.post({ type: "screen.control", controller, controllerSince: Date.now(), controllerDevice: pc.controllerDevice });
      return pc.status();
    },
    async focus() {
      return { editable: pc.focused };
    },
    async requestPermissions() {
      pc.permission = false;
      return pc.status();
    },
    async frame() {
      return new Promise((r) => pc.canvas.toBlob(r, "image/jpeg", 0.7));
    },
    async clipboard() {
      return { available: true, item: { ...pc.clip } };
    },
    async clipboardImage() {
      return new Promise((r) => pc.canvas.toBlob(r, "image/png"));
    },
    async putClipboard(put) {
      const n = pc.clip.changeCount + 1;
      if ("text" in put) pc.clip = { changeCount: n, kind: "text", text: put.text, preview: put.text.slice(0, 160), size: put.text.length, at: Date.now(), source: "phone" };
      else pc.clip = { changeCount: n, kind: "files", files: put.files.map((f) => ({ name: f.name, size: f.size })), preview: put.files.map((f) => f.name).join(", "), at: Date.now(), source: "phone" };
      const { text, ...summary } = pc.clip;
      pc.post({ type: "clipboard.changed", available: true, item: summary });
      return { available: true, item: { ...pc.clip }, saved: "files" in put ? put.files.map((f) => ({ name: f.name, path: `/Users/demo/Downloads/${f.name}`, size: f.size })) : [] };
    },
    sendsClipboardFiles: true,
    events() {
      const queue = [];
      let wake = null;
      const fn = (e) => {
        queue.push(e);
        wake?.();
      };
      pc.listeners.add(fn);
      return {
        [Symbol.asyncIterator]() {
          return {
            async next() {
              while (!queue.length) await new Promise((r) => (wake = r));
              return { value: queue.shift(), done: false };
            },
            async return() {
              pc.listeners.delete(fn);
              wake?.();
              return { value: undefined, done: true };
            },
          };
        },
      };
    },
  };
}

/** The stream: the drawn desktop encoded at 30 fps, a cursor part on every pointer move. */
function stream(pc, init) {
  if (typeof VideoEncoder === "undefined") return Promise.resolve(json(501, { error: "no VideoEncoder here" }));
  let seq = 0;
  let frames = 0;
  let timer = 0;
  let encoder;
  const body = new ReadableStream({
    start(c) {
      const cursor = (withShape) => {
        const p = { x: pc.cursor.x, y: pc.cursor.y, visible: true, shapeId: 1000001 };
        if (withShape) p.shape = { id: 1000001, png: pc.shape, hotX: 1.5 / 1512, hotY: 1.5 / 982, width: 14 / 1512, height: 20 / 982 };
        c.enqueue(part({ "Content-Type": "application/vnd.yoyo-control.cursor+json", "X-Frame-Seq": seq++ }, enc.encode(JSON.stringify(p))));
      };
      cursor(true);
      c.enqueue(part({ "Content-Type": "application/vnd.yoyo-control.status+json", "X-Frame-Seq": seq++ }, enc.encode(JSON.stringify({ display: 1, main: true, phase: "ready", since: Date.now() }))));
      pc.cursorMoved = () => cursor(false);
      encoder = new VideoEncoder({
        output: (chunk) => {
          const data = new Uint8Array(chunk.byteLength);
          chunk.copyTo(data);
          try {
            c.enqueue(part({ "Content-Type": "video/h264", "X-Frame-Seq": seq++, "X-Frame-Kind": chunk.type, "X-Frame-Time": Date.now(), "X-Frame-Width": 1512, "X-Frame-Height": 982 }, data));
          } catch {
            /* closed */
          }
        },
        error: (e) => c.error(e),
      });
      encoder.configure({ codec: "avc1.42002a", width: 1512, height: 982, bitrate: 3_000_000, framerate: 30, latencyMode: "realtime", avc: { format: "annexb" } });
      timer = setInterval(() => {
        pc.draw();
        const f = new VideoFrame(pc.canvas, { timestamp: frames * 33_333 });
        encoder.encode(f, { keyFrame: frames % 90 === 0 || pc.wantKey });
        pc.wantKey = false;
        f.close();
        frames++;
      }, 33);
    },
    cancel() {
      clearInterval(timer);
      pc.cursorMoved = null;
      try {
        encoder?.close();
      } catch {
        /* closed */
      }
    },
  });
  init.signal?.addEventListener("abort", () => clearInterval(timer));
  return Promise.resolve(new Response(body, { status: 200, headers: { "content-type": `multipart/x-mixed-replace; boundary=${BOUNDARY}`, "x-stream-codec": "h264" } }));
}

/** The sound: silent Opus packets (20 ms), so the speaker button has something to play. */
async function audio(init) {
  if (typeof AudioEncoder === "undefined") return json(404, { error: "no sound" });
  const config = { codec: "opus", sampleRate: 48000, numberOfChannels: 2, bitrate: 32000 };
  const ok = await AudioEncoder.isConfigSupported(config).catch(() => ({ supported: false }));
  if (!ok.supported) return json(404, { error: "no sound" });
  let timer = 0;
  let n = 0;
  const body = new ReadableStream({
    start(c) {
      const encoder = new AudioEncoder({
        output: (chunk) => {
          const d = new Uint8Array(chunk.byteLength);
          chunk.copyTo(d);
          try {
            c.enqueue(part({ "Content-Type": "audio/opus", "X-Audio-Seq": n++, "X-Audio-Time": Date.now() }, d));
          } catch {
            /* closed */
          }
        },
        error: () => {},
      });
      encoder.configure(config);
      let ts = 0;
      timer = setInterval(() => {
        const data = new Float32Array(960 * 2);
        encoder.encode(new AudioData({ format: "f32-planar", sampleRate: 48000, numberOfFrames: 960, numberOfChannels: 2, timestamp: ts, data }));
        ts += 20_000;
      }, 20);
      init.signal?.addEventListener("abort", () => clearInterval(timer));
    },
    cancel() {
      clearInterval(timer);
    },
  });
  return new Response(body, { headers: { "content-type": `multipart/x-mixed-replace; boundary=${BOUNDARY}`, "x-audio-codec": "opus", "x-audio-rate": "48000", "x-audio-channels": "2" } });
}
