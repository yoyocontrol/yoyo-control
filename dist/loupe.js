import { Drop, DropMotion } from "./drop.js";
/**
 * The loupe over the pointer: the liquid drop (`Drop`) drawn with WebGL2 into a small canvas around it (above the
 * picture, under the pointer), sampling the same picture the page shows (the video's canvas, or a still). The iOS
 * kit's Metal shader, ported to GLSL ES 3.0. Driven by springs every animation frame while it moves; a new video
 * picture redraws it at rest. Without WebGL2 (or with Reduce Transparency / more contrast) it is a plain magnifier: a
 * sharp disc magnified evenly with a solid rim. Reduce Motion: no wobble, a short scale in and out. Never takes input.
 */
const VERTEX = `#version 300 es
void main() {
  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}`;
const FRAGMENT = `#version 300 es
precision highp float;
uniform sampler2D t0;
uniform vec4 box;      // origin (px of the clip), px per device pixel, device height of the canvas
uniform vec4 center;   // center, flat radius (unit space), magnification
uniform vec4 shapeM;   // points -> unit space, row major
uniform vec4 tailU;    // direction (unit space), amount, radius
uniform vec4 picture;  // origin, size
uniform vec4 light;    // refraction, dispersion, presence, dim
uniform vec4 style;    // plain, opacity, outline width, tint
uniform vec4 outline;
uniform vec4 area;
out vec4 color;

vec3 pictureAt(vec2 pt, out float a) {
  vec2 q = (pt - picture.xy) / picture.zw;
  vec2 inside = min(q, 1.0 - q) * picture.zw / box.z;
  a = clamp(min(inside.x, inside.y) + 0.5, 0.0, 1.0);
  return texture(t0, clamp(q, 0.0, 1.0)).rgb;
}

float edgeDistance(vec2 p, vec4 r, out vec2 inward) {
  float l = p.x - r.x, rr = r.x + r.z - p.x, t = p.y - r.y, b = r.y + r.w - p.y;
  float dx = min(l, rr), dy = min(t, b);
  if (dx < dy) { inward = vec2(l < rr ? 1.0 : -1.0, 0.0); return dx; }
  inward = vec2(0.0, t < b ? 1.0 : -1.0);
  return dy;
}

vec3 spectrum(float w) {
  vec3 d = (w - vec3(-0.7, 0.0, 0.7)) / 0.55;
  return exp(-d * d);
}

void main() {
  vec2 frag = vec2(gl_FragCoord.x, box.w - gl_FragCoord.y);
  vec2 p = box.xy + frag * box.z;
  vec2 d = p - center.xy;
  vec2 e = vec2(dot(shapeM.xy, d), dot(shapeM.zw, d));
  float along = dot(e, tailU.xy);
  if (along > 0.0) e -= tailU.xy * along * (tailU.z / (1.0 + tailU.z));
  float drop = length(e);
  vec2 inward;
  float edge = edgeDistance(p, area, inward);
  float a0 = drop - 1.0, b0 = edge / max(tailU.w, 1.0) + ${Drop.MERGE_OFFSET.toFixed(4)};
  const float k = ${Drop.MERGE.toFixed(4)};
  float h = clamp(0.5 + 0.5 * (b0 - a0) / k, 0.0, 1.0);
  float rho = 1.0 + mix(b0, a0, h) - k * h * (1.0 - h);
  float w = max(fwidth(rho), 1e-4);
  float on = clamp(edge / box.z + 0.5, 0.0, 1.0);
  float presence = light.z;
  float shadow = presence * 0.16 * pow(clamp(1.0 - (drop - 1.0) / 0.2, 0.0, 1.0), 2.0);
  on *= style.y;
  if (rho >= 1.0 + w) { color = vec4(0.0, 0.0, 0.0, shadow * on); return; }
  float cover = 1.0 - smoothstep(1.0 - w, 1.0 + w, rho);
  float m = center.w;
  float a;
  vec2 da = p - center.xy;
  if (style.x > 0.5) {
    vec3 c = pictureAt(center.xy + da / m, a) * (1.0 - light.w);
    float rim = smoothstep(1.0 - style.z - w, 1.0 - style.z, rho);
    color = mix(vec4(c, 1.0), vec4(outline.rgb, 1.0), rim) * cover * on;
    return;
  }
  float flat_ = center.z;
  float x = clamp((rho - flat_) / (1.0 - flat_), 0.0, 1.0);
  vec3 c;
  if (x > 0.0) {
    const float kk = 0.97;
    float n0 = 1.0 - sqrt(1.0 - kk * kk);
    float root = sqrt(1.0 - kk * kk * x * x);
    float profile = (1.0 - root) / n0;
    float slope = kk * kk * x / (root * n0);
    float depth = light.x;
    vec2 ray = d / max(drop, 1e-4);
    vec2 dir = normalize(ray);
    float squeeze = 1.0 / m + depth * slope / (1.0 - flat_);
    float spread = 0.5 * squeeze * box.z;
    vec3 sum = vec3(0.0), weight = vec3(0.0);
    for (int i = 0; i < 8; i++) {
      float wl = (float(i) + 0.5) / 4.0 - 1.0;
      vec2 q = center.xy + da / m + ray * depth * profile * (1.0 + light.y * wl) + dir * spread * wl;
      vec3 wt = spectrum(wl);
      sum += pictureAt(q, a) * wt;
      weight += wt;
    }
    c = sum / weight;
  } else {
    c = pictureAt(center.xy + da / m, a);
  }
  c = mix(c, outline.rgb, style.w * 0.6 * smoothstep(0.0, 0.6, x));
  c *= 1.0 - light.w;
  c = mix(c, vec3(1.0), presence * (0.045 + 0.05 * x * x));
  vec2 n = mix(inward, drop > 1e-4 ? e / drop : vec2(0.0), h);
  n = length(n) > 1e-4 ? normalize(n) : vec2(0.0);
  float facing = dot(n, normalize(vec2(-0.55, -0.85)));
  float rimD = (1.0 - rho) / style.z;
  float line = exp(-rimD * rimD * 1.2);
  float hl = presence * (line * (0.22 + 0.7 * pow(abs(facing), 3.0)) + 0.12 * x * x * x * clamp(facing, 0.0, 1.0));
  c = c + (1.0 - c) * clamp(hl, 0.0, 1.0);
  color = (vec4(c, 1.0) * cover + vec4(0.0, 0.0, 0.0, shadow) * (1.0 - cover)) * on;
}`;
function compile(gl) {
    const shader = (type, src) => {
        const s = gl.createShader(type);
        if (!s)
            return null;
        gl.shaderSource(s, src);
        gl.compileShader(s);
        return gl.getShaderParameter(s, gl.COMPILE_STATUS) ? s : null;
    };
    const vs = shader(gl.VERTEX_SHADER, VERTEX), fs = shader(gl.FRAGMENT_SHADER, FRAGMENT);
    const program = gl.createProgram();
    const texture = gl.createTexture();
    if (!vs || !fs || !program || !texture)
        return null;
    gl.attachShader(program, vs);
    gl.attachShader(program, fs);
    gl.linkProgram(program);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS))
        return null;
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    const u = {};
    for (const n of ["t0", "box", "center", "shapeM", "tailU", "picture", "light", "style", "outline", "area"])
        u[n] = gl.getUniformLocation(program, n);
    return { gl, program, texture, u };
}
/** The loupe: a canvas the page puts in the picture's clip (positioned by the loupe itself). */
export class LoupeView {
    canvas;
    g;
    /** The 2D fallback (no WebGL2). */
    ctx2d;
    motion = new DropMotion();
    picture = { x: 0, y: 0, width: 0, height: 0 };
    clip = { x: 0, y: 0, width: 0, height: 0 };
    magnification = 1;
    radius = 76;
    raf = 0;
    last = null;
    source = null;
    uploaded = false;
    /** Over a still picture: dimmed like it. */
    dim = 0;
    /** A held touch armed a drag: the bevel turns the accent colour. */
    tinted = false;
    /** Reduce Motion; Reduce Transparency / more contrast (the plain magnifier). */
    reduceMotion = false;
    plain = false;
    /** The accent (tint) and the text colour (the plain rim), as 0…1 RGB. */
    accent = [0.85, 0.45, 0.33];
    ink = [0.1, 0.1, 0.1];
    /** How much it magnifies at the pointer right now (1 when gone), every frame: the pointer over it grows as much. */
    onMagnification = null;
    reported = 1;
    constructor(doc = document) {
        this.canvas = doc.createElement("canvas");
        this.canvas.className = "loupe";
        this.canvas.setAttribute("aria-hidden", "true");
        const gl = this.canvas.getContext("webgl2", { premultipliedAlpha: true, alpha: true, antialias: false });
        this.g = gl ? compile(gl) : null;
        this.ctx2d = this.g ? null : this.canvas.getContext("2d");
        this.canvas.hidden = true;
    }
    /** WebGL2 draws the drop (false: the plain 2D magnifier). */
    get liquid() {
        return this.g !== null;
    }
    get visible() {
        return this.motion.visible;
    }
    /** The picture to sample changed (a new video picture, a still): re-uploaded at the next draw. */
    setSource(source) {
        this.source = source;
        this.uploaded = false;
        if (this.visible && this.motion.settled)
            this.draw();
    }
    /** Look at `point` (clip px) of `picture` (its frame in the clip; zoomed: bigger than `clip`). */
    aim(point, picture, clip, magnification, radius) {
        this.picture = picture;
        this.clip = clip;
        this.magnification = magnification;
        this.radius = radius;
        this.motion.aim(point, this.reduceMotion);
        this.run();
    }
    setVisible(on, animated = true) {
        if (on === this.visible)
            return;
        this.motion.setVisible(on, animated, this.reduceMotion);
        if (on) {
            this.canvas.hidden = false;
            this.uploaded = false;
        }
        this.run();
    }
    /** The page went away. */
    stop() {
        if (this.raf)
            cancelAnimationFrame(this.raf);
        this.raf = 0;
        this.motion.setVisible(false, false);
        this.hide();
    }
    run() {
        if (!this.raf) {
            this.last = null;
            this.raf = requestAnimationFrame((t) => this.tick(t));
        }
        this.draw();
    }
    tick(t) {
        this.raf = 0;
        const dt = Math.min(this.last === null ? 1 / 120 : (t - this.last) / 1000, 1 / 30);
        this.last = t;
        this.motion.step(dt, this.reduceMotion);
        this.draw();
        if (this.motion.settled) {
            if (!this.visible)
                this.hide();
            return;
        }
        this.raf = requestAnimationFrame((n) => this.tick(n));
    }
    hide() {
        this.canvas.hidden = true;
        this.report(1);
    }
    report(m) {
        if (Math.abs(m - this.reported) <= 0.001)
            return;
        this.reported = m;
        this.onMagnification?.(m);
    }
    draw() {
        if (this.canvas.hidden || !(this.picture.width > 0) || !(this.picture.height > 0))
            return;
        const c = this.clip;
        const area = intersect(this.picture, { x: 0, y: 0, width: c.width, height: c.height });
        const shape = this.motion.shape(this.radius, this.magnification, area);
        this.report(shape.radius > 0.5 ? shape.magnification : 1);
        const scale = globalThis.devicePixelRatio || 1;
        const side = Math.ceil(this.radius * Drop.BOX * scale) / scale;
        const ox = Math.round((shape.center.x - side / 2) * scale) / scale;
        const oy = Math.round((shape.center.y - side / 2) * scale) / scale;
        const px = Math.round(side * scale);
        if (this.canvas.width !== px || this.canvas.height !== px) {
            this.canvas.width = px;
            this.canvas.height = px;
            this.canvas.style.width = `${side}px`;
            this.canvas.style.height = `${side}px`;
        }
        this.canvas.style.transform = `translate3d(${ox}px, ${oy}px, 0)`;
        if (this.g)
            this.drawGl(this.g, shape, ox, oy, scale, px);
        else
            this.draw2d(shape, ox, oy, scale, px);
    }
    drawGl(g, s, ox, oy, scale, px) {
        const { gl, u } = g;
        gl.viewport(0, 0, px, px);
        gl.clearColor(0, 0, 0, 0);
        gl.clear(gl.COLOR_BUFFER_BIT);
        const src = this.source;
        if (!src || !(s.radius > 0.5))
            return;
        gl.useProgram(g.program);
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, g.texture);
        if (!this.uploaded) {
            try {
                gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, src);
                this.uploaded = true;
            }
            catch {
                return;
            }
        }
        const area = s.area ?? this.picture;
        const outline = this.tinted ? this.accent : this.ink;
        gl.uniform1i(u.t0, 0);
        gl.uniform4f(u.box, ox, oy, 1 / scale, px);
        gl.uniform4f(u.center, s.center.x, s.center.y, Drop.FLAT_RADIUS, s.magnification);
        gl.uniform4f(u.shapeM, s.inverse[0], s.inverse[1], s.inverse[2], s.inverse[3]);
        gl.uniform4f(u.tailU, s.tailDirection.x, s.tailDirection.y, s.tail, s.radius);
        gl.uniform4f(u.picture, this.picture.x, this.picture.y, this.picture.width, this.picture.height);
        gl.uniform4f(u.light, s.refraction, Drop.DISPERSION, s.presence, this.dim);
        gl.uniform4f(u.style, this.plain ? 1 : 0, s.opacity, 2 / Math.max(s.radius, 1), this.tinted ? 1 : 0);
        gl.uniform4f(u.outline, outline[0], outline[1], outline[2], 1);
        gl.uniform4f(u.area, area.x, area.y, area.width, area.height);
        gl.drawArrays(gl.TRIANGLES, 0, 3);
    }
    /** Without WebGL2: a round magnifier with a rim (no refraction). */
    draw2d(s, ox, oy, scale, px) {
        const ctx = this.ctx2d;
        const src = this.source;
        if (!ctx)
            return;
        ctx.setTransform(1, 0, 0, 1, 0, 0);
        ctx.clearRect(0, 0, px, px);
        if (!src || !(s.radius > 0.5))
            return;
        ctx.setTransform(scale, 0, 0, scale, -ox * scale, -oy * scale);
        ctx.globalAlpha = s.opacity;
        ctx.save();
        ctx.beginPath();
        ctx.arc(s.center.x, s.center.y, s.radius, 0, Math.PI * 2);
        ctx.clip();
        const m = s.magnification;
        const p = this.picture;
        ctx.translate(s.center.x, s.center.y);
        ctx.scale(m, m);
        ctx.translate(-s.center.x, -s.center.y);
        ctx.drawImage(src, p.x, p.y, p.width, p.height);
        if (this.dim > 0) {
            ctx.fillStyle = `rgba(0,0,0,${this.dim})`;
            ctx.fillRect(p.x, p.y, p.width, p.height);
        }
        ctx.restore();
        const o = this.tinted ? this.accent : this.ink;
        ctx.strokeStyle = `rgb(${o.map((v) => Math.round(v * 255)).join(",")})`;
        ctx.lineWidth = 2;
        ctx.beginPath();
        ctx.arc(s.center.x, s.center.y, s.radius - 1, 0, Math.PI * 2);
        ctx.stroke();
        ctx.globalAlpha = 1;
    }
}
function intersect(a, b) {
    const x = Math.max(a.x, b.x), y = Math.max(a.y, b.y);
    const r = Math.min(a.x + a.width, b.x + b.width), bt = Math.min(a.y + a.height, b.y + b.height);
    return { x, y, width: Math.max(0, r - x), height: Math.max(0, bt - y) };
}
